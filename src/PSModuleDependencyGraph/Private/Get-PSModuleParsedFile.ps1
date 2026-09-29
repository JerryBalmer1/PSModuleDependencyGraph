function Get-PSModuleParsedFile {
    <#
    .SYNOPSIS
        Parses a PowerShell file into an AST with tokens and parse errors.
    .DESCRIPTION
        Always uses [Parser]::ParseFile, never ParseInput: ParseInput leaves
        $ast.Extent.File null, which strips the path off every downstream record.

        Results are memoised for the lifetime of the module session, keyed on the
        file's full path plus its last write time in UTC ticks. An unchanged file
        is parsed once no matter how many callers ask for it; an edited file gets
        a new key and is re-parsed. Get-PSModuleDependencyGraph alone drives seven
        getters, each of which walks every file in the module, so without this the
        same file is parsed seven times per graph.

        Cache hits return the same object instance, so the AST is reference-equal
        across calls. ASTs are immutable, so sharing them is safe.
    .PARAMETER FilePath
        Path to the file to parse.
    .PARAMETER NoCache
        Parse unconditionally, neither reading from nor writing to the cache.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path')]
        [string] $FilePath,

        [Parameter()]
        [switch] $NoCache
    )

    begin {
        # Lazily created: Set-StrictMode makes reading an undefined variable fatal.
        #
        # -ErrorAction Ignore, not SilentlyContinue. SilentlyContinue suppresses
        # the DISPLAY and still writes the record to $Error and to any caller's
        # -ErrorVariable, so every caller saw "Cannot find a variable with the
        # name 'PSModuleParsedFileCache'" on the first file of every module, for
        # the ordinary absence this line exists to handle, and a caller running with
        # $ErrorActionPreference = 'Stop' could not use the command at all.
        if (-not (Get-Variable -Name PSModuleParsedFileCache -Scope Script -ErrorAction Ignore)) {
            $script:PSModuleParsedFileCache = @{}
        }
    }

    process {
        $full = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "File not found: $FilePath"
        }

        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        $key = if ($item) { "$full|$($item.LastWriteTimeUtc.Ticks)" } else { $null }

        if (-not $NoCache -and $key -and $script:PSModuleParsedFileCache.ContainsKey($key)) {
            return $script:PSModuleParsedFileCache[$key]
        }

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)

        $parsed = [pscustomobject]@{
            PSTypeName  = 'PSModuleDependencyGraph.ParsedFile'
            Path        = $full
            Ast         = $ast
            Tokens      = $tokens
            ParseErrors = @($errors)
            IsParsed    = ($null -ne $ast)
            HasErrors   = ($errors -and $errors.Count -gt 0)
        }

        if (-not $NoCache -and $key) {
            $script:PSModuleParsedFileCache[$key] = $parsed
        }

        $parsed
    }
}

function Get-PSModuleScriptAstFile {
    <#
    .SYNOPSIS
        Returns parsed AST objects for all script files in a module target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target
    )

    $inventory = @(Get-PSModuleFileInventory -Target $Target)
    foreach ($file in $inventory) {
        if ($file.Extension -notin @('.ps1', '.psm1', '.psd1')) {
            continue
        }

        # .psd1 is data - still parseable as a script expression AST
        try {
            Get-PSModuleParsedFile -FilePath $file.Path
        }
        catch {
            [pscustomobject]@{
                PSTypeName  = 'PSModuleDependencyGraph.ParsedFile'
                Path        = $file.Path
                Ast         = $null
                Tokens      = @()
                ParseErrors = @([pscustomobject]@{ Message = $_.Exception.Message })
                IsParsed    = $false
                HasErrors   = $true
            }
        }
    }
}

function Get-EnclosingFunctionName {
    <#
    .SYNOPSIS
        Walks up from an AST element to find the nearest enclosing function/filter name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $AstElement
    )

    $current = $AstElement
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        $current = $current.Parent
    }
    return $null
}

function Test-AstIsClassMemberFunction {
    param($FunctionAst)

    $parent = $FunctionAst.Parent
    while ($null -ne $parent) {
        if ($parent -is [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $true
        }
        # ScriptBlockAst inside type is still a member
        $parent = $parent.Parent
    }
    return $false
}

function Get-ManifestDataSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Target
    )

    if (-not $Target.ManifestPath -or -not (Test-Path -LiteralPath $Target.ManifestPath)) {
        return $null
    }

    try {
        Import-PowerShellDataFile -LiteralPath $Target.ManifestPath -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-AstHashtableEntry {
    <#
    .SYNOPSIS
        Reads one key out of a HashtableAst as text, without evaluating it.
    .DESCRIPTION
        `using module @{ ModuleName = 'X'; RequiredVersion = '1.0' }` parses to a
        HashtableAst. Reading the key means walking the pairs; it must never mean
        running the hashtable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $HashtableAst,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key
    )

    if ($null -eq $HashtableAst) { return $null }
    if (-not $HashtableAst.PSObject.Properties['KeyValuePairs']) { return $null }

    foreach ($pair in @($HashtableAst.KeyValuePairs)) {
        $name = $pair.Item1.Extent.Text.Trim('"', "'")
        if ($name -eq $Key) {
            return $pair.Item2.Extent.Text.Trim('"', "'")
        }
    }

    return $null
}

function Resolve-AstLiteralString {
    <#
    .SYNOPSIS
        Returns the literal string an AST element denotes, or $null when it
        denotes an expression.
    .DESCRIPTION
        The extent text of `([System.IO.Path]::Combine($here, 'x.dll'))` is not a
        path and must not be handed to something that resolves paths: the leading
        token is read as a provider name and the failure surfaces nowhere near
        the cause. An expandable string is an expression too - "$root\x.dll" is
        only a path once something has run.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $AstElement
    )

    if ($null -eq $AstElement) { return $null }
    if ($AstElement -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $AstElement.Value
    }

    return $null
}

function Get-PathLeafSafe {
    <#
    .SYNOPSIS
        The last segment of a path-shaped string, by string operations only.
    .DESCRIPTION
        Split-Path is provider-aware and throws on text that is not a path.
        Nothing that reads other people's source can assume it holds one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    if (-not $Path) { return $Path }
    return @($Path.Split([char]92, [char]47))[-1]
}
