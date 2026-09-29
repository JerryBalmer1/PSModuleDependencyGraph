# Install with: Install-PSResource -RequiredResourceFile ./requirements.psd1
# build.ps1 imports Pester at this floor and refuses to run tests below it.
@{
    Pester = @{
        version    = '[6.1.0, )'
        repository = 'PSGallery'
    }
}
