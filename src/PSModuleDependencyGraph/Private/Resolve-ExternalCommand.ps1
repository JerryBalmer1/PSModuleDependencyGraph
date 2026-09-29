function Resolve-ExternalCommand {
    <#
    .SYNOPSIS
        Finds which module provides each command a module calls but does not define.
    .DESCRIPTION
        Looks the names up on this machine without importing anything:

          - Get-Command given an exact name imports the module that has it, so
            each name is asked for as a one-character wildcard - Get-ChildIte[m]
            - which is answered from the module analysis cache instead.
          - The lookup runs in a fresh runspace, so functions and aliases from
            the caller's profile or session cannot answer for a module.
          - An alias is followed to the command it names, and reported with that
            command's module.
          - Where several versions of a module have the command, the highest wins.

        A name nothing answers for comes back with Found = $false: a typo, a
        module that is not installed here, or a function the module expected
        someone else to define.

        Returns @{ Commands = name -> command info; Modules = module name ->
        highest installed version }. Modules covers every module a command was
        found in plus any named in -ModuleName; one missing from it is not
        installed here.
    .PARAMETER Name
        Command names, without module qualifiers.
    .PARAMETER ModuleName
        Further modules to look up, such as those a manifest requires.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Name,

        [AllowEmptyCollection()]
        [string[]] $ModuleName = @()
    )

    $result = @{}
    $moduleVersions = @{}
    $names = @($Name | Where-Object { $_ } | Sort-Object -Unique)
    if ($names.Count -eq 0 -and @($ModuleName | Where-Object { $_ }).Count -eq 0) {
        return @{ Commands = $result; Modules = $moduleVersions }
    }

    # Name[lastchar]: still matches only itself, but as a wildcard it is looked
    # up without importing. Characters that are wildcards themselves are
    # escaped. Name.* catches applications, which are git.exe rather than git on
    # Windows; only applications are taken from that pattern.
    $toPattern = {
        param([string] $CommandName)
        $escaped = [System.Management.Automation.WildcardPattern]::Escape($CommandName.Substring(0, $CommandName.Length - 1))
        $last = $CommandName[-1]
        if ($last -match '[\[\]\*\?`]') { "$escaped``$last" } else { "$escaped[$last]" }
    }
    $patterns = foreach ($n in $names) {
        & $toPattern $n
        [System.Management.Automation.WildcardPattern]::Escape($n) + '.*'
    }

    $shell = [powershell]::Create([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    try {
        $invoke = {
            param([string] $Command, [hashtable] $Parameters)
            [void]$shell.Commands.Clear()
            [void]$shell.AddCommand($Command)
            foreach ($key in $Parameters.Keys) { [void]$shell.AddParameter($key, $Parameters[$key]) }
            $shell.Invoke()
        }

        $found = @(if ($names.Count) { & $invoke 'Get-Command' @{ Name = [string[]]$patterns; ErrorAction = 'Ignore' } })

        # An alias names another command; look that one up too.
        $aliasTargets = @($found | Where-Object CommandType -EQ 'Alias' | ForEach-Object Definition | Where-Object { $_ } | Sort-Object -Unique)
        $aliasCommands = @{}
        if ($aliasTargets.Count) {
            foreach ($c in & $invoke 'Get-Command' @{ Name = [string[]]@($aliasTargets | ForEach-Object { & $toPattern $_ }); ErrorAction = 'Ignore' }) {
                $aliasCommands[$c.Name] = $c
            }
        }

        # Commands found in modules that are not loaded report version 0.0;
        # the installed module's own manifest has the real one.
        $moduleNames = @(
            @(@($found) + @($aliasCommands.Values) | Where-Object { $_.ModuleName } | ForEach-Object ModuleName) +
            @($ModuleName | Where-Object { $_ }) |
                Sort-Object -Unique
        )
        if ($moduleNames.Count) {
            foreach ($m in & $invoke 'Get-Module' @{ Name = [string[]]$moduleNames; ListAvailable = $true; ErrorAction = 'Ignore' }) {
                if (-not $moduleVersions.ContainsKey($m.Name) -or $m.Version -gt $moduleVersions[$m.Name]) {
                    $moduleVersions[$m.Name] = $m.Version
                }
            }
            foreach ($m in & $invoke 'Get-Module' @{ Name = [string[]]$moduleNames; ErrorAction = 'Ignore' }) {
                if (-not $moduleVersions.ContainsKey($m.Name)) { $moduleVersions[$m.Name] = $m.Version }
            }
        }
    }
    finally {
        $shell.Dispose()
    }

    $wanted = [System.Collections.Generic.HashSet[string]]::new([string[]]$names, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($command in $found) {
        # Name.* also matches git.exe for 'git': key an application by its base name.
        $key = $command.Name
        if (-not $wanted.Contains($key)) {
            if ($command.CommandType -ne 'Application') { continue }
            $key = [System.IO.Path]::GetFileNameWithoutExtension($command.Name)
            if (-not $wanted.Contains($key) -or $result.ContainsKey($key)) { continue }
        }

        $resolved = $command
        if ($command.CommandType -eq 'Alias' -and $aliasCommands.ContainsKey([string]$command.Definition)) {
            $resolved = $aliasCommands[[string]$command.Definition]
        }
        $moduleName = if ($resolved.ModuleName) { $resolved.ModuleName } else { $null }

        $result[$key] = [pscustomobject]@{
            Name          = $key
            Found         = $true
            CommandType   = [string]$command.CommandType
            ResolvesTo    = if ($command.CommandType -eq 'Alias') { [string]$command.Definition } else { $null }
            ModuleName    = $moduleName
            ModuleVersion = if ($moduleName) { $moduleVersions[$moduleName] } else { $null }
            Path          = if ($command.CommandType -eq 'Application') { $command.Source } else { $null }
        }
    }

    foreach ($n in $names) {
        if (-not $result.ContainsKey($n)) {
            $result[$n] = [pscustomobject]@{
                Name          = $n
                Found         = $false
                CommandType   = $null
                ResolvesTo    = $null
                ModuleName    = $null
                ModuleVersion = $null
                Path          = $null
            }
        }
    }
    @{ Commands = $result; Modules = $moduleVersions }
}
