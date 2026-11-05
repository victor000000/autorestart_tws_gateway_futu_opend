# Paper startup never reuses, hides, stops, or reconfigures another Gateway.
function New-PaperGatewayBatchText {
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if ($Template -match '(?im)^set (?:TWSUSERID|TWSPASSWORD)=[ \t]*[^\r\n \t]') {
        throw 'IBC template must not contain inline login credentials.'
    }
    $values = [ordered]@{ CONFIG=$ConfigPath; TRADING_MODE='paper'; TWS_SETTINGS_PATH=$SettingsPath; LOG_PATH=$LogPath }
    foreach ($name in $values.Keys) {
        $pattern = '(?im)^set ' + $name + '=[^\r\n]*'
        if ([regex]::Matches($Template, $pattern).Count -ne 1) {
            throw "IBC template must contain exactly one $name assignment."
        }
        $replacement = 'set ' + $name + '=' + $values[$name]
        $Template = [regex]::Replace($Template, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement })
    }
    return $Template
}

function Invoke-IsolatedPaperGatewayStartup {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [switch]$PrepareOnly
    )
    $configPath = Join-Path $ProjectDirectory 'secrets/ibc-paper-config.ini'
    $settingsPath = Join-Path $ProjectDirectory 'ibc/settings-paper'
    $logPath = Join-Path $ProjectDirectory 'logs/ibc-paper'
    $batchPath = Join-Path $ProjectDirectory 'ibc/StartPaperGateway.bat'
    $paperProcesses = @(Get-IbcGatewayProcesses -ConfigPath $configPath)
    if ($paperProcesses.Count -eq 0) {
        if (@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq 4002 }).Count -gt 0) {
            throw 'Paper API port 4002 is already owned by another process; nothing was changed.'
        }
        $templatePath = Join-Path $ProjectDirectory 'ibc/StartGateway.bat'
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
            throw 'Paper mode requires the installed IBC Gateway batch template.'
        }
        $batchText = New-PaperGatewayBatchText -Template ([IO.File]::ReadAllText($templatePath)) `
            -ConfigPath $configPath -SettingsPath $settingsPath -LogPath $logPath
        if (-not (New-IbcConfig -Path $configPath -TradingMode paper -SettingsPath $settingsPath)) {
            throw 'Dedicated paper credentials are unavailable; no Gateway was launched.'
        }
        $null = New-Item -ItemType Directory -Path $settingsPath, $logPath -Force -ErrorAction Stop
        [IO.File]::WriteAllText($batchPath, $batchText, [Text.Encoding]::ASCII)
        if ($PrepareOnly) {
            Write-AppLog 'Paper Gateway prepared for port 4002; no application was launched and no account identity was verified.' 'ibgateway-paper'
            return
        }
        Write-AppLog 'Starting isolated paper Gateway on port 4002 with a read-only API; passkey may require manual approval.' 'ibgateway-paper'
        $previousPathExt = $env:PATHEXT
        try {
            $env:PATHEXT = (@('.COM', '.EXE', '.BAT', '.CMD') + @($previousPathExt -split ';') |
                Where-Object { $_ } | Select-Object -Unique) -join ';'
            Start-Process -FilePath $batchPath -ArgumentList '/INLINE' -WorkingDirectory (Split-Path $batchPath -Parent) `
                -WindowStyle Hidden -ErrorAction Stop | Out-Null
        }
        finally { $env:PATHEXT = $previousPathExt }
    }
    else {
        if ($PrepareOnly) { throw 'Dedicated paper process is already running; no configuration was changed.' }
        Write-AppLog 'Existing dedicated paper process found; checking only its port 4002 listener.' 'ibgateway-paper'
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $identities = @(Get-IbcGatewayProcesses -ConfigPath $configPath | ForEach-Object { [int]$_.ProcessId })
        if (Test-ProcessPortOwner -Port 4002 -ProcessIds $identities) {
            Write-AppLog 'Dedicated paper Gateway owns API port 4002; exact managedAccounts verification is still required.' 'ibgateway-paper'
            return
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw 'Paper Gateway API port 4002 is not ready. Check its login/passkey prompt and logs/ibc-paper; existing sessions were left untouched.'
}

function Start-IsolatedPaperGateway {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [switch]$PrepareOnly
    )
    # Serialize boot/manual launches for this checkout without sharing test locks.
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ProjectDirectory).ToLowerInvariant())
        $key = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\TradingAppsPaperGateway-' + $key))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another paper Gateway startup is already in progress.' }
        Invoke-IsolatedPaperGatewayStartup -ProjectDirectory $ProjectDirectory -TimeoutSeconds $TimeoutSeconds -PrepareOnly:$PrepareOnly
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
