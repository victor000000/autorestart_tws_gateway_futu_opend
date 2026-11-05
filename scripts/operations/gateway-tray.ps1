# IB Gateway notification icon: green API-ready, orange waiting, gray stopped.
# Double-click restores the window. Exiting the tray restores hidden gateway windows.
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
if (-not ('TrayWinTools' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TrayWinTools {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
}
'@ -ErrorAction Stop
}

function Get-GatewayState {
    $running = (@(Get-IbcGatewayProcesses).Count -gt 0) -or
        [bool](Get-Process -Name 'ibgateway', 'ibgateway1' -ErrorAction SilentlyContinue)
    if (-not $running) { return 'down' }
    if (Test-GatewayApiReady) { return 'up' }
    return 'waiting'
}

function Get-GatewayWindowHandles {
    $processIds = @(Get-IbcGatewayProcesses | ForEach-Object { $_.ProcessId })
    $processIds += @(Get-Process -Name 'ibgateway', 'ibgateway1' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    foreach ($procId in @($processIds | Select-Object -Unique)) {
        foreach ($window in (Get-ProcessWindowList -ProcessId $procId)) {
            if ($window.Title -match 'IBKR Gateway') { $window.Hwnd }
        }
    }
}

function Show-GatewayWindows {
    $count = 0
    foreach ($handle in (Get-GatewayWindowHandles)) {
        [void][WinTools]::ShowWindow($handle, 5)
        [void][TrayWinTools]::SetForegroundWindow($handle)
        $count++
    }
    if ($count -gt 0) { Write-AppLog "Tray: showed IB Gateway window ($count)." 'apps' }
    return $count
}

function Hide-GatewayWindows {
    $count = 0
    foreach ($handle in (Get-GatewayWindowHandles)) {
        [void][WinTools]::ShowWindow($handle, 0)
        $count++
    }
    if ($count -gt 0) { Write-AppLog "Tray: hid IB Gateway window ($count)." 'apps' }
    return $count
}

function New-TrayIcon {
    param([System.Drawing.Color]$Color)
    $bitmap = $graphics = $brush = $pen = $font = $format = $null
    $nativeIcon = [intptr]::Zero
    try {
        $bitmap = New-Object System.Drawing.Bitmap(32, 32)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush($Color)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 70, 70), 2)
        $graphics.FillEllipse($brush, 2, 2, 28, 28)
        $graphics.DrawEllipse($pen, 2, 2, 28, 28)
        $font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $graphics.DrawString('IB', $font, [System.Drawing.Brushes]::White,
            (New-Object System.Drawing.RectangleF(2, 2, 28, 28)), $format)
        $nativeIcon = $bitmap.GetHicon()
        return [System.Drawing.Icon]::FromHandle($nativeIcon).Clone()
    }
    finally {
        if ($nativeIcon -ne [intptr]::Zero) { [void][TrayWinTools]::DestroyIcon($nativeIcon) }
        foreach ($resource in @($format, $font, $pen, $brush, $graphics, $bitmap)) {
            if ($null -ne $resource) { $resource.Dispose() }
        }
    }
}

function Set-TrayState {
    param([string]$NewState)
    if ($NewState -eq $script:state) { return }
    $newIcon = New-TrayIcon -Color $colors[$NewState]
    try { $notify.Icon = $newIcon }
    catch { $newIcon.Dispose(); throw }
    if ($script:currentIcon) { $script:currentIcon.Dispose() }
    $script:currentIcon = $newIcon
    $script:state = $NewState
    $notify.Text = $texts[$NewState]
    $statusItem.Text = $statusTexts[$NewState]
    $running = $NewState -ne 'down'
    $showItem.Enabled = $running
    $hideItem.Enabled = $running
    $startItem.Enabled = -not $running
    Write-AppLog "Tray: IB Gateway state is now '$NewState'." 'apps'
}

function Close-GatewayTray {
    param($Timer, $Notify, $Menu, $Icon, $Mutex, [bool]$OwnsMutex)
    # Each cleanup is independent, so one failure cannot leak the other resources.
    foreach ($cleanup in @(
        { if ($null -ne $Timer) { try { $Timer.Stop() } finally { $Timer.Dispose() } } },
        { if ($OwnsMutex) { [void](Show-GatewayWindows) } },
        { if ($null -ne $Notify) { try { $Notify.Visible = $false } finally { $Notify.Dispose() } } },
        { if ($null -ne $Menu) { $Menu.Dispose() } },
        { if ($null -ne $Icon) { $Icon.Dispose() } },
        { if ($null -ne $Mutex) { try { if ($OwnsMutex) { $Mutex.ReleaseMutex() } } finally { $Mutex.Dispose() } } }
    )) {
        try { & $cleanup }
        catch { Write-Warning "Tray cleanup failed: $($_.Exception.Message)" }
    }
}

function Start-GatewayTray {
    $mutex = $timer = $notify = $menu = $null
    $ownsMutex = $false
    $script:state = ''
    $script:downSince = $null
    $script:currentIcon = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\IbGatewayTrayIcon')
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            Write-AppLog 'Gateway tray icon is already running; nothing to do.' 'apps'
            return
        }
        $colors = @{
            up = [System.Drawing.Color]::FromArgb(0, 140, 0)
            waiting = [System.Drawing.Color]::FromArgb(230, 140, 0)
            down = [System.Drawing.Color]::FromArgb(130, 130, 130)
        }
        $texts = @{
            up = 'IB Gateway: connected (API port 4001)'
            waiting = 'IB Gateway: running, waiting for login'
            down = 'IB Gateway: not running'
        }
        $statusTexts = @{
            up = 'Status: connected (API port 4001)'
            waiting = 'Status: running - login/API not up yet'
            down = 'Status: not running'
        }
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Status: ...'
        $statusItem.Enabled = $false
        [void]$menu.Items.Add($statusItem)
        $showItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Show gateway window'
        $hideItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide gateway window'
        [void]$menu.Items.Add($showItem)
        [void]$menu.Items.Add($hideItem)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $startItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start IB Gateway'
        [void]$menu.Items.Add($startItem)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit tray icon'
        [void]$menu.Items.Add($exitItem)
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.ContextMenuStrip = $menu
        $showItem.Add_Click({ [void](Show-GatewayWindows) })
        $hideItem.Add_Click({ [void](Hide-GatewayWindows) })
        $startItem.Add_Click({
            try { Start-ProjectScript -Name 'start-ibgateway.ps1' }
            catch { Write-AppLog "Tray: gateway launch failed: $($_.Exception.Message)" 'apps' }
        })
        $exitItem.Add_Click({ [System.Windows.Forms.Application]::Exit() })
        $notify.Add_DoubleClick({
            if ((Show-GatewayWindows) -eq 0) {
                $notify.ShowBalloonTip(3000, 'IB Gateway', 'No gateway window found (is the gateway running?)', 'Info')
            }
        })
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5000
        $timer.Add_Tick({
            try {
                $state = Get-GatewayState
                Set-TrayState -NewState $state
                if ($state -eq 'down') {
                    if (-not $script:downSince) { $script:downSince = Get-Date }
                    elseif (((Get-Date) - $script:downSince).TotalSeconds -ge 120) {
                        Write-AppLog 'Tray: IB Gateway has been gone for 2 minutes; removing tray icon.' 'apps'
                        [System.Windows.Forms.Application]::Exit()
                    }
                }
                else { $script:downSince = $null }
            }
            catch { Write-AppLog "Tray: state check failed: $($_.Exception.Message)" 'apps' }
        })
        Set-TrayState -NewState (Get-GatewayState)
        $notify.Visible = $true
        $timer.Start()
        Write-AppLog 'Gateway tray icon started (double-click to show the gateway window).' 'apps'
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Close-GatewayTray -Timer $timer -Notify $notify -Menu $menu -Icon $script:currentIcon -Mutex $mutex -OwnsMutex $ownsMutex
    }
}

Start-GatewayTray
