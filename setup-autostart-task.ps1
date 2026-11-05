# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param([switch]$Enable)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/setup/setup-autostart-task.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
