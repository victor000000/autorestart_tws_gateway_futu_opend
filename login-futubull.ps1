# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [int]$TimeoutSeconds = 300,
    [double]$MaxScreenDistance = 12.0,
    [switch]$TestOnly,
    # No verified workspace reference is shipped. Without one, session state
    # stays unverified; a changed/closed login view is NOT proof of login.
    [ValidatePattern('^(?:[0-9a-fA-F]{720})?$')][string]$MainScreenFingerprint = ''
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/login/login-futubull.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
