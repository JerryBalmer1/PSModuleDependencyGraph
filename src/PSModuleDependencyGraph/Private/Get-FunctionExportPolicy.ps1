function Get-FunctionExportPolicy {
    <#
    .SYNOPSIS
        Decides, statically, how a module's functions are exported.
    .DESCRIPTION
        Mirrors the order PowerShell itself applies, as far as source alone allows:

          Manifest            FunctionsToExport is present in the manifest. When the
                              module's own export is also knowable, the effective set
                              is the intersection, which is what PowerShell exports.
          ExportModuleMember  Export-ModuleMember -Function with literal names
                              (wildcards allowed).
          ImplicitAll         A script module with no Export-ModuleMember at all:
                              PowerShell exports every function.
          FolderConvention    Export-ModuleMember is given a computed value, such as
                              $public.BaseName, which cannot be read without running
                              the module. Functions under a Public folder are taken as
                              exported and everything else as not.
          NotApplicable       A plain .ps1 script. Nothing is exported from a script.
          Unknown             None of the above could be established.

        Returns the policy; Test-FunctionExported applies it to one function.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target,

        [Parameter(Mandatory)]
        [AllowNull()]
        $ManifestData,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $ParsedFiles,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $DefinedFunctionNames
    )

    $moduleBase = $Target.ModuleBase

    # The module's own export, from Export-ModuleMember or its absence.
    $modulePolicy = $null

    $rootIsScript = -not $ManifestData -and $Target.RootModulePath -and
        [System.IO.Path]::GetExtension($Target.RootModulePath) -eq '.ps1'
    $hasScriptModule = @($ParsedFiles | Where-Object { $_.Path -like '*.psm1' }).Count -gt 0

    if ($rootIsScript) {
        $modulePolicy = [pscustomobject]@{ Source = 'NotApplicable'; Names = $null; Dynamic = $false }
    }
    else {
        $exportCalls = @(
            foreach ($file in $ParsedFiles) {
                if (-not $file.Ast -or $file.Path -like '*.psd1') { continue }
                $file.Ast.FindAll({
                        param($ast)
                        $ast -is [System.Management.Automation.Language.CommandAst] -and
                        $ast.GetCommandName() -in @('Export-ModuleMember', 'Microsoft.PowerShell.Core\Export-ModuleMember')
                    }, $true)
            }
        )

        if ($exportCalls.Count -eq 0) {
            if ($hasScriptModule) {
                $modulePolicy = [pscustomobject]@{ Source = 'ImplicitAll'; Names = $null; Dynamic = $false }
            }
        }
        else {
            $names = [System.Collections.Generic.List[string]]::new()
            $dynamic = $false
            foreach ($call in $exportCalls) {
                $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($call, $true)
                $bound = $null
                if ($binding.BoundParameters.ContainsKey('Function')) {
                    $bound = $binding.BoundParameters['Function'].Value
                }
                if (-not $bound) {
                    # -Alias / -Variable / -Cmdlet only: this call exports no functions.
                    continue
                }

                $elements = if ($bound -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    $bound.Elements
                }
                else {
                    @($bound)
                }

                foreach ($element in $elements) {
                    if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $names.Add($element.Value)
                    }
                    else {
                        $dynamic = $true
                    }
                }
            }

            $modulePolicy = [pscustomobject]@{
                Source  = if ($dynamic) { 'FolderConvention' } else { 'ExportModuleMember' }
                Names   = $names
                Dynamic = $dynamic
            }
        }
    }

    $manifestExports = $null
    if ($ManifestData) {
        $raw = Get-HashtableValue -InputObject $ManifestData -Key 'FunctionsToExport'
        if ($null -ne $raw) {
            $manifestExports = @(@($raw) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }
    }

    $source = if ($null -ne $manifestExports) {
        'Manifest'
    }
    elseif ($modulePolicy) {
        $modulePolicy.Source
    }
    else {
        'Unknown'
    }

    [pscustomobject]@{
        Source          = $source
        ManifestExports = $manifestExports
        ModulePolicy    = $modulePolicy
        ModuleBase      = $moduleBase
    }
}

function Test-FunctionExported {
    <#
    .SYNOPSIS
        Applies a policy from Get-FunctionExportPolicy to one function.
        Returns $true, $false, or $null when the policy cannot say.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Policy,

        [Parameter(Mandatory)]
        [string] $FunctionName,

        [Parameter(Mandatory)]
        [string] $FilePath
    )

    $fromModule = $null
    $modulePolicy = $Policy.ModulePolicy
    if ($modulePolicy) {
        $fromModule = switch ($modulePolicy.Source) {
            'NotApplicable' { $false }
            'ImplicitAll' { $true }
            'ExportModuleMember' { Test-NameMatchesPattern -Pattern $modulePolicy.Names -Name $FunctionName }
            'FolderConvention' {
                (Test-NameMatchesPattern -Pattern $modulePolicy.Names -Name $FunctionName) -or
                (Test-PathIsPublic -ModuleBase $Policy.ModuleBase -FilePath $FilePath)
            }
        }
    }

    if ($null -ne $Policy.ManifestExports) {
        if (-not (Test-NameMatchesPattern -Pattern $Policy.ManifestExports -Name $FunctionName)) {
            return $false
        }
        return ($null -eq $fromModule -or $fromModule)
    }

    $fromModule
}

function Test-NameMatchesPattern {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Pattern,

        [string] $Name
    )

    foreach ($p in @($Pattern)) {
        if ($p -and $Name -like $p) { return $true }
    }
    $false
}

function Test-PathIsPublic {
    [CmdletBinding()]
    param(
        [string] $ModuleBase,
        [string] $FilePath
    )

    $relative = $FilePath
    if ($ModuleBase -and $relative.StartsWith($ModuleBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($ModuleBase.Length)
    }
    $relative -match '(^|[\\/])Public[\\/]'
}
