function Resolve-GraphNodeCandidate {
    <#
    .SYNOPSIS
        Points a call at the definitions its name could mean.
    .DESCRIPTION
        Once a node's identity stops being its bare name, a call by name no
        longer has one answer. PowerShell gives every function in a module the
        same scope and the last one loaded wins, and load order is not in the
        source - so which definition runs is genuinely undecidable statically.

        Three outcomes, and the caller is told which it got:

        - **Unique** - one definition carries the name. Nothing to decide.
        - **SameFile** - several do, and one of them is in the calling file.
          That one. This is a rule rather than a guess: a DSC module ships the
          same helper name in twenty resource folders and each calls its own
          neighbour, and a resolver that ignored the file would be choosing at
          random between twenty right answers and nineteen wrong ones.
        - **Ambiguous** - several do and none is in the calling file. Every
          candidate is returned and the edges are marked. One arbitrary edge
          would be a confident answer to an undecidable question, and dropping
          the call would be the thing "Report, do not drop" exists to stop.

        Nothing here reads a file or runs anything; it reads the index the graph
        built.
    .PARAMETER Index
        name(lower) -> a list of { Id; Path }.
    .PARAMETER Name
        The name the call used, unqualified.
    .PARAMETER CallerPath
        The file the call was made in.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable] $Index,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $CallerPath
    )

    $empty = [pscustomobject]@{ Nodes = @(); Resolution = 'None'; CandidateCount = 0 }
    if (-not $Name) { return $empty }

    $key = $Name.ToLowerInvariant()
    if (-not $Index.ContainsKey($key)) { return $empty }

    $candidates = @($Index[$key])
    if ($candidates.Count -eq 0) { return $empty }

    if ($candidates.Count -eq 1) {
        return [pscustomobject]@{ Nodes = $candidates; Resolution = 'Unique'; CandidateCount = 1 }
    }

    if ($CallerPath) {
        $local = @($candidates | Where-Object {
                $_.Path -and $_.Path.Equals($CallerPath, [System.StringComparison]::OrdinalIgnoreCase)
            })
        if ($local.Count -gt 0) {
            return [pscustomobject]@{
                Nodes          = @($local[0])
                Resolution     = 'SameFile'
                CandidateCount = $candidates.Count
            }
        }
    }

    return [pscustomobject]@{
        Nodes          = $candidates
        Resolution     = 'Ambiguous'
        CandidateCount = $candidates.Count
    }
}
