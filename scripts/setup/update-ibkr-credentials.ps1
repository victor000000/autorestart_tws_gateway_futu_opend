# Copies the IBKR login (username + password) from 1Password into the local
# DPAPI-encrypted store (secrets\credentials.sec), so the market-set scripts
# can fill the IBC login form without any 1Password authorization.
#
# Run again whenever the IBKR password changes in 1Password:
#   powershell -ExecutionPolicy Bypass -File .\update-ibkr-credentials.ps1
#
# 1Password may show an unlock/approve prompt - that is the one-time auth this
# script exists to avoid at startup.
[CmdletBinding()]
param(
    [string]$ItemId = 'qhhuqifb3anutix6qbca6emena'
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

$creds = Get-OnePasswordIbkrCredentials -ItemId $ItemId
if (-not $creds) {
    Write-Error 'Could not read the IBKR login item from 1Password (CLI missing, item not found, or authorization not completed).'
    exit 1
}

$mutex = New-Object Threading.Mutex($false, 'Local\TradingAppsCredentialUpdate')
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(30000) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Another credential update is in progress.' }

$store = Get-StoredCredentials
if ($null -ceq $store) { $store = [pscustomobject]@{} }

$old = $store.ibkr_tws_gateway
$wasInSync = ($old -and $old.username -ceq $creds.Username -and $old.password -ceq $creds.Password)

$entry = $old
if ($null -ceq $entry) {
    $entry = [pscustomobject]@{}
    $store | Add-Member -NotePropertyName ibkr_tws_gateway -NotePropertyValue $entry
}
$entry | Add-Member -NotePropertyName username -NotePropertyValue $creds.Username -Force
$entry | Add-Member -NotePropertyName password -NotePropertyValue $creds.Password -Force
$entry | Add-Member -NotePropertyName updated -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force

Save-StoredCredentials -Store $store

$check = Get-StoredCredentials
$okUser = ($check.ibkr_tws_gateway.username -ceq $creds.Username)
$okPw = ($check.ibkr_tws_gateway.password -ceq $creds.Password)

Write-Host ("IBKR credentials saved to secrets\credentials.sec (username ok: {0}; password ok: {1}; already in sync: {2})." -f $okUser, $okPw, [bool]$wasInSync)
if (-not ($okUser -and $okPw)) { throw 'Credential update verification failed.' }
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
