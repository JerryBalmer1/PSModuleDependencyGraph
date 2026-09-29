function Get-Something {
    Test-Something
}

function Test-Something {
    $true
}

function Remove-Something {
    if (Test-Something) { 'removed' }
}
