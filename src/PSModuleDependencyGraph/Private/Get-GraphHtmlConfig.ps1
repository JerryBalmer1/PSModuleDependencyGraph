function Get-GraphHtmlConfig {
    <#
    .SYNOPSIS
        The rendering settings for the HTML page: the defaults, with a user file merged over them.
    .DESCRIPTION
        Defaults are Resources/GraphHtmlConfig.psd1. A file passed as -Path only
        needs the keys it changes. The result is checked, so a mistyped colour or
        direction fails here, with the key named, rather than drawing a broken page.
    .PARAMETER Path
        Optional .psd1 to merge over the defaults.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Path
    )

    $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot 'Resources/GraphHtmlConfig.psd1')

    if ($Path) {
        $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Config file not found: $Path"
        }
        $override = Import-PowerShellDataFile -LiteralPath $resolved
        $config = Merge-GraphHtmlConfig -Base $config -Override $override
    }

    Assert-GraphHtmlConfig -Config $config
    $config
}

function Merge-GraphHtmlConfig {
    <#
    .SYNOPSIS
        Merges one config hashtable over another: hashtables key by key, NodeGroups by Name, other lists whole.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Base,
        [Parameter(Mandatory)] [hashtable] $Override,
        [string] $KeyPath = ''
    )

    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }

    foreach ($key in $Override.Keys) {
        $here = if ($KeyPath) { "$KeyPath.$key" } else { $key }
        $baseValue = $merged[$key]
        $value = $Override[$key]

        if ($baseValue -is [hashtable] -and $value -is [hashtable]) {
            $merged[$key] = Merge-GraphHtmlConfig -Base $baseValue -Override $value -KeyPath $here
        }
        elseif ($here -eq 'NodeGroups') {
            # Merge by Name, so a file can recolour one group without restating all.
            $groups = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($group in @($baseValue)) { $groups.Add($group.Clone()) }
            foreach ($group in @($value)) {
                $existing = $groups | Where-Object { $_.Name -eq $group.Name } | Select-Object -First 1
                if ($existing) {
                    foreach ($k in $group.Keys) { $existing[$k] = $group[$k] }
                }
                else {
                    $groups.Add($group)
                }
            }
            $merged[$key] = @($groups)
        }
        else {
            $merged[$key] = $value
        }
    }
    $merged
}

function Assert-GraphHtmlConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config
    )

    $hex = '^#[0-9a-fA-F]{6}$'
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($key in 'Background', 'Panel', 'PanelAlt', 'Border', 'Text', 'TextDim', 'Accent') {
        if ($Config.Theme[$key] -notmatch $hex) { $problems.Add("Theme.$key must be a #rrggbb colour; got '$($Config.Theme[$key])'.") }
    }
    foreach ($key in 'Color', 'AmbiguousColor', 'ExternalColor', 'InheritsColor', 'OutputsColor') {
        if ($Config.Edges[$key] -notmatch $hex) { $problems.Add("Edges.$key must be a #rrggbb colour; got '$($Config.Edges[$key])'.") }
    }
    foreach ($group in @($Config.NodeGroups)) {
        if (-not $group.Name) { $problems.Add('Every NodeGroups entry needs a Name.'); continue }
        if ($group.Color -notmatch $hex) { $problems.Add("NodeGroups '$($group.Name)'.Color must be a #rrggbb colour; got '$($group.Color)'.") }
    }
    $groupNames = @($Config.NodeGroups | ForEach-Object { $_.Name })
    foreach ($type in @($Config.Show.Types)) {
        if ($type -notin $groupNames) { $problems.Add("Show.Types names '$type', which is not a NodeGroups Name.") }
    }
    if ($Config.Layout.Direction -notin 'LeftToRight', 'TopToBottom') {
        $problems.Add("Layout.Direction must be LeftToRight or TopToBottom; got '$($Config.Layout.Direction)'.")
    }
    if ($Config.Layout.SortMethod -notin 'directed', 'hubsize') {
        $problems.Add("Layout.SortMethod must be directed or hubsize; got '$($Config.Layout.SortMethod)'.")
    }
    $fill = $Config.Nodes.FillStrength -as [double]
    if ($null -eq $fill -or $fill -lt 0 -or $fill -gt 1) {
        $problems.Add("Nodes.FillStrength must be between 0 and 1; got '$($Config.Nodes.FillStrength)'.")
    }
    foreach ($item in @($Config.NodeMenu)) {
        if (-not $item.Label -or -not $item.Target) { $problems.Add('Every NodeMenu entry needs a Label and a Target.'); continue }
        if ($item.Action -notin 'Open', 'Copy') { $problems.Add("NodeMenu '$($item.Label)'.Action must be Open or Copy; got '$($item.Action)'.") }
        if ($item.When -and $item.When -notin 'Always', 'HasFile', 'HasModule') { $problems.Add("NodeMenu '$($item.Label)'.When must be Always, HasFile or HasModule; got '$($item.When)'.") }
    }

    if ($problems.Count) {
        throw "Invalid graph HTML config:`n  " + ($problems -join "`n  ")
    }
}
