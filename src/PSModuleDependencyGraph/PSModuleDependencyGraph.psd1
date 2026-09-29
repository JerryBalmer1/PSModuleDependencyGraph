@{
    RootModule           = 'PSModuleDependencyGraph.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'e4b1c9a2-7d3f-4c68-9a15-2f0e8b6d4c31'
    Author               = 'Jerry Balmer'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 Jerry Balmer. MIT License.'
    Description          = 'Builds a dependency graph of the public and private functions in a PowerShell module or script, statically through the AST. Nothing is imported, dot-sourced, or executed.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Get-PSModuleDependencyGraph', 'Save-PSModuleDependencyGraphHtml')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('AST', 'Module', 'Dependency', 'StaticAnalysis', 'Graph', 'PowerShell')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/JerryBalmer1/PSModuleDependencyGraph'
        }
    }
}
