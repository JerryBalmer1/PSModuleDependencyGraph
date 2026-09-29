function Invoke-Something {
    Get-Something | Out-Null
    Assert-Something
}
