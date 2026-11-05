# Re-shows the hidden IB Gateway status window (and any hidden Futu OpenD
# window) that the start scripts tuck away.

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')

$shownAny = $false

# Both the IBC-hosted gateway (java) and a directly launched ibgateway.exe
# carry the 'IBKR Gateway' main window title.
$gatewayPids = @(Get-IbcGatewayProcesses | ForEach-Object { $_.ProcessId })
$gatewayPids += @(Get-Process -Name 'ibgateway', 'ibgateway1' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

foreach ($procId in $gatewayPids) {
    $n = 0
    foreach ($w in (Get-ProcessWindowList -ProcessId $procId)) {
        if ($w.Title -match 'IBKR Gateway') {
            [void][WinTools]::ShowWindow($w.Hwnd, 5)
            $n++
        }
    }
    if ($n -gt 0) { Write-AppLog "Showed IB Gateway window ($n)." 'apps'; $shownAny = $true }
}

$futu = Get-Process -Name 'Futu_OpenD' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($futu) {
    $n = Show-AppWindows -ProcessId $futu.Id -TitleMatch 'Futu'
    if ($n -gt 0) { Write-AppLog "Showed Futu OpenD window ($n)." 'apps'; $shownAny = $true }
}

if (-not $shownAny) { Write-Host 'No hidden windows found to show.' }
