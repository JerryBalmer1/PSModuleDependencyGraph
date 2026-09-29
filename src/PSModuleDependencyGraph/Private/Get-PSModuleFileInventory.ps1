function Get-PSModuleFileInventory {
    <#
    .SYNOPSIS
        Enumerates PowerShell source and assembly files under a resolved module target.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Target
    )

    $moduleBase = $Target.ModuleBase
    if (-not $moduleBase -or -not (Test-Path -LiteralPath $moduleBase)) {
        throw "Module base not found: $moduleBase"
    }

    $files = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen = @{}

    function Add-InventoryFile {
        param(
            [string] $Path,
            [string] $Kind,
            [string] $Origin
        )

        if (-not $Path) { return }
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return
        }

        if (-not (Test-Path -LiteralPath $full)) { return }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true

        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer) { return }

        $files.Add([pscustomobject]@{
                PSTypeName     = 'PSModuleDependencyGraph.SourceFile'
                Path           = $full
                RelativePath   = Get-RelativePathSafe -BasePath $moduleBase -TargetPath $full
                Extension      = $item.Extension.ToLowerInvariant()
                Kind           = $Kind
                Origin         = $Origin
                Length         = $item.Length
                LastWriteTime  = $item.LastWriteTime
            })
    }

    # Manifest-declared files first (authoritative when present)
    $manifestData = $null
    if ($Target.ManifestPath -and (Test-Path -LiteralPath $Target.ManifestPath)) {
        Add-InventoryFile -Path $Target.ManifestPath -Kind 'Manifest' -Origin 'Manifest'
        try {
            $manifestData = Import-PowerShellDataFile -LiteralPath $Target.ManifestPath -ErrorAction Stop
        }
        catch {
            $manifestData = $null
        }
    }

    if ($manifestData) {
        $rootModule = Get-HashtableValue -InputObject $manifestData -Key 'RootModule'
        if ($rootModule) {
            $kind = if ($rootModule -like '*.dll') { 'Assembly' } else { 'RootModule' }
            Add-InventoryFile -Path (Join-Path $moduleBase $rootModule) -Kind $kind -Origin 'RootModule'
        }

        foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'NestedModules' -Default @())) {
            if (-not $entry) { continue }
            $name = if ($entry -is [hashtable] -or $entry -is [System.Collections.IDictionary]) {
                [string](Get-HashtableValue -InputObject $entry -Key 'ModuleName')
            }
            else {
                [string]$entry
            }
            if (-not $name) { continue }
            $path = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $moduleBase $name }
            $kind = if ($name -like '*.dll') { 'NestedAssembly' } else { 'NestedModule' }
            Add-InventoryFile -Path $path -Kind $kind -Origin 'NestedModules'
        }

        foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'ScriptsToProcess' -Default @())) {
            if ($entry) {
                $path = if ([System.IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $moduleBase $entry }
                Add-InventoryFile -Path $path -Kind 'ScriptsToProcess' -Origin 'ScriptsToProcess'
            }
        }

        foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'FileList' -Default @())) {
            if ($entry) {
                $path = if ([System.IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $moduleBase $entry }
                $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
                $kind = switch ($ext) {
                    '.psd1' { 'Manifest' }
                    '.psm1' { 'ScriptModule' }
                    '.ps1' { 'Script' }
                    '.dll' { 'Assembly' }
                    default { 'FileList' }
                }
                Add-InventoryFile -Path $path -Kind $kind -Origin 'FileList'
            }
        }

        foreach ($entry in @(Get-HashtableValue -InputObject $manifestData -Key 'RequiredAssemblies' -Default @())) {
            if ($entry) {
                $path = if ([System.IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $moduleBase $entry }
                # Only inventory local paths; GAC/simple names are reported by Get-PSModuleAssembly
                if ($entry -match '[\\/]' -or $entry -like '*.dll') {
                    Add-InventoryFile -Path $path -Kind 'RequiredAssembly' -Origin 'RequiredAssemblies'
                }
            }
        }
    }
    elseif ($Target.RootModulePath) {
        Add-InventoryFile -Path $Target.RootModulePath -Kind 'RootModule' -Origin 'RootModulePath'
    }

    if ($Target.IsSingleFile) {
        return $files
    }

    # Always scan the module tree for script/assembly files not listed in the manifest
    $extensions = @('*.ps1', '*.psm1', '*.psd1', '*.dll')
    foreach ($pattern in $extensions) {
        Get-ChildItem -Path $moduleBase -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                # Match exclusions against the module-relative path, not the absolute one.
                # A module can legitimately live under a directory named 'tests' or
                # 'output' (the test fixtures do); matching $_.FullName would silently
                # drop every file in it.
                $relative = $_.FullName
                if ($relative.StartsWith($moduleBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $relative.Substring($moduleBase.Length)
                }
                $relative -notmatch '[\\/](\.git|output|tests|\.tools)[\\/]'
            } |
            ForEach-Object {
                $ext = $_.Extension.ToLowerInvariant()
                $kind = switch ($ext) {
                    '.psd1' { 'Manifest' }
                    '.psm1' { 'ScriptModule' }
                    '.ps1' { 'Script' }
                    '.dll' { 'Assembly' }
                    default { 'Other' }
                }
                Add-InventoryFile -Path $_.FullName -Kind $kind -Origin 'FileSystem'
            }
    }

    $files
}

function Get-RelativePathSafe {
    [CmdletBinding()]
    param(
        [string] $BasePath,
        [string] $TargetPath
    )

    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
        $baseUri = [Uri]$baseFull
        $targetUri = [Uri]$targetFull
        $rel = $baseUri.MakeRelativeUri($targetUri).ToString()
        return [Uri]::UnescapeDataString($rel).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    }
    catch {
        return $TargetPath
    }
}
