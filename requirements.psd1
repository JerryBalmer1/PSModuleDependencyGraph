# Install with: Install-PSResource -RequiredResourceFile ./requirements.psd1 -Scope CurrentUser -TrustRepository
# module.build.ps1 reads these versions: Pester is a floor, InvokeBuild is pinned.
@{
    Pester      = @{
        version    = '[6.1.0, )'
        repository = 'PSGallery'
    }
    InvokeBuild = @{
        version    = '[5.14.23]'
        repository = 'PSGallery'
    }
}
