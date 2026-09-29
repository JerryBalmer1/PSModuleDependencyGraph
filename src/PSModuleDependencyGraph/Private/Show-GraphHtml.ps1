function Show-GraphHtml {
    <#
    .SYNOPSIS
        Opens a saved graph page in the default browser or in VS Code.
    .DESCRIPTION
        Browser: the system's default handler for .html, which is the default
        browser.

        VSCode: the 'code' command line, reusing the open window. VS Code has no
        built-in HTML preview, so the page opens as source; an extension such as
        Live Preview (ms-vscode.live-server) renders it. 'code' is a native
        command, and with $PSNativeCommandUseErrorActionPreference on, a
        non-zero exit from it is an error here rather than a silent failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('Browser', 'VSCode')]
        [string] $In
    )

    switch ($In) {
        'Browser' {
            Start-Process -FilePath $Path
        }
        'VSCode' {
            $code = Get-Command -Name 'code', 'code-insiders' -CommandType Application -ErrorAction Ignore |
                Select-Object -First 1
            if (-not $code) {
                throw "VS Code's 'code' command was not found on PATH. In VS Code, run 'Shell Command: Install 'code' command in PATH', or open $Path yourself."
            }
            & $code.Source --reuse-window $Path
        }
    }
}
