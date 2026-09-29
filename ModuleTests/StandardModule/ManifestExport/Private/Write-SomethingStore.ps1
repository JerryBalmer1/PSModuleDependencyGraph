function Write-SomethingStore {
    param($Value)
    $query = "INSERT INTO Something (Value) VALUES ('$Value')" | ConvertTo-Json
    SqlServer\Invoke-Sqlcmd -Query $query
}
