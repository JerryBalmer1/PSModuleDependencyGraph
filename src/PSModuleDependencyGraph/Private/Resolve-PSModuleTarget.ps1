function Resolve-PSModuleTarget {
    <#
    .SYNOPSIS
        Resolves a module identity (name, path, or PSModuleInfo) to a static inspection context.
    .DESCRIPTION
        Never imports or executes the target module. Locates the module root and optional
        manifest path so callers can walk source files via the AST only.
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
        $moduleName = $null
        $moduleVersion = $null
        $moduleBase = $null
        $manifestPath = $null
        $rootModulePath = $null
        $resolutionSource = $null
        # True when the caller pointed at one .ps1/.psm1 with no sibling manifest.
        # Only that file is inspected; anything else in its folder is not part of it.
        $isSingleFile = $false

        switch ($PSCmdlet.ParameterSetName) {
            'ByModuleInfo' {
                $moduleName = $ModuleInfo.Name
                $moduleVersion = $ModuleInfo.Version
                $moduleBase = $ModuleInfo.ModuleBase
                $resolutionSource = 'ModuleInfo'

                if ($ModuleInfo.Path -and (Test-Path -LiteralPath $ModuleInfo.Path)) {
                    if ($ModuleInfo.Path -like '*.psd1') {
                        $manifestPath = $ModuleInfo.Path
                    }
                    else {
                        $rootModulePath = $ModuleInfo.Path
                    }
                }

                if (-not $manifestPath) {
                    $candidate = Join-Path $moduleBase "$moduleName.psd1"
                    if (Test-Path -LiteralPath $candidate) {
                        $manifestPath = $candidate
                    }
                }
            }

            'ByPath' {
                $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
                if (-not (Test-Path -LiteralPath $resolved)) {
                    throw "Path not found: $Path"
                }

                $item = Get-Item -LiteralPath $resolved
                $resolutionSource = 'Path'

                if ($item.PSIsContainer) {
                    $moduleBase = $item.FullName
                    $psd1 = @(Get-ChildItem -Path $moduleBase -Filter '*.psd1' -File -ErrorAction SilentlyContinue)
                    if ($psd1.Count -eq 1) {
                        $manifestPath = $psd1[0].FullName
                        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($psd1[0].Name)
                    }
                    elseif ($psd1.Count -gt 1) {
                        $byFolder = $psd1 | Where-Object {
                            [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $item.Name
                        } | Select-Object -First 1
                        if ($byFolder) {
                            $manifestPath = $byFolder.FullName
                            $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($byFolder.Name)
                        }
                        else {
                            throw "Multiple manifests found under '$moduleBase'. Pass a specific .psd1 path."
                        }
                    }
                    else {
                        $moduleName = $item.Name
                        $psm1 = @(Get-ChildItem -Path $moduleBase -Filter '*.psm1' -File -ErrorAction SilentlyContinue)
                        if ($psm1.Count -eq 1) {
                            $rootModulePath = $psm1[0].FullName
                        }
                    }
                }
                elseif ($item.Extension -eq '.psd1') {
                    $manifestPath = $item.FullName
                    $moduleBase = $item.DirectoryName
                    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                }
                elseif ($item.Extension -in @('.psm1', '.ps1')) {
                    $rootModulePath = $item.FullName
                    $moduleBase = $item.DirectoryName
                    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                    $siblingManifest = Join-Path $moduleBase "$moduleName.psd1"
                    if (Test-Path -LiteralPath $siblingManifest) {
                        $manifestPath = $siblingManifest
                    }
                    else {
                        $isSingleFile = $true
                    }
                }
                else {
                    throw "Unsupported path type '$($item.Extension)'. Expected directory, .psd1, .psm1, or .ps1."
                }
            }

            'ByName' {
                $resolutionSource = 'Name'

                # Prefer already-loaded module (still only use path metadata - no re-import).
                $loaded = @(Get-Module -Name $Name -ErrorAction SilentlyContinue)
                if ($RequiredVersion) {
                    $loaded = @($loaded | Where-Object { $_.Version -eq $RequiredVersion })
                }

                if ($loaded.Count -gt 0) {
                    $pick = $loaded | Sort-Object Version -Descending | Select-Object -First 1
                    return Resolve-PSModuleTarget -ModuleInfo $pick
                }

                $listParams = @{
                    Name          = $Name
                    ListAvailable = $true
                    ErrorAction   = 'SilentlyContinue'
                    Refresh       = $true
                }
                if ($RequiredVersion) {
                    $listParams['RequiredVersion'] = $RequiredVersion
                }

                $available = @(Get-Module @listParams)
                if ($available.Count -eq 0) {
                    $msg = "Module '$Name' was not loaded and was not found on PSModulePath."
                    if ($RequiredVersion) {
                        $msg = "Module '$Name' version $RequiredVersion was not found."
                    }
                    throw $msg
                }

                $pick = $available | Sort-Object Version -Descending | Select-Object -First 1
                return Resolve-PSModuleTarget -ModuleInfo $pick
            }
        }

        if ($manifestPath -and -not $moduleVersion) {
            try {
                $raw = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
                $rawVersion = Get-HashtableValue -InputObject $raw -Key 'ModuleVersion'
                if ($rawVersion) {
                    $moduleVersion = [version]$rawVersion
                }
                $rawRoot = Get-HashtableValue -InputObject $raw -Key 'RootModule'
                if (-not $rootModulePath -and $rawRoot) {
                    $candidateRoot = Join-Path $moduleBase $rawRoot
                    if (Test-Path -LiteralPath $candidateRoot) {
                        $rootModulePath = $candidateRoot
                    }
                }
            }
            catch {
                # Manifest parse failures are surfaced by Get-PSModuleManifest; keep resolving.
                Write-Verbose "Manifest version probe failed for '$manifestPath': $($_.Exception.Message)"
            }
        }

        if (-not $moduleName) {
            $moduleName = Split-Path -Path $moduleBase -Leaf
        }

        [pscustomobject]@{
            PSTypeName       = 'PSModuleDependencyGraph.ModuleTarget'
            Name             = $moduleName
            Version          = $moduleVersion
            ModuleBase       = $moduleBase
            ManifestPath     = $manifestPath
            RootModulePath   = $rootModulePath
            ResolutionSource = $resolutionSource
            IsSingleFile     = $isSingleFile
        }
    }
}
