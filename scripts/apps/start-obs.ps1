# Starts OBS and begins recording by default; installation defaults are in config/apps.psd1.
# Recording uses OBS's own --startrecording switch, so no desktop input is sent.
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    # Starts OBS without recording; the workspace then records only if it already is.
    [switch]$NoRecord
)

$sourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $sourceRoot 'src/common.ps1')
. (Join-Path $sourceRoot 'src/obs.ps1')

$startedAt = Get-Date
$existingLogs = @(Get-ObsLogFiles | ForEach-Object { $_.FullName })
$launchArguments = @()
if (-not $NoRecord) { $launchArguments = @('--startrecording') }

$started = Start-ConfiguredApplication -Name 'obs' -TimeoutSeconds $TimeoutSeconds -Arguments $launchArguments -PassThru
if ($NoRecord) { return }

if ($started) {
    $state = Wait-ObsRecordingStart -ExistingLogPaths $existingLogs -Since $startedAt -TimeoutSeconds $TimeoutSeconds
    if (-not $state) {
        throw 'OBS started but recording did not begin. Check the OBS output settings and the OBS log.'
    }
    Write-AppLog "OBS recording started: $($state.OutputFile)" 'apps'
    return
}

# An already-running OBS cannot be told to record from its command line, so
# report what it is actually doing instead of claiming a start that did not happen.
$log = Get-ObsLogFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) {
    throw 'OBS is already running; its log is unavailable and recording cannot be verified.'
}
$state = Get-ObsRecordingState -LogPath $log.FullName
if ($state.Recording -and $state.OutputFile -and -not $state.Failure) {
    Write-AppLog "OBS is already running and recording: $($state.OutputFile)" 'apps'
    return
}
throw 'OBS is already running but not recording. Start recording in OBS, or close OBS and rerun start-obs.ps1.'
