function New-GraphNode {
    <#
    .SYNOPSIS
        One node of the dependency graph, with the same properties whatever its kind.
    .DESCRIPTION
        Every node carries every property, so a caller running under
        Set-StrictMode can read .Help on a class node or .ModuleName on a
        function and get $null rather than an error.

        Type, DependsOn, UsedBy, ExternalCalls, ModulesUsed and the output-type
        cross references are filled in by Get-PSModuleDependencyGraph once the
        edges are known.
    .PARAMETER Kind
        Function, Class, Enum, Script (a file's top level) or Command (a command
        from outside the module).
    .PARAMETER Function
        A FunctionInfo from Get-PSModuleFunction. Its export state, signature,
        help and output types are copied onto the node.
    .PARAMETER Command
        For a Command node: the lookup result from Resolve-ExternalCommand.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Function', 'Class', 'Enum', 'Script', 'Command')] [string] $Kind,
        [string] $Path,
        $StartLine,
        $EndLine,
        [pscustomobject] $Function,
        [pscustomobject] $Command
    )

    $type = switch ($Kind) {
        'Class' { 'Class' }
        'Enum' { 'Enum' }
        'Script' { 'Script' }
        'Command' { 'External' }
        default { if ($Function -and $Function.IsExported) { 'Public' } else { 'Private' } }
    }

    [pscustomobject]@{
        PSTypeName           = 'PSModuleDependencyGraph.GraphNode'
        Id                   = $Id
        Name                 = $Name
        Kind                 = $Kind
        Type                 = $type
        IsExported           = if ($Function) { [bool]$Function.IsExported } else { $false }
        ExportState          = if ($Function) { $Function.ExportState } else { $null }
        ExportSource         = if ($Function) { $Function.ExportSource } else { $null }
        Path                 = $Path
        StartLine            = $StartLine
        EndLine              = $EndLine
        DependsOn            = [string[]]@()
        UsedBy               = [string[]]@()
        ExternalCalls        = [string[]]@()
        ModulesUsed          = [string[]]@()
        CmdletBinding        = if ($Function) { [bool]$Function.CmdletBinding } else { $false }
        DefaultParameterSet  = if ($Function) { $Function.DefaultParameterSet } else { $null }
        Parameters           = if ($Function) { @($Function.Parameters) } else { @() }
        ParameterSets        = if ($Function) { @($Function.ParameterSets) } else { @() }
        Help                 = if ($Function) { $Function.Help } else { $null }
        OutputType           = if ($Function) { [string[]]@($Function.OutputType) } else { [string[]]@() }
        InferredOutputType   = if ($Function) { [string[]]@($Function.InferredOutputType) } else { [string[]]@() }
        UndeclaredOutputType = [string[]]@()
        OutputBy             = [string[]]@()
        UndeclaredOutputBy   = [string[]]@()
        ModuleName           = if ($Command) { $Command.ModuleName } else { $null }
        ModuleVersion        = if ($Command) { $Command.ModuleVersion } else { $null }
        CommandType          = if ($Command) { $Command.CommandType } else { $null }
        ResolvesTo           = if ($Command) { $Command.ResolvesTo } else { $null }
        IsFound              = if ($Command) { [bool]$Command.Found } else { $true }
    }
}
