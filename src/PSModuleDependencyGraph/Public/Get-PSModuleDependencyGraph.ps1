function Get-PSModuleDependencyGraph {
    <#
    .SYNOPSIS
        Builds a node/edge dependency model for a module with roots, leaves, and unresolved targets.
    .DESCRIPTION
        Nodes are module-defined functions, classes, and enums. Edges are internal command
        references (function -> function). Call targets not defined in the module appear under
        Unresolved rather than being dropped.

        Roots have no inbound internal edge (entry points or dead code).
        Leaves have no outbound internal edge.

        A node's identity is its qualified path - kind, module-relative file and
        name - not its bare name. Two functions called Get-TargetResource in two
        files are two nodes, and neither can overwrite the other. See
        New-GraphNodeId and Resolve-GraphNodeCandidate for what that costs at
        the point a call has to be pointed at one of them.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(ParameterSetName = 'ByName')]
        [version] $RequiredVersion,

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'ByModuleInfo', ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.PSModuleInfo] $ModuleInfo
    )

    process {
        $target = Resolve-BoundParameter -Name $Name -RequiredVersion $RequiredVersion -Path $Path -ModuleInfo $ModuleInfo -ParameterSetName $PSCmdlet.ParameterSetName

        $inspectPath = if ($target.ManifestPath) {
            $target.ManifestPath
        }
        elseif ($target.IsSingleFile) {
            $target.RootModulePath
        }
        else {
            $target.ModuleBase
        }
        $functions = @(Get-PSModuleFunction -Path $inspectPath)
        $classes = @(Get-PSModuleClass -Path $inspectPath)
        $enums = @(Get-PSModuleEnum -Path $inspectPath)
        $references = @(Get-PSModuleCommandReference -Path $inspectPath)
        $usings = @(Get-PSModuleUsingStatement -Path $inspectPath)
        $assemblies = @(Get-PSModuleAssembly -Path $inspectPath)
        $manifest = Get-PSModuleManifest -Path $inspectPath

        $moduleBase = $target.ModuleBase

        $nodes = [System.Collections.Generic.List[object]]::new()

        # name(lower) -> every definition carrying that name, in parse order.
        # A dictionary of name -> ONE id is what made 144 of SqlServerDsc's 496
        # nodes unaddressable and then reported them as roots.
        $nodeIndex = @{}

        function Add-NodeCandidate {
            param([string] $NodeName, [string] $Id, [string] $NodePath)

            $key = $NodeName.ToLowerInvariant()
            if (-not $nodeIndex.ContainsKey($key)) {
                $nodeIndex[$key] = [System.Collections.Generic.List[object]]::new()
            }
            $nodeIndex[$key].Add([pscustomobject]@{ Id = $Id; Path = $NodePath })
        }

        foreach ($fn in $functions) {
            $id = New-GraphNodeId -Kind 'function' -ModuleBase $moduleBase -Path $fn.Path -Name $fn.Name
            $nodes.Add([pscustomobject]@{
                    PSTypeName   = 'PSModuleDependencyGraph.GraphNode'
                    Id           = $id
                    Name         = $fn.Name
                    Kind         = 'Function'
                    IsExported   = $fn.IsExported
                    ExportState  = $fn.ExportState
                    ExportSource = $fn.ExportSource
                    Path         = $fn.Path
                    StartLine    = $fn.StartLine
                })
            Add-NodeCandidate -NodeName $fn.Name -Id $id -NodePath $fn.Path
        }

        foreach ($c in $classes) {
            $id = New-GraphNodeId -Kind 'class' -ModuleBase $moduleBase -Path $c.Path -Name $c.Name
            $nodes.Add([pscustomobject]@{
                    PSTypeName = 'PSModuleDependencyGraph.GraphNode'
                    Id         = $id
                    Name       = $c.Name
                    Kind       = 'Class'
                    IsExported = $false
                    Path       = $c.Path
                    StartLine  = $c.StartLine
                })
            Add-NodeCandidate -NodeName $c.Name -Id $id -NodePath $c.Path
        }

        foreach ($e in $enums) {
            $id = New-GraphNodeId -Kind 'enum' -ModuleBase $moduleBase -Path $e.Path -Name $e.Name
            $nodes.Add([pscustomobject]@{
                    PSTypeName = 'PSModuleDependencyGraph.GraphNode'
                    Id         = $id
                    Name       = $e.Name
                    Kind       = 'Enum'
                    IsExported = $false
                    Path       = $e.Path
                    StartLine  = $e.StartLine
                })
            Add-NodeCandidate -NodeName $e.Name -Id $id -NodePath $e.Path
        }

        $edges = [System.Collections.Generic.List[object]]::new()
        $unresolved = [System.Collections.Generic.List[object]]::new()

        # ORDINAL. A node id is opaque and unique within the payload - see
        # New-GraphNodeId - and PowerShell hashtable keys are case-insensitive,
        # so @{} here deduplicated two DIFFERENT edges into one and dropped the
        # second.
        $edgeSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $unresolvedSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        # One synthetic node per file with top-level calls, not one per module.
        # A single 'script:toplevel' node is the same name collision in the one
        # place it is guaranteed: every file's top level shared it, and the node
        # reported the path of whichever file was parsed first.
        $scriptNodes = @{}
        function Get-ScriptNodeId {
            param([string] $FilePath, $FirstLine)

            $key = $FilePath.ToLowerInvariant()
            if (-not $scriptNodes.ContainsKey($key)) {
                $id = New-GraphNodeId -Kind 'script' -ModuleBase $moduleBase -Path $FilePath -Name '<script>'
                $scriptNodes[$key] = $id
                $nodes.Add([pscustomobject]@{
                        PSTypeName = 'PSModuleDependencyGraph.GraphNode'
                        Id         = $id
                        Name       = '<script>'
                        Kind       = 'Script'
                        IsExported = $false
                        Path       = $FilePath
                        StartLine  = $FirstLine
                    })
            }
            return $scriptNodes[$key]
        }

        # Built-in / language keywords to ignore as unresolved noise
        $ignoreCommands = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        @(
            'if', 'else', 'elseif', 'foreach', 'for', 'while', 'do', 'switch', 'break', 'continue',
            'return', 'exit', 'throw', 'try', 'catch', 'finally', 'trap', 'data', 'dynamicparam',
            'begin', 'process', 'end', 'clean', 'param', 'filter', 'function', 'workflow', 'class',
            'enum', 'using', 'configuration', 'parallel', 'sequence', 'inlinescript'
        ) | ForEach-Object { [void]$ignoreCommands.Add($_) }

        foreach ($ref in $references) {
            $fromName = $ref.EnclosingFunction
            if (-not $fromName) {
                $fromId = Get-ScriptNodeId -FilePath $ref.Path -FirstLine $ref.StartLine
            }
            else {
                # The enclosing definition is the one in this file. Where the
                # same name is defined elsewhere too, that is not a guess.
                $fromCandidates = Resolve-GraphNodeCandidate -Index $nodeIndex -Name $fromName -CallerPath $ref.Path
                if (-not $fromCandidates.Nodes) {
                    continue
                }
                $fromId = $fromCandidates.Nodes[0].Id
            }

            $toName = $ref.UnqualifiedName
            if (-not $toName -or $ignoreCommands.Contains($toName)) {
                continue
            }

            # Skip self-defining patterns and operators
            if ($toName -match '^[\$\.\@]') {
                continue
            }

            $to = Resolve-GraphNodeCandidate -Index $nodeIndex -Name $toName -CallerPath $ref.Path
            if ($to.Nodes) {
                # Ambiguous means several definitions share the name and none is
                # in the calling file. Which one runs depends on load order,
                # which is not in the source; an edge to each says so, and a
                # single arbitrary edge would say something false about the rest.
                foreach ($candidate in $to.Nodes) {
                    if (-not $edgeSeen.Add("$fromId->$($candidate.Id)")) { continue }
                    $edges.Add([pscustomobject]@{
                            PSTypeName       = 'PSModuleDependencyGraph.GraphEdge'
                            Source           = $fromId
                            Target           = $candidate.Id
                            SourceName       = if ($fromName) { $fromName } else { '<script>' }
                            TargetName       = $toName
                            Kind             = 'CommandReference'
                            Resolution       = $to.Resolution
                            TargetCandidates = $to.CandidateCount
                            Path             = $ref.Path
                            StartLine        = $ref.StartLine
                        })
                }
            }
            else {
                # The command name folds, because PowerShell resolves command
                # names case-insensitively and two spellings of an unresolved
                # call are one missing command. The SOURCE id does not: it is an
                # identity, and folding it drops a real unresolved reference.
                if ($unresolvedSeen.Add("$fromId=>" + $toName.ToLowerInvariant())) {
                    $unresolved.Add([pscustomobject]@{
                            PSTypeName      = 'PSModuleDependencyGraph.UnresolvedReference'
                            Source          = $fromId
                            SourceName      = if ($fromName) { $fromName } else { '<script>' }
                            TargetName      = $toName
                            QualifiedName   = $ref.CommandName
                            ModuleQualifier = $ref.ModuleQualifier
                            Path            = $ref.Path
                            StartLine       = $ref.StartLine
                        })
                }
            }
        }

        # Class inheritance edges
        foreach ($c in $classes) {
            $fromId = New-GraphNodeId -Kind 'class' -ModuleBase $moduleBase -Path $c.Path -Name $c.Name
            foreach ($base in @($c.BaseTypes) + @($c.Interfaces)) {
                if (-not $base) { continue }
                $simple = ($base -split '\.')[-1]
                $to = Resolve-GraphNodeCandidate -Index $nodeIndex -Name $simple -CallerPath $c.Path
                foreach ($candidate in $to.Nodes) {
                    if (-not $edgeSeen.Add("$fromId->$($candidate.Id):inherits")) { continue }
                    $edges.Add([pscustomobject]@{
                            PSTypeName       = 'PSModuleDependencyGraph.GraphEdge'
                            Source           = $fromId
                            Target           = $candidate.Id
                            SourceName       = $c.Name
                            TargetName       = $simple
                            Kind             = 'Inherits'
                            Resolution       = $to.Resolution
                            TargetCandidates = $to.CandidateCount
                            Path             = $c.Path
                            StartLine        = $c.StartLine
                        })
                }
            }
        }

        # RequiredModules as external dependency nodes (unresolved module-level)
        foreach ($rm in @($manifest.RequiredModules)) {
            if (-not $rm -or -not $rm.Name) { continue }
            $unresolved.Add([pscustomobject]@{
                    PSTypeName      = 'PSModuleDependencyGraph.UnresolvedReference'
                    Source          = 'module:manifest'
                    SourceName      = $target.Name
                    TargetName      = $rm.Name
                    QualifiedName   = $rm.Name
                    ModuleQualifier = $null
                    Path            = $manifest.ManifestPath
                    StartLine       = $null
                    Kind            = 'RequiredModule'
                })
        }

        foreach ($u in $usings) {
            if ($u.Kind -eq 'Module' -and $u.Name) {
                $unresolved.Add([pscustomobject]@{
                        PSTypeName      = 'PSModuleDependencyGraph.UnresolvedReference'
                        Source          = 'using:module'
                        SourceName      = '<using>'
                        TargetName      = $u.Name
                        QualifiedName   = $u.Name
                        ModuleQualifier = $null
                        Path            = $u.Path
                        StartLine       = $u.StartLine
                        Kind            = 'UsingModule'
                    })
            }
        }

        # Compute roots / leaves based on internal edges only.
        #
        # ORDINAL, for the reason $edgeSeen is. Keyed on @{}, two node ids
        # differing only in case shared one counter, so each reported the
        # other's degree and one of them could be called a root while something
        # called it.
        $inbound = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
        $outbound = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
        foreach ($n in $nodes) {
            $inbound[$n.Id] = 0
            $outbound[$n.Id] = 0
        }
        foreach ($e in $edges) {
            if ($outbound.ContainsKey($e.Source)) { $outbound[$e.Source]++ }
            if ($inbound.ContainsKey($e.Target)) { $inbound[$e.Target]++ }
        }

        $roots = @($nodes | Where-Object { $inbound[$_.Id] -eq 0 })
        $leaves = @($nodes | Where-Object { $outbound[$_.Id] -eq 0 })

        # A name carried by more than one definition. Reported rather than
        # resolved away: it is the reason an edge can be ambiguous, and a reader
        # looking at a surprising root needs to be able to find it.
        $ambiguousNames = @(
            $nodeIndex.GetEnumerator() |
                Where-Object { $_.Value.Count -gt 1 } |
                ForEach-Object { $_.Key } |
                Sort-Object
        )

        [pscustomobject]@{
            PSTypeName      = 'PSModuleDependencyGraph.DependencyGraph'
            ModuleName      = $target.Name
            ModuleVersion   = $target.Version
            ModuleBase      = $target.ModuleBase
            ManifestPath    = $target.ManifestPath
            Nodes           = @($nodes)
            Edges           = @($edges)
            Roots           = @($roots)
            Leaves          = @($leaves)
            Unresolved      = @($unresolved)
            AmbiguousNames  = $ambiguousNames
            Functions       = $functions
            Classes         = $classes
            Enums           = $enums
            Assemblies      = $assemblies
            UsingStatements = $usings
            Manifest        = $manifest
            Stats           = [pscustomobject]@{
                NodeCount          = $nodes.Count
                EdgeCount          = $edges.Count
                RootCount          = $roots.Count
                LeafCount          = $leaves.Count
                UnresolvedCount    = $unresolved.Count
                FunctionCount      = $functions.Count
                ClassCount         = $classes.Count
                EnumCount          = $enums.Count
                AmbiguousNameCount = $ambiguousNames.Count
                AmbiguousEdgeCount = @($edges | Where-Object { $_.Resolution -eq 'Ambiguous' }).Count
            }
        }
    }
}
