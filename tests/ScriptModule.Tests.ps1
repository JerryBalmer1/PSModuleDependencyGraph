#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'ScriptModule: a single .psm1' {
    Context 'ImplicitExport (no Export-ModuleMember, no manifest)' {
        BeforeAll { $graph = Get-FixtureGraph 'ScriptModule/ImplicitExport' }

        It 'exports every function, as PowerShell does' {
            foreach ($fn in $graph.Functions) {
                $fn.IsExported | Should -BeTrue
                $fn.ExportSource | Should -Be 'ImplicitAll'
            }
        }

        It 'links Get-Something to ConvertTo-Something' {
            Get-EdgePair $graph | Should -Be @('Get-Something->ConvertTo-Something')
        }
    }

    Context 'ExportModuleMember (literal names)' {
        BeforeAll { $graph = Get-FixtureGraph 'ScriptModule/ExportModuleMember' }

        It 'exports <Name>: <Expected>' -ForEach @(
            @{ Name = 'Get-Something'; Expected = $true }
            @{ Name = 'Set-Something'; Expected = $true }
            @{ Name = 'Get-SomethingInternal'; Expected = $false }
        ) {
            $node = Get-FunctionNode $graph $Name
            $node.IsExported | Should -Be $Expected
            $node.ExportSource | Should -Be 'ExportModuleMember'
        }

        It 'links both public functions to the private one' {
            Get-EdgePair $graph | Should -Be @('Get-Something->Get-SomethingInternal', 'Set-Something->Get-SomethingInternal')
        }
    }

    Context 'WithManifest (FunctionsToExport list)' {
        BeforeAll { $graph = Get-FixtureGraph 'ScriptModule/WithManifest' }

        It 'exports <Name>: <Expected>' -ForEach @(
            @{ Name = 'Get-Something'; Expected = $true }
            @{ Name = 'Remove-Something'; Expected = $true }
            @{ Name = 'Test-Something'; Expected = $false }
        ) {
            $node = Get-FunctionNode $graph $Name
            $node.IsExported | Should -Be $Expected
            $node.ExportSource | Should -Be 'Manifest'
        }

        It 'reports the private helper as a leaf both public functions reach' {
            Get-EdgePair $graph | Should -Be @('Get-Something->Test-Something', 'Remove-Something->Test-Something')
            @($graph.Leaves.Name) | Should -Contain 'Test-Something'
        }
    }

    Context 'Wildcard (FunctionsToExport = Get-*)' {
        BeforeAll { $graph = Get-FixtureGraph 'ScriptModule/Wildcard' }

        It 'exports <Name>: <Expected>' -ForEach @(
            @{ Name = 'Get-Something'; Expected = $true }
            @{ Name = 'Get-SomethingElse'; Expected = $true }
            @{ Name = 'New-Something'; Expected = $false }
        ) {
            (Get-FunctionNode $graph $Name).IsExported | Should -Be $Expected
        }
    }
}
