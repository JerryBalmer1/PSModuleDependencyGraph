#Requires -Version 7.4
<#
.SYNOPSIS
    Build script for PSModuleDependencyGraph. Run with InvokeBuild.
.DESCRIPTION
    First time on a machine, install the requirements (InvokeBuild included):

        Install-PSResource -RequiredResourceFile ./requirements.psd1 -Scope CurrentUser -TrustRepository

    Then:

        Invoke-Build              # default: Test
        Invoke-Build Bootstrap    # re-install what requirements.psd1 declares
        Invoke-Build Test         # run Pester
#>

$ErrorActionPreference                   = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$requirementsPath = Join-Path $BuildRoot 'requirements.psd1'
$requirements     = Import-PowerShellDataFile -LiteralPath $requirementsPath
$pesterFloor      = [version]($requirements.Pester.version -replace '^\[([^,\]]+).*$', '$1')
$invokeBuildPin   = [version]($requirements.InvokeBuild.version -replace '^\[([^,\]]+).*$', '$1')

$runningInvokeBuild = (Get-Module -Name InvokeBuild).Version
if ($runningInvokeBuild -ne $invokeBuildPin) {
    throw "InvokeBuild $invokeBuildPin is required, but $runningInvokeBuild is running. Run: Import-Module InvokeBuild -RequiredVersion $invokeBuildPin"
}

# Synopsis: Install what requirements.psd1 declares.
task Bootstrap {
    Install-PSResource -RequiredResourceFile $requirementsPath -Scope CurrentUser -TrustRepository
}

# Synopsis: Run the Pester tests.
task Test {
    $available = Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version -ge $pesterFloor } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $available) {
        throw "Pester $pesterFloor or later is required. Run: Invoke-Build Bootstrap"
    }

    Get-Module -Name Pester | Remove-Module -Force
    Import-Module -Name Pester -MinimumVersion $pesterFloor -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $BuildRoot 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $config

    assert ($result.FailedCount -eq 0) "$($result.FailedCount) test(s) failed."
}

task . Test
