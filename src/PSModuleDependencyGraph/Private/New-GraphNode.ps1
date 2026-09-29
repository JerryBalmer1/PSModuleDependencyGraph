function New-GraphNode {
    <#
    .SYNOPSIS
        One node of the dependency graph, with the same properties whatever its kind.
    .DESCRIPTION
        Every node carries every property, so a caller running under
        Set-StrictMode can read .Help or .ParameterSets on a class node and get
        $null rather than an error. DependsOn, UsedBy, UnresolvedCalls and
        IsDangling are filled in by Get-PSModuleDependencyGraph once the edges
        are known.
    .PARAMETER Function
        A FunctionInfo from Get-PSModuleFunction. Its export state, signature and
        help are copied onto the node.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Function', 'Class', 'Enum', 'Script')] [string] $Kind,
        [string] $Path,
        $StartLine,
        $EndLine,
        [pscustomobject] $Function
    )

    [pscustomobject]@{
        PSTypeName          = 'PSModuleDependencyGraph.GraphNode'
        Id                  = $Id
        Name                = $Name
        Kind                = $Kind
        IsExported          = if ($Function) { [bool]$Function.IsExported } else { $false }
        ExportState         = if ($Function) { $Function.ExportState } else { $null }
        ExportSource        = if ($Function) { $Function.ExportSource } else { $null }
        IsDangling          = $false
        Path                = $Path
        StartLine           = $StartLine
        EndLine             = $EndLine
        DependsOn           = [string[]]@()
        UsedBy              = [string[]]@()
        UnresolvedCalls     = [string[]]@()
        CmdletBinding       = if ($Function) { $Function.CmdletBinding } else { $false }
        DefaultParameterSet = if ($Function) { $Function.DefaultParameterSet } else { $null }
        Parameters          = if ($Function) { @($Function.Parameters) } else { @() }
        ParameterSets       = if ($Function) { @($Function.ParameterSets) } else { @() }
        Help                = if ($Function) { $Function.Help } else { $null }
    }
}
