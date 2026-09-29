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

# Calls between the module's own functions: no calls to external commands, no
# output or inheritance edges.
function Get-EdgePair {
    param($Graph)
    @($Graph.Edges |
            Where-Object { $_.Kind -eq 'CommandReference' -and $_.Resolution -ne 'External' } |
            ForEach-Object { "$($_.SourceName)->$($_.TargetName)" } |
            Sort-Object)
}

function Get-ExternalCommandName {
    param($Graph)
    @($Graph.Nodes | Where-Object Kind -EQ 'Command' | ForEach-Object Name | Sort-Object)
}
