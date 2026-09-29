function Get-Something {
    New-Something
}

function Get-SomethingElse {
    Get-Something
}

function New-Something {
    [pscustomobject]@{}
}
