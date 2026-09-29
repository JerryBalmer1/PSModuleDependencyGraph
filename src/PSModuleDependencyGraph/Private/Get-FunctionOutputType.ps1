function Get-FunctionOutputType {
    <#
    .SYNOPSIS
        What a function says it outputs, from [OutputType()], and what its body outputs.
    .DESCRIPTION
        Declared: the types named in [OutputType()], as written.

        Inferred: the types PowerShell's own type inference - the engine tab
        completion uses - finds the body writing to the pipeline, run with no
        runtime evaluation. It follows variables, casts, ::new() and New-Object.
        It cannot see through a static member such as [MyEnum]::Value, so a
        module-defined enum or class used that way in an output position is added
        here. The inference API is internal to PowerShell; if a later version
        moves it, Inferred is empty rather than an error.

        System.Object carries no information and is left out.
    .PARAMETER FunctionAst
        The function definition.
    .PARAMETER ModuleTypeName
        Names of the classes and enums the module defines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst] $FunctionAst,

        [AllowEmptyCollection()]
        [string[]] $ModuleTypeName = @()
    )

    $declared = [System.Collections.Generic.List[string]]::new()
    $paramBlock = if ($FunctionAst.Body) { $FunctionAst.Body.ParamBlock } else { $null }
    if ($paramBlock) {
        $outputAttributes = $paramBlock.Attributes | Where-Object {
            $_.TypeName.GetReflectionAttributeType() -eq [System.Management.Automation.OutputTypeAttribute]
        }
        foreach ($attribute in $outputAttributes) {
            foreach ($argument in $attribute.PositionalArguments) {
                $values = if ($argument -is [System.Management.Automation.Language.ArrayLiteralAst]) { $argument.Elements } else { @($argument) }
                foreach ($value in $values) {
                    $typeName = switch ($value) {
                        { $_ -is [System.Management.Automation.Language.TypeExpressionAst] } { $_.TypeName.FullName }
                        { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } { $_.Value }
                        default { $_.Extent.Text }
                    }
                    if ($typeName -and -not $declared.Contains($typeName)) { $declared.Add($typeName) }
                }
            }
        }
    }

    $inferred = [System.Collections.Generic.List[string]]::new()
    $add = { param([string] $TypeName) if ($TypeName -and $TypeName -ne 'System.Object' -and -not $inferred.Contains($TypeName)) { $inferred.Add($TypeName) } }

    # Looked up once per session. Set-StrictMode makes reading an unset
    # variable fatal, so its absence is tested with Get-Variable.
    if (-not (Get-Variable -Name AstTypeInferenceMethod -Scope Script -ErrorAction Ignore)) {
        $script:AstTypeInferenceMethod = $false
        try {
            $inference = [psobject].Assembly.GetType('System.Management.Automation.AstTypeInference')
            $permissions = [psobject].Assembly.GetType('System.Management.Automation.TypeInferenceRuntimePermissions')
            if ($inference -and $permissions) {
                $method = $inference.GetMethod('InferTypeOf', [type[]]@([System.Management.Automation.Language.Ast], $permissions))
                if ($method) {
                    $script:AstTypeInferenceMethod = $method
                    $script:AstTypeInferenceNone = [enum]::ToObject($permissions, 0)
                }
            }
        }
        catch {
            Write-Verbose "PowerShell type inference is unavailable: $($_.Exception.Message)"
        }
    }

    if ($script:AstTypeInferenceMethod -and $FunctionAst.Body) {
        try {
            foreach ($type in $script:AstTypeInferenceMethod.Invoke($null, @($FunctionAst.Body, $script:AstTypeInferenceNone))) {
                & $add $type.Name
            }
        }
        catch {
            Write-Verbose "Type inference failed for $($FunctionAst.Name): $($_.Exception.Message)"
        }
    }

    # [ModuleType]::Member written to the pipeline: a pipeline whose only element
    # is that expression, not assigned to anything.
    if ($ModuleTypeName.Count -and $FunctionAst.Body) {
        $known = [System.Collections.Generic.HashSet[string]]::new([string[]]$ModuleTypeName, [System.StringComparer]::OrdinalIgnoreCase)
        $staticOutputs = $FunctionAst.Body.FindAll({
                param($ast)
                $ast -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $ast.Static -and
                $ast.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                $ast.Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $ast.Parent.Parent -is [System.Management.Automation.Language.PipelineAst] -and
                $ast.Parent.Parent.PipelineElements.Count -eq 1 -and
                $ast.Parent.Parent.Parent -isnot [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)
        foreach ($member in $staticOutputs) {
            $typeName = $member.Expression.TypeName.FullName
            if ($known.Contains($typeName)) { & $add $typeName }
        }
    }

    [pscustomobject]@{
        Declared = [string[]]@($declared)
        Inferred = [string[]]@($inferred)
    }
}
