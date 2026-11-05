# Stops captured Futu OpenD / IB Gateway processes gracefully, then forces survivors.
[CmdletBinding()]
param([ValidateSet('Futu', 'IBGateway', 'Both')][string]$Target = 'Both')

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')

if (-not ('TradingStopWinTools' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TradingStopWinTools {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@ -ErrorAction Stop
}

function Get-TradingProcessSnapshot {
    param([ValidateSet('Futu', 'IBGateway', 'Both')][string]$Target = 'Both')
    $names = @()
    if ($Target -in @('Futu', 'Both')) { $names += 'Futu_OpenD' }
    if ($Target -in @('IBGateway', 'Both')) { $names += @('ibgateway', 'ibgateway1') }
    $ibcIds = @()
    if ($Target -in @('IBGateway', 'Both')) {
        $ibcIds = @(Get-IbcGatewayProcesses | ForEach-Object { [int]$_.ProcessId })
    }
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        $isIbc = $ibcIds -contains $process.Id
        if ($names -notcontains $process.ProcessName -and -not $isIbc) { continue }
        try {
            [pscustomobject]@{
                Process = $process
                Id = $process.Id
                Name = $process.ProcessName
                StartTicks = $process.StartTime.ToUniversalTime().Ticks
                IsIbc = $isIbc
            }
        }
        catch {
            if ($process.HasExited) { continue }
            throw
        }
    }
}

function Test-TradingProcessIdentity {
    param([Parameter(Mandatory = $true)]$Snapshot)
    try { $current = Get-Process -Id $Snapshot.Id -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $false }
        throw
    }
    return ($current.ProcessName -eq $Snapshot.Name -and
        $current.StartTime.ToUniversalTime().Ticks -eq $Snapshot.StartTicks)
}

function Assert-IbcStopTarget {
    param([Parameter(Mandatory = $true)]$Snapshot)
    if ($Snapshot.IsIbc -and -not (@(Get-IbcGatewayProcesses |
                Where-Object { $_.ProcessId -eq $Snapshot.Id }).Count -gt 0)) {
        throw "Refusing to stop PID $($Snapshot.Id): exact IBC gateway marker no longer matches."
    }
}

function Request-TradingProcessClose {
    param([Parameter(Mandatory = $true)]$Snapshot)
    if (-not (Test-TradingProcessIdentity $Snapshot)) { return }
    Assert-IbcStopTarget $Snapshot
    $closed = $Snapshot.Process.CloseMainWindow()
    if ($closed -or $Snapshot.Name -eq 'Futu_OpenD') { return }
    # CloseMainWindow ignores hidden windows. Post (never synchronous SendMessage)
    # WM_CLOSE only to gateway status windows, including those hidden by this project.
    foreach ($window in @(Get-ProcessWindowList -ProcessId $Snapshot.Id)) {
        if ($window.Title -notmatch 'IBKR Gateway') { continue }
        if (-not (Test-TradingProcessIdentity $Snapshot)) { return }
        Assert-IbcStopTarget $Snapshot
        if (-not [TradingStopWinTools]::PostMessage($window.Hwnd, 0x0010, [intptr]::Zero, [intptr]::Zero)) {
            throw "Could not request closure of gateway window for PID $($Snapshot.Id)."
        }
    }
}

function Stop-TradingProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [int]$GraceSeconds = 15,
        [int]$ForceSeconds = 5
    )
    if (-not (Test-TradingProcessIdentity $Snapshot)) { return }
    Write-AppLog "Stopping $($Snapshot.Name) (PID $($Snapshot.Id))..."
    try { Request-TradingProcessClose $Snapshot }
    catch {
        if (Test-TradingProcessIdentity $Snapshot) { throw }
        return
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Test-TradingProcessIdentity $Snapshot) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-TradingProcessIdentity $Snapshot)) { return }
    # Recheck PID/start time AND exact IBC command-line ownership before force.
    Assert-IbcStopTarget $Snapshot
    Write-AppLog "Forcing $($Snapshot.Name) (PID $($Snapshot.Id)) to stop."
    try { Stop-Process -InputObject $Snapshot.Process -Force -ErrorAction Stop }
    catch {
        if (Test-TradingProcessIdentity $Snapshot) { throw }
        return
    }
    $deadline = (Get-Date).AddSeconds($ForceSeconds)
    while ((Test-TradingProcessIdentity $Snapshot) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-TradingProcessIdentity $Snapshot) {
        throw "Failed to stop $($Snapshot.Name) (PID $($Snapshot.Id))."
    }
}

function Stop-TradingApps {
    param([ValidateSet('Futu', 'IBGateway', 'Both')][string]$Target = 'Both')
    Write-AppLog "=== Stop requested ($Target) ==="
    $snapshots = @(Get-TradingProcessSnapshot -Target $Target)
    foreach ($snapshot in $snapshots) { Stop-TradingProcessSnapshot $snapshot }
    Write-AppLog 'All captured target processes stopped.'
}

Stop-TradingApps -Target $Target
