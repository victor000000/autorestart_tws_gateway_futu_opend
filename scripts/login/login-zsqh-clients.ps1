# Auto-login for the Zheshang Futures clients in the CN market set:
#   - KuaiQi3  (Q73N / ShinnyClient)  : login dialog driven via Win32 messages
#   - AlgoMaster (YongChun Master 2)  : login form driven via UI Automation
# Credentials come from the DPAPI store (secrets\credentials.sec), key 'zsqh':
#   资金账号 -> account, 交易mm -> trading password (parsed from notes).
# If an app is already logged in (no login dialog), it is skipped.
# -Apps limits a run to one client so an individual starter does not wait for
# an application it did not launch.
# Log file: logs\zsqh-login.log

[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 150,
    # -Apps lets an individual starter log in only the client it launched.
    [ValidateSet('Both', 'Q73N', 'AlgoMaster')][string]$Apps = 'Both'
)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'src/ui-input.ps1')
. (Join-Path $ProjectRoot 'src/window-util.ps1')

$logName = 'zsqh-login'

# ---------------------------------------------------------------- credentials
function Get-ZsqhCreds {
    $stored = Get-StoredCredentials
    if (-not $stored -or -not $stored.zsqh -or -not $stored.zsqh.notes) { return $null }
    $notes = [string]$stored.zsqh.notes
    $acct = $null; $tpwd = $null
    if ($notes -match '资金账号\s*[:：=]?\s*(\d+)') { $acct = $Matches[1] }
    if ($notes -match '交易(?:密码|mm)\s*[:：=]?\s*([A-Za-z0-9!@#\$%^&*._\-]+)') { $tpwd = $Matches[1] }
    if (-not $acct -or -not $tpwd) { return $null }
    return @{ Account = $acct; TradingPassword = $tpwd }
}

# -------------------------------------------------------------------- Win32
$win32Type = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class ZsqhWin32 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, string lp);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, StringBuilder lp);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
if (-not ('ZsqhWin32' -as [type])) { Add-Type $win32Type }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Find-ByAId {
    param([System.Windows.Automation.AutomationElement]$Root, [string]$Id)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Set-EditValue {
    param([System.Windows.Automation.AutomationElement]$El, [string]$Value)
    # The control can briefly be unavailable while a freshly opened login
    # window is still settling (seen: "could not set password" right after the
    # window appeared), so retry a few times before giving up.
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $vp = $El.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $vp.SetValue($Value)
            return $true
        } catch { Start-Sleep -Milliseconds 400 }
    }
    return $false
}

# --------------------------------------------------------------- KuaiQi3
function Test-Q73NDialog {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        return ($null -ne (Find-ByAId $el '7402'))   # the login button
    } catch { return $false }
}

function Test-Q73NAccount {
    param([System.Windows.Automation.AutomationElement]$Root, [string]$Account)
    # No verified account AutomationId is available. Only proceed if an exposed
    # non-password edit already holds the requested account, never a guessed ID.
    if (-not $Account) { return $false }
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    foreach ($edit in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        if ($edit.Current.IsPassword) { continue }
        $pattern = $null
        if ($edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) -and $pattern.Current.Value -ceq $Account) { return $true }
    }
    # Build 3.9.2608.4 exposes the login form as ControlType.Pane without
    # ValuePattern, so the pre-filled account is readable only as the field's
    # accessible name. Accept an exact name match on a non-password account
    # field; the known password control (1208) is never eligible.
    foreach ($field in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            $current = $field.Current
            if ($current.AutomationId -eq '1208' -or $current.IsPassword) { continue }
            if ($current.ClassName -notin @('ComboBox', 'Edit')) { continue }
            if ($current.Name -ceq $Account) { return $true }
        } catch { continue }
    }
    return $false
}

function Assert-Q73NControls {
    param([IntPtr]$Dialog, [IntPtr]$Edit, [IntPtr]$Button)
    if (-not [ZsqhWin32]::IsWindow($Dialog) -or -not [ZsqhWin32]::IsWindowVisible($Dialog) -or
        -not [ZsqhWin32]::IsWindow($Edit) -or -not [ZsqhWin32]::IsWindow($Button) -or
        -not [ZsqhWin32]::IsChild($Dialog, $Edit) -or -not [ZsqhWin32]::IsChild($Dialog, $Button)) {
        throw 'Q73N login controls changed; no further input sent.'
    }
}

function Invoke-Q73NLogin {
    param([IntPtr]$DialogHwnd, [string]$Account, [string]$Password)
    try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($DialogHwnd)
        $pwdEdit = Find-ByAId $el '1208'
        $loginBtn = Find-ByAId $el '7402'
        if (-not $pwdEdit -or -not $loginBtn) { Write-AppLog 'Q73N: login dialog controls not found' $logName; return $false }
        $pwdH = [IntPtr]$pwdEdit.Current.NativeWindowHandle
        $btnH = [IntPtr]$loginBtn.Current.NativeWindowHandle
        if ($pwdH -eq [IntPtr]::Zero -or $btnH -eq [IntPtr]::Zero) { Write-AppLog 'Q73N: controls have no native hwnd' $logName; return $false }

        if (-not $Password -or -not (Test-Q73NAccount -Root $el -Account $Account)) {
            Write-AppLog 'Q73N: requested account could not be verified; no password sent' $logName
            return $false
        }
        Assert-Q73NControls -Dialog $DialogHwnd -Edit $pwdH -Button $btnH
        [ZsqhWin32]::SendMessage($pwdH, 0x00B1, [IntPtr]::Zero, [IntPtr](-1)) | Out-Null     # EM_SETSEL(0,-1)
        [ZsqhWin32]::SendMessage($pwdH, 0x0303, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLEAR
        Start-Sleep -Milliseconds 150
        foreach ($ch in $Password.ToCharArray()) {
            Assert-Q73NControls -Dialog $DialogHwnd -Edit $pwdH -Button $btnH
            [ZsqhWin32]::SendMessage($pwdH, 0x0102, [IntPtr][int]$ch, [IntPtr]::Zero) | Out-Null  # WM_CHAR
            Start-Sleep -Milliseconds 40
        }
        Start-Sleep -Milliseconds 200
        Assert-Q73NControls -Dialog $DialogHwnd -Edit $pwdH -Button $btnH
        if (-not (Test-Q73NAccount -Root $el -Account $Account)) { return $false }
        [ZsqhWin32]::SendMessage($btnH, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # BM_CLICK
        Write-AppLog 'Q73N: credentials entered, login clicked' $logName
        return $true
    } catch {
        Write-AppLog 'Q73N: login controls unavailable or input failed; check manually' $logName
        return $false
    }
}

function Test-Q73NMainWindow {
    param($Process)
    $Process.Refresh()
    if ($Process.HasExited -or $Process.MainWindowHandle -eq [IntPtr]::Zero) { return $false }
    $main = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
    # The live trading window is an Afx MDI frame titled '<holder>-浙商期货-主屏';
    # the login form is the '#32770' dialog titled '快期3'.
    return ($main.Current.ClassName -ne '#32770' -and $main.Current.Name -match '快期|KuaiQi|Q73N|浙商期货')
}

function AutoLogin-Q73N {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $proc = Wait-AppProcess -Name Q73N -TimeoutSeconds $TimeoutSeconds
    $dlg = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline) {
        $proc.Refresh()
        if ($proc.HasExited) { throw 'Q73N exited while waiting for login.' }
        $dlg = [IntPtr]$proc.MainWindowHandle
        if (Test-Q73NDialog $dlg) { break }
        if (Test-Q73NMainWindow $proc) {
            Write-AppLog 'Q73N: main window positively recognized; no input sent' $logName
            return $true
        }
        Start-Sleep -Seconds 3
    }
    if (-not (Test-Q73NDialog $dlg)) { throw 'Q73N login state unverified within timeout.' }
    if (-not (Invoke-Q73NLogin -DialogHwnd $dlg -Account $Creds.Account -Password $Creds.TradingPassword)) { return $false }
    # Submit once. Only the live process's main window establishes success.
    # Server handshake plus workspace load is observed to exceed 40s.
    $wait = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $wait) {
        Start-Sleep -Seconds 2
        $proc.Refresh()
        if ($proc.HasExited) { throw 'Q73N exited after login submission.' }
        if (-not [ZsqhWin32]::IsWindow($dlg) -and (Test-Q73NMainWindow $proc)) {
            Write-AppLog 'Q73N: main window positively recognized after login' $logName
            return $true
        }
    }
    Write-AppLog 'Q73N: login not confirmed after 90s; check manually' $logName
    return $false
}

# -------------------------------------------------------------- AlgoMaster
function Get-AlgoMasterLoginWindow {
    param([int]$ProcessId)
    # UI Automation's RootElement enumeration omits hidden windows, but this
    # client hides its login form to the tray once authenticated. Enumerating the
    # process's top-level HWNDs keeps an already-authenticated session visible to
    # the worker instead of reporting it as unverified.
    foreach ($window in (Get-ProcessWindowList -ProcessId $ProcessId)) {
        # Untitled helper/IME windows cannot host the form; skip them cheaply.
        if (-not $window.Title) { continue }
        try { $element = [System.Windows.Automation.AutomationElement]::FromHandle($window.Hwnd) } catch { continue }
        if (-not $element) { continue }
        if (-not (Find-ByAId $element 'btn_login') -or -not (Find-ByAId $element 'text_id')) { continue }
        return [pscustomobject]@{ Window = $element; Handle = $window.Hwnd; Visible = $window.Visible }
    }
    return $null
}

function Invoke-AlgoMasterLogin {
    param([System.Windows.Automation.AutomationElement]$Win, [string]$Account, [string]$Password)
    try {
        $idEdit = Find-ByAId $Win 'text_id'
        $pwdEdit = Find-ByAId $Win 'text_pwd'
        $capEdit = Find-ByAId $Win 'text_captcha'
        $loginBtn = Find-ByAId $Win 'btn_login'
        if (-not $Account -or -not $Password -or -not $idEdit -or -not $pwdEdit -or -not $loginBtn) { Write-AppLog 'AlgoMaster: required login controls or credentials missing' $logName; return $false }

        if (-not (Set-EditValue $idEdit $Account)) { Write-AppLog 'AlgoMaster: could not set account; no password sent' $logName; return $false }
        $accountPattern = $idEdit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($accountPattern.Current.Value -cne $Account) { Write-AppLog 'AlgoMaster: account verification failed; no password sent' $logName; return $false }
        $pwdOk = Set-EditValue $pwdEdit $Password
        if (-not $pwdOk) { Write-AppLog 'AlgoMaster: could not set password' $logName; return $false }

        # captcha digits are exposed as text1..text4
        $cap = ''
        foreach ($i in 1..4) {
            $t = Find-ByAId $Win "text$i"
            if ($t) { $cap += $t.Current.Name } else { $cap = ''; break }
        }
        if ($cap) {
            if ($capEdit) {
                $capOk = Set-EditValue $capEdit $cap
                if (-not $capOk) { Write-AppLog 'AlgoMaster: could not set captcha' $logName; return $false }
            } else { Write-AppLog 'AlgoMaster: captcha shown but input field missing' $logName; return $false }
        } else {
            Write-AppLog 'AlgoMaster: captcha digits unreadable; manual verification required' $logName
            return $false
        }

        $rem = Find-ByAId $Win 'checkbox_rememberPwd'
        if ($rem) {
            try {
                $tp = $rem.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $tp.Toggle() }
            } catch {}
        }
        if ($accountPattern.Current.Value -cne $Account -or -not $loginBtn.Current.IsEnabled -or $loginBtn.Current.IsOffscreen) { return $false }
        $ip = $loginBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $ip.Invoke()
        Write-AppLog 'AlgoMaster: credentials entered, login clicked' $logName
        return $true
    } catch {
        Write-AppLog 'AlgoMaster: login controls unavailable or input failed; check manually' $logName
        return $false
    }
}

function AutoLogin-AlgoMaster {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $proc = Wait-AppProcess -Name AlgoMaster -TimeoutSeconds $TimeoutSeconds
    $login = $null
    $hiddenPolls = 0
    while ((Get-Date) -lt $deadline) {
        $proc.Refresh()
        if ($proc.HasExited) { throw 'AlgoMaster exited while waiting for login.' }
        $login = Get-AlgoMasterLoginWindow -ProcessId $proc.Id
        if ($login -and $login.Visible) { break }
        if ($login) {
            # A hidden login form is the same signal this worker trusts after
            # submitting credentials, so an already-authenticated session is
            # recognized here. Two consecutive observations keep a transient
            # startup hide from being mistaken for a completed login.
            $hiddenPolls++
            if ($hiddenPolls -ge 2) {
                Write-AppLog 'AlgoMaster: login form hidden while process remains running' $logName
                return $true
            }
        }
        else { $hiddenPolls = 0 }
        Start-Sleep -Seconds 3
    }
    if (-not $login -or -not $login.Visible) { throw 'AlgoMaster login state unverified within timeout.' }
    $loginHwnd = $login.Handle
    if ($loginHwnd -eq [IntPtr]::Zero -or -not [ZsqhWin32]::IsWindowVisible($loginHwnd)) { return $false }
    if (-not (Invoke-AlgoMasterLogin $login.Window $Creds.Account $Creds.TradingPassword)) { return $false }
    $wait = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $wait) {
        Start-Sleep -Seconds 5
        $proc.Refresh()
        if ($proc.HasExited) { throw 'AlgoMaster exited after login submission.' }
        # A native visibility check on a STILL EXISTING login HWND is the
        # client's known hide-to-tray signal. UIA exceptions are failures, not
        # evidence that login succeeded.
        if (-not [ZsqhWin32]::IsWindow($loginHwnd)) { throw 'AlgoMaster login window disappeared; session state unverified.' }
        if (-not [ZsqhWin32]::IsWindowVisible($loginHwnd)) {
            Write-AppLog 'AlgoMaster: login form hidden while process remains running' $logName
            return $true
        }
    }
    Write-AppLog 'AlgoMaster: login window still visible after 90s; check manually' $logName
    return $false
}

# -------------------------------------------------------------------- main
$loginLock = Enter-UiLoginLock
try {
    Write-AppLog '=== zsqh clients auto-login starting ===' $logName
    $Creds = Get-ZsqhCreds
    if (-not $Creds) { Write-AppLog 'ERROR: no zsqh credentials in the store' $logName; exit 1 }
    $q73Ok = $true
    $algoOk = $true
    if ($Apps -in @('Both', 'Q73N')) {
        try { $q73Ok = AutoLogin-Q73N }
        catch {
            Write-AppLog 'Q73N: login failed or session state unverified; check manually' $logName
            $q73Ok = $false
        }
    }
    if ($Apps -in @('Both', 'AlgoMaster')) {
        try { $algoOk = AutoLogin-AlgoMaster }
        catch {
            Write-AppLog 'AlgoMaster: login failed or session state unverified; check manually' $logName
            $algoOk = $false
        }
    }
    if (-not $q73Ok -or -not $algoOk) { exit 1 }
    Write-AppLog '=== zsqh clients auto-login finished ===' $logName
}
finally {
    $loginLock.ReleaseMutex()
    $loginLock.Dispose()
}
