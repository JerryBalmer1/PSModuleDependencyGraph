# Parameter shapes whose sets Get-Command reports in ways that are easy to get
# wrong from the source alone. Signature.Tests.ps1 checks the AST reading of
# each against Get-Command after importing this file.

function Get-Plain($x, [int] $y = 3) { }

function Get-NoSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [switch] $Force)
}

function Get-TwoSet {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)][string] $Name,
        [Parameter(Mandatory, ParameterSetName = 'ById')][int] $Id,
        [Parameter(ValueFromPipeline)][object] $InputObject,
        [Alias('f', 'Frc')][switch] $Force
    )
}

function Get-UnusedDefault {
    [CmdletBinding(DefaultParameterSetName = 'Nothing')]
    param([Parameter(ParameterSetName = 'A')] $a, $b)
}

function Get-MultiMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'One')]
        [Parameter(ParameterSetName = 'Two')]
        [string] $Shared,
        [Parameter(ParameterSetName = 'Two', Mandatory = $true)] $OnlyTwo
    )
}

function Get-DefaultOnly {
    [CmdletBinding(DefaultParameterSetName = 'Solo')]
    param($p)
}

function Get-ExplicitPosition {
    param([Parameter(Position = 1)] $a, $b)
}

function Get-NoPositionalBinding {
    [CmdletBinding(PositionalBinding = $false)]
    param($a, $b)
}

function Get-SwitchSkipped {
    param([Parameter(Mandatory)] $a, [switch] $s, $b)
}
