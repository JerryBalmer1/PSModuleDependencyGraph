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
        $externalReferences = [System.Collections.Generic.List[object]]::new()

        # ORDINAL. A node id is opaque and unique within the payload - see
        # New-GraphNodeId - and PowerShell hashtable keys are case-insensitive,
        # so @{} here deduplicated two DIFFERENT edges into one and dropped the
        # second.
        $edgeSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $externalSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        function Add-GraphEdge {
            param([string] $Source, [string] $Target, [string] $SourceName, [string] $TargetName, [string] $Kind,
                [string] $Resolution, $TargetCandidates, [string] $EdgePath, $Line, $IsDeclared = $null)

            if (-not $edgeSeen.Add("$Source->$Target|$Kind")) { return }
            $edges.Add([pscustomobject]@{
                    PSTypeName       = 'PSModuleDependencyGraph.GraphEdge'
                    Source           = $Source
                    Target           = $Target
                    SourceName       = $SourceName
                    TargetName       = $TargetName
                    Kind             = $Kind
                    Resolution       = $Resolution
                    TargetCandidates = $TargetCandidates
                    IsDeclared       = $IsDeclared
                    Path             = $EdgePath
                    StartLine        = $Line
                })
        }

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

        # Language keywords the reference walk can surface; none is a command.
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

            $sourceName = if ($fromName) { $fromName } else { '<script>' }
            $to = Resolve-GraphNodeCandidate -Index $nodeIndex -Name $toName -CallerPath $ref.Path
            if ($to.Nodes -and -not $ref.ModuleQualifier) {
                # Ambiguous means several definitions share the name and none is
                # in the calling file. Which one runs depends on load order,
                # which is not in the source; an edge to each says so, and a
                # single arbitrary edge would say something false about the rest.
                foreach ($candidate in $to.Nodes) {
                    Add-GraphEdge -Source $fromId -Target $candidate.Id -SourceName $sourceName -TargetName $toName `
                        -Kind 'CommandReference' -Resolution $to.Resolution -TargetCandidates $to.CandidateCount -EdgePath $ref.Path -Line $ref.StartLine
                }
            }
            else {
                # A command from outside the module. The command name folds,
                # because PowerShell resolves command names case-insensitively;
                # the SOURCE id does not, because it is an identity.
                if ($externalSeen.Add("$fromId=>" + $toName.ToLowerInvariant())) {
                    $externalReferences.Add([pscustomobject]@{
                            PSTypeName      = 'PSModuleDependencyGraph.ExternalReference'
                            Source          = $fromId
                            SourceName      = $sourceName
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
                    Add-GraphEdge -Source $fromId -Target $candidate.Id -SourceName $c.Name -TargetName $simple `
                        -Kind 'Inherits' -Resolution $to.Resolution -TargetCandidates $to.CandidateCount -EdgePath $c.Path -Line $c.StartLine
                }
            }
        }

        # A function that outputs one of the module's classes or enums, whether
        # its [OutputType()] says so or type inference finds it in the body.
        $moduleTypeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in @($classes) + @($enums)) { [void]$moduleTypeNames.Add($t.Name) }
        $functionNodes = @($nodes | Where-Object Kind -EQ 'Function')
        foreach ($fnNode in $functionNodes) {
            $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($t in $fnNode.OutputType) { [void]$declared.Add(($t -split '\.')[-1]) }

            $fnNode.UndeclaredOutputType = [string[]]@($fnNode.InferredOutputType | Where-Object { -not $declared.Contains(($_ -split '\.')[-1]) })

            $outputs = @($fnNode.OutputType) + @($fnNode.InferredOutputType) |
                ForEach-Object { ($_ -split '\.')[-1] } |
                Where-Object { $moduleTypeNames.Contains($_) } |
                Sort-Object -Unique
            foreach ($typeName in $outputs) {
                $to = Resolve-GraphNodeCandidate -Index $nodeIndex -Name $typeName -CallerPath $fnNode.Path
                foreach ($candidate in $to.Nodes) {
                    Add-GraphEdge -Source $fnNode.Id -Target $candidate.Id -SourceName $fnNode.Name -TargetName $typeName `
                        -Kind 'Outputs' -Resolution $to.Resolution -TargetCandidates $to.CandidateCount -EdgePath $fnNode.Path `
                        -Line $fnNode.StartLine -IsDeclared $declared.Contains($typeName)
                }
            }
        }

        # Every module the code depends on, and how each was named.
        $requirements = @(Get-PSModuleRequirement -Target $target)
        $declaredModules = [System.Collections.Generic.List[object]]::new()
        foreach ($rm in @($manifest.RequiredModules)) {
            if (-not $rm -or -not $rm.Name) { continue }
            $version = if ($rm.RequiredVersion) { $rm.RequiredVersion } else { $rm.ModuleVersion }
            $declaredModules.Add([pscustomobject]@{ Name = $rm.Name; Version = $version; Source = 'RequiredModules'; UsedBy = $null })
        }
        foreach ($u in $usings) {
            if ($u.Kind -eq 'Module' -and $u.Name) {
                $declaredModules.Add([pscustomobject]@{ Name = [System.IO.Path]::GetFileNameWithoutExtension($u.Name); Version = $null; Source = 'using module'; UsedBy = $null })
            }
        }
        foreach ($r in $requirements) {
            $declaredModules.Add([pscustomobject]@{ Name = $r.Name; Version = $r.Version; Source = $r.Source; UsedBy = $r.EnclosingFunction })
        }

        # Look every external command up on this machine, without importing.
        $lookup = Resolve-ExternalCommand -Name @($externalReferences | ForEach-Object TargetName) -ModuleName @($declaredModules | ForEach-Object Name)

        # One node per external command, and an edge to it from each caller.
        $commandNodes = @{}
        foreach ($ref in $externalReferences) {
            $key = $ref.TargetName.ToLowerInvariant()
            if (-not $commandNodes.ContainsKey($key)) {
                $info = $lookup.Commands[$ref.TargetName]
                if ($ref.ModuleQualifier) {
                    # Module\Command names its module, installed here or not.
                    $info = [pscustomobject]@{
                        Name          = $ref.TargetName
                        Found         = $info.Found -and $info.ModuleName -eq $ref.ModuleQualifier
                        CommandType   = $info.CommandType
                        ResolvesTo    = $info.ResolvesTo
                        ModuleName    = $ref.ModuleQualifier
                        ModuleVersion = $lookup.Modules[$ref.ModuleQualifier]
                        Path          = $null
                    }
                }
                $node = New-GraphNode -Id "command:$key" -Name $ref.TargetName -Kind 'Command' -Command $info
                $commandNodes[$key] = $node
                $nodes.Add($node)
            }
            Add-GraphEdge -Source $ref.Source -Target $commandNodes[$key].Id -SourceName $ref.SourceName -TargetName $ref.TargetName `
                -Kind 'CommandReference' -Resolution 'External' -TargetCandidates 0 -EdgePath $ref.Path -Line $ref.StartLine
        }

        # Each node lists, by name, what it calls and what calls it. Calls a
        # function makes to itself do not count as use.
        $nodeById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($n in $nodes) { $nodeById[$n.Id] = $n }

        # Id -> names, built in one pass over the edges rather than a scan per node.
        $newIndex = { [System.Collections.Generic.Dictionary[string, System.Collections.Generic.SortedSet[string]]]::new([System.StringComparer]::Ordinal) }
        $calls = & $newIndex
        $callers = & $newIndex
        $externalCalls = & $newIndex
        $modulesUsed = & $newIndex
        $outputBy = & $newIndex
        $undeclaredOutputBy = & $newIndex
        $addTo = {
            param($Index, [string] $Key, [string] $Value)
            if (-not $Value) { return }
            if (-not $Index.ContainsKey($Key)) {
                $Index[$Key] = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            [void]$Index[$Key].Add($Value)
        }
        foreach ($e in $edges) {
            $targetNode = $nodeById[$e.Target]
            $sourceNode = $nodeById[$e.Source]
            if ($targetNode.Kind -eq 'Command') {
                & $addTo $externalCalls $e.Source $targetNode.Name
                & $addTo $modulesUsed $e.Source $targetNode.ModuleName
            }
            else {
                & $addTo $calls $e.Source $targetNode.Name
            }
            if ($e.Source -cne $e.Target) {
                & $addTo $callers $e.Target $sourceNode.Name
            }
            if ($e.Kind -eq 'Outputs') {
                & $addTo $outputBy $e.Target $sourceNode.Name
                if (-not $e.IsDeclared) { & $addTo $undeclaredOutputBy $e.Target $sourceNode.Name }
            }
        }

        foreach ($n in $nodes) {
            if ($calls.ContainsKey($n.Id)) { $n.DependsOn = [string[]]@($calls[$n.Id]) }
            if ($callers.ContainsKey($n.Id)) { $n.UsedBy = [string[]]@($callers[$n.Id]) }
            if ($externalCalls.ContainsKey($n.Id)) { $n.ExternalCalls = [string[]]@($externalCalls[$n.Id]) }
            if ($modulesUsed.ContainsKey($n.Id)) { $n.ModulesUsed = [string[]]@($modulesUsed[$n.Id]) }
            if ($outputBy.ContainsKey($n.Id)) { $n.OutputBy = [string[]]@($outputBy[$n.Id]) }
            if ($undeclaredOutputBy.ContainsKey($n.Id)) { $n.UndeclaredOutputBy = [string[]]@($undeclaredOutputBy[$n.Id]) }

            # A private function nothing in the module calls: dead code, or an
            # entry point the module forgot to export.
            if ($n.Type -eq 'Private' -and -not $callers.ContainsKey($n.Id)) {
                $n.Type = 'Unresolved'
            }
        }
        $unresolvedFunctions = @($nodes | Where-Object Type -EQ 'Unresolved')

        $externalCommands = @(
            foreach ($node in $commandNodes.Values | Sort-Object Name) {
                [pscustomobject]@{
                    PSTypeName    = 'PSModuleDependencyGraph.ExternalCommand'
                    Name          = $node.Name
                    CommandType   = $node.CommandType
                    ResolvesTo    = $node.ResolvesTo
                    ModuleName    = $node.ModuleName
                    ModuleVersion = $node.ModuleVersion
                    IsFound       = $node.IsFound
                    UsedBy        = $node.UsedBy
                }
            }
        )

        # One entry per module, from what the code declares and what its
        # commands turned out to belong to.
        $moduleIndex = [ordered]@{}
        $getModule = {
            param([string] $ModuleName)
            if (-not $moduleIndex.Contains($ModuleName)) {
                $moduleIndex[$ModuleName] = [pscustomobject]@{
                    PSTypeName       = 'PSModuleDependencyGraph.ModuleDependency'
                    Name             = $ModuleName
                    Version          = $null
                    InstalledVersion = $lookup.Modules[$ModuleName]
                    IsInstalled      = $lookup.Modules.ContainsKey($ModuleName)
                    DeclaredBy       = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    Commands         = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    UsedBy           = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
            }
            $moduleIndex[$ModuleName]
        }
        foreach ($d in $declaredModules) {
            $entry = & $getModule $d.Name
            [void]$entry.DeclaredBy.Add($d.Source)
            if ($d.Version -and -not $entry.Version) { $entry.Version = [string]$d.Version }
            if ($d.UsedBy) { [void]$entry.UsedBy.Add($d.UsedBy) }
        }
        foreach ($command in $externalCommands | Where-Object ModuleName) {
            $entry = & $getModule $command.ModuleName
            [void]$entry.Commands.Add($command.Name)
            foreach ($caller in $command.UsedBy) { [void]$entry.UsedBy.Add($caller) }
            # A command was found in it, so it is here - even when, like
            # Microsoft.PowerShell.Core, it is not a module Get-Module lists.
            if ($command.IsFound) { $entry.IsInstalled = $true }
            $qualified = $externalReferences | Where-Object { $_.ModuleQualifier -eq $command.ModuleName -and $_.TargetName -eq $command.Name } | Select-Object -First 1
            [void]$entry.DeclaredBy.Add($(if ($qualified) { 'Module\Command' } else { 'Command lookup' }))
        }
        $modules = @(
            foreach ($entry in $moduleIndex.Values | Sort-Object Name) {
                $entry.DeclaredBy = [string[]]@($entry.DeclaredBy)
                $entry.Commands = [string[]]@($entry.Commands)
                $entry.UsedBy = [string[]]@($entry.UsedBy)
                if (-not $entry.Version -and $entry.InstalledVersion) { $entry.Version = [string]$entry.InstalledVersion }
                $entry
            }
        )

        # Roots and leaves describe the module's own code, so commands from
        # outside it are left out of both.
        #
        # ORDINAL, for the reason $edgeSeen is. Keyed on @{}, two node ids
        # differing only in case shared one counter, so each reported the
        # other's degree and one of them could be called a root while something
        # called it.
        $internalNodes = @($nodes | Where-Object Kind -NE 'Command')
        $inbound = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
        $outbound = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
        foreach ($n in $internalNodes) {
            $inbound[$n.Id] = 0
            $outbound[$n.Id] = 0
        }
        foreach ($e in $edges) {
            if (-not ($inbound.ContainsKey($e.Source) -and $inbound.ContainsKey($e.Target))) { continue }
            $outbound[$e.Source]++
            $inbound[$e.Target]++
        }

        $roots = @($internalNodes | Where-Object { $inbound[$_.Id] -eq 0 })
        $leaves = @($internalNodes | Where-Object { $outbound[$_.Id] -eq 0 })

        # A name carried by more than one definition. Reported rather than
        # resolved away: it is the reason an edge can be ambiguous, and a reader
        # looking at a surprising root needs to be able to find it.
        $ambiguousNames = @(
            $nodeIndex.GetEnumerator() |
                Where-Object { $_.Value.Count -gt 1 } |
                ForEach-Object { $_.Key } |
                Sort-Object
        )

        $typeCount = { param([string] $Type) @($nodes | Where-Object Type -EQ $Type).Count }
        $graph = [ModuleDependencyGraph]@{
            ModuleName         = $target.Name
            ModuleVersion      = $target.Version
            ModuleBase         = $target.ModuleBase
            ManifestPath       = $target.ManifestPath
            Nodes              = @($nodes)
            Edges              = @($edges)
            Roots              = @($roots)
            Leaves             = @($leaves)
            Unresolved         = $unresolvedFunctions
            ExternalCommands   = $externalCommands
            Modules            = $modules
            ExternalReferences = @($externalReferences)
            AmbiguousNames     = $ambiguousNames
            Functions          = $functions
            Classes            = $classes
            Enums              = $enums
            Assemblies         = $assemblies
            UsingStatements    = $usings
            Manifest           = $manifest
            Stats              = [pscustomobject]@{
                NodeCount            = $nodes.Count
                EdgeCount            = $edges.Count
                RootCount            = $roots.Count
                LeafCount            = $leaves.Count
                FunctionCount        = $functions.Count
                PublicCount          = & $typeCount 'Public'
                PrivateCount         = & $typeCount 'Private'
                UnresolvedCount      = $unresolvedFunctions.Count
                ExternalCommandCount = $externalCommands.Count
                NotFoundCommandCount = @($externalCommands | Where-Object { -not $_.IsFound }).Count
                ModuleCount          = $modules.Count
                ClassCount           = $classes.Count
                EnumCount            = $enums.Count
                AmbiguousNameCount   = $ambiguousNames.Count
                AmbiguousEdgeCount   = @($edges | Where-Object { $_.Resolution -eq 'Ambiguous' }).Count
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
