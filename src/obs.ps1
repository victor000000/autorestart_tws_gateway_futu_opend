# OBS recording helpers.
# OBS is the authority on its own recording state: these helpers read OBS's log
# instead of guessing from a process or a window. Nothing here sends desktop
# input; recording is requested only through OBS's own --startrecording switch.

function Get-ObsConfigurationDirectory {
    return (Join-Path $env:APPDATA 'obs-studio')
}

function Get-ObsLogFiles {
    # OBS writes one log file per run under %APPDATA%\obs-studio\logs.
    $directory = Join-Path (Get-ObsConfigurationDirectory) 'logs'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Filter '*.txt' -File -ErrorAction Stop)
}

function Read-ObsLogLines {
    <#
    Reads an OBS log while OBS itself holds it open for writing. A plain
    File.ReadAllLines requests a read-only share and is refused by OBS's handle,
    so the stream is opened sharing read and write.
    #>
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $stream = New-Object IO.FileStream($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        return @($reader.ReadToEnd() -split "`r?`n")
    }
    finally { $reader.Dispose() }
}

function Get-ObsRecordingState {
    <#
    Folds one OBS log in order. OBS writes '==== Recording Start/Stop' markers
    and the exact output path, so the last marker decides whether the session is
    recording now. A failure line is surfaced so a launch that did not record
    cannot be reported as healthy.
    #>
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $state = [pscustomobject]@{
        Recording  = $false
        OutputFile = $null
        Failure    = $null
        LogPath    = $LogPath
    }
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $state }
    foreach ($line in (Read-ObsLogLines -LogPath $LogPath)) {
        if ($line -match '==== Recording Start') {
            $state.Recording = $true
            $state.OutputFile = $null
            $state.Failure = $null
        }
        elseif ($line -match '==== Recording Stop') {
            $state.Recording = $false
        }
        elseif ($line -match "Writing .+ file '([^']+)'") {
            $state.OutputFile = $Matches[1]
        }
        elseif ($line -match 'Failed to start recording|Could not start recording|Recording failed') {
            $state.Recording = $false
            $state.Failure = $line
        }
    }
    return $state
}

function Wait-ObsRecordingStart {
    <#
    Waits for the log written by the OBS process started at $Since to report a
    recording start. Log files that already existed before the launch are
    ignored, so an earlier session is never mistaken for this one.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExistingLogPaths,
        [Parameter(Mandatory = $true)][datetime]$Since,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $logs = @(Get-ObsLogFiles | Where-Object {
                ($ExistingLogPaths -notcontains $_.FullName) -and ($_.LastWriteTime -ge $Since.AddSeconds(-2))
            } | Sort-Object LastWriteTime -Descending)
        foreach ($log in $logs) {
            $state = Get-ObsRecordingState -LogPath $log.FullName
            if ($state.Failure) { throw "OBS reported a recording failure: $($state.Failure)" }
            if ($state.Recording -and $state.OutputFile) { return $state }
        }
        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)
    return $null
}
