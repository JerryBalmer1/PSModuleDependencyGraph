#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Script: a single .ps1 with functions' {
    Context 'SingleFile' {
        BeforeAll { $graph = Get-FixtureGraph 'Script/SingleFile/Invoke-Report.ps1' }

        It 'finds every function in the script' {
            @($graph.Functions.Name | Sort-Object) | Should -Be @('Format-ReportLine', 'Get-ReportData', 'Write-Report')
        }

        It 'marks export as not applicable to a script' {
            foreach ($fn in $graph.Functions) {
                $fn.IsExported | Should -BeFalse
                $fn.ExportState | Should -Be 'NotApplicable'
                $fn.ExportSource | Should -Be 'NotApplicable'
            }
        }

        It 'links the calls, including the top-level one' {
            Get-EdgePair $graph | Should -Be @('<script>->Write-Report', 'Get-ReportData->Format-ReportLine', 'Write-Report->Get-ReportData')
        }

        It 'reports the top-level script as the only root' {
            @($graph.Roots.Name) | Should -Be @('<script>')
        }
    }

    Context 'WithSibling' {
        BeforeAll { $graph = Get-FixtureGraph 'Script/WithSibling/Invoke-Main.ps1' }

        It 'inspects only the named file, not the rest of its folder' {
            @($graph.Functions.Name | Sort-Object) | Should -Be @('Get-MainValue', 'Invoke-Main')
            @($graph.Nodes.Path | Split-Path -Leaf | Sort-Object -Unique) | Should -Be @('Invoke-Main.ps1')
        }
    }
}
