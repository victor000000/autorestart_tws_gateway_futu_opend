# Window helper utilities used by the start/stop scripts.
# Provides window enumeration, hide/show, and close-to-tray helpers.

if (-not ('WinTools' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinTools
{
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static List<string[]> GetProcessWindows(uint targetPid)
    {
        var result = new List<string[]>();
        EnumWindows((h, l) =>
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == targetPid)
            {
                var sb = new StringBuilder(512);
                GetWindowText(h, sb, 512);
                result.Add(new string[] { h.ToInt64().ToString(), IsWindowVisible(h) ? "1" : "0", sb.ToString() });
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@
}

function Get-ProcessWindowList {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    return [WinTools]::GetProcessWindows([uint32]$ProcessId) | ForEach-Object {
        [pscustomobject]@{
            Hwnd    = [intptr][long]$_[0]
            Visible = ($_[1] -eq '1')
            Title   = $_[2]
        }
    }
}

function Hide-AppWindows {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$TitleMatch = ''
    )
    $hidden = 0
    foreach ($w in (Get-ProcessWindowList -ProcessId $ProcessId)) {
        if ($TitleMatch -and ($w.Title -notmatch $TitleMatch)) { continue }
        if ($w.Visible -and $w.Title) {
            [void][WinTools]::ShowWindow($w.Hwnd, 0)
            $hidden++
        }
    }
    return $hidden
}

function Show-AppWindows {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$TitleMatch = ''
    )
    $shown = 0
    foreach ($w in (Get-ProcessWindowList -ProcessId $ProcessId)) {
        if ($TitleMatch -and ($w.Title -notmatch $TitleMatch)) { continue }
        if ($w.Title) {
            [void][WinTools]::ShowWindow($w.Hwnd, 5)
            $shown++
        }
    }
    return $shown
}

function Send-CloseToTray {
    # Sends WM_CLOSE to visible top-level windows so the app can hide itself
    # to the system tray (used for Futu OpenD, which minimizes to tray on close).
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $sent = 0
    foreach ($w in (Get-ProcessWindowList -ProcessId $ProcessId)) {
        if ($w.Visible -and $w.Title) {
            [void][WinTools]::SendMessage($w.Hwnd, 0x0010, [intptr]::Zero, [intptr]::Zero)
            $sent++
        }
    }
    return $sent
}

function Ensure-GatewayWindowHidden {
    # The IB Gateway (running inside IBC's Java process) has no system tray
    # support, so the status window is hidden entirely to keep the taskbar clean.
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $hidden = 0
    foreach ($w in (Get-ProcessWindowList -ProcessId $ProcessId)) {
        if ($w.Visible -and ($w.Title -match 'IBKR Gateway')) {
            [void][WinTools]::ShowWindow($w.Hwnd, 0)
            $hidden++
        }
    }
    return $hidden
}
