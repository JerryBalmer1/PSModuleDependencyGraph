function Get-FunctionSignature {
    <#
    .SYNOPSIS
        Reads a function's parameters and parameter sets from its AST.
    .DESCRIPTION
        Mirrors what Get-Command reports once a function is loaded, without
        loading it:

          - A parameter with no ParameterSetName belongs to every set.
          - The sets are the ParameterSetNames used, plus DefaultParameterSetName
            when [CmdletBinding()] names one.
          - With no named set at all there is one set, called
            __AllParameterSets, unless DefaultParameterSetName names it.
          - Positions are numbered automatically, in declaration order and
            skipping switches, only when no parameter gives a Position or a
            ParameterSetName and PositionalBinding is not $false.

        Common parameters (-Verbose, -ErrorAction, ...) are not in the source
        and are not reported.
    .PARAMETER FunctionAst
        The function definition.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst] $FunctionAst
    )

    $allSets = '__AllParameterSets'

    $paramBlock = if ($FunctionAst.Body) { $FunctionAst.Body.ParamBlock } else { $null }
    $parameterAsts = @(
        if ($paramBlock -and $paramBlock.Parameters) { $paramBlock.Parameters }
        elseif ($FunctionAst.Parameters) { $FunctionAst.Parameters }
    )

    $cmdletBinding = $null
    if ($paramBlock) {
        $cmdletBinding = $paramBlock.Attributes |
            Where-Object { $_.TypeName.GetReflectionAttributeType() -eq [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1
    }
    $defaultSet = if ($cmdletBinding) { Get-AttributeArgumentValue -Attribute $cmdletBinding -Name 'DefaultParameterSetName' } else { $null }
    $positionalBinding = -not ($cmdletBinding -and (Get-AttributeArgumentValue -Attribute $cmdletBinding -Name 'PositionalBinding') -eq $false)

    $parameters = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $parameterAsts) {
        $parameterAttributes = @($p.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.GetReflectionAttributeType() -eq [System.Management.Automation.ParameterAttribute]
            })

        # One entry per [Parameter()] attribute: a parameter can sit in several
        # sets with different settings in each.
        $membership = @(
            if ($parameterAttributes.Count -eq 0) {
                [pscustomobject]@{
                    ParameterSetName                = $allSets
                    Mandatory                       = $false
                    Position                        = $null
                    ValueFromPipeline               = $false
                    ValueFromPipelineByPropertyName = $false
                    HelpMessage                     = $null
                }
            }
            foreach ($attribute in $parameterAttributes) {
                $setName = Get-AttributeArgumentValue -Attribute $attribute -Name 'ParameterSetName'
                $position = Get-AttributeArgumentValue -Attribute $attribute -Name 'Position'
                [pscustomobject]@{
                    ParameterSetName                = if ($setName) { [string]$setName } else { $allSets }
                    Mandatory                       = [bool](Get-AttributeArgumentValue -Attribute $attribute -Name 'Mandatory')
                    Position                        = if ($null -ne $position) { [int]$position } else { $null }
                    ValueFromPipeline               = [bool](Get-AttributeArgumentValue -Attribute $attribute -Name 'ValueFromPipeline')
                    ValueFromPipelineByPropertyName = [bool](Get-AttributeArgumentValue -Attribute $attribute -Name 'ValueFromPipelineByPropertyName')
                    HelpMessage                     = Get-AttributeArgumentValue -Attribute $attribute -Name 'HelpMessage'
                }
            }
        )

        $aliases = @(
            $p.Attributes |
                Where-Object {
                    $_ -is [System.Management.Automation.Language.AttributeAst] -and
                    $_.TypeName.GetReflectionAttributeType() -eq [System.Management.Automation.AliasAttribute]
                } |
                ForEach-Object { $_.PositionalArguments } |
                ForEach-Object { Get-AstConstantValue -Ast $_ } |
                ForEach-Object { $_ }
        )

        $parameters.Add([pscustomobject]@{
                PSTypeName    = 'PSModuleDependencyGraph.ParameterInfo'
                Name          = $p.Name.VariablePath.UserPath
                Type          = $p.StaticType.FullName
                TypeName      = Get-ParameterTypeName -ParameterAst $p
                Aliases       = [string[]]$aliases
                DefaultValue  = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { $null }
                ParameterSets = @($membership)
            })
    }

    $explicitPositionOrSet = $parameters | Where-Object {
        $_.ParameterSets | Where-Object { $null -ne $_.Position -or $_.ParameterSetName -ne $allSets }
    }
    if ($positionalBinding -and -not $explicitPositionOrSet) {
        $next = 0
        foreach ($parameter in $parameters) {
            if ($parameter.TypeName -in 'switch', 'System.Management.Automation.SwitchParameter') { continue }
            foreach ($entry in $parameter.ParameterSets) { $entry.Position = $next }
            $next++
        }
    }

    $setNames = [System.Collections.Generic.List[string]]::new()
    foreach ($parameter in $parameters) {
        foreach ($entry in $parameter.ParameterSets) {
            $name = $entry.ParameterSetName
            if ($name -ne $allSets -and -not $setNames.Contains($name)) { $setNames.Add($name) }
        }
    }
    if ($defaultSet -and -not $setNames.Contains($defaultSet)) { $setNames.Add($defaultSet) }
    if ($setNames.Count -eq 0) { $setNames.Add($allSets) }

    $sets = foreach ($setName in $setNames) {
        $members = foreach ($parameter in $parameters) {
            $entry = $parameter.ParameterSets | Where-Object ParameterSetName -EQ $setName | Select-Object -First 1
            if (-not $entry) {
                $entry = $parameter.ParameterSets | Where-Object ParameterSetName -EQ $allSets | Select-Object -First 1
            }
            if (-not $entry) { continue }
            [pscustomobject]@{
                Name                            = $parameter.Name
                TypeName                        = $parameter.TypeName
                Mandatory                       = $entry.Mandatory
                Position                        = $entry.Position
                ValueFromPipeline               = $entry.ValueFromPipeline
                ValueFromPipelineByPropertyName = $entry.ValueFromPipelineByPropertyName
            }
        }

        [pscustomobject]@{
            PSTypeName = 'PSModuleDependencyGraph.ParameterSetInfo'
            Name       = $setName
            IsDefault  = $setName -eq $defaultSet
            Parameters = @($members)
        }
    }

    [pscustomobject]@{
        CmdletBinding       = [bool]$cmdletBinding
        DefaultParameterSet = $defaultSet
        Parameters          = @($parameters)
        ParameterSets       = @($sets)
    }
}

function Get-FunctionHelp {
    <#
    .SYNOPSIS
        Reads a function's comment-based help from its AST, or $null when it has none.
    .DESCRIPTION
        Examples are kept one entry per .EXAMPLE, so a build can compare their
        number against the function's parameter sets.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionDefinitionAst] $FunctionAst
    )

    $help = $FunctionAst.GetHelpContent()
    if (-not $help) {
        return $null
    }

    $trim = { param($Text) if ($null -ne $Text) { ([string]$Text).Trim() } else { $null } }

    $parameterHelp = [ordered]@{}
    foreach ($key in $help.Parameters.Keys) {
        # CommentHelpInfo upper-cases parameter names.
        $parameterHelp[$key] = & $trim $help.Parameters[$key]
    }

    [pscustomobject]@{
        PSTypeName  = 'PSModuleDependencyGraph.HelpInfo'
        Synopsis    = & $trim $help.Synopsis
        Description = & $trim $help.Description
        Parameters  = [pscustomobject]$parameterHelp
        Examples    = [string[]]@($help.Examples | ForEach-Object { & $trim $_ })
        Inputs      = [string[]]@($help.Inputs | ForEach-Object { & $trim $_ })
        Outputs     = [string[]]@($help.Outputs | ForEach-Object { & $trim $_ })
        Notes       = & $trim $help.Notes
        Links       = [string[]]@($help.Links | ForEach-Object { & $trim $_ })
        Component   = & $trim $help.Component
        Role        = & $trim $help.Role
        Functionality = & $trim $help.Functionality
    }
}

function Get-AttributeArgumentValue {
    <#
    .SYNOPSIS
        The value of a named attribute argument, as a literal: Mandatory, Mandatory = $true,
        Position = 0, ParameterSetName = 'ByName'. $null when absent or not a literal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.AttributeAst] $Attribute,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $argument = $Attribute.NamedArguments | Where-Object { $_.ArgumentName -eq $Name } | Select-Object -First 1
    if (-not $argument) {
        return $null
    }
    if ($argument.ExpressionOmitted) {
        return $true
    }
    Get-AstConstantValue -Ast $argument.Argument
}

function Get-AstConstantValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Ast
    )

    switch ($Ast) {
        { $_ -is [System.Management.Automation.Language.ConstantExpressionAst] } { return $_.Value }
        { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } {
            switch ($_.VariablePath.UserPath) {
                'true' { return $true }
                'false' { return $false }
                'null' { return $null }
            }
            return $null
        }
        { $_ -is [System.Management.Automation.Language.ArrayLiteralAst] } {
            return @($_.Elements | ForEach-Object { Get-AstConstantValue -Ast $_ })
        }
    }
    $null
}

function Get-ParameterTypeName {
    <#
    .SYNOPSIS
        The parameter's type as written: [string[]] gives 'string[]'. 'object' when untyped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ParameterAst] $ParameterAst
    )

    $typeConstraint = $ParameterAst.Attributes |
        Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } |
        Select-Object -Last 1
    if ($typeConstraint) {
        return $typeConstraint.TypeName.FullName
    }
    'object'
}
