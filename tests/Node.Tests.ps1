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

        It 'gives every node an array, never $null, for <Property>' -ForEach @(
            'DependsOn', 'UsedBy', 'ExternalCalls', 'ModulesUsed', 'Parameters', 'ParameterSets',
            'OutputType', 'InferredOutputType', 'UndeclaredOutputType', 'OutputBy', 'UndeclaredOutputBy'
        ).ForEach({ @{ Property = $_ } }) {
            foreach ($node in $graph.Nodes) {
                , $node.$Property | Should -BeOfType [array] -Because "$($node.Kind) $($node.Name).$Property"
            }
        }

        It 'records where each function starts and ends' {
            $node = Get-FunctionNode $graph 'Get-Something'
            $node.StartLine | Should -Be 1
            $node.EndLine | Should -Be 29
        }

        It 'gives <Name> the Type <Type>' -ForEach @(
            @{ Name = 'Get-Something'; Type = 'Public' }
            @{ Name = 'Read-SomethingStore'; Type = 'Private' }
            @{ Name = 'Remove-SomethingCache'; Type = 'Unresolved' }
            @{ Name = 'Get-ChildItem'; Type = 'External' }
            @{ Name = 'SomethingRecord'; Type = 'Class' }
            @{ Name = 'SomethingKind'; Type = 'Enum' }
            @{ Name = '<script>'; Type = 'Script' }
        ) {
            ($graph.Nodes | Where-Object Name -EQ $Name).Type | Should -Be $Type
        }

        It 'lists by name what a function calls and what calls it' {
            $get = Get-FunctionNode $graph 'Get-Something'
            $get.DependsOn | Should -Be @('ConvertTo-SomethingObject', 'Read-SomethingStore', 'SomethingRecord')
            $get.UsedBy | Should -BeNullOrEmpty
            (Get-FunctionNode $graph 'Read-SomethingStore').UsedBy | Should -Be @('Get-Something')
        }

        It 'lists the external commands a function calls, and their modules' {
            (Get-FunctionNode $graph 'Get-Something').ExternalCalls | Should -Be @('Get-SomethingCache')
            $write = Get-FunctionNode $graph 'Write-SomethingStore'
            $write.ExternalCalls | Should -Be @('ConvertTo-Json', 'Invoke-Sqlcmd')
            $write.ModulesUsed | Should -Be @('Microsoft.PowerShell.Utility', 'SqlServer')
        }

        It 'marks a private function nothing calls as Unresolved, and nothing else' {
            @($graph.Unresolved.Name) | Should -Be @('Remove-SomethingCache')
            $graph.Stats.UnresolvedCount | Should -Be 1
        }

        It 'makes each external command a node, with the module that provides it' {
            Get-ExternalCommandName $graph | Should -Be @('ConvertTo-Json', 'Get-ChildItem', 'Get-SomethingCache', 'Invoke-Sqlcmd', 'Join-Path', 'Test-SomethingValid')
            $gci = $graph.Nodes | Where-Object Name -EQ 'Get-ChildItem'
            $gci.ModuleName | Should -Be 'Microsoft.PowerShell.Management'
            $gci.CommandType | Should -Be 'Cmdlet'
            $gci.IsFound | Should -BeTrue
            $gci.UsedBy | Should -Be @('<script>')
        }

        It 'takes the module from Module\Command even when that module is not installed' {
            $sql = $graph.Nodes | Where-Object Name -EQ 'Invoke-Sqlcmd'
            $sql.ModuleName | Should -Be 'SqlServer'
            $sql.IsFound | Should -BeFalse
        }

        It 'reports a command nothing on this machine provides as not found, with no module' {
            $missing = $graph.Nodes | Where-Object Name -EQ 'Get-SomethingCache'
            $missing.IsFound | Should -BeFalse
            $missing.ModuleName | Should -BeNullOrEmpty
            $graph.Stats.NotFoundCommandCount | Should -Be 3
        }

        It 'lists every module the code depends on, and how each was named' {
            @($graph.Modules.Name) | Should -Be @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'SqlServer')
            $sql = $graph.Modules | Where-Object Name -EQ 'SqlServer'
            $sql.DeclaredBy | Should -Be @('Module\Command', 'RequiredModules')
            $sql.IsInstalled | Should -BeFalse
            $sql.Commands | Should -Be @('Invoke-Sqlcmd')
            $sql.UsedBy | Should -Be @('Write-SomethingStore')
            ($graph.Modules | Where-Object Name -EQ 'Microsoft.PowerShell.Management').IsInstalled | Should -BeTrue
        }

        It 'looks commands up without importing the module that has them' {
            # A fresh process, and a module no session loads by itself: in this
            # test run's own session the answer could come from an earlier import.
            $manifest = Join-Path $RepoRoot 'src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1'
            $result = pwsh -NoProfile -NonInteractive -Command "
                Import-Module '$manifest'
                `$lookup = & (Get-Module PSModuleDependencyGraph) { Resolve-ExternalCommand -Name 'Compress-Archive' }
                `$lookup.Commands['Compress-Archive'].ModuleName
                [bool](Get-Module Microsoft.PowerShell.Archive)
            "
            $result[0] | Should -Be 'Microsoft.PowerShell.Archive'
            $result[1] | Should -Be 'False'
        }

        It 'says whether a function uses [CmdletBinding()]' {
            (Get-FunctionNode $graph 'Get-Something').CmdletBinding | Should -BeTrue
            (Get-FunctionNode $graph 'Read-SomethingStore').CmdletBinding | Should -BeFalse
        }

        It 'reads declared and inferred output types' {
            $get = Get-FunctionNode $graph 'Get-Something'
            $get.OutputType | Should -Be @('SomethingRecord')
            $get.UndeclaredOutputType | Should -BeNullOrEmpty
            $convert = Get-FunctionNode $graph 'ConvertTo-SomethingObject'
            $convert.OutputType | Should -BeNullOrEmpty
            $convert.InferredOutputType | Should -Be @('SomethingRecord')
            $convert.UndeclaredOutputType | Should -Be @('SomethingRecord')
            (Get-FunctionNode $graph 'Get-SomethingKind').InferredOutputType | Should -Be @('SomethingKind')
        }

        It 'marks on a class which functions output it, and which do so without declaring it' {
            $record = $graph.Nodes | Where-Object Name -EQ 'SomethingRecord'
            $record.OutputBy | Should -Be @('ConvertTo-SomethingObject', 'Get-Something')
            $record.UndeclaredOutputBy | Should -Be @('ConvertTo-SomethingObject')
            ($graph.Nodes | Where-Object Name -EQ 'SomethingKind').UndeclaredOutputBy | Should -Be @('Get-SomethingKind')
        }

        It 'keeps roots and leaves to the module''s own code' {
            $graph.Roots.Kind | Should -Not -Contain 'Command'
            $graph.Leaves.Kind | Should -Not -Contain 'Command'
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
