function ConvertTo-GraphHtml {
    <#
    .SYNOPSIS
        Renders a dependency graph as one self-contained HTML page.
    .DESCRIPTION
        The page is Resources/PSModuleDependencyGraph.html with three things put
        in: the title, the graph data as JSON, and vis-network itself, so the
        file works offline and can be attached or mailed as it is.

        The idea - hand vis-network a nodes array, an edges array and an options
        object - comes from PSWriteHTML's New-HTMLDiagram. The data here is built
        from plain hashtables and ConvertTo-Json, so it needs nothing .NET 9
        removed.
    .PARAMETER Graph
        Graph from Get-PSModuleDependencyGraph.
    .PARAMETER Title
        Page title. Defaults to '<ModuleName> dependency graph'.
    .PARAMETER IncludeUnresolved
        Add commands the module calls but does not define, hidden until the
        page's "Unresolved commands" box is ticked.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ModuleDependencyGraph] $Graph,

        [string] $Title,

        [switch] $IncludeUnresolved
    )

    if (-not $Title) {
        $Title = "$($Graph.ModuleName) dependency graph"
    }

    $resources = Join-Path $script:ModuleRoot 'Resources'
    $template = [System.IO.File]::ReadAllText((Join-Path $resources 'PSModuleDependencyGraph.html'))
    $visNetwork = [System.IO.File]::ReadAllText((Join-Path $resources 'vis-network.min.js'))

    $payload = ConvertTo-GraphHtmlData -Graph $Graph -IncludeUnresolved:$IncludeUnresolved

    # EscapeHtml writes <, >, & and ' as \u escapes, so no value - a function
    # name included - can close the <script> element the JSON sits in.
    $json = $payload | ConvertTo-Json -Depth 8 -Compress -EscapeHandling EscapeHtml

    # String.Replace rather than -replace: the JSON and the library are full of
    # $ and \ that a regex replacement would reinterpret.
    $template.
        Replace('{{TITLE}}', [System.Net.WebUtility]::HtmlEncode($Title)).
        Replace('/*{{GRAPH_DATA}}*/', $json).
        Replace('/*{{VIS_NETWORK}}*/', $visNetwork)
}

function ConvertTo-GraphHtmlData {
    <#
    .SYNOPSIS
        Shapes a dependency graph into the nodes and edges the HTML page draws.
    .DESCRIPTION
        One edge per graph edge, each with both ends pointing at a node that is
        in the payload. Paths are made relative to the module base: a report gets
        passed around, and absolute paths carry the user name and folder layout.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ModuleDependencyGraph] $Graph,

        [switch] $IncludeUnresolved
    )

    $moduleBase = $Graph.ModuleBase
    $nodeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $Graph.Nodes) {
        $group = switch ($node.Kind) {
            'Function' { if ($node.IsExported) { 'exported' } else { 'internal' } }
            'Script' { 'script' }
            'Class' { 'class' }
            'Enum' { 'enum' }
            default { 'internal' }
        }
        $kindLabel = switch ($node.Kind) {
            'Function' { if ($node.IsExported) { 'Exported function' } else { 'Function' } }
            'Script' { 'Top-level script code' }
            default { [string]$node.Kind }
        }
        $label = if ($node.Kind -eq 'Script') { "<script> $(Split-Path -Path $node.Path -Leaf)" } else { $node.Name }

        [void]$nodeIds.Add($node.Id)
        $nodes.Add([ordered]@{
                id           = $node.Id
                label        = $label
                kind         = [string]$node.Kind
                kindLabel    = $kindLabel
                group        = $group
                exported     = [bool]$node.IsExported
                exportState  = if ($node.PSObject.Properties['ExportState']) { [string]$node.ExportState } else { $null }
                exportSource = if ($node.PSObject.Properties['ExportSource']) { [string]$node.ExportSource } else { $null }
                path         = if ($node.Path) { Get-RelativePathSafe -BasePath $moduleBase -TargetPath $node.Path } else { $null }
                line         = $node.StartLine
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

    $hasUnresolved = $false
    if ($IncludeUnresolved) {
        $externalIds = @{}
        foreach ($ref in $Graph.Unresolved) {
            # Manifest RequiredModules and using-module entries have no calling
            # node to draw an edge from.
            if (-not $nodeIds.Contains([string]$ref.Source)) { continue }

            $key = ([string]$ref.TargetName).ToLowerInvariant()
            if (-not $externalIds.ContainsKey($key)) {
                $id = "external:$key"
                $externalIds[$key] = $id
                $nodes.Add([ordered]@{
                        id           = $id
                        label        = [string]$ref.TargetName
                        kind         = 'External'
                        kindLabel    = 'Unresolved command'
                        group        = 'external'
                        exported     = $false
                        exportState  = $null
                        exportSource = $null
                        path         = $null
                        line         = $null
                    })
            }
            $edges.Add([ordered]@{
                    from       = $ref.Source
                    to         = $externalIds[$key]
                    kind       = 'Unresolved'
                    resolution = 'Unresolved'
                    candidates = 0
                })
            $hasUnresolved = $true
        }
    }

    [ordered]@{
        meta          = [ordered]@{
            moduleName  = $Graph.ModuleName
            version     = if ($Graph.ModuleVersion) { $Graph.ModuleVersion.ToString() } else { $null }
            generatedAt = (Get-Date).ToString('o')
            stats       = $Graph.Stats
        }
        hasUnresolved = $hasUnresolved
        nodes         = @($nodes)
        edges         = @($edges)
    }
}
