function New-GraphNodeId {
    <#
    .SYNOPSIS
        Builds a node's identity from its kind, its file and its name.
    .DESCRIPTION
        A node's identity used to be its lowercased bare name. Two functions
        called Get-TargetResource in two resource folders were two nodes and one
        addressable target, so every edge to that name pointed at whichever was
        parsed last and the rest could not be reached by anything - and were then
        reported as roots, which the report labels "entry point or dead code".

        The identity is `kind:relative/path:Name`:

        - **kind** distinguishes a class from a same-named function.
        - **the path** is relative to the module base, with forward slashes, so
          an id carries neither the machine it was produced on nor the operating
          system. Two runs of the same module on two machines produce the same
          ids; that is what makes a committed result file comparable.
        - **the name** keeps its original casing. It is the label a reader sees
          and the id should not be the place that changes it.

        The renderer's contract says a node id is a string, unique within the
        payload, opaque. A longer opaque string satisfies it as written.
    .PARAMETER Kind
        The lowercase discriminator: function, class, enum, script.
    .PARAMETER ModuleBase
        The directory paths are made relative to.
    .PARAMETER Path
        The file the definition is in.
    .PARAMETER Name
        The definition's name, at its original casing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $ModuleBase,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $relative = ''
    if ($Path) {
        $relative = if ($ModuleBase) {
            Get-RelativePathSafe -BasePath $ModuleBase -TargetPath $Path
        }
        else {
            $Path
        }
        $relative = $relative.Replace([char]92, [char]47).TrimStart([char]47)
    }

    return "{0}:{1}:{2}" -f $Kind, $relative, $Name
}
