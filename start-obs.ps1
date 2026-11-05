# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    # Starts OBS without recording; the workspace then records only if it already is.
    [switch]$NoRecord
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/apps/start-obs.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
