# Dispatches the extra application group; use -Wait to aggregate worker results.
[CmdletBinding()]
param([switch]$Wait, [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
Invoke-AppGroup -Name 'extra' -Wait:$Wait -TimeoutSeconds $TimeoutSeconds
