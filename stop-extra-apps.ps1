# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param()
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/operations/stop-extra-apps.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
