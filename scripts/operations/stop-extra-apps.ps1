# Stops only the captured auxiliary trading processes; never Excel or OBS.
[CmdletBinding()]
param()

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')

function Get-ExtraProcessSnapshot {
    # Exact executable names, not prefixes (ntws is thinkorswim's current name).
    $names = @('TradingView', 'thinkorswim', 'ntws', 'mytrader_spqh', 'AlgoMaster', 'Q73N', 'FTNN')
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        if ($names -notcontains $process.ProcessName) { continue }
        try {
            [pscustomobject]@{
                Process = $process
                Id = $process.Id
                Name = $process.ProcessName
                StartTicks = $process.StartTime.ToUniversalTime().Ticks
            }
        }
        catch {
            if ($process.HasExited) { continue }
            throw
        }
    }
}

function Test-ExtraProcessIdentity {
    param([Parameter(Mandatory = $true)]$Snapshot)
    try { $current = Get-Process -Id $Snapshot.Id -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $false }
        throw
    }
    return ($current.ProcessName -eq $Snapshot.Name -and
        $current.StartTime.ToUniversalTime().Ticks -eq $Snapshot.StartTicks)
}

function Stop-ExtraProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [int]$GraceSeconds = 8,
        [int]$ForceSeconds = 5
    )
    if (-not (Test-ExtraProcessIdentity $Snapshot)) { return }
    Write-AppLog "Stopping $($Snapshot.Name) (PID $($Snapshot.Id))..." 'apps'
    try { $null = $Snapshot.Process.CloseMainWindow() }
    catch {
        if (Test-ExtraProcessIdentity $Snapshot) { throw }
        return
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Test-ExtraProcessIdentity $Snapshot) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-ExtraProcessIdentity $Snapshot)) { return }
    Write-AppLog "Forcing $($Snapshot.Name) (PID $($Snapshot.Id)) to stop." 'apps'
    try { Stop-Process -InputObject $Snapshot.Process -Force -ErrorAction Stop }
    catch {
        if (Test-ExtraProcessIdentity $Snapshot) { throw }
        return
    }
    $deadline = (Get-Date).AddSeconds($ForceSeconds)
    while ((Test-ExtraProcessIdentity $Snapshot) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-ExtraProcessIdentity $Snapshot) {
        throw "Failed to stop $($Snapshot.Name) (PID $($Snapshot.Id))."
    }
}

function Stop-ExtraApps {
    Write-AppLog '=== Stopping extra apps ===' 'apps'
    # Capture once before closing anything. A replacement/new instance is never swept up.
    $snapshots = @(Get-ExtraProcessSnapshot)
    foreach ($snapshot in $snapshots) { Stop-ExtraProcessSnapshot $snapshot }
    Write-AppLog '=== Captured extra apps stopped ===' 'apps'
}

Stop-ExtraApps
