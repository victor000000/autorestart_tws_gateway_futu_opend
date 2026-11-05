# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [int]$TimeoutSeconds = 180,
    [double]$MaxScreenDistance = 12.0,
    [switch]$TestOnly,
    [switch]$CaptureDiagnostics
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/login/login-thinkorswim.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
