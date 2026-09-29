#Requires -Version 7.4
Set-StrictMode -Version Latest

# Module scope, so every function in this module sees it through the scope chain:
# a native command that exits non-zero raises an error governed by
# $ErrorActionPreference instead of passing silently.
$PSNativeCommandUseErrorActionPreference = $true

# Captured once at import. Inside a dot-sourced function $PSScriptRoot is that
# function's own folder, so Resources/ is found from here.
$script:ModuleRoot = $PSScriptRoot

# What Get-PSModuleDependencyGraph returns and Save-PSModuleDependencyGraphHtml
# takes from the pipeline. Nodes, edges and the rest stay pscustomobjects.
class ModuleDependencyGraph {
    [string]   $ModuleName
    [version]  $ModuleVersion
    [string]   $ModuleBase
    [string]   $ManifestPath
    [object[]] $Nodes = @()
    [object[]] $Edges = @()
    [object[]] $Roots = @()
    [object[]] $Leaves = @()
    [object[]] $Unresolved = @()
    [object[]] $ExternalCommands = @()
    [object[]] $Modules = @()
    [object[]] $ExternalReferences = @()
    [string[]] $AmbiguousNames = @()
    [object[]] $Functions = @()
    [object[]] $Classes = @()
    [object[]] $Enums = @()
    [object[]] $Assemblies = @()
    [object[]] $UsingStatements = @()
    [object]   $Manifest
    [object]   $Stats
}

$private = Join-Path $PSScriptRoot 'Private'
if (Test-Path -LiteralPath $private) {
    Get-ChildItem -Path $private -Filter '*.ps1' -File -Recurse | Sort-Object FullName | ForEach-Object {
        . $_.FullName
    }
}

$public = Join-Path $PSScriptRoot 'Public'
$publicFunctions = @()
if (Test-Path -LiteralPath $public) {
    Get-ChildItem -Path $public -Filter '*.ps1' -File -Recurse | Sort-Object FullName | ForEach-Object {
        . $_.FullName
        $publicFunctions += [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    }
}

if ($publicFunctions.Count -gt 0) {
    Export-ModuleMember -Function $publicFunctions
}
