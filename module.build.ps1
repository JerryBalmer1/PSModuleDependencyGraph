#Requires -Version 7.4
<#
.SYNOPSIS
    Build script for PSModuleDependencyGraph.
.DESCRIPTION
    Installs ModuleFast if it is missing, then has ModuleFast install what
    requirements.psd1 declares (Pester, InvokeBuild), then runs the tasks with
    InvokeBuild. Works on a machine that has none of them yet:

        ./module.build.ps1          # default: Test
        ./module.build.ps1 Test

    Once InvokeBuild is installed, Invoke-Build works too:

        Invoke-Build
        Invoke-Build Test
.PARAMETER Tasks
    Tasks to run when this script is called directly. Ignored under Invoke-Build.
#>
param(
    [Parameter(Position = 0)]
    [string[]] $Tasks = @('.')
)

$ErrorActionPreference                   = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$requirementsPath = Join-Path $PSScriptRoot 'requirements.psd1'

if (-not (Get-Module -ListAvailable -Name ModuleFast)) {
    Install-PSResource -Name ModuleFast -Scope CurrentUser -TrustRepository
}
Import-Module -Name ModuleFast
Install-ModuleFast -Path $requirementsPath -Scope CurrentUser

$requirements   = Import-PowerShellDataFile -LiteralPath $requirementsPath
$pesterFloor    = [version]($requirements.Pester.version -replace '^\[([^,\]]+).*$', '$1')
$invokeBuildPin = [version]($requirements.InvokeBuild.version -replace '^\[([^,\]]+).*$', '$1')

# Import the required versions, and confirm what actually loaded: an older copy
# elsewhere on PSModulePath must not be the one that runs.
Get-Module -Name Pester | Remove-Module -Force
Import-Module -Name Pester -MinimumVersion $pesterFloor -Force
$loadedPester = (Get-Module -Name Pester).Version
if ($loadedPester -lt $pesterFloor) {
    throw "Pester $pesterFloor or later is required, but $loadedPester loaded."
}

# Called directly rather than by Invoke-Build: hand over to the pinned InvokeBuild.
if ([System.IO.Path]::GetFileName($MyInvocation.ScriptName) -ne 'Invoke-Build.ps1') {
    Get-Module -Name InvokeBuild | Remove-Module -Force
    Import-Module -Name InvokeBuild -RequiredVersion $invokeBuildPin
    $loadedInvokeBuild = (Get-Module -Name InvokeBuild).Version
    if ($loadedInvokeBuild -ne $invokeBuildPin) {
        throw "InvokeBuild $invokeBuildPin is required, but $loadedInvokeBuild loaded."
    }
    Invoke-Build -Task $Tasks -File $PSCommandPath
    return
}

$runningInvokeBuild = (Get-Module -Name InvokeBuild).Version
if ($runningInvokeBuild -ne $invokeBuildPin) {
    throw "InvokeBuild $invokeBuildPin is required, but $runningInvokeBuild is running. Run: ./module.build.ps1"
}

Enter-Build {
    Write-Build Green "Pester $loadedPester, InvokeBuild $runningInvokeBuild"
}

# Synopsis: Run the Pester tests.
task Test {
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $BuildRoot 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $config

    assert ($result.FailedCount -eq 0) "$($result.FailedCount) test(s) failed."
}

task . Test
