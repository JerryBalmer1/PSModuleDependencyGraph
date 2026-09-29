function Resolve-BoundParameter {
    <#
    .SYNOPSIS
        Shared binder used by public commands: Name / Path / ModuleInfo -> ModuleTarget.
    #>
    [CmdletBinding()]
    param(
        [string] $Name,
        [version] $RequiredVersion,
        [string] $Path,
        [System.Management.Automation.PSModuleInfo] $ModuleInfo,
        [string] $ParameterSetName
    )

    switch ($ParameterSetName) {
        'ByModuleInfo' { Resolve-PSModuleTarget -ModuleInfo $ModuleInfo }
        'ByPath' { Resolve-PSModuleTarget -Path $Path }
        default {
            if ($RequiredVersion) {
                Resolve-PSModuleTarget -Name $Name -RequiredVersion $RequiredVersion
            }
            else {
                Resolve-PSModuleTarget -Name $Name
            }
        }
    }
}
