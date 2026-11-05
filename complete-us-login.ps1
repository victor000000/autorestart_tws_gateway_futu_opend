# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/groups/complete-us-login.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
