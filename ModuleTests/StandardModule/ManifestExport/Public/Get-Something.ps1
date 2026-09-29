function Get-Something {
    <#
    .SYNOPSIS
        Gets a something by name or by id.
    .PARAMETER Name
        Name of the something.
    .PARAMETER Id
        Id of the something.
    .EXAMPLE
        Get-Something -Name 'alpha'
    .EXAMPLE
        Get-Something -Id 7
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [string] $Name,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [int] $Id
    )

    $cached = Get-SomethingCache -Key "$Name$Id"
    if ($cached) { return $cached }

    $raw = Read-SomethingStore
    ConvertTo-SomethingObject -InputObject $raw
}
