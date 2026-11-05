# Decrypts and prints the credentials stored in secrets\credentials.sec.
# The file is protected with Windows DPAPI and can only be decrypted by the
# Windows user "victo" on this machine.

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

$creds = Get-StoredCredentials
if ($null -eq $creds) {
    Write-Host 'No credential store found (secrets\credentials.sec).'
    return
}
$creds | ConvertTo-Json -Depth 4
