function Get-PSModuleClass {
    <#
    .SYNOPSIS
        Returns PowerShell classes defined in a module, including base types, interfaces, and DSC attribution.
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

            $types = $file.Ast.FindAll({
                    param($ast)
                    $ast -is [System.Management.Automation.Language.TypeDefinitionAst] -and
                    -not $ast.IsEnum
                }, $true)

            foreach ($type in $types) {
                $baseTypes = @()
                $interfaces = @()
                if ($type.BaseTypes) {
                    foreach ($bt in $type.BaseTypes) {
                        $typeName = $bt.TypeName.FullName
                        # Heuristic: interface names often start with I + Upper; keep all in BaseTypes and split softly
                        if ($typeName -match '^I[A-Z]') {
                            $interfaces += $typeName
                        }
                        else {
                            $baseTypes += $typeName
                        }
                    }
                }

                $members = @()
                if ($type.Members) {
                    $members = @($type.Members | ForEach-Object {
                            $memberKind = $_.GetType().Name -replace 'MemberAst$', '' -replace 'Ast$', ''
                            $memberName = $null
                            if ($_.PSObject.Properties['Name']) { $memberName = $_.Name }
                            [pscustomobject]@{
                                Name = $memberName
                                Kind = $memberKind
                            }
                        })
                }

                $isDsc = $false
                $dscAttribute = $null
                # DSC resources: class with [DscResource()] attribute
                if ($type.Attributes) {
                    foreach ($attr in $type.Attributes) {
                        $attrName = $attr.TypeName.Name
                        if ($attrName -eq 'DscResource' -or $attrName -eq 'DscResourceAttribute') {
                            $isDsc = $true
                            $dscAttribute = $attrName
                        }
                    }
                }

                $isInterface = $false
                if ($type.PSObject.Properties['IsInterface']) {
                    $isInterface = [bool]$type.IsInterface
                }

                [pscustomobject]@{
                    PSTypeName    = 'PSModuleDependencyGraph.ClassInfo'
                    ModuleName    = $target.Name
                    ModuleVersion = $target.Version
                    Name          = $type.Name
                    IsClass       = [bool]$type.IsClass
                    IsInterface   = $isInterface
                    BaseTypes     = $baseTypes
                    Interfaces    = $interfaces
                    Members       = $members
                    IsDscResource = $isDsc
                    DscAttribute  = $dscAttribute
                    Path          = $file.Path
                    StartLine     = $type.Extent.StartLineNumber
                    StartColumn   = $type.Extent.StartColumnNumber
                    EndLine       = $type.Extent.EndLineNumber
                    EndColumn     = $type.Extent.EndColumnNumber
                }
            }
        }
    }
}
