# Starts Excel with the newest trading workbook, excluding Office lock files.
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
if (Get-Process -Name EXCEL -ErrorAction SilentlyContinue) {
    Write-AppLog 'Excel is already running.' 'apps'
    return
}
$executable = 'C:\Program Files\Microsoft Office\Root\Office16\EXCEL.EXE'
if (-not (Test-Path -LiteralPath $executable)) {
    $executable = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\excel.exe' -ErrorAction SilentlyContinue).'(default)'
}
if (-not $executable) { throw 'Excel executable not found.' }
$workbookDirectory = Join-Path $env:USERPROFILE 'Documents/trading_logs'
$workbook = Get-LatestWorkbook -Directory $workbookDirectory
$arguments = @()
if ($workbook) { $arguments = @($workbook.FullName) }
Start-ManagedApplication -Name EXCEL -Executable $executable -Arguments $arguments -TimeoutSeconds $TimeoutSeconds
