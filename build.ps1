#Requires -Version 7.4
<#
.SYNOPSIS
    Installs the requirements and runs the tests.
.PARAMETER Task
    Bootstrap installs what requirements.psd1 declares. Test runs Pester.
#>
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Test')]
    [string[]] $Task = @('Test')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$requirementsPath = Join-Path $PSScriptRoot 'requirements.psd1'
$pesterFloor = [version]'6.1.0'

if ('Bootstrap' -in $Task) {
    Install-PSResource -RequiredResourceFile $requirementsPath -Scope CurrentUser -TrustRepository
}

if ('Test' -in $Task) {
    $available = Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version -ge $pesterFloor } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $available) {
        throw "Pester $pesterFloor or later is required. Run: ./build.ps1 -Task Bootstrap"
    }

    Get-Module -Name Pester | Remove-Module -Force
    Import-Module -Name Pester -MinimumVersion $pesterFloor -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $PSScriptRoot 'tests'
    $config.Run.Exit = $true
    $config.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $config
}
