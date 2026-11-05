# Trader Workstation launcher used by the US group. IBKR Desktop uses the same
# IBKR login, so a running desktop is signed out first.
[CmdletBinding()]
param([switch]$UseDirectExe, [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
if ((Get-Process -Name tws, tws1 -ErrorAction SilentlyContinue) -or @(Get-IbcProcesses -Application Tws).Count -gt 0) {
    Write-AppLog 'Trader Workstation is already running.' 'apps'
    return
}
Stop-IbkrDesktopProcesses
$installDirectory = 'C:\Jts\1050'
$runtimeDirectory = Join-Path $ProjectRoot 'ibc'
$batch = Join-Path $runtimeDirectory 'StartTWS.bat'
$useIbc = (Test-Path -LiteralPath $batch -PathType Leaf) -and -not $UseDirectExe
if ($useIbc) { $useIbc = New-IbcConfig -Path (Join-Path $ProjectRoot 'secrets/ibc-config.ini') -LogName apps }
if ($useIbc) {
    Start-Process -FilePath $batch -ArgumentList '/INLINE' -WorkingDirectory $runtimeDirectory -WindowStyle Hidden -ErrorAction Stop | Out-Null
}
else {
    $executable = Get-DirectIbExecutable -Directory $installDirectory -Name tws
    Start-Process -FilePath $executable -ArgumentList (ConvertTo-NativeArgument -Value "-J-DjtsConfigDir=$installDirectory") `
        -WorkingDirectory $installDirectory -ErrorAction Stop | Out-Null
}
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    if ((Get-Process -Name tws, tws1 -ErrorAction SilentlyContinue) -or @(Get-IbcProcesses -Application Tws).Count -gt 0) {
        Write-AppLog 'Trader Workstation process detected; authentication may require manual action.' 'apps'
        return
    }
    Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
throw "Trader Workstation was not detected within $TimeoutSeconds seconds."
