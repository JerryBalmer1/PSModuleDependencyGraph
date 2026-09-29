@{
    RootModule        = 'ManifestExport.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '9e7d6c5b-4a39-4821-b0f1-e2d3c4b5a697'
    FunctionsToExport = @('Get-Something', 'Set-Something')
    RequiredModules   = @('SqlServer')
}
