# Captures a window's contents directly (works even if occluded).
# Usage: powershell -File capture-window.ps1 -Hwnd 1234 -Out C:\temp\win.png

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][long]$Hwnd,
    [Parameter(Mandatory = $true)][string]$Out
)

$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class WinCap
{
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static void Save(IntPtr hwnd, string path)
    {
        // Without this the process sees DPI-virtualized window rects, so the
        // bitmap covers only part of the window and the rest is clipped.
        SetProcessDPIAware();
        RECT r;
        GetWindowRect(hwnd, out r);
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) throw new Exception("window has no size");
        using (var bmp = new Bitmap(w, h))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                IntPtr hdc = g.GetHdc();
                try { PrintWindow(hwnd, hdc, 2); }
                finally { g.ReleaseHdc(hdc); }
            }
            bmp.Save(path);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing

[WinCap]::Save([intptr]$Hwnd, $Out)
Write-Output "saved $Out"
