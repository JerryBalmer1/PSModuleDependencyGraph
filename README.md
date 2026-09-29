# PSModuleDependencyGraph

Builds a dependency graph of the public and private functions in a PowerShell module or script, statically through the AST. Nothing is imported, dot-sourced, or executed.

Requires PowerShell 7.4 or later.

## Usage

From the root of a clone of this repository, paste this into PowerShell 7.4 or later. It graphs one of the example modules in `ModuleTests/`, which has `Public/` and `Private/` folders and a manifest:

```powershell
Import-Module ./src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1

$graph = Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport

# Functions, whether each is public (exported) or private, and which private ones nothing calls
$graph.Nodes | Where-Object Kind -eq 'Function' |
    Format-Table Name, IsExported, IsDangling, ExportSource, @{ n = 'File'; e = { Split-Path $_.Path -Leaf } }

# Which function calls which
$graph.Edges | Format-Table SourceName, TargetName, Resolution
```

Output:

```text
Name                      IsExported IsDangling ExportSource File
----                      ---------- ---------- ------------ ----
ConvertTo-SomethingObject      False      False Manifest     ConvertTo-SomethingObject.ps1
Read-SomethingStore            False      False Manifest     Read-SomethingStore.ps1
Remove-SomethingCache          False       True Manifest     Remove-SomethingCache.ps1
Write-SomethingStore           False      False Manifest     Write-SomethingStore.ps1
Get-Something                   True      False Manifest     Get-Something.ps1
Set-Something                   True      False Manifest     Set-Something.ps1

SourceName    TargetName                Resolution
----------    ----------                ----------
Get-Something Read-SomethingStore       Unique
Get-Something ConvertTo-SomethingObject Unique
Set-Something Write-SomethingStore      Unique
```

To graph your own code, point `-Path` at a module folder, a `.psd1`, a `.psm1`, or a `.ps1` script. The other folders under `ModuleTests/` work the same way, for example `./ModuleTests/Script/SingleFile/Invoke-Report.ps1` or `./ModuleTests/StandardModule/NameCollision`.

The result is a `ModuleDependencyGraph`. Besides `Nodes` and `Edges` it carries `Dangling`, `Roots`, `Leaves`, `Unresolved`, `AmbiguousNames`, and `Stats`.

## What each node carries

Every node has the same properties, whatever its kind, so they are safe to read under `Set-StrictMode`:

| Property | What it holds |
|---|---|
| `Name`, `Kind`, `Path` | The function, class, enum or file top level, and its file. |
| `StartLine`, `EndLine` | Where the definition starts and ends. |
| `IsExported`, `ExportState`, `ExportSource` | Public or private, and how that was decided (see below). |
| `DependsOn` | Names of the module's functions, classes and enums it calls or inherits from. |
| `UsedBy` | Names of what calls it. |
| `UnresolvedCalls` | Commands it calls that the module does not define. |
| `IsDangling` | A private function nothing in the module calls. |
| `Parameters` | Name, type, aliases, default value, the `.PARAMETER` help text, and its settings in each parameter set. |
| `ParameterSets`, `DefaultParameterSet` | Each set's name, whether it is the default, and its parameters, as `Get-Command` reports them once the module is loaded. |
| `Help` | Comment-based help: `Synopsis`, `Description`, `Examples` (one entry per `.EXAMPLE`), `Parameters`, `Inputs`, `Outputs`, `Notes`, `Links`. |

```powershell
# What each function calls, what calls it, and what it calls that the module does not define
$graph.Nodes | Where-Object Kind -eq 'Function' |
    Format-Table Name, DependsOn, UsedBy, UnresolvedCalls
```

```text
Name                      DependsOn                                        UsedBy          UnresolvedCalls
----                      ---------                                        ------          ---------------
ConvertTo-SomethingObject {}                                               {Get-Something} {}
Read-SomethingStore       {}                                               {Get-Something} {}
Remove-SomethingCache     {}                                               {}              {}
Write-SomethingStore      {}                                               {Set-Something} {}
Get-Something             {ConvertTo-SomethingObject, Read-SomethingStore} {}              {Get-SomethingCache}
Set-Something             {Write-SomethingStore}                           {}              {Test-SomethingValid}
```

### Using it in a build

Parameter sets and help are on each node, so a build can check them without importing the module. For example, every public function should have at least one example per parameter set, and no private function should be dangling:

```powershell
$graph.Nodes | Where-Object IsExported |
    Where-Object { $_.Help.Examples.Count -lt $_.ParameterSets.Count } |
    ForEach-Object { "$($_.Name) has $($_.ParameterSets.Count) parameter sets but $($_.Help.Examples.Count) example(s)" }

$graph.Dangling | Format-Table Name, StartLine, EndLine
```

```text
Set-Something has 2 parameter sets but 1 example(s)

Name                  StartLine EndLine
----                  --------- -------
Remove-SomethingCache         1       5
```

This repository's own tests run the first check against this module.

## Viewing the graph as HTML

The same module, drawn as an interactive page. Paste this from the root of the repository:

```powershell
Import-Module ./src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1

Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
    Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html
```

Or save it to `$env:TEMP\PSModuleDependencyGraph\ManifestExport.html` and open it in one step:

```powershell
# In your default browser
Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport -ShowInBrowser

# In VS Code, with the 'code' command
Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport -ShowInVSCode
```

VS Code has no built-in HTML preview, so `-ShowInVSCode` opens the page as source. A preview extension such as [Live Preview](https://marketplace.visualstudio.com/items?itemName=ms-vscode.live-server) renders it.

![ManifestExport dependency graph](docs/images/ManifestExport.png)

The page is one self-contained file, with no internet connection needed, so it can be attached to a ticket or mailed. Functions are laid out left to right, each caller before what it calls:

- **Blue** functions are public, **grey** are private, and **dashed purple** are private functions nothing calls. The dashed purple ones are also listed under *Never called*, and clicking *never called* in the header selects them all.
- **Red, dashed** nodes are commands the module calls but does not define, such as the missing `Get-SomethingCache`. The *Unresolved commands* box hides them.
- A **dashed amber** arrow is an ambiguous call: more than one function has that name (try `./ModuleTests/StandardModule/NameCollision`).
- Click a node to see its file, lines, synopsis, parameter sets, examples, what it calls and what calls it.
- Right-click a node for **Show in VS Code**, which opens the file at the function's first line, and to copy its path or name.

### Changing how it looks

Colours, spacing, what shows when the page opens, and the right-click menu come from [`GraphHtmlConfig.psd1`](src/PSModuleDependencyGraph/Resources/GraphHtmlConfig.psd1). To change them, write a `.psd1` with only the keys you want and pass it with `-ConfigPath`:

```powershell
# MyColours.psd1
@{
    Theme      = @{ Background = '#000000' }
    NodeGroups = @( @{ Name = 'private'; Color = '#b0b0b0' } )
    Layout     = @{ Direction = 'TopToBottom'; TopToBottom = @{ NodeSpacing = 220 } }
}
```

```powershell
Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
    Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html -ConfigPath ./MyColours.psd1
```

Your file is merged over the defaults: hashtables key by key, `NodeGroups` by `Name`, and other lists replaced whole.

- **Right-click menu:** it's a list, `NodeMenu`, so adding an entry adds a menu item. Each entry opens a link or copies text built from placeholders such as `{fullPath}` and `{startLine}`.
- **Other kinds of graph:** the graph only says which group each node belongs to, and the config says how each group looks, so the same page can draw other kinds of graph.
- **Sharing a saved page:** for the right-click menu to open files, the page holds the module's full folder path. Keep that in mind before sharing it.

## How a function is decided to be exported

`ExportSource` on each function says which rule applied:

| ExportSource         | When                                                                                      |
|----------------------|-------------------------------------------------------------------------------------------|
| `Manifest`           | The manifest has `FunctionsToExport` (wildcards honoured).                                |
| `ExportModuleMember` | `Export-ModuleMember -Function` with literal names.                                       |
| `ImplicitAll`        | A `.psm1` with no `Export-ModuleMember`: every function is exported, as PowerShell does.   |
| `FolderConvention`   | `Export-ModuleMember` is given a computed value (e.g. `$public.BaseName`); functions under a `Public` folder count as exported. |
| `NotApplicable`      | A plain `.ps1` script.                                                                    |
| `Unknown`            | None of the above could be established.                                                   |

Pointing `-Path` at a single `.ps1` or `.psm1` with no sibling manifest graphs only that file.

## Supported layouts

`ModuleTests/` holds one example of each, and `tests/` asserts the graph for each:

- `Script/` - a single `.ps1` with functions.
- `ScriptModule/` - a single `.psm1`: implicit export, `Export-ModuleMember`, manifest list, manifest wildcard.
- `StandardModule/` - `Public/` and `Private/` folders: manifest export, dynamic export, a `[public]Get-Something` / `[private]Get-Something` name collision, nested folders.

## Tests

`requirements.psd1` declares Pester 6.1.0 or later and InvokeBuild 5.14.23. The build script installs [ModuleFast](https://github.com/JustinGrote/ModuleFast) if it is missing, uses it to install what `requirements.psd1` declares, and then runs the tests with InvokeBuild. Nothing needs installing first:

```powershell
./module.build.ps1
```

Once InvokeBuild 5.14.23 is installed, `Invoke-Build` works too.

## Credits

The HTML view is inspired by [PSWriteHTML](https://github.com/EvotecIT/PSWriteHTML) by [Przemysław Kłys](https://github.com/PrzemyslawKlys) of [Evotec](https://evotec.xyz). Its `New-HTMLDiagram` showed the approach used here: hand [vis-network](https://visjs.github.io/vis-network/) a list of nodes, a list of edges and a set of layout options, and let the browser draw it. This module does not use PSWriteHTML's code; it builds the page itself so that it runs on PowerShell 7.4 and later.

vis-network 10.1.2 is included in `src/PSModuleDependencyGraph/Resources/` and embedded in each saved page. It is dual-licensed under the Apache 2.0 and MIT licenses; both license files are next to it.
