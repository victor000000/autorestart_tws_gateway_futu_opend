# Starts Gateway and waits for its own API listener. Manual passkey stays manual.
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 300, [switch]$UseDirectExe, [switch]$Paper, [switch]$PrepareOnly)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'window-util.ps1')

function Start-GatewayTray {
    $path = Join-Path $ProjectRoot 'gateway-tray.ps1'
    $pattern = [regex]::Escape($path)
    $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match $pattern -and $_.CommandLine -match '(?i)(?:^|\s)"?-File"?\s' }
    if (-not $existing) { Start-ProjectScript -Name 'gateway-tray.ps1' }
}

if ($PrepareOnly -and -not $Paper) { throw 'PrepareOnly is supported only with Paper.' }
if ($Paper) {
    if ($UseDirectExe) { throw 'Paper mode requires isolated IBC startup; direct launch is not supported.' }
    Start-IsolatedPaperGateway -ProjectDirectory $ProjectRoot -TimeoutSeconds $TimeoutSeconds -PrepareOnly:$PrepareOnly
    return
}

$liveConfigPath = Join-Path $ProjectRoot 'secrets/ibc-config.ini'
$running = @(Get-Process -Name ibgateway, ibgateway1 -ErrorAction SilentlyContinue).Count -gt 0 -or
    @(Get-IbcGatewayProcesses -ConfigPath $liveConfigPath).Count -gt 0
if (-not $running) {
    $directory = Join-Path $ProjectRoot 'ibc'
    $batch = Join-Path $directory 'StartGateway.bat'
    $useIbc = (Test-Path -LiteralPath $batch -PathType Leaf) -and -not $UseDirectExe
    if ($useIbc) {
        $useIbc = New-IbcConfig -Path (Join-Path $ProjectRoot 'secrets/ibc-config.ini') -TradingMode live
    }
    if ($useIbc) {
        Write-AppLog 'Starting IB Gateway via IBC; passkey confirmation may be required.' 'ibgateway'
        # IBC invokes extensionless Windows commands (including powershell).
        # WSL callers can inherit PATHEXT=.CPL, silently dropping required JVM options.
        $previousPathExt = $env:PATHEXT
        try {
            $env:PATHEXT = (@('.COM', '.EXE', '.BAT', '.CMD') + @($previousPathExt -split ';') |
                Where-Object { $_ } | Select-Object -Unique) -join ';'
            Start-Process -FilePath $batch -ArgumentList '/INLINE' -WorkingDirectory $directory -WindowStyle Hidden -ErrorAction Stop | Out-Null
        }
        finally { $env:PATHEXT = $previousPathExt }
    }
    else {
        $executable = Get-DirectIbExecutable -Directory $IbGatewayDir -Name ibgateway
        Write-AppLog 'Starting IB Gateway directly (manual login).' 'ibgateway'
        Start-Process -FilePath $executable -ArgumentList (ConvertTo-NativeArgument -Value "-J-DjtsConfigDir=$IbGatewayDir") `
            -WorkingDirectory $IbGatewayDir -ErrorAction Stop | Out-Null
    }
}
else { Write-AppLog 'IB Gateway is already running; checking its API listener.' 'ibgateway' }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    if (Test-GatewayApiReady -ConfigPath $liveConfigPath) {
        Write-AppLog 'IB Gateway owns API port 4001 and accepts connections.' 'ibgateway'
        $identities = @(Get-IbcGatewayProcesses -ConfigPath $liveConfigPath | ForEach-Object { $_.ProcessId })
        $identities += @(Get-Process -Name ibgateway, ibgateway1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        foreach ($identity in $identities) { $null = Ensure-GatewayWindowHidden -ProcessId $identity }
        Start-GatewayTray
        return
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
throw "IB Gateway API was not ready within $TimeoutSeconds seconds. Check the login/passkey prompt and local logs."
