function Get-Something {
    $raw = Read-SomethingStore
    ConvertTo-SomethingObject -InputObject $raw
}
