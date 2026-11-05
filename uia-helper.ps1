# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
param(
    [string]$AutomationId,
    [string]$Name,
    [switch]$Invoke,
    [int]$ProcessId = 0,
    [ValidateRange(1, 1000)][int]$Limit = 10
)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'scripts/tools/uia-helper.ps1') @PSBoundParameters @args
    if (-not $?) { exit 1 }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
