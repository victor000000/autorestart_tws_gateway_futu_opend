# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [Parameter(Mandatory = $true)][string]$Key,
    [ValidateSet('username', 'password')][string]$Field = 'password'
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/tools/type-secret.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
