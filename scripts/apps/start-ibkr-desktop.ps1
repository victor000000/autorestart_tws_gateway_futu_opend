# IBKR Desktop does not support IBC. Password and passkey remain manual.
# Preserve existing TWS / IB Gateway sessions and refuse a conflicting launch.
[CmdletBinding()]
param([string]$InstallDir = 'C:\ntws', [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

if (-not (Get-Process -Name ntws -ErrorAction SilentlyContinue)) {
    Assert-NoIbLaunchConflict -Application Desktop
}
Start-ManagedApplication -Name ntws -Executable (Join-Path $InstallDir 'ntws.exe') `
    -WorkingDirectory $InstallDir -TimeoutSeconds $TimeoutSeconds
