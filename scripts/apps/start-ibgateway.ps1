# Starts Gateway and waits for its own API listener. Manual passkey stays manual.
[CmdletBinding()]
param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 300, [switch]$UseDirectExe, [switch]$Paper)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
. (Join-Path $ProjectRoot 'window-util.ps1')

function Start-GatewayTray {
    $path = Join-Path $ProjectRoot 'gateway-tray.ps1'
    $pattern = [regex]::Escape($path)
    $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match $pattern -and $_.CommandLine -match '(?i)(?:^|\s)"?-File"?\s' }
    if (-not $existing) { Start-ProjectScript -Name 'gateway-tray.ps1' }
}

$running = @(Get-Process -Name ibgateway, ibgateway1 -ErrorAction SilentlyContinue).Count -gt 0 -or
    @(Get-IbcGatewayProcesses).Count -gt 0
if (-not $running) {
    $directory = Join-Path $ProjectRoot 'ibc'
    $batch = Join-Path $directory 'StartGateway.bat'
    $useIbc = (Test-Path -LiteralPath $batch -PathType Leaf) -and -not $UseDirectExe
    if ($useIbc) {
        $configName = if ($Paper) { 'secrets/ibc-paper-config.ini' } else { 'secrets/ibc-config.ini' }
        $mode = if ($Paper) { 'paper' } else { 'live' }
        $configPath = Join-Path $ProjectRoot $configName
        $useIbc = New-IbcConfig -Path $configPath -TradingMode $mode
        if ($Paper -and $useIbc) {
            $template = [IO.File]::ReadAllText($batch)
            $template = [regex]::Replace($template, '(?m)^set CONFIG=.*$', ('set CONFIG=' + $configPath))
            $template = [regex]::Replace($template, '(?m)^set TRADING_MODE=.*$', 'set TRADING_MODE=paper')
            $batch = Join-Path $directory 'StartPaperGateway.bat'
            [IO.File]::WriteAllText($batch, $template, [Text.Encoding]::ASCII)
        }
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
    if (Test-GatewayApiReady) {
        Write-AppLog 'IB Gateway owns API port 4001 and accepts connections.' 'ibgateway'
        $identities = @(Get-IbcGatewayProcesses | ForEach-Object { $_.ProcessId })
        $identities += @(Get-Process -Name ibgateway, ibgateway1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        foreach ($identity in $identities) { $null = Ensure-GatewayWindowHidden -ProcessId $identity }
        Start-GatewayTray
        return
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
throw "IB Gateway API was not ready within $TimeoutSeconds seconds. Check the login/passkey prompt and local logs."
