# TradingView is installed as a Microsoft Store application.
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
if (Get-Process -Name TradingView -ErrorAction SilentlyContinue) {
    Write-AppLog 'TradingView is already running.' 'apps'
    return
}
$appId = 'TradingView.Desktop_n534cwy3pjxzj!TradingView.Desktop'
Write-AppLog 'Launching TradingView desktop...' 'apps'
Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') `
    -ArgumentList (ConvertTo-NativeArgument -Value "shell:appsFolder\$appId") -ErrorAction Stop | Out-Null
$null = Wait-AppProcess -Name TradingView -TimeoutSeconds $TimeoutSeconds
Write-AppLog 'TradingView process detected.' 'apps'
