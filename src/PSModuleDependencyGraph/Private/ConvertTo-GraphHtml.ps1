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
        [object] $Graph,

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
        Shapes a dependency graph into what the HTML page draws.
    .DESCRIPTION
        Every node goes in with its Type as its group - public, private,
        unresolved, external, class, enum or script - and the page's config
        decides how each group looks. External commands are nodes of the graph
        already, with their module, so the page draws what the graph holds and
        works nothing out for itself. The module list feeds the page's Modules
        panel.

        Paths are relative to the module, and the module's own folder is carried
        once, as meta.rootPath, for the right-click menu to build full paths from.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object] $Graph
    )

    $moduleBase = $Graph.ModuleBase
    $nodeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    # A list as an array with no $null in it. A graph read back from
    # Export-Clixml has $null where an empty list was, and piping $null runs
    # the pipeline once, for it.
    $list = { param($Value) @($Value | Where-Object { $null -ne $_ }) }

    $nodes = foreach ($node in $Graph.Nodes) {
        [void]$nodeIds.Add($node.Id)
        [ordered]@{
            id                   = $node.Id
            label                = if ($node.Kind -eq 'Script') { "<script> $(Split-Path -Path $node.Path -Leaf)" } else { $node.Name }
            name                 = $node.Name
            kind                 = $node.Kind
            type                 = $node.Type
            group                = $node.Type.ToLowerInvariant()
            exported             = [bool]$node.IsExported
            exportState          = $node.ExportState
            exportSource         = $node.ExportSource
            path                 = if ($node.Path) { Get-RelativePathSafe -BasePath $moduleBase -TargetPath $node.Path } else { $null }
            startLine            = $node.StartLine
            endLine              = $node.EndLine
            cmdletBinding        = [bool]$node.CmdletBinding
            synopsis             = if ($node.Help) { $node.Help.Synopsis } else { $null }
            exampleCount         = if ($node.Help) { @($node.Help.Examples).Count } else { 0 }
            parameterSets        = @(
                foreach ($set in & $list $node.ParameterSets) {
                    [ordered]@{
                        name       = $set.Name
                        isDefault  = [bool]$set.IsDefault
                        parameters = @(& $list $set.Parameters | ForEach-Object {
                                [ordered]@{ name = $_.Name; type = $_.TypeName; mandatory = [bool]$_.Mandatory }
                            })
                    }
                }
            )
            outputType           = & $list $node.OutputType
            inferredOutputType   = & $list $node.InferredOutputType
            undeclaredOutputType = & $list $node.UndeclaredOutputType
            outputBy             = & $list $node.OutputBy
            undeclaredOutputBy   = & $list $node.UndeclaredOutputBy
            moduleName           = $node.ModuleName
            moduleVersion        = if ($node.ModuleVersion) { [string]$node.ModuleVersion } else { $null }
            commandType          = $node.CommandType
            resolvesTo           = $node.ResolvesTo
            found                = [bool]$node.IsFound
        }
    }

    $edges = foreach ($edge in $Graph.Edges) {
        if (-not ($nodeIds.Contains($edge.Source) -and $nodeIds.Contains($edge.Target))) { continue }
        [ordered]@{
            from       = $edge.Source
            to         = $edge.Target
            kind       = $edge.Kind
            resolution = $edge.Resolution
            candidates = $edge.TargetCandidates
            isDeclared = $edge.IsDeclared
        }
    }

    $modules = foreach ($module in & $list $(if ($Graph.PSObject.Properties['Modules']) { $Graph.Modules })) {
        [ordered]@{
            name        = $module.Name
            version     = $module.Version
            installed   = [bool]$module.IsInstalled
            declaredBy  = & $list $module.DeclaredBy
            commands    = & $list $module.Commands
            usedBy      = & $list $module.UsedBy
        }
    }

    [ordered]@{
        meta    = [ordered]@{
            moduleName  = $Graph.ModuleName
            version     = if ($Graph.ModuleVersion) { $Graph.ModuleVersion.ToString() } else { $null }
            rootPath    = $moduleBase
            separator   = [string][System.IO.Path]::DirectorySeparatorChar
            generatedAt = (Get-Date).ToString('o')
            stats       = $Graph.Stats
        }
        nodes   = @($nodes)
        edges   = @($edges)
        modules = @($modules)
    }
}
