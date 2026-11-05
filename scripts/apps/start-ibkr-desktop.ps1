# IBKR Desktop does not support IBC. Password and passkey remain manual.
# TWS / IB Gateway use the same IBKR login, so they are signed out first.
[CmdletBinding()]
param([string]$InstallDir = 'C:\ntws', [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

if (-not (Get-Process -Name ntws -ErrorAction SilentlyContinue)) {
    Stop-IbSessionProcesses
}
Start-ManagedApplication -Name ntws -Executable (Join-Path $InstallDir 'ntws.exe') `
    -WorkingDirectory $InstallDir -TimeoutSeconds $TimeoutSeconds
