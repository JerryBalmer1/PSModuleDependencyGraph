#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-EmbeddedJson {
        param([string] $Html, [string] $Id)
        [regex]::Match($Html, "(?s)<script type=""application/json"" id=""$Id"">(.*?)</script>").Groups[1].Value
    }
}

Describe 'Save-PSModuleDependencyGraphHtml' {
    Context 'ManifestExport, from the pipeline' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'out/ManifestExport.html')
            $html = [System.IO.File]::ReadAllText($file.FullName)
            $json = Get-EmbeddedJson $html 'graph-data'
            $data = $json | ConvertFrom-Json
            $config = Get-EmbeddedJson $html 'graph-config' | ConvertFrom-Json
            $byLabel = @{}
            foreach ($n in $data.nodes) { $byLabel[$n.label] = $n }
        }

        It 'takes the graph from Get-PSModuleDependencyGraph as a ModuleDependencyGraph' {
            $graph.GetType().Name | Should -Be 'ModuleDependencyGraph'
        }

        It 'writes the file, creating its folder, and returns it' {
            $file | Should -BeOfType System.IO.FileInfo
            $file.FullName | Should -Exist
        }

        It 'writes UTF-8 without a byte order mark' {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
            [System.Text.Encoding]::UTF8.GetString($bytes, 0, 15) | Should -Be '<!DOCTYPE html>'
        }

        It 'fills every placeholder' {
            $html | Should -Not -Match '\{\{[A-Z_]+\}\}'
        }

        It 'embeds vis-network, so the page works offline' {
            $html | Should -Match 'vis-network'
            $html | Should -Not -Match '<script[^>]+src='
        }

        It 'embeds exactly the graph''s nodes and edges, external commands included' {
            $data.nodes.Count | Should -Be $graph.Nodes.Count
            $data.edges.Count | Should -Be $graph.Edges.Count
            @($data.nodes | Where-Object group -EQ 'external').label | Sort-Object |
                Should -Be (Get-ExternalCommandName $graph)
        }

        It 'embeds the module list for the Modules panel' {
            @($data.modules.name) | Should -Be @($graph.Modules.Name)
            ($data.modules | Where-Object name -EQ 'SqlServer').installed | Should -BeFalse
        }

        It 'gives every edge both ends, each pointing at a node in the page' {
            $ids = @($data.nodes.id)
            foreach ($edge in $data.edges) {
                $edge.from | Should -BeIn $ids
                $edge.to | Should -BeIn $ids
            }
        }

        It 'puts <Label> in the <Group> group' -ForEach @(
            @{ Label = 'Get-Something'; Group = 'public' }
            @{ Label = 'Read-SomethingStore'; Group = 'private' }
            @{ Label = 'Remove-SomethingCache'; Group = 'unresolved' }
            @{ Label = 'Get-ChildItem'; Group = 'external' }
            @{ Label = 'SomethingRecord'; Group = 'class' }
            @{ Label = 'SomethingKind'; Group = 'enum' }
            @{ Label = '<script> ManifestExport.psm1'; Group = 'script' }
        ) {
            $byLabel[$Label].group | Should -Be $Group
        }

        It 'has a style in the config for every group the data uses' {
            foreach ($group in $data.nodes.group | Sort-Object -Unique) {
                $group | Should -BeIn $config.NodeGroups.Name
            }
        }

        It 'carries line ranges, parameter sets and the example count for the page' {
            $set = $byLabel['Set-Something']
            $set.startLine | Should -Be 1
            $set.endLine | Should -Be 29
            @($set.parameterSets.name) | Should -Be @('ByValue', 'ByInputObject')
            $set.exampleCount | Should -Be 1
            $set.cmdletBinding | Should -BeTrue
        }

        It 'carries modules for external commands and output types for functions and classes' {
            $byLabel['Get-ChildItem'].moduleName | Should -Be 'Microsoft.PowerShell.Management'
            $byLabel['Get-SomethingCache'].found | Should -BeFalse
            $byLabel['ConvertTo-SomethingObject'].undeclaredOutputType | Should -Be @('SomethingRecord')
            $byLabel['SomethingRecord'].undeclaredOutputBy | Should -Be @('ConvertTo-SomethingObject')
        }

        It 'writes paths relative to the module, with the module folder carried once for the right-click menu' {
            $byLabel['Get-Something'].path | Should -Be (Join-Path 'Public' 'Get-Something.ps1')
            $data.meta.rootPath | Should -Be $graph.ModuleBase
        }

        It 'uses the module name for the title by default' {
            $html | Should -Match '<title>ManifestExport dependency graph</title>'
        }
    }

    Context 'Config' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $defaults = Import-PowerShellDataFile (Join-Path $RepoRoot 'src/PSModuleDependencyGraph/Resources/GraphHtmlConfig.psd1')
        }

        It 'embeds the defaults: cyan public, blue private, magenta external, red unresolved' {
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'defaults.html')
            $config = Get-EmbeddedJson ([System.IO.File]::ReadAllText($file.FullName)) 'graph-config' | ConvertFrom-Json
            $colour = @{}
            foreach ($g in $config.NodeGroups) { $colour[$g.Name] = $g.Color }
            $colour['public'] | Should -Be '#22d3ee'
            $colour['private'] | Should -Be '#3b82f6'
            $colour['external'] | Should -Be '#e040fb'
            $colour['unresolved'] | Should -Be '#ff4d4f'
            $config.Show.Types | Should -Be @('public', 'private', 'unresolved', 'external', 'class', 'enum', 'script')
            $config.Theme.Background | Should -Be $defaults.Theme.Background
            $config.Layout.LeftToRight.LevelSeparation | Should -Be $defaults.Layout.LeftToRight.LevelSeparation
        }

        It 'merges a -ConfigPath file over the defaults, changing only what it sets' {
            $override = Join-Path $TestDrive 'override.psd1'
            Set-Content -LiteralPath $override -Value @'
@{
    Theme      = @{ Background = '#000000' }
    NodeGroups = @( @{ Name = 'public'; Color = '#00ff00' } )
    Layout     = @{ LeftToRight = @{ NodeSpacing = 90 } }
}
'@
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'override.html') -ConfigPath $override
            $config = Get-EmbeddedJson ([System.IO.File]::ReadAllText($file.FullName)) 'graph-config' | ConvertFrom-Json

            $config.Theme.Background | Should -Be '#000000'
            $config.Theme.Panel | Should -Be $defaults.Theme.Panel
            ($config.NodeGroups | Where-Object Name -EQ 'public').Color | Should -Be '#00ff00'
            ($config.NodeGroups | Where-Object Name -EQ 'public').Label | Should -Be 'Public'
            ($config.NodeGroups | Where-Object Name -EQ 'private').Color | Should -Be '#3b82f6'
            @($config.NodeGroups).Count | Should -Be $defaults.NodeGroups.Count
            $config.Layout.LeftToRight.NodeSpacing | Should -Be 90
            $config.Layout.LeftToRight.LevelSeparation | Should -Be $defaults.Layout.LeftToRight.LevelSeparation
        }

        It 'refuses a config with a bad value, naming the key' {
            $bad = Join-Path $TestDrive 'bad.psd1'
            Set-Content -LiteralPath $bad -Value "@{ NodeGroups = @( @{ Name = 'private'; Color = 'grey' } ); Show = @{ Types = @('public', 'nonsense') }; Layout = @{ Direction = 'Sideways' } }"
            { $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'bad.html') -ConfigPath $bad } |
                Should -Throw -ExpectedMessage "*NodeGroups 'private'.Color*Show.Types names 'nonsense'*Layout.Direction*"
        }

        It 'refuses a config file that does not exist' {
            { $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'x.html') -ConfigPath (Join-Path $TestDrive 'missing.psd1') } |
                Should -Throw -ExpectedMessage 'Config file not found*'
        }

        It 'builds the right-click menu from a list, Show in VS Code first' {
            $defaults.NodeMenu.Count | Should -BeGreaterThan 1
            $defaults.NodeMenu[0].Label | Should -Be 'Show in VS Code'
            $defaults.NodeMenu[0].Target | Should -Be 'vscode://file/{fileUrlPath}:{startLine}'
            ($defaults.NodeMenu | Where-Object Label -EQ 'Copy module name').When | Should -Be 'HasModule'
        }
    }

    Context 'Escaping' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $title = '</script><script>alert(1)</script>'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'escape.html') -Title $title
            $html = [System.IO.File]::ReadAllText($file.FullName)
            $json = Get-EmbeddedJson $html 'graph-data'
        }

        It 'HTML-encodes the title' {
            $html | Should -Not -Match ([regex]::Escape('<script>alert(1)'))
            $html | Should -Match ([regex]::Escape('&lt;/script&gt;&lt;script&gt;alert(1)'))
        }

        It 'keeps < out of the embedded data, so a name cannot close the script element' {
            # The <script> node label contains '<script>' literally.
            ($json | ConvertFrom-Json).nodes.label | Should -Contain '<script> ManifestExport.psm1'
            $json | Should -Not -Match '<'
        }
    }

    Context 'What it takes from the pipeline' {
        It 'still takes the graph after the module is changed and re-imported in the same session' {
            # PowerShell caches parsed files. With the class and Get changed but
            # Save not, a Save typed [ModuleDependencyGraph] kept the old class
            # and refused the new graph: "cannot be bound to any parameters".
            $copy = Join-Path $TestDrive 'reimport/PSModuleDependencyGraph'
            Copy-Item (Join-Path $RepoRoot 'src/PSModuleDependencyGraph') $copy -Recurse
            $fixture = Join-Path $ModuleTestsRoot 'StandardModule/ManifestExport'
            $out = Join-Path $TestDrive 'reimport.html'
            $result = pwsh -NoProfile -NonInteractive -Command "
                `$ErrorActionPreference = 'Stop'
                Import-Module '$copy/PSModuleDependencyGraph.psd1' -Force
                `$null = Get-PSModuleDependencyGraph -Path '$fixture' | Save-PSModuleDependencyGraphHtml -Path '$out'
                Add-Content '$copy/PSModuleDependencyGraph.psm1' '# changed'
                Add-Content '$copy/Public/Get-PSModuleDependencyGraph.ps1' '# changed'
                Import-Module '$copy/PSModuleDependencyGraph.psd1' -Force
                try { (Get-PSModuleDependencyGraph -Path '$fixture' | Save-PSModuleDependencyGraphHtml -Path '$out').Name }
                catch { 'FAILED: ' + `$_.Exception.Message }
            "
            $result | Select-Object -Last 1 | Should -Be 'reimport.html'
        }

        It 'takes a graph saved with Export-Clixml and read back' {
            $xml = Join-Path $TestDrive 'graph.clixml'
            Get-FixtureGraph 'StandardModule/ManifestExport' | Export-Clixml -Path $xml -Depth 8
            $restored = Import-Clixml -Path $xml
            $file = $restored | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'restored.html')
            $data = Get-EmbeddedJson ([System.IO.File]::ReadAllText($file.FullName)) 'graph-data' | ConvertFrom-Json
            $data.nodes.Count | Should -Be $restored.Nodes.Count
        }

        It 'refuses something that is not a graph, saying what is missing' {
            { [pscustomobject]@{ ModuleName = 'x' } | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'no.html') -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*has no Nodes, Edges property*'
        }
    }

    Context 'Ambiguous calls' {
        It 'keeps the resolution, so the page can draw both edges dashed' {
            $graph = Get-FixtureGraph 'StandardModule/NameCollision'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'collision.html')
            $data = Get-EmbeddedJson ([System.IO.File]::ReadAllText($file.FullName)) 'graph-data' | ConvertFrom-Json
            @($data.edges | Where-Object resolution -EQ 'Ambiguous').Count | Should -Be 2
        }
    }
}

Describe 'Get-PSModuleDependencyGraph -ShowInBrowser / -ShowInVSCode' {
    BeforeAll {
        $savedTemp = $env:TEMP
        $env:TEMP = Join-Path $TestDrive 'temp'
        $fixture = Join-Path $ModuleTestsRoot 'StandardModule/ManifestExport'
        $expected = Join-Path $env:TEMP 'PSModuleDependencyGraph/ManifestExport.html'
    }

    AfterAll {
        $env:TEMP = $savedTemp
    }

    Context '-ShowInBrowser' {
        BeforeAll {
            Mock -CommandName Start-Process -ModuleName PSModuleDependencyGraph
            $graph = Get-PSModuleDependencyGraph -Path $fixture -ShowInBrowser
        }

        It 'saves the page in $env:TEMP\PSModuleDependencyGraph, named after the module' {
            $expected | Should -Exist
        }

        It 'opens that file with the default handler' {
            Should -Invoke -CommandName Start-Process -ModuleName PSModuleDependencyGraph -Times 1 -Exactly -Scope Context -ParameterFilter {
                $FilePath -eq $expected
            }
        }

        It 'still returns the graph' {
            $graph.GetType().Name | Should -Be 'ModuleDependencyGraph'
            $graph.ModuleName | Should -Be 'ManifestExport'
        }
    }

    Context '-ShowInVSCode' {
        It 'saves the page and hands it to VS Code' {
            Mock -CommandName Show-GraphHtml -ModuleName PSModuleDependencyGraph
            $graph = Get-PSModuleDependencyGraph -Path $fixture -ShowInVSCode
            $expected | Should -Exist
            Should -Invoke -CommandName Show-GraphHtml -ModuleName PSModuleDependencyGraph -Times 1 -Exactly -ParameterFilter {
                $Path -eq $expected -and $In -eq 'VSCode'
            }
            $graph.ModuleName | Should -Be 'ManifestExport'
        }

        It 'says how to fix it when the code command is not on PATH' {
            Mock -CommandName Get-Command -ModuleName PSModuleDependencyGraph -ParameterFilter { $Name -contains 'code' }
            { & (Get-Module PSModuleDependencyGraph) { Show-GraphHtml -Path 'x.html' -In VSCode } } |
                Should -Throw -ExpectedMessage "*'code' command was not found on PATH*"
        }
    }
}
