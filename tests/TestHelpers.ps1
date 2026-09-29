$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ModuleTestsRoot = Join-Path $script:RepoRoot 'ModuleTests'

Import-Module (Join-Path $script:RepoRoot 'src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1') -Force

function Get-FixtureGraph {
    param([Parameter(Mandatory)] [string] $RelativePath)
    Get-PSModuleDependencyGraph -Path (Join-Path $script:ModuleTestsRoot $RelativePath)
}

function Get-FunctionNode {
    param($Graph, [string] $Name)
    @($Graph.Nodes | Where-Object { $_.Kind -eq 'Function' -and $_.Name -eq $Name })
}

function Get-EdgePair {
    param($Graph)
    @($Graph.Edges | ForEach-Object { "$($_.SourceName)->$($_.TargetName)" } | Sort-Object)
}
