function Get-PSModuleAssembly {
    <#
    .SYNOPSIS
        Surfaces RequiredAssemblies, binary NestedModules, Add-Type sites, and loose .dll files.
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
        $results = [System.Collections.Generic.List[object]]::new()
        $seen = @{}

        function Add-AssemblyRecord {
            param(
                [string] $AssemblyName,
                [string] $Kind,
                [string] $Source,
                [string] $Path,
                [int] $StartLine = 0,
                [int] $StartColumn = 0,
                [bool] $Exists = $false,
                [string] $Detail = $null
            )

            $key = "$Kind|$AssemblyName|$Path|$StartLine".ToLowerInvariant()
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true

            $results.Add([pscustomobject]@{
                    PSTypeName    = 'PSModuleDependencyGraph.AssemblyInfo'
                    ModuleName    = $target.Name
                    ModuleVersion = $target.Version
                    Name          = $AssemblyName
                    Kind          = $Kind
                    Source        = $Source
                    Path          = $Path
                    Exists        = $Exists
                    Detail        = $Detail
                    StartLine     = if ($StartLine -gt 0) { $StartLine } else { $null }
                    StartColumn   = if ($StartColumn -gt 0) { $StartColumn } else { $null }
                })
        }

        $manifestData = Get-ManifestDataSafe -Target $target

        if ($manifestData) {
            foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'RequiredAssemblies' -Default @())) {
                if (-not $entry) { continue }
                $s = [string]$entry
                $full = $null
                $exists = $false
                if ($s -match '[\\/]' -or $s -like '*.dll') {
                    $full = if ([System.IO.Path]::IsPathRooted($s)) { $s } else { Join-Path $target.ModuleBase $s }
                    $exists = Test-Path -LiteralPath $full
                }
                Add-AssemblyRecord -AssemblyName $s -Kind 'RequiredAssembly' -Source 'Manifest' -Path $full -Exists $exists
            }

            foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'NestedModules' -Default @())) {
                if (-not $entry) { continue }
                $nestedName = if ($entry -is [hashtable] -or $entry -is [System.Collections.IDictionary]) {
                    [string](Get-HashtableValue -InputObject $entry -Key 'ModuleName')
                }
                else { [string]$entry }
                if (-not $nestedName) { continue }
                if ($nestedName -like '*.dll') {
                    $full = if ([System.IO.Path]::IsPathRooted($nestedName)) { $nestedName } else { Join-Path $target.ModuleBase $nestedName }
                    Add-AssemblyRecord -AssemblyName $nestedName -Kind 'NestedModuleAssembly' -Source 'Manifest' -Path $full -Exists (Test-Path -LiteralPath $full)
                }
            }

            $rootModule = Get-HashtableValue -InputObject $manifestData -Key 'RootModule'
            if ($rootModule -and $rootModule -like '*.dll') {
                $full = Join-Path $target.ModuleBase $rootModule
                Add-AssemblyRecord -AssemblyName $rootModule -Kind 'RootModuleAssembly' -Source 'Manifest' -Path $full -Exists (Test-Path -LiteralPath $full)
            }
        }

        # Loose DLLs on disk
        Get-ChildItem -Path $target.ModuleBase -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-AssemblyRecord -AssemblyName $_.Name -Kind 'FileSystemAssembly' -Source 'FileSystem' -Path $_.FullName -Exists $true
            }

        # Add-Type call sites
        $parsedFiles = @(Get-PSModuleScriptAstFile -Target $target)
        foreach ($file in $parsedFiles) {
            if (-not $file.Ast) { continue }
            if ($file.Path -like '*.psd1') { continue }

            $commands = $file.Ast.FindAll({
                    param($ast)
                    $ast -is [System.Management.Automation.Language.CommandAst]
                }, $true)

            foreach ($cmd in $commands) {
                $cmdName = $cmd.GetCommandName()
                if (-not $cmdName) { continue }
                if ($cmdName -ne 'Add-Type' -and $cmdName -ne 'Microsoft.PowerShell.Utility\Add-Type') {
                    continue
                }

                $assemblyName = 'Add-Type'
                $detailParts = [System.Collections.Generic.List[string]]::new()
                $pathValue = $null

                $elements = @($cmd.CommandElements)
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $el = $elements[$i]
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $paramName = $el.ParameterName
                        $argText = $null
                        $argAst = $null
                        if ($null -ne $el.Argument) {
                            $argAst = $el.Argument
                        }
                        elseif (($i + 1) -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                            $argAst = $elements[$i + 1]
                            $i++
                        }
                        if ($null -ne $argAst) {
                            $argText = $argAst.Extent.Text.Trim('"', "'")
                        }

                        if ($paramName -in @('Path', 'LiteralPath') -and $argText) {
                            # An -Path argument that is an expression is not a path.
                            # Handing its text to a path cmdlet reads the leading token
                            # as a provider name and takes the whole module down, and
                            # dropping it would hide an assembly the module really
                            # loads. Reported instead, named by the expression that
                            # produces it, with the path left unresolved.
                            $literal = Resolve-AstLiteralString -AstElement $argAst
                            if ($literal) {
                                $pathValue = $literal
                                $assemblyName = Get-PathLeafSafe -Path $literal
                            }
                            else {
                                $assemblyName = $argText
                                $detailParts.Add('ComputedPath')
                            }
                        }
                        elseif ($paramName -eq 'AssemblyName' -and $argText) {
                            $assemblyName = $argText
                        }
                        elseif ($paramName -eq 'Name' -and $argText) {
                            $assemblyName = $argText
                        }
                        elseif ($paramName -eq 'TypeDefinition') {
                            $detailParts.Add('TypeDefinition')
                        }
                        elseif ($paramName -eq 'MemberDefinition') {
                            $detailParts.Add('MemberDefinition')
                        }
                        else {
                            $detailParts.Add("-$paramName")
                        }
                    }
                }

                $exists = $false
                $resolvedPath = $null
                if ($pathValue) {
                    # A literal out of someone else's source is still only a string.
                    # IsPathRooted throws on invalid characters under .NET Framework,
                    # which would put the failure back where it just came from.
                    $rooted = $false
                    try { $rooted = [System.IO.Path]::IsPathRooted($pathValue) } catch { $rooted = $false }
                    $candidate = if ($rooted) {
                        $pathValue
                    }
                    else {
                        Join-Path (Split-Path -LiteralPath $file.Path -Parent) $pathValue
                    }
                    if (Test-Path -LiteralPath $candidate) {
                        $resolvedPath = $candidate
                        $exists = $true
                    }
                    else {
                        $resolvedPath = $pathValue
                    }
                }

                Add-AssemblyRecord `
                    -AssemblyName $assemblyName `
                    -Kind 'AddType' `
                    -Source $file.Path `
                    -Path $resolvedPath `
                    -StartLine $cmd.Extent.StartLineNumber `
                    -StartColumn $cmd.Extent.StartColumnNumber `
                    -Exists $exists `
                    -Detail ($detailParts -join ', ')
            }
        }

        $results
    }
}
