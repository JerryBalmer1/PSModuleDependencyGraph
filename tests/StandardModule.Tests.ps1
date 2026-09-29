#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'StandardModule: Public / Private directories' {
    Context 'ManifestExport (manifest lists the public functions)' {
        BeforeAll { $graph = Get-FixtureGraph 'StandardModule/ManifestExport' }

        It 'exports <Name>: <Expected>' -ForEach @(
            @{ Name = 'Get-Something'; Expected = $true }
            @{ Name = 'Set-Something'; Expected = $true }
            @{ Name = 'Read-SomethingStore'; Expected = $false }
            @{ Name = 'Write-SomethingStore'; Expected = $false }
            @{ Name = 'ConvertTo-SomethingObject'; Expected = $false }
            @{ Name = 'Remove-SomethingCache'; Expected = $false }
        ) {
            $node = Get-FunctionNode $graph $Name
            $node.IsExported | Should -Be $Expected
            $node.ExportSource | Should -Be 'Manifest'
        }

        It 'links public functions to the private ones they call' {
            Get-EdgePair $graph | Should -Be @(
                'Get-Something->ConvertTo-SomethingObject'
                'Get-Something->Read-SomethingStore'
                'Set-Something->Write-SomethingStore'
            )
        }
    }

    Context 'DynamicExport (Export-ModuleMember -Function $public.BaseName)' {
        BeforeAll { $graph = Get-FixtureGraph 'StandardModule/DynamicExport' }

        It 'falls back to the folder: <Name> exported is <Expected>' -ForEach @(
            @{ Name = 'Get-Something'; Expected = $true }
            @{ Name = 'Invoke-Something'; Expected = $true }
            @{ Name = 'Get-SomethingCore'; Expected = $false }
            @{ Name = 'Assert-Something'; Expected = $false }
        ) {
            $node = Get-FunctionNode $graph $Name
            $node.IsExported | Should -Be $Expected
            $node.ExportSource | Should -Be 'FolderConvention'
        }

        It 'links public to public and public to private' {
            Get-EdgePair $graph | Should -Be @(
                'Get-Something->Get-SomethingCore'
                'Invoke-Something->Assert-Something'
                'Invoke-Something->Get-Something'
            )
        }
    }

    Context 'NameCollision ([public]Get-Something and [private]Get-Something)' {
        BeforeAll { $graph = Get-FixtureGraph 'StandardModule/NameCollision' }

        It 'keeps both definitions as separate nodes' {
            $nodes = Get-FunctionNode $graph 'Get-Something'
            $nodes.Count | Should -Be 2
            @($nodes.Id | Sort-Object -Unique).Count | Should -Be 2
        }

        It 'marks the public one exported and the private one not' {
            $nodes = Get-FunctionNode $graph 'Get-Something'
            ($nodes | Where-Object { $_.Path -match '[\\/]Public[\\/]' }).IsExported | Should -BeTrue
            ($nodes | Where-Object { $_.Path -match '[\\/]Private[\\/]' }).IsExported | Should -BeFalse
        }

        It 'reports the call as ambiguous, with an edge to each definition' {
            $graph.AmbiguousNames | Should -Be @('get-something')
            $edges = @($graph.Edges | Where-Object TargetName -EQ 'Get-Something')
            $edges.Count | Should -Be 2
            $edges.Resolution | Sort-Object -Unique | Should -Be 'Ambiguous'
        }
    }

    Context 'NestedFolders (Public/Items, Private/Helpers)' {
        BeforeAll { $graph = Get-FixtureGraph 'StandardModule/NestedFolders' }

        It 'treats nested folders under Public and Private the same: <Name> exported is <Expected>' -ForEach @(
            @{ Name = 'Get-Root'; Expected = $true }
            @{ Name = 'Get-Item2'; Expected = $true }
            @{ Name = 'Resolve-Item2Path'; Expected = $false }
        ) {
            (Get-FunctionNode $graph $Name).IsExported | Should -Be $Expected
        }

        It 'follows the chain across folders' {
            Get-EdgePair $graph | Should -Be @('Get-Item2->Resolve-Item2Path', 'Get-Root->Get-Item2')
        }
    }
}
