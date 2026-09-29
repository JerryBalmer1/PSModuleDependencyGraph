function Save-PSModuleDependencyGraphHtml {
    <#
    .SYNOPSIS
        Saves a dependency graph as an interactive HTML page.
    .DESCRIPTION
        Writes one self-contained .html file: the graph data and the vis-network
        library are inside it, so it opens offline and can be attached or mailed.

        Functions are laid out in layers, callers to the left of what they call.
        Public and private functions, private functions nothing calls, and
        commands the module calls but does not define each have their own
        colour. Click a node for its file, lines, parameter sets, callers and
        callees; right-click it for a menu that includes Show in VS Code.

        Colours, spacing, what shows at first and the right-click menu come from
        Resources/GraphHtmlConfig.psd1; -ConfigPath merges your own settings over it.
    .PARAMETER InputObject
        Graph from Get-PSModuleDependencyGraph, or one saved with Export-Clixml and
        read back. Anything with ModuleName, Nodes and Edges properties is taken.
    .PARAMETER Path
        File to write. Its folder is created when missing.
    .PARAMETER Title
        Page title. Defaults to '<ModuleName> dependency graph'.
    .PARAMETER ConfigPath
        A .psd1 with the rendering settings to change. Only the keys you set are
        used; everything else comes from Resources/GraphHtmlConfig.psd1.
    .EXAMPLE
        Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
            Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html

        Saves the graph of a module folder as a page.
    .EXAMPLE
        Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
            Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html -ConfigPath ./MyColours.psd1

        Saves it with your own colours or spacing merged over the defaults.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [ValidateScript({ Test-GraphObject -InputObject $_ })]
        [object] $InputObject,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [string] $Title,

        [Parameter()]
        [string] $ConfigPath
    )

    begin {
        $config = Get-GraphHtmlConfig -Path $ConfigPath
    }

    process {
        $html = ConvertTo-GraphHtml -Graph $InputObject -Title $Title -Config $config

        $targetPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $directory = Split-Path -Path $targetPath -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }

        # UTF-8 without a BOM: a BOM ahead of <!DOCTYPE html> can put a browser
        # into quirks mode.
        [System.IO.File]::WriteAllText($targetPath, $html, [System.Text.UTF8Encoding]::new($false))
        Get-Item -LiteralPath $targetPath
    }
}
