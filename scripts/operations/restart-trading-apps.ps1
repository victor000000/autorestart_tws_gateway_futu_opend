# Restart the gateway services, leaving auxiliary apps untouched.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

# Stop synchronously: a failure must prevent the next launch.
& (Join-Path $ProjectRoot 'stop-trading-apps.ps1') -Target Both
if (-not $?) { throw 'Stopping trading apps failed; restart cancelled.' }
Start-ProjectScript -Name 'autostart-trading-apps.ps1'
