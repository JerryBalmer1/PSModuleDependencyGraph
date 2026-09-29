# PSModuleDependencyGraph

Builds a dependency graph of the public and private functions in a PowerShell module or script, statically through the AST. Nothing is imported, dot-sourced, or executed.

Requires PowerShell 7.4 or later.

## Usage

```powershell
Import-Module ./src/PSModuleDependencyGraph/PSModuleDependencyGraph.psd1

$graph = Get-PSModuleDependencyGraph -Path ./path/to/MyModule      # folder, .psd1, .psm1, or .ps1
$graph.Nodes | Format-Table Name, Kind, IsExported, ExportSource, Path
$graph.Edges | Format-Table SourceName, TargetName, Resolution
```

The result carries `Nodes`, `Edges`, `Roots`, `Leaves`, `Unresolved`, `AmbiguousNames`, and `Stats`.

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

`requirements.psd1` declares Pester 6.1.0 or later and InvokeBuild 5.14.23. The build runs with InvokeBuild (`module.build.ps1`).

```powershell
# once per machine
Install-PSResource -RequiredResourceFile ./requirements.psd1 -Scope CurrentUser -TrustRepository

Import-Module InvokeBuild -RequiredVersion 5.14.23
Invoke-Build              # default task: Test
Invoke-Build Bootstrap    # re-install the requirements
```
