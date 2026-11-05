# Starts doublecmd if needed; installation defaults are in config/apps.psd1.
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
Start-ConfiguredApplication -Name 'doublecmd' -TimeoutSeconds $TimeoutSeconds
