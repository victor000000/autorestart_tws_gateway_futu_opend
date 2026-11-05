# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param([string]$InstallDir = 'C:\ntws', [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/apps/start-ibkr-desktop.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
