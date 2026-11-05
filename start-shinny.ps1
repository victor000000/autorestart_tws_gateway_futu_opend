# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    # Groups that dispatch a covering login worker pass -NoLogin.
    [switch]$NoLogin
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/apps/start-shinny.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
