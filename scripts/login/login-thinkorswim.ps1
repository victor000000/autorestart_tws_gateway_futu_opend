# Auto-login for thinkorswim (Charles Schwab).
#
# The login window is a two-step form: Login ID -> Continue -> password ->
# sign in. Credentials come from the DPAPI-encrypted store (secrets\credentials.sec),
# entry 'schwab' (username + password), so nothing is stored in this file.
#
# IMPORTANT - why this checks the real screen rather than the window:
# thinkorswim's login window can exist as a live, minimised-to-nowhere window
# that still renders a perfect login form when asked (PrintWindow), while the
# screen at those coordinates shows something else entirely. Acting on that
# would send clicks and keystrokes into whatever window the user really has
# there. So the form is located and verified against an actual screen grab,
# and if the form is not genuinely on screen, nothing is sent.
#
# Schwab asks for a verification code on a new device only, so a normal start
# completes unattended. If a code is required the window stays open and the
# script says so instead of guessing.
#
# Log file: logs\thinkorswim-login.log

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 180,
    [double]$MaxScreenDistance = 12.0,
    [switch]$TestOnly,
    [switch]$CaptureDiagnostics
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')
. (Join-Path $ProjectRoot 'src/ui-input.ps1')

$logName = 'thinkorswim-login'

# 24x15 grayscale thumbnails of the "Welcome" (Login ID) screen, taken from the
# real screen (title bar excluded - its colour follows window activation).
# Build 1994.0.53 draws two vertical layouts for this screen: when a Login ID
# is already filled in, the "Remember Login ID" row is also drawn and the
# Continue button moves down (y=480 instead of y=428). Each layout is verified
# separately and the matching Continue position is used, so the click lands on
# the button either way.
$WelcomeFingerprint = '050d121416181b120507050404040404040404040405050501000000000f231f1f23160000000000000000000000000001000000000a160e0000000202020202020202010000000001000000000920201b201002040505050505060a00000000010000000029271e231e1a180d050505050505060000000001000000001107030402030401000000000000000000000001000000001e423f3e3f3f3b3b3d4040404045230000000001000000003f80787878766e6b6d76787878804100000000010000000000000000000608070805000000000000000000010000000000000000000506050604000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000'
$WelcomeEmptyFingerprint = '050d121416181b120507050404040404040404040405050501000000000f231f1f23160000000000000000000000000001000000000a191202010202020202020202020100000000010000000010160e05050505050505050505060a0000000001000000000100000101010101010101010101010000000001000000001934313131312f2e2f31313131341a00000000010000000043898181807f7772757f818181894600000000010000000001030303040b0c0c0c0b030303030100000000010000000000000000000607060704000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000'

# Same-thumbnail fingerprint of the "Password" step (the form after Continue),
# also from the real screen. It exists because the two steps are very similar
# as 24x15 thumbnails (about 9 apart, i.e. under the 12.0 default threshold) -
# so "is the Welcome screen gone?" cannot detect the advance. Test the
# Password fingerprint directly with a tight threshold instead.
$PasswordFingerprint = '050d121416181b120507050404040404040404040405050501000000000f231d1d23160000000000000000000000000001000000000c18190c01020202020202020200000000000001000000011415140c0707070707070707081b11000000000100000000040000010101010101010101010907000000000100000000132a2828282827262728282828281400000000010000000052a89d9d9c9e978e979e9c9d9da854000000000100000000070e0e0e100f11121010100f0e0e0700000000010000000000000000050406090406090200000000000000010000000000000000010908080909010000000000000000010000000000000000010706060706010000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000'

# Control positions, measured from the real screen with the window at its
# normal size. The form is top-anchored, so both axes scale with the width.
$RefWidth = 849
$RefHeight = 1050
$LoginIdX = 425
$LoginIdY = 285
$ContinueX = 425
$ContinueY = 480
$ContinueEmptyY = 428
# Second step: the password form replaces the Login ID form in the same window.
$PasswordX = 425
$PasswordY = 290
$LogInButtonX = 425
$LogInButtonY = 434

# Fingerprint crop: below the title bar, down to the bottom bar.
$CropOffsetY = 100
$CropHeight = 850

function Get-TosLoginWindow {
    $proc = Get-Process thinkorswim -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }
    return Get-ProcessWindowList -ProcessId $proc.Id |
        Where-Object { $_.Title -eq 'Logon to thinkorswim' } |
        Select-Object -First 1
}

function Test-TosLoginState {
    param([IntPtr]$Hwnd, [ValidateSet('Welcome', 'WelcomeEmpty', 'Password')][string]$State, [switch]$RequireForeground)
    if (-not [UiInput]::IsWindow($Hwnd)) { return $false }
    if ($RequireForeground -and -not [UiInput]::IsForegroundWindow($Hwnd)) { return $false }
    $size = Get-UiWindowSize -Hwnd $Hwnd
    if ([Math]::Abs($size.Width - $RefWidth) -gt 8 -or [Math]::Abs($size.Height - $RefHeight) -gt 8) { return $false }
    if ($LoginGeometry -and ($size.Width -ne $LoginGeometry.Width -or $size.Height -ne $LoginGeometry.Height)) { return $false }
    $expected = $WelcomeFingerprint
    $rejected = $PasswordFingerprint
    if ($State -eq 'Password') { $expected = $PasswordFingerprint; $rejected = $WelcomeFingerprint }
    if ($State -eq 'WelcomeEmpty') { $expected = $WelcomeEmptyFingerprint }
    return (Test-UiScreen -Hwnd $Hwnd -ExpectedFingerprint $expected -RejectedFingerprint $rejected `
        -MaxDistance ([Math]::Min(6.0, $MaxScreenDistance)) -FromScreen `
        -CropOffsetY $CropOffsetY -CropWidth $RefWidth -CropHeight $CropHeight)
}

function Assert-TosLoginState {
    param([IntPtr]$Hwnd, [string]$State)
    if (-not (Test-TosLoginState -Hwnd $Hwnd -State $State -RequireForeground)) {
        throw 'Login screen, geometry or foreground changed; no further input sent.'
    }
}

function Get-TosWelcomeLayout {
    # Which Login ID layout is on screen, or $null. Both are verified states and
    # the caller uses the Continue position that belongs to the one it found.
    param([IntPtr]$Hwnd, [switch]$RequireForeground)
    if (Test-TosLoginState -Hwnd $Hwnd -State Welcome -RequireForeground:$RequireForeground) { return 'Prefilled' }
    if (Test-TosLoginState -Hwnd $Hwnd -State WelcomeEmpty -RequireForeground:$RequireForeground) { return 'Empty' }
    return $null
}

$loginLock = $null
$LoginGeometry = $null
try {
if (-not $TestOnly) { $loginLock = Enter-UiLoginLock }
Write-AppLog '=== thinkorswim auto-login starting ===' $logName

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$win = $null
while ((Get-Date) -lt $deadline) {
    $win = Get-TosLoginWindow
    if ($win) { break }
    # No login window: either thinkorswim is not running yet, or it is already
    # logged in. Keep waiting briefly for one to appear.
    Start-Sleep -Seconds 3
}

if (-not $win) {
    Write-AppLog 'No thinkorswim login window (not running, or already logged in) - no action taken.' $logName
    exit 0
}

# A successful login leaves the 'Logon to thinkorswim' window behind as a
# hidden, stale window for the rest of the app session. If it is hidden and
# the main window is up, the session is live: leave it alone (forcing it on
# screen would pop a dead login dialog over the running app).
if (-not $win.Visible) {
    $tosProcId = (Get-Process thinkorswim -ErrorAction SilentlyContinue | Select-Object -First 1).Id
    $main = Get-ProcessWindowList -ProcessId $tosProcId | Where-Object { $_.Visible -and $_.Title -like 'Main@thinkorswim*' } | Select-Object -First 1
    if ($main) {
        Write-AppLog 'Already logged in (main window is up; hidden stale login window left alone) - no action taken.' $logName
        exit 0
    }
}

# TestOnly observes the current screen without raising, restoring or resizing it,
# and never reads the credential store.
if ($TestOnly) {
    $layout = Get-TosWelcomeLayout -Hwnd $win.Hwnd
    Write-AppLog "TestOnly: current Welcome form recognized=$([bool]$layout) (layout=$layout); no window changes or input sent." $logName
    exit 0
}

# Bring it on screen and wait until the form is genuinely displayed. This is
# the gate: until the real screen shows the login form, nothing is clicked.
$onScreen = $false
$sized = $false
while ((Get-Date) -lt $deadline) {
    # Force it on screen at the size the positions were measured at; while the
    # window is hidden thinkorswim lays it out differently, and clicking at the
    # measured positions would then miss.
    Show-UiWindowSized -Hwnd $win.Hwnd -Width $RefWidth -Height $RefHeight
    $try = Get-UiWindowSize -Hwnd $win.Hwnd
    if ([Math]::Abs($try.Width - $RefWidth) -le 8 -and [Math]::Abs($try.Height - $RefHeight) -le 8) {
        $sized = $true
        $layout = Get-TosWelcomeLayout -Hwnd $win.Hwnd -RequireForeground
        if ($layout) { $onScreen = $true; break }
    }
    Start-Sleep -Seconds 3
}

# Every position below is expressed in the reference geometry, so acting on a
# differently-sized window would put the clicks in the wrong place. Refuse.
if (-not $sized) {
    Write-AppLog "Could not bring the login window to its expected size ($RefWidth x $RefHeight) - no input was sent." $logName
    exit 1
}

if (-not $onScreen) {
    Write-AppLog 'The thinkorswim login form is not on screen (unexpected screen or window hidden) - no input was sent.' $logName
    exit 1
}

$store = Get-StoredCredentials
$entry = $store.schwab
if (-not $entry -or -not $entry.username -or -not $entry.password) {
    Write-AppLog "ERROR: no 'schwab' entry (username + password) in the encrypted store." $logName
    exit 1
}

$welcomeState = if ($layout -eq 'Empty') { 'WelcomeEmpty' } else { 'Welcome' }
$continueY = if ($layout -eq 'Empty') { $ContinueEmptyY } else { $ContinueY }
Assert-TosLoginState -Hwnd $win.Hwnd -State $welcomeState
$size = Get-UiWindowSize -Hwnd $win.Hwnd
$LoginGeometry = $size
$scale = $size.Width / $RefWidth
$welcomeGuard = { param($target) Test-TosLoginState -Hwnd $target -State $welcomeState -RequireForeground }
$passwordGuard = { param($target) Test-TosLoginState -Hwnd $target -State Password -RequireForeground }

Write-AppLog "Login form on screen ($($size.Width)x$($size.Height)); entering the Login ID." $logName
if (-not (Invoke-UiClick -Hwnd $win.Hwnd -X ([int][Math]::Round($LoginIdX * $scale)) -Y ([int][Math]::Round($LoginIdY * $scale)) -ValidateState $welcomeGuard)) {
    Write-AppLog 'Could not click the Login ID field (another window is in front) - no input was sent.' $logName
    exit 1
}
Start-Sleep -Milliseconds 400
Assert-TosLoginState -Hwnd $win.Hwnd -State $welcomeState
Send-UiKeyWithCtrl -VirtualKey 0x41 -Hwnd $win.Hwnd   # Ctrl+A
Start-Sleep -Milliseconds 300
Assert-TosLoginState -Hwnd $win.Hwnd -State $welcomeState
Send-UiText -Text $entry.username -Hwnd $win.Hwnd
Start-Sleep -Milliseconds 800
Assert-TosLoginState -Hwnd $win.Hwnd -State $welcomeState

if (-not (Invoke-UiClick -Hwnd $win.Hwnd -X ([int][Math]::Round($ContinueX * $scale)) -Y ([int][Math]::Round($continueY * $scale)) -ValidateState $welcomeGuard)) {
    Write-AppLog 'Could not click Continue (another window is in front).' $logName
    exit 1
}
Start-Sleep -Seconds 2

# Wait for the password step. Schwab shows a spinner on Continue and can take
# a while to advance (seen: over a minute on 2026-10-17), so poll for the
# change rather than assume a fixed delay.
# Detect the Password step directly, with a tight threshold: "the Welcome
# screen is gone" is not a usable signal, because the two screens are only
# about 9 apart in the thumbnail metric - under the 12.0 default, so the
# Welcome check keeps matching the Password screen.
$advanced = $false
$stepDeadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $stepDeadline) {
    Start-Sleep -Seconds 2
    if (Test-TosLoginState -Hwnd $win.Hwnd -State Password -RequireForeground) {
        $advanced = $true
        break
    }
}

# Diagnostics are opt-in: a login screenshot can contain account details.
if ($CaptureDiagnostics) {
    $shot = Join-Path $ProjectRoot 'logs\thinkorswim-password-step.png'
    & (Join-Path $ProjectRoot 'scripts/tools/capture-window.ps1') -Hwnd $win.Hwnd -Out $shot | Out-Null
}

# Only type the password if the form actually advanced past the Login ID step.
# If it did not (Continue missed, or Schwab asked for something else), typing
# would put the password somewhere it does not belong.
if (-not $advanced) {
    Write-AppLog 'The Login ID step did not advance within 120s - the password was NOT typed; check manually.' $logName
    exit 1
}

Assert-TosLoginState -Hwnd $win.Hwnd -State Password
Write-AppLog 'Password step shown; entering the password.' $logName
if (-not (Invoke-UiClick -Hwnd $win.Hwnd -X ([int][Math]::Round($PasswordX * $scale)) -Y ([int][Math]::Round($PasswordY * $scale)) -ValidateState $passwordGuard)) {
    Write-AppLog 'Could not click the password field (another window is in front).' $logName
    exit 1
}
Start-Sleep -Milliseconds 400
Assert-TosLoginState -Hwnd $win.Hwnd -State Password
Send-UiKeyWithCtrl -VirtualKey 0x41 -Hwnd $win.Hwnd   # Ctrl+A
Start-Sleep -Milliseconds 300
Assert-TosLoginState -Hwnd $win.Hwnd -State Password
Send-UiText -Text $entry.password -Hwnd $win.Hwnd
Start-Sleep -Milliseconds 600
Assert-TosLoginState -Hwnd $win.Hwnd -State Password
if (-not (Invoke-UiClick -Hwnd $win.Hwnd -X ([int][Math]::Round($LogInButtonX * $scale)) -Y ([int][Math]::Round($LogInButtonY * $scale)) -ValidateState $passwordGuard)) {
    Write-AppLog 'Could not click Log In (another window is in front).' $logName
    exit 1
}

# Success signal: the main window ('Main@thinkorswim ...') appears. The old
# signal - the login window disappearing - never fires, because after a
# successful login thinkorswim keeps that window around as a hidden, stale
# one. The session can take ~30-60 seconds to set up, so allow generous time.
$wait = (Get-Date).AddSeconds(150)
$loggedIn = $false
while ((Get-Date) -lt $wait) {
    Start-Sleep -Seconds 3
    $tosProc = Get-Process thinkorswim -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tosProc) {
        Write-AppLog 'The thinkorswim process exited during login (check logs\thinkorswim).' $logName
        break
    }
    $main = Get-ProcessWindowList -ProcessId $tosProc.Id | Where-Object { $_.Visible -and $_.Title -like 'Main@thinkorswim*' } | Select-Object -First 1
    if ($main) { $loggedIn = $true; break }
}

if ($loggedIn) {
    Write-AppLog 'thinkorswim logged in (main window is up).' $logName
} else {
    Write-AppLog "thinkorswim's main window did not appear within 150s - the login may be waiting on a verification code (check manually)." $logName
    exit 1
}

Write-AppLog '=== thinkorswim auto-login finished ===' $logName
}
finally {
    if ($loginLock) { $loginLock.ReleaseMutex(); $loginLock.Dispose() }
}
