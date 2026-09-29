function Get-Something {
    ConvertTo-Something -Value 1
}

function ConvertTo-Something {
    param($Value)
    $Value * 2
}
