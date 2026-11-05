# Auto-login for the Futubull desktop app (FTNN / 富途牛牛).
#
# Futubull remembers both the account and the password, so its login screen
# only needs the "Log In" button clicked - no credential is read or typed.
# (Futubull's own "Automatic Login" option - the gear on the login screen -
# was enabled on 2026-10-17, so a normal start should not show the login
# screen at all; this script stays as the fallback for when it does.)
#
# Before clicking anything the window is fingerprinted and compared with a
# known login screen. That check is what makes this safe: the same window
# shows the live trading UI once logged in, and a blind click there could hit
# a trade button. If the screen is not recognised, nothing happens.
#
# Log file: logs\futunn-login.log

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,
    [double]$MaxScreenDistance = 12.0,
    [switch]$TestOnly,
    # No verified workspace reference is shipped. Without one, session state
    # stays unverified; a changed/closed login view is NOT proof of login.
    [ValidatePattern('^(?:[0-9a-fA-F]{720})?$')][string]$MainScreenFingerprint = ''
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/ui-input.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')

$logName = 'futunn-login'

# 24x15 grayscale thumbnail of the Futubull login screen (360 bytes as hex).
$LoginScreenFingerprint = '10110c0c0c0c0c0c0c0c0c0e015cfefefefefefefefefef111150f0f0e0e0e0e0e0e0e0f0264ffffffffffffffffffff1413100f0e0e0d0d0d0d0e0f025dffeaecffffffffffffff181813110f0f0e0e0e0e0f10035effeff2ffffffffffffff1c1d161311100f0f0f0f1011055ffff5f3f9ebfeffffffff20211a160a0b0a090b0c1112065ffff7f5f2eefdfeffffff24241c17533e3d3a2e2b13130760fff9faf9f9fefef6f5ff28281e1a9864655e3d3a14120660fffffffffffffffef8ff2a2b221e14120f0e0d0c12130661ffbfb1b8bebfbbbdbcfd2a2c24201c1a1816151313130763ff6f5258616558555bf92a2d26221f1c1918171615150861fffffff6efefefffffff2a2d2723201d1b1a1a1818180c65fffefefcfcfbfbfdfdff2a2d26221f1d1c1c1d1c1c1e1168fffffefafcfdfcfdffff2a2b2421201e222421212224176afffffdf1f4f6f3fbffff272e282626272d2e2a2a2a2a1a73ffffffffffffffffffff'

# The "Log In" button centre, and the window size the coordinates were taken at.
# Positions are scaled to the live window, so a resized window still works.
$ButtonX = 1074
$ButtonY = 525
$ButtonRefWidth = 1440
$ButtonRefHeight = 900

function Test-FutubullMainWindow {
    param([IntPtr]$Hwnd)
    if (-not $MainScreenFingerprint -or -not [UiInput]::IsWindow($Hwnd)) { return $false }
    return (Test-UiScreen -Hwnd $Hwnd -ExpectedFingerprint $MainScreenFingerprint `
        -RejectedFingerprint $LoginScreenFingerprint -MaxDistance ([Math]::Min(6.0, $MaxScreenDistance)))
}

$loginLock = $null
try {
if (-not $TestOnly) { $loginLock = Enter-UiLoginLock }
Write-AppLog '=== Futubull auto-login starting ===' $logName

# Wait for the login screen to appear. The login view lives inside the app's
# main window ('Futubull'), which starts small and resizes to the full
# workspace once logged in; a cold start can take a couple of minutes. Every
# visible window of the process is fingerprinted rather than just the first
# one found, so the process's helper windows (QTrayIconMessageWindow,
# Futubull AI, hidden FTNN popups) cannot be mistaken for the login screen.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process FTNN -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        foreach ($w in (Get-ProcessWindowList -ProcessId $proc.Id)) {
            if (-not $w.Visible -or $w.Title -ne 'Futubull') { continue }
            if (Test-FutubullMainWindow -Hwnd $w.Hwnd) {
                Write-AppLog 'Futubull main workspace positively recognized; no login needed.' $logName
                exit 0
            }
            if (Test-UiScreen -Hwnd $w.Hwnd -ExpectedFingerprint $LoginScreenFingerprint -MaxDistance $MaxScreenDistance) {
                $hwnd = $w.Hwnd
                break
            }
        }
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    Start-Sleep -Seconds 3
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-AppLog 'No recognized Futubull login screen; session state unverified - no action taken.' $logName
    exit 0
}

if ($TestOnly) {
    Write-AppLog 'Login screen detected; -TestOnly so no click was sent.' $logName
    exit 0
}

# PrintWindow only locates a candidate; foreground can expose a different state.
Show-UiWindow -Hwnd $hwnd
if (-not [UiInput]::IsForegroundWindow($hwnd) -or -not (Test-UiScreen -Hwnd $hwnd `
        -ExpectedFingerprint $LoginScreenFingerprint -MaxDistance $MaxScreenDistance -FromScreen)) {
    Write-AppLog 'Futubull real screen is no longer the login form - no click sent.' $logName
    exit 1
}
$size = Get-UiWindowSize -Hwnd $hwnd
if ($size.Width -le 0 -or $size.Height -le 0) {
    Write-AppLog 'Futubull window has no usable size - no action taken.' $logName
    exit 1
}
$x = [int][Math]::Round($ButtonX * $size.Width / $ButtonRefWidth)
$y = [int][Math]::Round($ButtonY * $size.Height / $ButtonRefHeight)

Write-AppLog "Login screen detected ($($size.Width)x$($size.Height)); clicking Log In." $logName
$loginGuard = {
    param($target)
    if (-not [UiInput]::IsForegroundWindow($target)) { return $false }
    $current = Get-UiWindowSize -Hwnd $target
    if ($current.Width -ne $size.Width -or $current.Height -ne $size.Height) { return $false }
    return (Test-UiScreen -Hwnd $target -ExpectedFingerprint $LoginScreenFingerprint `
        -MaxDistance $MaxScreenDistance -FromScreen)
}
if (-not (Invoke-UiClick -Hwnd $hwnd -X $x -Y $y -ValidateState $loginGuard)) {
    Write-AppLog 'Could not click Log In because another window is in front of it - no click was sent.' $logName
    exit 1
}

# Attempt once only. A spinner, error popup, process exit or an unknown image
# is not a successful login; require a separately verified workspace reference.
$wait = (Get-Date).AddSeconds(45)
$loggedIn = $false
while ((Get-Date) -lt $wait) {
    Start-Sleep -Seconds 3
    if (-not (Get-Process FTNN -ErrorAction SilentlyContinue)) { break }
    if (-not [UiInput]::IsWindow($hwnd)) { break }
    if (Test-FutubullMainWindow -Hwnd $hwnd) { $loggedIn = $true; break }
}

if ($loggedIn) {
    Write-AppLog 'Futubull main workspace positively recognized - logged in.' $logName
} else {
    Write-AppLog 'Futubull session state unverified after the single login attempt; manual verification required.' $logName
    exit 1
}

Write-AppLog '=== Futubull auto-login finished ===' $logName
}
finally {
    if ($loginLock) { $loginLock.ReleaseMutex(); $loginLock.Dispose() }
}
