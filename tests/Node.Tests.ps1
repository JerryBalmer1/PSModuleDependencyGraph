#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Graph nodes' {
    Context 'ManifestExport' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
        }

        It 'gives every node the same properties, whatever its kind' {
            $shapes = $graph.Nodes | ForEach-Object { ($_.PSObject.Properties.Name | Sort-Object) -join ',' } | Sort-Object -Unique
            @($shapes).Count | Should -Be 1
        }

        It 'records where each function starts and ends' {
            $node = Get-FunctionNode $graph 'Get-Something'
            $node.StartLine | Should -Be 1
            $node.EndLine | Should -Be 28
        }

        It 'lists by name what a function calls and what calls it' {
            $get = Get-FunctionNode $graph 'Get-Something'
            $get.DependsOn | Should -Be @('ConvertTo-SomethingObject', 'Read-SomethingStore')
            $get.UsedBy | Should -BeNullOrEmpty
            (Get-FunctionNode $graph 'Read-SomethingStore').UsedBy | Should -Be @('Get-Something')
        }

        It 'lists the commands a function calls that the module does not define' {
            (Get-FunctionNode $graph 'Get-Something').UnresolvedCalls | Should -Be @('Get-SomethingCache')
            (Get-FunctionNode $graph 'Set-Something').UnresolvedCalls | Should -Be @('Test-SomethingValid')
        }

        It 'marks a private function nothing calls as dangling, and nothing else' {
            @($graph.Dangling.Name) | Should -Be @('Remove-SomethingCache')
            (Get-FunctionNode $graph 'Remove-SomethingCache').IsDangling | Should -BeTrue
            (Get-FunctionNode $graph 'Read-SomethingStore').IsDangling | Should -BeFalse
            $graph.Stats.DanglingCount | Should -Be 1
        }

        It 'reads parameter sets: <Name> has <Count>' -ForEach @(
            @{ Name = 'Get-Something'; Count = 2; Sets = @('ByName', 'ById'); Default = 'ByName' }
            @{ Name = 'Set-Something'; Count = 2; Sets = @('ByValue', 'ByInputObject'); Default = 'ByValue' }
        ) {
            $node = Get-FunctionNode $graph $Name
            $node.ParameterSets.Count | Should -Be $Count
            @($node.ParameterSets.Name) | Should -Be $Sets
            ($node.ParameterSets | Where-Object IsDefault).Name | Should -Be $Default
            $node.DefaultParameterSet | Should -Be $Default
        }

        It 'reads comment-based help, one entry per .EXAMPLE' {
            $node = Get-FunctionNode $graph 'Get-Something'
            $node.Help.Synopsis | Should -Be 'Gets a something by name or by id.'
            $node.Help.Examples.Count | Should -Be 2
            $node.Help.Examples[1] | Should -Match 'Get-Something -Id 7'
        }

        It 'puts each parameter''s .PARAMETER text on the parameter' {
            $node = Get-FunctionNode $graph 'Get-Something'
            ($node.Parameters | Where-Object Name -EQ 'Id').Description | Should -Be 'Id of the something.'
            ($node.Parameters | Where-Object Name -EQ 'Id').TypeName | Should -Be 'int'
        }

        It 'lets a build find public functions with fewer examples than parameter sets' {
            $short = $graph.Nodes |
                Where-Object IsExported |
                Where-Object { $_.Help.Examples.Count -lt $_.ParameterSets.Count }
            @($short.Name) | Should -Be @('Set-Something')
        }

        It 'leaves Help empty and ParameterSets empty on functions without them' {
            $node = Get-FunctionNode $graph 'Read-SomethingStore'
            $node.Help | Should -BeNullOrEmpty
            $node.ParameterSets.Count | Should -Be 1
            $node.ParameterSets[0].Name | Should -Be '__AllParameterSets'
        }
    }

    Context 'Parameter sets agree with Get-Command' {
        BeforeDiscovery {
            $fixture = Join-Path $PSScriptRoot 'fixtures/Signatures.psm1'
            $names = [System.Management.Automation.Language.Parser]::ParseFile($fixture, [ref]$null, [ref]$null).
                FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false).Name
            $cases = @($names | ForEach-Object { @{ Name = $_ } })
        }

        BeforeAll {
            $fixture = Join-Path $PSScriptRoot 'fixtures/Signatures.psm1'
            $fromAst = & (Get-Module PSModuleDependencyGraph) { param($p) Get-PSModuleFunction -Path $p } $fixture
            $loaded = Import-Module $fixture -Force -PassThru -WarningAction Ignore
            $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters

            function Format-SetFromCommand($Command) {
                $Command.ParameterSets | ForEach-Object {
                    "$($_.Name)$(if ($_.IsDefault) { '*' }): " + (($_.Parameters | Where-Object Name -NotIn $common | ForEach-Object {
                                "$($_.Name)$(if ($_.IsMandatory) { '!' })$(if ($_.Position -ge 0) { "@$($_.Position)" })$(if ($_.ValueFromPipeline) { '|' })"
                            }) -join ',')
                } | Sort-Object
            }
            function Format-SetFromAst($Function) {
                $Function.ParameterSets | ForEach-Object {
                    "$($_.Name)$(if ($_.IsDefault) { '*' }): " + (($_.Parameters | ForEach-Object {
                                "$($_.Name)$(if ($_.Mandatory) { '!' })$(if ($null -ne $_.Position) { "@$($_.Position)" })$(if ($_.ValueFromPipeline) { '|' })"
                            }) -join ',')
                } | Sort-Object
            }
        }

        AfterAll {
            $loaded | Remove-Module -Force
        }

        It '<Name>: sets, defaults, mandatory, positions and pipeline input match' -ForEach $cases {
            $fn = $fromAst | Where-Object Name -EQ $Name
            Format-SetFromAst $fn | Should -Be (Format-SetFromCommand (Get-Command -Module $loaded.Name -Name $Name))
        }
    }

    Context 'This module''s own help' {
        It 'gives every public function at least as many examples as parameter sets' {
            $graph = Get-PSModuleDependencyGraph -Path (Join-Path $RepoRoot 'src/PSModuleDependencyGraph')
            $short = $graph.Nodes |
                Where-Object IsExported |
                Where-Object { $_.Help.Examples.Count -lt $_.ParameterSets.Count } |
                ForEach-Object { "$($_.Name): $($_.Help.Examples.Count) examples, $($_.ParameterSets.Count) sets" }
            $short | Should -BeNullOrEmpty
        }
    }
}
