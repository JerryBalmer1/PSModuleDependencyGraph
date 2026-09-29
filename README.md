# PSModuleDependencyGraph

Builds a dependency graph of the public and private functions in a PowerShell module or script, statically through the AST. Nothing is imported, dot-sourced, or executed.

Requires PowerShell 7.4 or later.

## Usage

From the root of a clone of this repository, paste this into PowerShell 7.4 or later. It graphs one of the example modules in `ModuleTests/`, which has `Public/` and `Private/` folders and a manifest:

```powershell
Import-Module ./src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1

$graph = Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport

# Functions, and whether each one is public (exported) or private
$graph.Nodes | Where-Object Kind -eq 'Function' |
    Format-Table Name, IsExported, ExportSource, @{ n = 'File'; e = { Split-Path $_.Path -Leaf } }

# Which function calls which
$graph.Edges | Format-Table SourceName, TargetName, Resolution
```

Output:

```text
Name                      IsExported ExportSource File
----                      ---------- ------------ ----
ConvertTo-SomethingObject      False Manifest     ConvertTo-SomethingObject.ps1
Read-SomethingStore            False Manifest     Read-SomethingStore.ps1
Write-SomethingStore           False Manifest     Write-SomethingStore.ps1
Get-Something                   True Manifest     Get-Something.ps1
Set-Something                   True Manifest     Set-Something.ps1

SourceName    TargetName                Resolution
----------    ----------                ----------
Get-Something Read-SomethingStore       Unique
Get-Something ConvertTo-SomethingObject Unique
Set-Something Write-SomethingStore      Unique
```

To graph your own code, point `-Path` at a module folder, a `.psd1`, a `.psm1`, or a `.ps1` script. The other folders under `ModuleTests/` work the same way, for example `./ModuleTests/Script/SingleFile/Invoke-Report.ps1` or `./ModuleTests/StandardModule/NameCollision`.

The result is a `ModuleDependencyGraph` and also carries `Roots`, `Leaves`, `Unresolved`, `AmbiguousNames`, and `Stats`.

## Viewing the graph as HTML

The same module, drawn as an interactive page. Paste this from the root of the repository:

```powershell
Import-Module ./src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1

Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport |
    Save-PSModuleDependencyGraphHtml -Path ./ManifestExport.html
```

Or save it to `$env:TEMP\PSModuleDependencyGraph\ManifestExport.html` and open it in your default browser in one step:

```powershell
Get-PSModuleDependencyGraph -Path ./ModuleTests/StandardModule/ManifestExport -Show
```

![ManifestExport dependency graph](docs/images/ManifestExport.png)

The page is one self-contained file, with no internet connection needed, so it can be attached to a ticket or mailed. Functions are laid out left to right, each caller before what it calls:

- **Blue** functions are exported, **grey** are not, and the ellipse is code at a file's top level.
- A **dashed amber** arrow is an ambiguous call: more than one function has that name (try `./ModuleTests/StandardModule/NameCollision`).
- Click a function to see its file, line, what it calls and what calls it. Search by name, show exported functions only, or switch to top-to-bottom.
- `-IncludeUnresolved` adds the commands the module calls but does not define, such as `Get-ChildItem`, behind a checkbox on the page.

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
