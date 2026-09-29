function ConvertTo-SomethingObject {
    # Outputs a SomethingRecord but has no [OutputType()] saying so.
    param($InputObject)
    [SomethingRecord]@{ Value = $InputObject; Kind = Get-SomethingKind }
}

function Get-SomethingKind {
    [SomethingKind]::Primary
}
