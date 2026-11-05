# Manually registers the logon task, DISABLED unless -Enable is explicitly supplied.
# No Startup-folder fallback: that would silently bypass the disabled-by-default gate.
[CmdletBinding()]
param([switch]$Enable)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

function Register-TradingAutostartTask {
    [CmdletBinding()]
    param([switch]$Enable)
    $ErrorActionPreference = 'Stop'
    $taskName = 'TradingApps-Autostart'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $ProjectRoot 'autostart-trading-apps.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments -ErrorAction Stop
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId -ErrorAction Stop
        $trigger.Delay = 'PT20S'
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -ErrorAction Stop
        # Register with its intended state atomically, never briefly enable then disable.
        $settings.Enabled = [bool]$Enable
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited -ErrorAction Stop
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Starts configured trading apps after Windows logon (explicit opt-in).' -Force -ErrorAction Stop | Out-Null
        $state = if ($Enable) { 'enabled (explicit -Enable)' } else { 'disabled' }
        Write-AppLog "Scheduled task '$taskName' registered $state."
        Write-Host "Scheduled task '$taskName' registered $state."
    }
    catch {
        Write-Error "Scheduled task registration failed; no Startup shortcut was created. $($_.Exception.Message)" -ErrorAction Continue
        throw
    }
}

Register-TradingAutostartTask -Enable:$Enable
