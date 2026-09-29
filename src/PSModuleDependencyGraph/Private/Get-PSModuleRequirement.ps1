function Get-PSModuleRequirement {
    <#
    .SYNOPSIS
        Modules a module's source asks for: #Requires -Modules and Import-Module with a literal name.
    .DESCRIPTION
        The manifest's RequiredModules and using-module statements are read by
        Get-PSModuleManifest and Get-PSModuleUsingStatement; this covers the two
        ways the code itself names a module. An Import-Module whose name is
        computed cannot be read without running it and is skipped.
    .PARAMETER Target
        A resolved module target.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target
    )

    foreach ($file in @(Get-PSModuleScriptAstFile -Target $Target)) {
        if (-not $file.Ast -or $file.Path -like '*.psd1') { continue }

        if ($file.Ast.ScriptRequirements) {
            foreach ($module in $file.Ast.ScriptRequirements.RequiredModules) {
                [pscustomobject]@{
                    Name              = $module.Name
                    Version           = if ($module.RequiredVersion) { $module.RequiredVersion } else { $module.Version }
                    Source            = '#Requires'
                    Path              = $file.Path
                    StartLine         = $null
                    EnclosingFunction = $null
                }
            }
        }

        $imports = $file.Ast.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.CommandAst] -and
                $ast.GetCommandName() -in @('Import-Module', 'Microsoft.PowerShell.Core\Import-Module', 'ipmo')
            }, $true)
        foreach ($import in $imports) {
            $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($import, $true)
            if (-not $binding.BoundParameters.ContainsKey('Name')) { continue }
            $value = $binding.BoundParameters['Name'].Value
            $elements = if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) { $value.Elements } else { @($value) }
            foreach ($element in $elements) {
                if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
                # A path imports a file of this module or a sibling; its name is the leaf.
                $name = [System.IO.Path]::GetFileNameWithoutExtension($element.Value)
                if (-not $name) { continue }
                [pscustomobject]@{
                    Name              = $name
                    Version           = $null
                    Source            = 'Import-Module'
                    Path              = $file.Path
                    StartLine         = $import.Extent.StartLineNumber
                    EnclosingFunction = Get-EnclosingFunctionName -AstElement $import
                }
            }
        }
    }
}
