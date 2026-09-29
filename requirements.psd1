# Installed by module.build.ps1 through ModuleFast. PSGallery is the source.
# Also readable by: Install-PSResource -RequiredResourceFile ./requirements.psd1
# Pester is a floor; InvokeBuild is pinned.
@{
    Pester      = @{ version = '[6.1.0, )' }
    InvokeBuild = @{ version = '[5.14.23]' }
}
