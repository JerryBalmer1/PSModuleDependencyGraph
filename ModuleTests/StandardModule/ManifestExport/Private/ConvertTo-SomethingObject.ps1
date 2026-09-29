function ConvertTo-SomethingObject {
    param($InputObject)
    [pscustomobject]@{ Value = $InputObject }
}
