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
    .PARAMETER Name
        Name of a module on PSModulePath or already loaded. The newest version is used
        unless -RequiredVersion says otherwise.
    .PARAMETER RequiredVersion
        With -Name, the exact version to inspect.
    .PARAMETER Path
        A module folder, a .psd1, a .psm1, or a .ps1 script. A .ps1 or .psm1 with no
        manifest next to it is inspected on its own.
    .PARAMETER ModuleInfo
        A module from Get-Module. Only its path is used; nothing is imported.
    .PARAMETER ShowInBrowser
        Also save the graph as $env:TEMP\PSModuleDependencyGraph\<ModuleName>.html and open
        it in the default browser. The graph is still returned.
    .PARAMETER ShowInVSCode
        Also save the graph as $env:TEMP\PSModuleDependencyGraph\<ModuleName>.html and open
        it in VS Code with the 'code' command. VS Code shows HTML as source unless a
        preview extension, such as Live Preview, is installed. The graph is still returned.
    .EXAMPLE
        Get-PSModuleDependencyGraph -Name PSReadLine

        Graphs an installed module by name.
    .EXAMPLE
        Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport -ShowInBrowser

        Graphs a module folder and opens the result in the default browser.
    .EXAMPLE
        Get-Module -ListAvailable Pester | Select-Object -First 1 | Get-PSModuleDependencyGraph

        Graphs a module passed from Get-Module.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType('ModuleDependencyGraph')]
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
        [System.Management.Automation.PSModuleInfo] $ModuleInfo,

        [Parameter()]
        [switch] $ShowInBrowser,

        [Parameter()]
        [switch] $ShowInVSCode
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
            $nodes.Add((New-GraphNode -Id $id -Name $fn.Name -Kind 'Function' -Path $fn.Path -StartLine $fn.StartLine -EndLine $fn.EndLine -Function $fn))
            Add-NodeCandidate -NodeName $fn.Name -Id $id -NodePath $fn.Path
        }

        foreach ($c in $classes) {
            $id = New-GraphNodeId -Kind 'class' -ModuleBase $moduleBase -Path $c.Path -Name $c.Name
            $nodes.Add((New-GraphNode -Id $id -Name $c.Name -Kind 'Class' -Path $c.Path -StartLine $c.StartLine -EndLine $c.EndLine))
            Add-NodeCandidate -NodeName $c.Name -Id $id -NodePath $c.Path
        }

        foreach ($e in $enums) {
            $id = New-GraphNodeId -Kind 'enum' -ModuleBase $moduleBase -Path $e.Path -Name $e.Name
            $nodes.Add((New-GraphNode -Id $id -Name $e.Name -Kind 'Enum' -Path $e.Path -StartLine $e.StartLine -EndLine $e.EndLine))
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
                # A file's top level has no single extent: StartLine is its first
                # call, and EndLine is left empty.
                $nodes.Add((New-GraphNode -Id $id -Name '<script>' -Kind 'Script' -Path $FilePath -StartLine $FirstLine))
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

        # Each node lists, by name, what it calls and what calls it. A function
        # nothing calls and nothing exports is dangling: dead code, or an entry
        # point the module forgot to export. Calls a function makes to itself do
        # not count as use.
        $nodeById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($n in $nodes) { $nodeById[$n.Id] = $n }

        # Id -> names, built in one pass over the edges rather than a scan per node.
        $newIndex = { [System.Collections.Generic.Dictionary[string, System.Collections.Generic.SortedSet[string]]]::new([System.StringComparer]::Ordinal) }
        $calls = & $newIndex
        $callers = & $newIndex
        $unresolvedCalls = & $newIndex
        $addTo = {
            param($Index, [string] $Key, [string] $Value)
            if (-not $Index.ContainsKey($Key)) {
                $Index[$Key] = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$Index[$Key].Add($Value)
        }
        foreach ($e in $edges) {
            & $addTo $calls $e.Source $nodeById[$e.Target].Name
            if ($e.Source -cne $e.Target) {
                & $addTo $callers $e.Target $nodeById[$e.Source].Name
            }
        }
        foreach ($u in $unresolved) {
            & $addTo $unresolvedCalls ([string]$u.Source) $u.TargetName
        }

        foreach ($n in $nodes) {
            if ($calls.ContainsKey($n.Id)) { $n.DependsOn = [string[]]@($calls[$n.Id]) }
            if ($callers.ContainsKey($n.Id)) { $n.UsedBy = [string[]]@($callers[$n.Id]) }
            if ($unresolvedCalls.ContainsKey($n.Id)) { $n.UnresolvedCalls = [string[]]@($unresolvedCalls[$n.Id]) }
            $n.IsDangling = $n.Kind -eq 'Function' -and -not $n.IsExported -and -not $callers.ContainsKey($n.Id)
        }
        $dangling = @($nodes | Where-Object IsDangling)

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

        $graph = [ModuleDependencyGraph]@{
            ModuleName      = $target.Name
            ModuleVersion   = $target.Version
            ModuleBase      = $target.ModuleBase
            ManifestPath    = $target.ManifestPath
            Nodes           = @($nodes)
            Edges           = @($edges)
            Roots           = @($roots)
            Leaves          = @($leaves)
            Dangling        = $dangling
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
                DanglingCount      = $dangling.Count
                UnresolvedCount    = $unresolved.Count
                FunctionCount      = $functions.Count
                ClassCount         = $classes.Count
                EnumCount          = $enums.Count
                AmbiguousNameCount = $ambiguousNames.Count
                AmbiguousEdgeCount = @($edges | Where-Object { $_.Resolution -eq 'Ambiguous' }).Count
            }
        }

        if ($ShowInBrowser -or $ShowInVSCode) {
            $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
            $reportPath = Join-Path (Join-Path $tempRoot 'PSModuleDependencyGraph') "$($graph.ModuleName).html"
            $report = $graph | Save-PSModuleDependencyGraphHtml -Path $reportPath
            if ($ShowInBrowser) { Show-GraphHtml -Path $report.FullName -In Browser }
            if ($ShowInVSCode) { Show-GraphHtml -Path $report.FullName -In VSCode }
        }

        $graph
    }
}
