# Import-safe shared helpers. Runtime directories are created only when used.
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $ProjectRoot 'logs'
$FutuExe = Join-Path $env:APPDATA 'Futu_OpenD\Futu_OpenD.exe'
$IbGatewayDir = 'C:\Jts\ibgateway\1051'
$IbGatewayExe = Join-Path $IbGatewayDir 'ibgateway.exe'

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$LogName = 'autostart'
    )
    $directory = Join-Path $ProjectRoot 'logs'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $path = Join-Path $directory "$LogName.log"
    # Parallel startup workers append to the same file; retry transient sharing violations.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host $line
}

function Test-PortListening {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [string]$ComputerName = '127.0.0.1',
        [ValidateRange(1, 60000)][int]$TimeoutMs = 2000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Test-IbGatewayLoggedIn {
    param(
        [Parameter(Mandatory = $true)][datetime]$Since,
        [string]$LogPath
    )
    if (-not $LogPath) { $LogPath = Join-Path $IbGatewayDir 'launcher.log' }
    $path = $LogPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    # Explicit disposal is required even when authentication is found before EOF.
    $reader = [IO.File]::OpenText($path)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+\s+INFO\s+.*Authentication completed') {
                $stamp = [datetime]::MinValue
                if ([datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss',
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref]$stamp) -and $stamp -ge $Since.AddSeconds(-5)) {
                    return $true
                }
            }
        }
        return $false
    }
    finally { $reader.Dispose() }
}

. (Join-Path $PSScriptRoot 'credentials.ps1')
. (Join-Path $PSScriptRoot 'process-runner.ps1')
