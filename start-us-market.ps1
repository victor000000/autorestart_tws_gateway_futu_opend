# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param([switch]$Wait, [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/groups/start-us-market.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
