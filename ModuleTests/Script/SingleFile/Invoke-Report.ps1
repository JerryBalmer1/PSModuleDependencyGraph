function Get-ReportData {
    param([string] $Name)
    Format-ReportLine -Text $Name
}

function Format-ReportLine {
    param([string] $Text)
    "[$Text]"
}

function Write-Report {
    param([string[]] $Names)
    foreach ($n in $Names) {
        Get-ReportData -Name $n
    }
}

Write-Report -Names 'alpha', 'beta'
