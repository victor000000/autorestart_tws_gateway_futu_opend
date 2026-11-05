# MANUAL ONLY: enables/disables Windows auto-logon. Must run elevated.
# Windows stores DefaultPassword in plaintext in HKLM; this helper is never autostarted.
[CmdletBinding()]
param(
    [string]$UserEmail,
    [string]$Password,
    [switch]$Disable
)

$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Remove-AutologonProperty {
    param([string]$Path, [string]$Name)
    # Only absence is benign. Do not conceal permission/provider failures.
    $properties = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    if ($properties.PSObject.Properties.Name -contains $Name) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
}

function Set-WindowsAutologon {
    [CmdletBinding()]
    param([string]$UserEmail, [string]$Password, [switch]$Disable)
    $ErrorActionPreference = 'Stop'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $passwordless = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    $logDir = Join-Path $ProjectRoot 'logs'
    $resultFile = Join-Path $logDir 'enable-autologon-result.txt'
    try {
        if (-not $Disable -and (-not $UserEmail -or -not $Password)) {
            throw 'UserEmail and Password are required when enabling.'
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
        }
        # Keep auto-logon off while changing credentials; enable only after all writes succeed.
        Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction Stop
        if ($Disable) {
            foreach ($name in @('DefaultPassword', 'DefaultUserName', 'DefaultDomainName')) {
                Remove-AutologonProperty -Path $winlogon -Name $name
            }
            $result = "OK disabled at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        }
        else {
            Set-ItemProperty -LiteralPath $winlogon -Name DefaultUserName -Value $UserEmail -ErrorAction Stop
            Set-ItemProperty -LiteralPath $winlogon -Name DefaultDomainName -Value 'MicrosoftAccount' -ErrorAction Stop
            Set-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -Value $Password -ErrorAction Stop
            Remove-AutologonProperty -Path $winlogon -Name AutoLogonCount
            New-Item -Path $passwordless -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -LiteralPath $passwordless -Name DevicePasswordLessBuildVersion -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '1' -ErrorAction Stop
            $result = "OK enabled for $UserEmail at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        }
        $result | Set-Content -LiteralPath $resultFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        $failure = $_
        try {
            "FAILED: $($failure.Exception.Message)" | Set-Content -LiteralPath $resultFile -Encoding UTF8 -ErrorAction Stop
        }
        catch { Write-Warning 'Could not write the auto-logon result file.' }
        throw $failure
    }
}

Set-WindowsAutologon -UserEmail $UserEmail -Password $Password -Disable:$Disable
