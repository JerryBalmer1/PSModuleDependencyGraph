function Save-PSModuleDependencyGraphHtml {
    <#
    .SYNOPSIS
        Saves a dependency graph as an interactive HTML page.
    .DESCRIPTION
        Writes one self-contained .html file: the graph data and the vis-network
        library are inside it, so it opens offline and can be attached or mailed.

        Functions are laid out in layers, callers to the left of what they call.
        Click a node for its file, line, callers and callees; filter to exported
        functions; search by name.
    .PARAMETER InputObject
        Graph from Get-PSModuleDependencyGraph.
    .PARAMETER Path
        File to write. Its folder is created when missing.
    .PARAMETER Title
        Page title. Defaults to '<ModuleName> dependency graph'.
    .PARAMETER IncludeUnresolved
        Also include commands the module calls but does not define, such as
        Get-ChildItem. They start hidden; the page has a box to show them.
    .EXAMPLE
        Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
            Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [ModuleDependencyGraph] $InputObject,

        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [string] $Title,

        [Parameter()]
        [switch] $IncludeUnresolved
    )

    process {
        $html = ConvertTo-GraphHtml -Graph $InputObject -Title $Title -IncludeUnresolved:$IncludeUnresolved

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
