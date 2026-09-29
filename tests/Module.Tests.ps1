#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'PSModuleDependencyGraph module' {
    It 'requires PowerShell 7.4 or later' {
        $manifest = Test-ModuleManifest -Path (Join-Path $RepoRoot 'src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1')
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
        @($manifest.CompatiblePSEditions) | Should -Be @('Core')
    }

    It 'exports only Get-PSModuleDependencyGraph' {
        @((Get-Module PSModuleDependencyGraph).ExportedFunctions.Keys) | Should -Be @('Get-PSModuleDependencyGraph')
    }

    It 'turns on PSNativeCommandUseErrorActionPreference for its functions' {
        & (Get-Module PSModuleDependencyGraph) { $PSNativeCommandUseErrorActionPreference } | Should -BeTrue
    }

    It 'makes a failing native command an error inside the module' {
        {
            & (Get-Module PSModuleDependencyGraph) {
                $ErrorActionPreference = 'Stop'
                pwsh -NoProfile -NonInteractive -Command 'exit 3'
            }
        } | Should -Throw
    }

    It 'returns a dependency graph object' {
        $graph = Get-FixtureGraph 'ScriptModule/ImplicitExport'
        $graph.PSObject.TypeNames | Should -Contain 'PSModuleDependencyGraph.DependencyGraph'
    }
}
