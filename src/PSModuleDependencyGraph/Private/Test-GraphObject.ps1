function Test-GraphObject {
    <#
    .SYNOPSIS
        True when an object has the shape of a dependency graph; throws, saying what is missing, when not.
    .DESCRIPTION
        Graphs are taken by shape rather than by the ModuleDependencyGraph type.
        A type check breaks across re-imports - see New-ModuleDependencyGraph in
        the .psm1 - and would refuse a graph saved with Export-Clixml and read
        back, which has every property and no class.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject
    )

    $missing = @('ModuleName', 'Nodes', 'Edges') | Where-Object { -not $InputObject.PSObject.Properties[$_] }
    if ($missing) {
        throw "Expected a graph from Get-PSModuleDependencyGraph; this object has no $($missing -join ', ') property."
    }
    $true
}
