# Types a stored credential into the currently focused window (keeps the secret
# out of command lines and chat). Reads from the encrypted store.
#
# Usage:
#   powershell -File type-secret.ps1 -Key schwab
#   powershell -File type-secret.ps1 -Key zsqh        (parses the password out of notes)
#   powershell -File type-secret.ps1 -Key futunn_web

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Key,
    [ValidateSet('username', 'password')][string]$Field = 'password'
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/ui-input.ps1')

$c = Get-StoredCredentials
$e = $c.$Key
if (-not $e) { Write-Error "no store entry '$Key'"; exit 1 }

# Field-specific extraction must never substitute a password for a missing ID.
$val = Get-CredentialFieldValue -Entry $e -Field $Field
if (-not $val) { Write-Error "no '$Field' value found for '$Key'"; exit 1 }

# This is deliberately a manual helper: the caller chooses the focused control.
Send-UiText -Text $val
Write-Output 'typed'
