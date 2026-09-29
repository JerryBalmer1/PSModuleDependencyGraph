function Get-Something {
    Get-SomethingInternal
}

function Set-Something {
    param($Value)
    Get-SomethingInternal | Out-Null
    $Value
}

function Get-SomethingInternal {
    'internal'
}

Export-ModuleMember -Function Get-Something, Set-Something
