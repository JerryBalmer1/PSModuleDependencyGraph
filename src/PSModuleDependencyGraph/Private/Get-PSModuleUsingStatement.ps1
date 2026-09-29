function Get-PSModuleUsingStatement {
    <#
    .SYNOPSIS
        Returns using module / namespace / assembly statements from module source.
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

            $usings = @()
            if ($file.Ast.UsingStatements) {
                $usings = @($file.Ast.UsingStatements)
            }
            else {
                $usings = @($file.Ast.FindAll({
                            param($ast)
                            $ast -is [System.Management.Automation.Language.UsingStatementAst]
                        }, $false))
            }

            foreach ($u in $usings) {
                $kind = [string]$u.UsingStatementKind
                $usingName = $null
                $alias = $null

                switch ($kind) {
                    'Namespace' {
                        $usingName = if ($u.Name) { $u.Name.Value } else { $u.Extent.Text }
                    }
                    'Assembly' {
                        $usingName = if ($u.Name) { $u.Name.Value } else { $null }
                    }
                    'Module' {
                        # UsingStatementAst carries Name and ModuleSpecification, and
                        # never a ModuleName. Reading one under Set-StrictMode raises
                        # PropertyNotFoundStrict from inside the getter, which takes the
                        # whole graph down - so a module was unreadable for having a
                        # `using module` line in it at all.
                        if ($u.Name) {
                            $usingName = $u.Name.Value
                        }
                        elseif ($u.ModuleSpecification) {
                            $usingName = Get-AstHashtableEntry -HashtableAst $u.ModuleSpecification -Key 'ModuleName'
                        }
                    }
                    'Command' {
                        $usingName = if ($u.Name) { $u.Name.Value } else { $null }
                    }
                    default {
                        $usingName = $u.Extent.Text
                    }
                }

                if ($u.PSObject.Properties['Alias'] -and $u.Alias) {
                    $alias = $u.Alias.Value
                }

                [pscustomobject]@{
                    PSTypeName    = 'PSModuleDependencyGraph.UsingStatementInfo'
                    ModuleName    = $target.Name
                    ModuleVersion = $target.Version
                    Kind          = $kind
                    Name          = $usingName
                    Alias         = $alias
                    Text          = $u.Extent.Text
                    Path          = $file.Path
                    StartLine     = $u.Extent.StartLineNumber
                    StartColumn   = $u.Extent.StartColumnNumber
                    EndLine       = $u.Extent.EndLineNumber
                    EndColumn     = $u.Extent.EndColumnNumber
                }
            }
        }
    }
}
