# Starts thinkorswim and logs it in by default; installation defaults are in config/apps.psd1.
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    # Groups that dispatch a covering login worker pass -NoLogin.
    [switch]$NoLogin
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
$started = Start-ConfiguredApplication -Name 'schwab' -TimeoutSeconds $TimeoutSeconds -PassThru
if ($started -and -not $NoLogin) { Invoke-AppLogin -Entry 'start-schwab.ps1' }
