# Shared helpers for driving an app's UI when it exposes no usable accessibility
# tree (Chromium/Java apps with windowless rendering). Two capabilities:
#
#   * Fingerprint: a coarse grayscale "thumbnail" of a window, used to verify
#     WHICH screen is showing before any input is sent. Login forms look nothing
#     like a logged-in workspace, so this is a dependable gate - it is what stops
#     a stray click landing inside a live trading window.
#   * Click: a real mouse click at a position relative to the window's top-left,
#     so it is independent of where the user has moved the window.
#
# Fingerprints are stored as hex strings in the login scripts; a reference image
# is never committed, so no account details end up in the repository.

if (-not ('UiInput' -as [type])) {
    $uiReferences = @('System.Drawing')
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # Explicit references replace Core's defaults; keep its framework refs
        # alongside the Windows drawing implementation (5.1 uses System.Drawing).
        $uiReferences = @((Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName)
        $uiReferences += [System.Drawing.Bitmap].Assembly.Location
        $uiReferences += @((Get-ChildItem -LiteralPath $PSHOME -Filter 'System.Private.Windows*.dll').FullName)
    }
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

public class UiInput
{
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    static IntPtr RootWindow(IntPtr hwnd)
    {
        IntPtr root = GetAncestor(hwnd, 2); // GA_ROOT, not GA_ROOTOWNER
        return root == IntPtr.Zero ? hwnd : root;
    }

    // Pure predicates, also used by synthetic safety tests.
    public static bool SameRoot(IntPtr intended, IntPtr hit)
    {
        return intended != IntPtr.Zero && intended == hit;
    }

    public static bool ContainsRelativePoint(RECT r, int x, int y)
    {
        return x >= 0 && y >= 0 && x < (long)r.Right - r.Left && y < (long)r.Bottom - r.Top;
    }

    static bool SameRect(RECT a, RECT b)
    {
        return a.Left == b.Left && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom;
    }

    // A sibling window or owned popup in the SAME process is not the target.
    public static bool IsPointOnWindow(IntPtr hwnd, int x, int y)
    {
        if (!IsWindow(hwnd) || !IsWindowVisible(hwnd) || IsIconic(hwnd)) { return false; }
        RECT r;
        if (!GetWindowRect(hwnd, out r) || x < r.Left || x >= r.Right || y < r.Top || y >= r.Bottom) { return false; }
        POINT p;
        p.X = x;
        p.Y = y;
        IntPtr hit = WindowFromPoint(p);
        return hit != IntPtr.Zero && SameRoot(RootWindow(hwnd), RootWindow(hit));
    }

    public static bool IsForegroundWindow(IntPtr hwnd)
    {
        return IsWindow(hwnd) && IsWindowVisible(hwnd) && !IsIconic(hwnd) &&
            SameRoot(RootWindow(hwnd), GetForegroundWindow());
    }

    public static string DescribePoint(int x, int y)
    {
        POINT p;
        p.X = x;
        p.Y = y;
        IntPtr hit = WindowFromPoint(p);
        if (hit == IntPtr.Zero) { return "nothing"; }
        IntPtr root = GetAncestor(hit, 2);
        if (root == IntPtr.Zero) { root = hit; }
        uint pid;
        GetWindowThreadProcessId(root, out pid);
        var cls = new StringBuilder(128);
        GetClassName(root, cls, cls.Capacity);
        var txt = new StringBuilder(128);
        GetWindowText(root, txt, txt.Capacity);
        return "pid=" + pid + " cls=" + cls.ToString() + " title=[" + txt.ToString() + "]";
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Moves/sizes a window; SWP_SHOWWINDOW (0x40) also un-hides one the app
    // has hidden, which is what makes a Java login window usable.
    public static bool Place(IntPtr h, int x, int y, int cx, int cy, uint flags)
    {
        SetProcessDPIAware();
        return SetWindowPos(h, IntPtr.Zero, x, y, cx, cy, flags);
    }

    // Windows refuses SetForegroundWindow from a process that is not already
    // foreground, which would leave another app sitting over the window we are
    // about to click. Temporarily attaching to the foreground thread's input
    // queue lifts that restriction.
    public static void ForceForeground(IntPtr hwnd)    {
        if (IsIconic(hwnd)) { ShowWindow(hwnd, 9); }
        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = (fg == IntPtr.Zero) ? 0 : GetWindowThreadProcessId(fg, out fgPid);
        uint me = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != me) { attached = AttachThreadInput(me, fgThread, true); }
        try
        {
            // HWND_TOP = 0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
        }
        finally
        {
            if (attached) { AttachThreadInput(me, fgThread, false); }
        }
    }

    public static RECT Rect(IntPtr h)
    {
        SetProcessDPIAware();
        RECT r;
        if (!IsWindow(h) || !GetWindowRect(h, out r)) { throw new InvalidOperationException("Target window no longer exists."); }
        return r;
    }

    public static Bitmap Capture(IntPtr hwnd)
    {
        // Must be DPI-aware, otherwise the rect is virtualized and the bitmap
        // covers only part of the window.
        SetProcessDPIAware();
        RECT r;
        if (!IsWindow(hwnd) || !GetWindowRect(hwnd, out r)) { return null; }
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) { return null; }
        var bmp = new Bitmap(w, h);
        using (var g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            bool printed;
            try { printed = PrintWindow(hwnd, hdc, 2); }
            finally { g.ReleaseHdc(hdc); }
            if (!printed) { bmp.Dispose(); return null; }
        }
        return bmp;
    }

    public static Bitmap ScreenCapture(IntPtr hwnd)
    {
        // Grabs the window's area from the real screen. Use this rather than
        // PrintWindow when it matters whether the window is actually visible:
        // PrintWindow happily renders a window that is cloaked or parked
        // off-screen, so its output looks right while the user sees something
        // else entirely at those coordinates.
        SetProcessDPIAware();
        RECT r;
        if (!IsWindow(hwnd) || !GetWindowRect(hwnd, out r)) { return null; }
        int w = r.Right - r.Left;
        int h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) { return null; }
        var bmp = new Bitmap(w, h);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, h));
        }
        return bmp;
    }

    static byte[] ToFingerprint(Bitmap src, int cols, int rows, int cropX, int cropY, int cropW, int cropH)
    {
        if (src == null) { return null; }
        int x0 = (cropX > 0 && cropX < src.Width) ? cropX : 0;
        int y0 = (cropY > 0 && cropY < src.Height) ? cropY : 0;
        int w = (cropW > 0 && x0 + cropW < src.Width) ? cropW : src.Width - x0;
        int h = (cropH > 0 && y0 + cropH < src.Height) ? cropH : src.Height - y0;
        var crop = new Rectangle(x0, y0, w, h);
        using (var small = new Bitmap(cols, rows))
        {
            using (var g = Graphics.FromImage(small))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, new Rectangle(0, 0, cols, rows), crop, GraphicsUnit.Pixel);
            }
            var bytes = new byte[cols * rows];
            for (int y = 0; y < rows; y++)
            {
                for (int x = 0; x < cols; x++)
                {
                    Color c = small.GetPixel(x, y);
                    bytes[y * cols + x] = (byte)((c.R * 299 + c.G * 587 + c.B * 114) / 1000);
                }
            }
            return bytes;
        }
    }

    public static byte[] Fingerprint(IntPtr hwnd, int cols, int rows, int cropX, int cropY, int cropW, int cropH)
    {
        using (var src = Capture(hwnd))
        {
            // Some windows report a rect taller than the area they actually
            // paint (the rest stays transparent), so fingerprint only the
            // region that carries content. An offset also lets a caller skip
            // the title bar, whose colours change with window activation.
            return ToFingerprint(src, cols, rows, cropX, cropY, cropW, cropH);
        }
    }

    public static byte[] ScreenFingerprint(IntPtr hwnd, int cols, int rows, int cropX, int cropY, int cropW, int cropH)
    {
        using (var src = ScreenCapture(hwnd))
        {
            return ToFingerprint(src, cols, rows, cropX, cropY, cropW, cropH);
        }
    }

    public static bool Click(IntPtr hwnd, int relX, int relY, RECT expected, Func<bool> validateState)
    {
        SetProcessDPIAware();
        RECT r;
        if (!IsWindow(hwnd) || !GetWindowRect(hwnd, out r) || !SameRect(r, expected) ||
            !ContainsRelativePoint(r, relX, relY) || !IsForegroundWindow(hwnd)) { return false; }
        int x = r.Left + relX, y = r.Top + relY;
        if (!IsPointOnWindow(hwnd, x, y) || !SetCursorPos(x, y)) { return false; }
        System.Threading.Thread.Sleep(150);
        // Moving the cursor can open a popup. Re-check everything AFTER that wait,
        // immediately before mouse-down; never click an old position after a move.
        // The caller's screen predicate also runs after hover has settled.
        if (validateState != null && !validateState()) { return false; }
        RECT current;
        POINT cursor;
        if (!IsWindow(hwnd) || !GetWindowRect(hwnd, out current) || !SameRect(r, current) ||
            !ContainsRelativePoint(current, relX, relY) || !IsForegroundWindow(hwnd) ||
            !GetCursorPos(out cursor) || cursor.X != x || cursor.Y != y ||
            !IsPointOnWindow(hwnd, x, y)) { return false; }
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(70);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        return true;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // INPUT is a tagged union sized for MOUSEINPUT (40 bytes on x64); SendInput
    // rejects the call unless cbSize matches that, hence the explicit size.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint count, INPUT[] inputs, int size);

    // Types text as Unicode keystrokes. This is what actually reaches a
    // Chromium-hosted form - SendKeys silently does nothing there.
    public static int TypeUnicode(string text, IntPtr target)
    {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_UNICODE = 0x0004;
        const uint KEYEVENTF_KEYUP = 0x0002;
        var items = new List<INPUT>();
        foreach (char c in text)
        {
            INPUT down = new INPUT();
            down.type = INPUT_KEYBOARD;
            down.ki.wScan = c;
            down.ki.dwFlags = KEYEVENTF_UNICODE;
            items.Add(down);

            INPUT up = new INPUT();
            up.type = INPUT_KEYBOARD;
            up.ki.wScan = c;
            up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            items.Add(up);
        }
        RequireForeground(target);
        return (int)SendInput((uint)items.Count, items.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    static void RequireForeground(IntPtr target)
    {
        if (target != IntPtr.Zero && !IsForegroundWindow(target))
        { throw new InvalidOperationException("Target window lost foreground; no keyboard input sent."); }
    }

    // Presses and releases a virtual key (VK_RETURN 0x0D, VK_TAB 0x09, ...).
    public static int PressKey(ushort vk, IntPtr target)
    {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_KEYUP = 0x0002;
        var items = new INPUT[2];
        items[0].type = INPUT_KEYBOARD;
        items[0].ki.wVk = vk;
        items[1].type = INPUT_KEYBOARD;
        items[1].ki.wVk = vk;
        items[1].ki.dwFlags = KEYEVENTF_KEYUP;
        RequireForeground(target);
        return (int)SendInput(2, items, Marshal.SizeOf(typeof(INPUT)));
    }

    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();

    // Presses a key while holding Ctrl (e.g. Ctrl+A to select all, so that
    // typing over the selection replaces it).
    public static int PressKeyWithCtrl(ushort vk, IntPtr target)
    {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const ushort VK_CONTROL = 0x11;
        var items = new INPUT[4];
        items[0].type = INPUT_KEYBOARD;
        items[0].ki.wVk = VK_CONTROL;
        items[1].type = INPUT_KEYBOARD;
        items[1].ki.wVk = vk;
        items[2].type = INPUT_KEYBOARD;
        items[2].ki.wVk = vk;
        items[2].ki.dwFlags = KEYEVENTF_KEYUP;
        items[3].type = INPUT_KEYBOARD;
        items[3].ki.wVk = VK_CONTROL;
        items[3].ki.dwFlags = KEYEVENTF_KEYUP;
        RequireForeground(target);
        return (int)SendInput(4, items, Marshal.SizeOf(typeof(INPUT)));
    }

    // Gives keyboard focus to a specific window. A Chromium render widget nested
    // in a Java frame does not take focus from a click alone, so keystrokes
    // would otherwise go nowhere.
    public static void FocusHwnd(IntPtr target)
    {
        uint tmp;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = (fg == IntPtr.Zero) ? 0 : GetWindowThreadProcessId(fg, out tmp);
        uint targetThread = GetWindowThreadProcessId(target, out tmp);
        uint me = GetCurrentThreadId();
        bool a1 = false, a2 = false;
        if (fgThread != 0 && fgThread != me) { a1 = AttachThreadInput(me, fgThread, true); }
        if (targetThread != 0 && targetThread != me) { a2 = AttachThreadInput(me, targetThread, true); }
        try { SetFocus(target); }
        finally
        {
            if (a2) { AttachThreadInput(me, targetThread, false); }
            if (a1) { AttachThreadInput(me, fgThread, false); }
        }
    }

    // True when the given window currently holds the keyboard focus.
    public static bool HasFocus(IntPtr h)
    {
        return GetFocus() == h;
    }
}
"@ -ReferencedAssemblies $uiReferences -ErrorAction Stop
}

function Get-UiFingerprint {
    # Coarse grayscale thumbnail of a window, as a byte array ($null if unreadable).
    # CropOffset*/CropWidth/CropHeight limit it to the region the app actually
    # paints; skipping the title bar avoids counting its active/inactive colour.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [int]$Cols = 24,
        [int]$Rows = 15,
        [int]$CropOffsetX = 0,
        [int]$CropOffsetY = 0,
        [int]$CropWidth = 0,
        [int]$CropHeight = 0
    )
    return [UiInput]::Fingerprint($Hwnd, $Cols, $Rows, $CropOffsetX, $CropOffsetY, $CropWidth, $CropHeight)
}

function ConvertTo-UiFingerprintString {
    param([Parameter(Mandatory = $true)][byte[]]$Fingerprint)
    return (($Fingerprint | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertFrom-UiFingerprintString {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -notmatch '^(?:[0-9a-fA-F]{2})+$') { throw 'Invalid fingerprint hex string.' }
    $bytes = New-Object byte[] ($Text.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Text.Substring($i * 2, 2), 16)
    }
    return $bytes
}

function Get-UiFingerprintDistance {
    # Mean absolute per-pixel difference (0 = identical, 255 = black vs white).
    param(
        [Parameter(Mandatory = $true)][byte[]]$A,
        [Parameter(Mandatory = $true)][byte[]]$B
    )
    if (-not $A -or -not $B -or $A.Length -ne $B.Length) { return [double]::MaxValue }
    $sum = 0L
    for ($i = 0; $i -lt $A.Length; $i++) { $sum += [Math]::Abs([int]$A[$i] - [int]$B[$i]) }
    return [double]$sum / $A.Length
}

function Test-UiFingerprintMatch {
    # Pure comparison. An alternate screen must be farther away by a margin;
    # this prevents two similar login steps both passing a broad threshold.
    param(
        [AllowNull()][AllowEmptyCollection()][byte[]]$Fingerprint,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
        [double]$MaxDistance = 12.0,
        [string]$RejectedFingerprint = '',
        [double]$MinDistanceMargin = 1.0
    )
    if (-not $Fingerprint -or $MaxDistance -lt 0 -or $MinDistanceMargin -lt 0) { return $false }
    $want = ConvertFrom-UiFingerprintString -Text $ExpectedFingerprint
    if ($Fingerprint.Length -ne $want.Length) { return $false }
    $distance = Get-UiFingerprintDistance -A $Fingerprint -B $want
    if ($distance -gt $MaxDistance) { return $false }
    if ($RejectedFingerprint) {
        $reject = ConvertFrom-UiFingerprintString -Text $RejectedFingerprint
        if ($Fingerprint.Length -ne $reject.Length) { return $false }
        $otherDistance = Get-UiFingerprintDistance -A $Fingerprint -B $reject
        if ($distance + $MinDistanceMargin -ge $otherDistance) { return $false }
    }
    return $true
}

function Test-UiScreen {
    # $true when the window currently looks like the expected screen. The crop
    # values must match the ones the fingerprint was generated with. With
    # -FromScreen the comparison uses the real screen, so a window that is
    # cloaked or off-screen fails the test instead of passing it.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
        [double]$MaxDistance = 12.0,
        [int]$CropOffsetX = 0,
        [int]$CropOffsetY = 0,
        [int]$CropWidth = 0,
        [int]$CropHeight = 0,
        [switch]$FromScreen,
        [string]$RejectedFingerprint = '',
        [double]$MinDistanceMargin = 1.0
    )
    if ($FromScreen) {
        $now = [UiInput]::ScreenFingerprint($Hwnd, 24, 15, $CropOffsetX, $CropOffsetY, $CropWidth, $CropHeight)
    }
    else {
        $now = Get-UiFingerprint -Hwnd $Hwnd -CropOffsetX $CropOffsetX -CropOffsetY $CropOffsetY -CropWidth $CropWidth -CropHeight $CropHeight
    }
    return (Test-UiFingerprintMatch -Fingerprint $now -ExpectedFingerprint $ExpectedFingerprint `
        -MaxDistance $MaxDistance -RejectedFingerprint $RejectedFingerprint -MinDistanceMargin $MinDistanceMargin)
}

function Get-UiScreenFingerprintString {
    # Fingerprint of what is actually on screen for this window's area.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [int]$CropOffsetX = 0,
        [int]$CropOffsetY = 0,
        [int]$CropWidth = 0,
        [int]$CropHeight = 0
    )
    $fp = [UiInput]::ScreenFingerprint($Hwnd, 24, 15, $CropOffsetX, $CropOffsetY, $CropWidth, $CropHeight)
    if (-not $fp) { return $null }
    return (ConvertTo-UiFingerprintString -Fingerprint $fp)
}

function Invoke-UiClick {
    # Real mouse click, at a position relative to the window's top-left corner.
    #
    # A click is delivered to whatever window is topmost at that SCREEN point,
    # so the window is raised first and the point is then checked to belong to
    # the intended root HWND, never merely the same process. If something else
    # is on top there, no click is sent.
    # ValidateState is re-run after foreground/hover waits, before mouse-down.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [scriptblock]$ValidateState
    )
    if (-not [UiInput]::IsWindow($Hwnd)) { return $false }
    [UiInput]::ForceForeground($Hwnd)
    Start-Sleep -Milliseconds 600
    if (-not [UiInput]::IsForegroundWindow($Hwnd)) { return $false }
    $r = [UiInput]::Rect($Hwnd)
    if (-not [UiInput]::ContainsRelativePoint($r, $X, $Y)) { return $false }
    $validator = $null
    if ($ValidateState) {
        if (-not (& $ValidateState $Hwnd)) { return $false }
        $validator = [Func[bool]]{ return [bool](& $ValidateState $Hwnd) }
    }
    return [UiInput]::Click($Hwnd, $X, $Y, $r, $validator)
}

function Show-UiWindow {
    # Brings a window back on screen (Java apps minimize to (-48000,-48000)).
    # ForceForeground also restores an iconic window, and its AttachThreadInput
    # trick succeeds where a plain SetForegroundWindow is refused whenever this
    # process is not already the foreground one.
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    [UiInput]::ForceForeground($Hwnd)
    Start-Sleep -Milliseconds 700
}

function Show-UiWindowSized {
    # Shows a window and forces it to a known size, so positions measured at
    # that size line up. Needed because such a window otherwise reports (and
    # gets laid out at) a different size while it is hidden, which would put
    # every click in the wrong place.
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [int]$X = 150,
        [int]$Y = 150
    )
    [UiInput]::ForceForeground($Hwnd)                               # restores an iconic window too
    [void][UiInput]::ShowWindow($Hwnd, 5)                            # SW_SHOW
    [void][UiInput]::Place($Hwnd, $X, $Y, $Width, $Height, 0x0040)   # SWP_SHOWWINDOW
    Start-Sleep -Milliseconds 900
    [UiInput]::ForceForeground($Hwnd)
    Start-Sleep -Milliseconds 400
}

function Get-UiWindowSize {
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    $r = [UiInput]::Rect($Hwnd)
    return @{ Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
}

function Send-UiText {
    # Omitting Hwnd is reserved for the explicitly manual type-secret helper.
    param([Parameter(Mandatory = $true)][string]$Text, [IntPtr]$Hwnd = [IntPtr]::Zero)
    if ($PSBoundParameters.ContainsKey('Hwnd') -and ($Hwnd -eq [IntPtr]::Zero -or -not [UiInput]::IsForegroundWindow($Hwnd))) {
        throw 'Target window lost foreground; no text sent.'
    }
    $sent = [UiInput]::TypeUnicode($Text, $Hwnd)
    if ($sent -ne $Text.Length * 2) { throw 'Keyboard input was not fully delivered.' }
}

function Send-UiKey {
    param([Parameter(Mandatory = $true)][int]$VirtualKey, [IntPtr]$Hwnd = [IntPtr]::Zero)
    if ($PSBoundParameters.ContainsKey('Hwnd') -and ($Hwnd -eq [IntPtr]::Zero -or -not [UiInput]::IsForegroundWindow($Hwnd))) {
        throw 'Target window lost foreground; no key sent.'
    }
    if ([UiInput]::PressKey([uint16]$VirtualKey, $Hwnd) -ne 2) { throw 'Keyboard input was not fully delivered.' }
}

function Send-UiKeyWithCtrl {
    param([Parameter(Mandatory = $true)][int]$VirtualKey, [IntPtr]$Hwnd = [IntPtr]::Zero)
    if ($PSBoundParameters.ContainsKey('Hwnd') -and ($Hwnd -eq [IntPtr]::Zero -or -not [UiInput]::IsForegroundWindow($Hwnd))) {
        throw 'Target window lost foreground; no key sent.'
    }
    if ([UiInput]::PressKeyWithCtrl([uint16]$VirtualKey, $Hwnd) -ne 4) { throw 'Keyboard input was not fully delivered.' }
}

function Enter-UiLoginLock {
    # Shared across login workers, including independent manual launches.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\TradingApps.UiLogin')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another UI login worker is active; retry after it finishes.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}
