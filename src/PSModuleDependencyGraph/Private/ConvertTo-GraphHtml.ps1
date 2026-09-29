function ConvertTo-GraphHtml {
    <#
    .SYNOPSIS
        Renders a dependency graph as one self-contained HTML page.
    .DESCRIPTION
        The page is Resources/PSModuleDependencyGraph.html with four things put
        in: the title, the graph data as JSON, the rendering config as JSON, and
        vis-network itself, so the file works offline and can be attached or
        mailed as it is.

        The idea - hand vis-network a nodes array, an edges array and options -
        comes from PSWriteHTML's New-HTMLDiagram. The data here is built from
        plain hashtables and ConvertTo-Json, so it needs nothing .NET 9 removed.
    .PARAMETER Graph
        Graph from Get-PSModuleDependencyGraph.
    .PARAMETER Title
        Page title. Defaults to '<ModuleName> dependency graph'.
    .PARAMETER Config
        Rendering settings from Get-GraphHtmlConfig.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ModuleDependencyGraph] $Graph,

        [string] $Title,

        [Parameter(Mandatory)]
        [hashtable] $Config
    )

    if (-not $Title) {
        $Title = "$($Graph.ModuleName) dependency graph"
    }

    $resources = Join-Path $script:ModuleRoot 'Resources'
    $template = [System.IO.File]::ReadAllText((Join-Path $resources 'PSModuleDependencyGraph.html'))
    $visNetwork = [System.IO.File]::ReadAllText((Join-Path $resources 'vis-network.min.js'))

    # EscapeHtml writes <, >, & and ' as \u escapes, so no value - a function
    # name or a config label included - can close the <script> element it sits in.
    $toJson = { param($Value) $Value | ConvertTo-Json -Depth 10 -Compress -EscapeHandling EscapeHtml }
    $graphJson = & $toJson (ConvertTo-GraphHtmlData -Graph $Graph)
    $configJson = & $toJson $Config

    # String.Replace rather than -replace: the JSON and the library are full of
    # $ and \ that a regex replacement would reinterpret.
    $template.
        Replace('{{TITLE}}', [System.Net.WebUtility]::HtmlEncode($Title)).
        Replace('/*{{GRAPH_DATA}}*/', $graphJson).
        Replace('/*{{GRAPH_CONFIG}}*/', $configJson).
        Replace('/*{{VIS_NETWORK}}*/', $visNetwork)
}

function ConvertTo-GraphHtmlData {
    <#
    .SYNOPSIS
        Shapes a dependency graph into the nodes and edges the HTML page draws.
    .DESCRIPTION
        Each node is given a group name - public, private, dangling, script,
        class, enum or unresolved - and the page's config decides how each group
        looks. One edge per graph edge, both ends pointing at a node that is in
        the payload.

        Paths are relative to the module, and the module's own folder is carried
        once, as meta.rootPath, for the right-click menu to build full paths from.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ModuleDependencyGraph] $Graph
    )

    $moduleBase = $Graph.ModuleBase
    $nodeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $Graph.Nodes) {
        $group = switch ($node.Kind) {
            'Function' {
                if ($node.IsExported) { 'public' } elseif ($node.IsDangling) { 'dangling' } else { 'private' }
            }
            'Script' { 'script' }
            'Class' { 'class' }
            'Enum' { 'enum' }
        }
        $kindLabel = switch ($group) {
            'public' { 'Public function' }
            'private' { 'Private function' }
            'dangling' { 'Private function, never called' }
            'script' { 'Top-level script code' }
            default { [string]$node.Kind }
        }
        $label = if ($node.Kind -eq 'Script') { "<script> $(Split-Path -Path $node.Path -Leaf)" } else { $node.Name }

        [void]$nodeIds.Add($node.Id)
        $nodes.Add([ordered]@{
                id              = $node.Id
                label           = $label
                name            = $node.Name
                kind            = [string]$node.Kind
                kindLabel       = $kindLabel
                group           = $group
                exported        = [bool]$node.IsExported
                dangling        = [bool]$node.IsDangling
                exportState     = $node.ExportState
                exportSource    = $node.ExportSource
                path            = if ($node.Path) { Get-RelativePathSafe -BasePath $moduleBase -TargetPath $node.Path } else { $null }
                startLine       = $node.StartLine
                endLine         = $node.EndLine
                unresolvedCalls = @($node.UnresolvedCalls)
                synopsis        = if ($node.Help) { $node.Help.Synopsis } else { $null }
                exampleCount    = if ($node.Help) { @($node.Help.Examples).Count } else { 0 }
                parameterSets   = @(
                    foreach ($set in $node.ParameterSets) {
                        [ordered]@{
                            name       = $set.Name
                            isDefault  = [bool]$set.IsDefault
                            parameters = @($set.Parameters | ForEach-Object {
                                    [ordered]@{ name = $_.Name; type = $_.TypeName; mandatory = [bool]$_.Mandatory }
                                })
                        }
                    }
                )
            })
    }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($edge in $Graph.Edges) {
        if (-not ($nodeIds.Contains($edge.Source) -and $nodeIds.Contains($edge.Target))) { continue }
        $edges.Add([ordered]@{
                from       = $edge.Source
                to         = $edge.Target
                kind       = [string]$edge.Kind
                resolution = [string]$edge.Resolution
                candidates = $edge.TargetCandidates
            })
    }

    # Commands the module calls but does not define: one node per name, joined
    # to each caller. Manifest RequiredModules and using-module entries have no
    # calling node and are left out.
    $unresolvedIds = @{}
    foreach ($ref in $Graph.Unresolved) {
        if (-not $nodeIds.Contains([string]$ref.Source)) { continue }

        $key = ([string]$ref.TargetName).ToLowerInvariant()
        if (-not $unresolvedIds.ContainsKey($key)) {
            $unresolvedIds[$key] = "unresolved:$key"
            $nodes.Add([ordered]@{
                    id              = $unresolvedIds[$key]
                    label           = [string]$ref.TargetName
                    name            = [string]$ref.TargetName
                    kind            = 'Unresolved'
                    kindLabel       = 'Unresolved command'
                    group           = 'unresolved'
                    exported        = $false
                    dangling        = $false
                    exportState     = $null
                    exportSource    = $null
                    path            = $null
                    startLine       = $null
                    endLine         = $null
                    unresolvedCalls = @()
                    synopsis        = $null
                    exampleCount    = 0
                    parameterSets   = @()
                })
        }
        $edges.Add([ordered]@{
                from       = $ref.Source
                to         = $unresolvedIds[$key]
                kind       = 'Unresolved'
                resolution = 'Unresolved'
                candidates = 0
            })
    }

    [ordered]@{
        meta  = [ordered]@{
            moduleName  = $Graph.ModuleName
            version     = if ($Graph.ModuleVersion) { $Graph.ModuleVersion.ToString() } else { $null }
            rootPath    = $moduleBase
            separator   = [string][System.IO.Path]::DirectorySeparatorChar
            generatedAt = (Get-Date).ToString('o')
            stats       = $Graph.Stats
        }
        nodes = @($nodes)
        edges = @($edges)
    }
}
