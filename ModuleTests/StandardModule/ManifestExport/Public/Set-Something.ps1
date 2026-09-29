function Set-Something {
    <#
    .SYNOPSIS
        Stores a something.
    .DESCRIPTION
        Two parameter sets but only one example: the kind of gap a build can
        catch by comparing ParameterSets with Help.Examples.
    .PARAMETER Value
        The value to store.
    .PARAMETER InputObject
        A something from Get-Something.
    .EXAMPLE
        Set-Something -Value 'alpha'
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByValue')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByValue', Position = 0)]
        [string] $Value,

        [Parameter(Mandatory, ParameterSetName = 'ByInputObject', ValueFromPipeline)]
        [pscustomobject] $InputObject
    )

    process {
        if ($InputObject) { $Value = $InputObject.Value }
        if (-not (Test-SomethingValid -Value $Value)) { return }
        Write-SomethingStore -Value $Value
    }
}
