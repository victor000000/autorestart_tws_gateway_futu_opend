# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 150,
    # -Apps lets an individual starter log in only the client it launched.
    [ValidateSet('Both', 'Q73N', 'AlgoMaster')][string]$Apps = 'Both'
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/login/login-zsqh-clients.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
