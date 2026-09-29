function Get-PSModuleEnum {
    <#
    .SYNOPSIS
        Returns enums defined in a module with labels and underlying values.
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
        $parsedFiles = @(Get-PSModuleScriptAstFile -Target $target)

        foreach ($file in $parsedFiles) {
            if (-not $file.Ast) { continue }
            if ($file.Path -like '*.psd1') { continue }

            $enums = $file.Ast.FindAll({
                    param($ast)
                    $ast -is [System.Management.Automation.Language.TypeDefinitionAst] -and $ast.IsEnum
                }, $true)

            foreach ($enum in $enums) {
                $underlying = 'int'
                if ($enum.BaseTypes -and $enum.BaseTypes.Count -gt 0) {
                    $underlying = $enum.BaseTypes[0].TypeName.FullName
                }

                $labels = [System.Collections.Generic.List[object]]::new()
                $autoValue = 0
                if ($enum.Members) {
                    foreach ($member in $enum.Members) {
                        # MemberDefinitionAst for enum labels
                        $labelName = $member.Name
                        $value = $null
                        $hasExplicit = $false

                        if ($member.PSObject.Properties['InitialValue'] -and $null -ne $member.InitialValue) {
                            $hasExplicit = $true
                            $iv = $member.InitialValue
                            if ($iv -is [System.Management.Automation.Language.CommandExpressionAst]) {
                                $iv = $iv.Expression
                            }
                            if ($iv.PSObject.Properties['Value']) {
                                $value = $iv.Value
                            }
                            else {
                                $value = $iv.Extent.Text
                            }
                            # Keep auto-increment in sync when value is numeric
                            $asInt = 0
                            if ([int]::TryParse([string]$value, [ref]$asInt)) {
                                $autoValue = $asInt + 1
                            }
                        }
                        else {
                            $value = $autoValue
                            $autoValue++
                        }

                        $labels.Add([pscustomobject]@{
                                Name            = $labelName
                                Value           = $value
                                HasExplicitValue = $hasExplicit
                            })
                    }
                }

                [pscustomobject]@{
                    PSTypeName       = 'PSModuleDependencyGraph.EnumInfo'
                    ModuleName       = $target.Name
                    ModuleVersion    = $target.Version
                    Name             = $enum.Name
                    UnderlyingType   = $underlying
                    Labels           = @($labels)
                    Path             = $file.Path
                    StartLine        = $enum.Extent.StartLineNumber
                    StartColumn      = $enum.Extent.StartColumnNumber
                    EndLine          = $enum.Extent.EndLineNumber
                    EndColumn        = $enum.Extent.EndColumnNumber
                }
            }
        }
    }
}
