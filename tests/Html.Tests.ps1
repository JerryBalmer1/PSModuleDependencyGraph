#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Get-EmbeddedGraphData {
        param([string] $Html)
        $match = [regex]::Match($Html, '(?s)<script type="application/json" id="graph-data">(.*?)</script>')
        $match.Groups[1].Value
    }
}

Describe 'Save-PSModuleDependencyGraphHtml' {
    Context 'ManifestExport, from the pipeline' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'out/ManifestExport.html')
            $html = [System.IO.File]::ReadAllText($file.FullName)
            $json = Get-EmbeddedGraphData $html
            $data = $json | ConvertFrom-Json
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

        It 'embeds one node per graph node and one edge per graph edge' {
            $data.nodes.Count | Should -Be $graph.Nodes.Count
            $data.edges.Count | Should -Be $graph.Edges.Count
        }

        It 'gives every edge both ends, each pointing at a node in the page' {
            $ids = @($data.nodes.id)
            foreach ($edge in $data.edges) {
                $edge.from | Should -BeIn $ids
                $edge.to | Should -BeIn $ids
            }
        }

        It 'marks exported and not-exported functions as different groups' {
            ($data.nodes | Where-Object label -EQ 'Get-Something').group | Should -Be 'exported'
            ($data.nodes | Where-Object label -EQ 'Read-SomethingStore').group | Should -Be 'internal'
        }

        It 'writes paths relative to the module, not absolute' {
            $json | Should -Not -Match ([regex]::Escape(($graph.ModuleBase | ConvertTo-Json).Trim('"')))
            ($data.nodes | Where-Object label -EQ 'Get-Something').path | Should -Be (Join-Path 'Public' 'Get-Something.ps1')
        }

        It 'leaves unresolved commands out unless asked' {
            $data.hasUnresolved | Should -BeFalse
            @($data.nodes | Where-Object group -EQ 'external').Count | Should -Be 0
        }

        It 'uses the module name for the title by default' {
            $html | Should -Match '<title>ManifestExport dependency graph</title>'
        }
    }

    Context 'Escaping' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $title = '</script><script>alert(1)</script>'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'escape.html') -Title $title
            $html = [System.IO.File]::ReadAllText($file.FullName)
            $json = Get-EmbeddedGraphData $html
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

    Context 'IncludeUnresolved' {
        BeforeAll {
            $graph = Get-FixtureGraph 'StandardModule/ManifestExport'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'unresolved.html') -IncludeUnresolved
            $data = Get-EmbeddedGraphData ([System.IO.File]::ReadAllText($file.FullName)) | ConvertFrom-Json
        }

        It 'adds one node per unresolved command, joined to its caller' {
            $external = @($data.nodes | Where-Object group -EQ 'external')
            @($external.label | Sort-Object) | Should -Be @('Get-ChildItem', 'Join-Path')
            $ids = @($data.nodes.id)
            foreach ($edge in $data.edges | Where-Object kind -EQ 'Unresolved') {
                $edge.from | Should -BeIn $ids
                $edge.to | Should -BeIn $external.id
            }
            $data.hasUnresolved | Should -BeTrue
        }
    }

    Context 'Ambiguous calls' {
        It 'keeps the resolution, so the page can draw both edges dashed' {
            $graph = Get-FixtureGraph 'StandardModule/NameCollision'
            $file = $graph | Save-PSModuleDependencyGraphHtml -Path (Join-Path $TestDrive 'collision.html')
            $data = Get-EmbeddedGraphData ([System.IO.File]::ReadAllText($file.FullName)) | ConvertFrom-Json
            @($data.edges | Where-Object resolution -EQ 'Ambiguous').Count | Should -Be 2
        }
    }
}

Describe 'Get-PSModuleDependencyGraph -Show' {
    BeforeAll {
        $savedTemp = $env:TEMP
        $env:TEMP = Join-Path $TestDrive 'temp'
        Mock -CommandName Start-Process -ModuleName PSModuleDependencyGraph
        $graph = Get-PSModuleDependencyGraph -Path (Join-Path $ModuleTestsRoot 'StandardModule/ManifestExport') -Show
        $expected = Join-Path $env:TEMP 'PSModuleDependencyGraph/ManifestExport.html'
    }

    AfterAll {
        $env:TEMP = $savedTemp
    }

    It 'saves the page as $env:TEMP\PSModuleDependencyGraph\<ModuleName>.html' {
        $expected | Should -Exist
    }

    It 'opens that file with the default handler' {
        Should -Invoke -CommandName Start-Process -ModuleName PSModuleDependencyGraph -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $FilePath -eq $expected
        }
    }

    It 'still returns the graph' {
        $graph.GetType().Name | Should -Be 'ModuleDependencyGraph'
        $graph.ModuleName | Should -Be 'ManifestExport'
    }
}
