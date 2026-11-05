# Restart managed trading apps; Excel and OBS are never stopped.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

# Stop synchronously: a failure must prevent the next launch.
& (Join-Path $ProjectRoot 'stop-extra-apps.ps1')
if (-not $?) { throw 'Stopping extra apps failed; restart cancelled.' }
& (Join-Path $ProjectRoot 'stop-trading-apps.ps1') -Target Both
if (-not $?) { throw 'Stopping trading apps failed; restart cancelled.' }
Start-ProjectScript -Name 'autostart-trading-apps.ps1'
