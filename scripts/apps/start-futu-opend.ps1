# Starts Futu OpenD if it is not already running, then waits until its API port is up.
# Log file: logs\futu-opend.log
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 180)

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'window-util.ps1')

$name = 'Futu_OpenD'
if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
    Write-AppLog 'Futu OpenD is already running; waiting for the API port.' 'futu-opend'
} else {
    Write-AppLog 'Starting Futu OpenD...' 'futu-opend'
    if (-not (Test-Path -LiteralPath $FutuExe -PathType Leaf)) { throw "Futu OpenD executable not found: $FutuExe" }
    Start-Process -FilePath $FutuExe -WorkingDirectory (Split-Path -Path $FutuExe -Parent) -ErrorAction Stop | Out-Null
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $current = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if (Test-ProcessPortOwner -Port 11111 -ProcessIds @($current | ForEach-Object { $_.Id })) {
        Write-AppLog 'Futu OpenD owns API port 11111 and accepts connections.' 'futu-opend'
        # Tuck the window into the system tray (close-to-tray), like clicking its X.
        Start-Sleep -Seconds 3
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $sent = Send-CloseToTray -ProcessId $proc.Id
            Start-Sleep -Seconds 3
            $visible = @(Get-ProcessWindowList -ProcessId $proc.Id | Where-Object { $_.Visible -and $_.Title })
            if ($visible.Count -gt 0) {
                $hidden = Hide-AppWindows -ProcessId $proc.Id
                Write-AppLog "Futu OpenD window hidden directly (fallback; hidden=$hidden)." 'futu-opend'
            } else {
                Write-AppLog 'Futu OpenD minimized to the system tray.' 'futu-opend'
            }
        }
        return
    }
    Start-Sleep -Seconds 3
}
throw "Futu OpenD API port 11111 was not ready after $TimeoutSeconds seconds; manual login may be required."
