function Get-PSModuleCommandReference {
    <#
    .SYNOPSIS
        Returns raw command call sites attributed to the enclosing function (when any).
    .DESCRIPTION
        Static only: resolves the text of each CommandAst. Does not bind commands against
        a runspace. Operator invocations and bare command names are included; assignment
        LHS and parameter names are not.
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
        [System.Management.Automation.PSModuleInfo] $ModuleInfo,

        [Parameter()]
        [switch] $IncludeExternal
    )

    process {
        $target = Resolve-BoundParameter -Name $Name -RequiredVersion $RequiredVersion -Path $Path -ModuleInfo $ModuleInfo -ParameterSetName $PSCmdlet.ParameterSetName
        $parsedFiles = @(Get-PSModuleScriptAstFile -Target $target)

        # Build defined function name set for later classification
        $defined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $parsedFiles) {
            if (-not $file.Ast) { continue }
            if ($file.Path -like '*.psd1') { continue }
            foreach ($fn in $file.Ast.FindAll({
                        param($ast)
                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        -not (Test-AstIsClassMemberFunction -FunctionAst $ast)
                    }, $true)) {
                [void]$defined.Add($fn.Name)
            }
        }

        foreach ($file in $parsedFiles) {
            if (-not $file.Ast) { continue }
            if ($file.Path -like '*.psd1') { continue }

            $commands = $file.Ast.FindAll({
                    param($ast)
                    $ast -is [System.Management.Automation.Language.CommandAst]
                }, $true)

            foreach ($cmd in $commands) {
                $cmdName = $cmd.GetCommandName()
                if (-not $cmdName) {
                    # e.g. & $cmd or . $script - capture invocation text
                    $first = $cmd.CommandElements | Select-Object -First 1
                    $cmdName = if ($first) { $first.Extent.Text } else { $cmd.Extent.Text }
                }

                # Strip module qualifier for resolution: Module\Command
                $unqualified = $cmdName
                $moduleQualifier = $null
                if ($cmdName -match '^(?<mod>[^\\]+)\\(?<cmd>.+)$') {
                    $moduleQualifier = $Matches['mod']
                    $unqualified = $Matches['cmd']
                }

                $isInternal = $defined.Contains($unqualified)
                if (-not $IncludeExternal -and -not $isInternal -and $defined.Count -gt 0) {
                    # Still return all references by default - graph needs externals as Unresolved.
                    # IncludeExternal is reserved for filtering; default is return everything.
                }

                $enclosing = Get-EnclosingFunctionName -AstElement $cmd

                [pscustomobject]@{
                    PSTypeName       = 'PSModuleDependencyGraph.CommandReference'
                    ModuleName       = $target.Name
                    ModuleVersion    = $target.Version
                    CommandName      = $cmdName
                    UnqualifiedName  = $unqualified
                    ModuleQualifier  = $moduleQualifier
                    IsInternal       = $isInternal
                    EnclosingFunction = $enclosing
                    Path             = $file.Path
                    StartLine        = $cmd.Extent.StartLineNumber
                    StartColumn      = $cmd.Extent.StartColumnNumber
                    EndLine          = $cmd.Extent.EndLineNumber
                    EndColumn        = $cmd.Extent.EndColumnNumber
                    Text             = $cmd.Extent.Text
                }
            }
        }
    }
}
