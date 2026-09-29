function Get-PSModuleManifest {
    <#
    .SYNOPSIS
        Returns the parsed .psd1 surface and declared dependencies for a module.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(ParameterSetName = 'ByName')]
        [version] $RequiredVersion,

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'ByModuleInfo', ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.PSModuleInfo] $ModuleInfo
    )

    process {
        $target = Resolve-BoundParameter -Name $Name -RequiredVersion $RequiredVersion -Path $Path -ModuleInfo $ModuleInfo -ParameterSetName $PSCmdlet.ParameterSetName

        if (-not $target.ManifestPath) {
            [pscustomobject]@{
                PSTypeName       = 'PSModuleDependencyGraph.ManifestInfo'
                ModuleName       = $target.Name
                ModuleVersion    = $target.Version
                ModuleBase       = $target.ModuleBase
                ManifestPath     = $null
                HasManifest      = $false
                ParseSucceeded   = $false
                ParseError       = 'No module manifest (.psd1) found.'
                Manifest         = $null
                RootModule       = $null
                NestedModules    = @()
                RequiredModules  = @()
                RequiredAssemblies = @()
                ScriptsToProcess = @()
                FunctionsToExport = @()
                AliasesToExport  = @()
                CmdletsToExport  = @()
                VariablesToExport = @()
                GUID             = $null
                Author           = $null
                Description      = $null
                PowerShellVersion = $null
                CompatiblePSEditions = @()
                Tags             = @()
                ProjectUri       = $null
                LicenseUri       = $null
            }
            return
        }

        $parseError = $null
        $data = $null
        try {
            $data = Import-PowerShellDataFile -LiteralPath $target.ManifestPath -ErrorAction Stop
        }
        catch {
            $parseError = $_.Exception.Message
        }

        $requiredModules = @()
        $requiredModulesRaw = Get-HashtableValue -InputObject $data -Key 'RequiredModules'
        if ($requiredModulesRaw) {
            foreach ($rm in @($requiredModulesRaw)) {
                if ($rm -is [hashtable] -or $rm -is [System.Collections.IDictionary]) {
                    $requiredModules += [pscustomobject]@{
                        Name            = Get-HashtableValue -InputObject $rm -Key 'ModuleName'
                        ModuleVersion   = Get-HashtableValue -InputObject $rm -Key 'ModuleVersion'
                        RequiredVersion = Get-HashtableValue -InputObject $rm -Key 'RequiredVersion'
                        GUID            = Get-HashtableValue -InputObject $rm -Key 'GUID'
                        MaximumVersion  = Get-HashtableValue -InputObject $rm -Key 'MaximumVersion'
                    }
                }
                else {
                    $requiredModules += [pscustomobject]@{
                        Name            = [string]$rm
                        ModuleVersion   = $null
                        RequiredVersion = $null
                        GUID            = $null
                        MaximumVersion  = $null
                    }
                }
            }
        }

        $psData = $null
        $privateData = Get-HashtableValue -InputObject $data -Key 'PrivateData'
        if ($privateData) {
            $psData = Get-HashtableValue -InputObject $privateData -Key 'PSData'
        }

        $moduleVersionRaw = Get-HashtableValue -InputObject $data -Key 'ModuleVersion'
        [pscustomobject]@{
            PSTypeName           = 'PSModuleDependencyGraph.ManifestInfo'
            ModuleName           = $target.Name
            ModuleVersion        = if ($moduleVersionRaw) { [version]$moduleVersionRaw } else { $target.Version }
            ModuleBase           = $target.ModuleBase
            ManifestPath         = $target.ManifestPath
            HasManifest          = $true
            ParseSucceeded       = ($null -ne $data)
            ParseError           = $parseError
            Manifest             = $data
            RootModule           = Get-HashtableValue -InputObject $data -Key 'RootModule'
            NestedModules        = @(Get-HashtableValue -InputObject $data -Key 'NestedModules' -Default @())
            RequiredModules      = $requiredModules
            RequiredAssemblies   = @(Get-HashtableValue -InputObject $data -Key 'RequiredAssemblies' -Default @())
            ScriptsToProcess     = @(Get-HashtableValue -InputObject $data -Key 'ScriptsToProcess' -Default @())
            FunctionsToExport    = @(Get-HashtableValue -InputObject $data -Key 'FunctionsToExport' -Default @())
            AliasesToExport      = @(Get-HashtableValue -InputObject $data -Key 'AliasesToExport' -Default @())
            CmdletsToExport      = @(Get-HashtableValue -InputObject $data -Key 'CmdletsToExport' -Default @())
            VariablesToExport    = @(Get-HashtableValue -InputObject $data -Key 'VariablesToExport' -Default @())
            GUID                 = Get-HashtableValue -InputObject $data -Key 'GUID'
            Author               = Get-HashtableValue -InputObject $data -Key 'Author'
            Description          = Get-HashtableValue -InputObject $data -Key 'Description'
            PowerShellVersion    = Get-HashtableValue -InputObject $data -Key 'PowerShellVersion'
            CompatiblePSEditions = @(Get-HashtableValue -InputObject $data -Key 'CompatiblePSEditions' -Default @())
            Tags                 = @(Get-HashtableValue -InputObject $psData -Key 'Tags' -Default @())
            ProjectUri           = Get-HashtableValue -InputObject $psData -Key 'ProjectUri'
            LicenseUri           = Get-HashtableValue -InputObject $psData -Key 'LicenseUri'
        }
    }
}
