function Get-PSModuleFunction {
    <#
    .SYNOPSIS
        Returns functions and filters defined in a module, with export status from the manifest,
        Export-ModuleMember, or the Public/Private folder convention.
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

        $definitions = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $parsedFiles) {
            if (-not $file.Ast) { continue }
            # Skip pure data files for function discovery if they are manifests
            if ($file.Path -like '*.psd1') { continue }

            $fns = $file.Ast.FindAll({
                    param($ast)
                    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    -not (Test-AstIsClassMemberFunction -FunctionAst $ast)
                }, $true)

            foreach ($fn in $fns) {
                $definitions.Add([pscustomobject]@{
                        Ast      = $fn
                        FilePath = $file.Path
                    })
            }
        }

        $definedNames = @($definitions | ForEach-Object { $_.Ast.Name })
        $manifestData = Get-ManifestDataSafe -Target $target
        $exportPolicy = Get-FunctionExportPolicy -Target $target -ManifestData $manifestData -ParsedFiles $parsedFiles -DefinedFunctionNames $definedNames

        foreach ($def in $definitions) {
            $fn = $def.Ast
            $isFilter = [bool]$fn.IsFilter
            $isWorkflow = $false
            try { $isWorkflow = [bool]$fn.IsWorkflow } catch { $isWorkflow = $false }

            $signature = Get-FunctionSignature -FunctionAst $fn
            $help = Get-FunctionHelp -FunctionAst $fn

            # Each parameter carries its .PARAMETER text, so a build can find
            # parameters nobody documented.
            foreach ($parameter in $signature.Parameters) {
                $description = $null
                if ($help -and $help.Parameters.PSObject.Properties[$parameter.Name]) {
                    $description = $help.Parameters.PSObject.Properties[$parameter.Name].Value
                }
                $parameter | Add-Member -NotePropertyName Description -NotePropertyValue $description
            }

            # A function defined inside another function lives in that function's
            # scope and is never exported, whatever the module says.
            $isNested = $false
            for ($parent = $fn.Parent; $parent; $parent = $parent.Parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $isNested = $true
                    break
                }
            }

            $exported = if ($isNested) { $false } else { Test-FunctionExported -Policy $exportPolicy -FunctionName $fn.Name -FilePath $def.FilePath }
            $isExported = [bool]$exported
            $exportState = if ($exportPolicy.Source -eq 'NotApplicable') {
                'NotApplicable'
            }
            elseif ($null -eq $exported) {
                'Unknown'
            }
            elseif ($exported) {
                'Exported'
            }
            else {
                'NotExported'
            }

            [pscustomobject]@{
                PSTypeName      = 'PSModuleDependencyGraph.FunctionInfo'
                ModuleName      = $target.Name
                ModuleVersion   = $target.Version
                Name            = $fn.Name
                Kind            = if ($isFilter) { 'Filter' } elseif ($isWorkflow) { 'Workflow' } else { 'Function' }
                IsFilter        = $isFilter
                IsWorkflow      = $isWorkflow
                IsExported      = $isExported
                ExportState     = $exportState
                ExportSource    = $exportPolicy.Source
                CmdletBinding       = $signature.CmdletBinding
                DefaultParameterSet = $signature.DefaultParameterSet
                Parameters          = $signature.Parameters
                ParameterSets       = $signature.ParameterSets
                Help                = $help
                Path            = $def.FilePath
                StartLine       = $fn.Extent.StartLineNumber
                StartColumn     = $fn.Extent.StartColumnNumber
                EndLine         = $fn.Extent.EndLineNumber
                EndColumn       = $fn.Extent.EndColumnNumber
            }
        }
    }
}
