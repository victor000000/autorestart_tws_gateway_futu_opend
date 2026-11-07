function Start-ConfiguredApplication {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 60,
        # Launch switches an application needs from its first moment (for
        # example OBS --startrecording); ignored when the app is already running.
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        # PassThru reports whether this call launched the app (true) or reused
        # an existing process (false), so starters log in only after a launch.
        [switch]$PassThru
    )
    $definitions = Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'config/apps.psd1')
    if (-not $definitions.ContainsKey($Name)) { throw "Unknown application: $Name" }
    $definition = $definitions[$Name]
    if (Get-Process -Name $definition.ProcessName -ErrorAction SilentlyContinue) {
        Write-AppLog "$Name is already running." 'apps'
        if ($PassThru) { return $false }
        return
    }
    if ($definition.Directory) {
        $directory = [Environment]::ExpandEnvironmentVariables($definition.Directory)
        $executable = Get-LatestAppExecutable -Directory $directory -FileName $definition.FileName -Manifest $definition.Manifest
        if (-not $executable) { throw "No installed executable found for $Name." }
    }
    else { $executable = [Environment]::ExpandEnvironmentVariables($definition.Executable) }
    Start-ManagedApplication -Name $definition.ProcessName -Executable $executable -TimeoutSeconds $TimeoutSeconds -Arguments $Arguments
    if ($PassThru) { return $true }
}

function Get-LatestWorkbook {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Directory -Filter '*.xlsx' -File -ErrorAction Stop |
        Where-Object { $_.Name -notlike '~$*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-PowerShellExecutable {
    $path = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is required to launch applications.' }
    return $path
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Contains([char]0) -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw 'Native arguments cannot contain NUL or newlines.'
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-ProjectScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyCollection()][string[]]$ScriptArguments = @(),
        [switch]$PassThru
    )
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'config/entrypoints.psd1')
    if (-not $manifest.ContainsKey($Name) -or $manifest[$Name] -like 'src/*') { throw "Unknown command: $Name" }
    $path = Join-Path $ProjectRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing entry point: $Name" }
    # A $null argument list binds as a single empty string; forwarding that would
    # reach the child as an empty positional value and fail parameter validation.
    $extraArguments = @($ScriptArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $path) + $extraArguments
    $commandLine = ($arguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' '
    $process = Start-Process -FilePath (Get-PowerShellExecutable) -ArgumentList $commandLine `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -ErrorAction Stop
    if ($PassThru) { return $process }
}

function Get-AppLoginDefinition {
    param([Parameter(Mandatory = $true)][string]$Entry)
    $definitions = Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'config/logins.psd1')
    if ($definitions.starters.ContainsKey($Entry)) { return $definitions.starters[$Entry] }
    return $null
}

function Get-LoginSuppression {
    # A group that dispatches a login worker already covering this application
    # tells the individual starter not to run its own worker.
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [AllowEmptyCollection()][string[]]$GroupEntries = @()
    )
    $definition = Get-AppLoginDefinition -Entry $Entry
    # The unary comma keeps an empty array from collapsing into $null, which
    # would bind as one empty string in Start-ProjectScript's argument list.
    if (-not $definition) { return ,@() }
    foreach ($worker in @($definition.CoveredBy)) {
        if ($GroupEntries -contains $worker) { return ,@('-NoLogin') }
    }
    return ,@()
}

function Invoke-AppLogin {
    # Individual starters log in by default; groups that already run a covering
    # login worker pass -NoLogin to their starters instead.
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )
    $definition = Get-AppLoginDefinition -Entry $Entry
    if (-not $definition) { return }
    Write-AppLog "Starting $($definition.Worker) after $Entry (auto-login default)." 'apps'
    $worker = Start-ProjectScript -Name $definition.Worker -ScriptArguments @($definition.ScriptArguments) -PassThru
    Wait-ProjectProcesses -Processes @($worker) -TimeoutSeconds $TimeoutSeconds
}

function Wait-ProjectProcesses {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $failures = @()
    foreach ($process in $Processes) {
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $process.WaitForExit($remaining)) { throw 'Startup workers did not finish before the deadline; manual authentication may be required.' }
        $process.Refresh()
        if ($process.ExitCode -ne 0) { $failures += $process.Id }
    }
    if ($failures.Count -gt 0) { throw "Startup workers failed (PIDs: $($failures -join ', ')). See private local logs." }
}

function Invoke-AppGroup {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('cn', 'us', 'maintenance', 'extra', 'all')][string]$Name,
        [switch]$Wait,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )
    $definitions = Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'config/groups.psd1')
    $children = @()
    Write-AppLog "=== $Name group starting ===" 'apps'
    $entries = @($definitions[$Name])
    foreach ($entry in $entries) {
        $scriptArguments = Get-LoginSuppression -Entry $entry -GroupEntries $entries
        $children += Start-ProjectScript -Name $entry -ScriptArguments $scriptArguments -PassThru
        Start-Sleep -Milliseconds 800
    }
    Write-AppLog "=== $Name group dispatched ($($children.Count) workers) ===" 'apps'
    if ($Wait) {
        Wait-ProjectProcesses -Processes $children -TimeoutSeconds $TimeoutSeconds
        Write-AppLog "=== $Name group workers finished ===" 'apps'
    }
}

function Get-IbcProcesses {
    param([ValidateSet('Gateway', 'Tws')][string]$Application = 'Gateway')
    $marker = '(?i)(?:^|\s)ibcalpha\.ibc\.Ibc' + $Application + '(?:\s|$)'
    return @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match $marker })
}

function Get-IbcGatewayProcesses {
    param([string]$ConfigPath)
    $processes = @(Get-IbcProcesses -Application Gateway)
    if (-not $ConfigPath) { return $processes }
    # IBC receives its config filename as a complete command-line argument.
    $pattern = '(?i)(?:^|\s)"?' + [regex]::Escape([IO.Path]::GetFullPath($ConfigPath)) + '"?(?:\s|$)'
    return @($processes | Where-Object { $_.CommandLine -match $pattern })
}

function Test-ProcessPortOwner {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ProcessIds
    )
    if ($ProcessIds.Count -eq 0) { return $false }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
        if (-not ($listeners | Where-Object { $ProcessIds -contains [int]$_.OwningProcess })) { return $false }
        return (Test-PortListening -Port $Port)
    }
    catch { return $false }
}

function Test-GatewayApiReady {
    param([string]$ConfigPath)
    $identities = @(Get-IbcGatewayProcesses -ConfigPath $ConfigPath | ForEach-Object { [int]$_.ProcessId })
    $identities += @(Get-Process -Name 'ibgateway', 'ibgateway1' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    return (Test-ProcessPortOwner -Port 4001 -ProcessIds $identities)
}

function Get-DirectIbExecutable {
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string]$Name)
    foreach ($file in @("$Name.exe", "${Name}1.exe")) {
        $path = Join-Path $Directory $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    throw "No direct $Name launcher was found in $Directory."
}

function Get-ManifestBuildExecutable {
    # Version-directory installs that stage the next build (Shinny/KuaiQi) put an
    # unsigned upgrade stub in that directory, so the newest directory is not
    # necessarily the installed client. The launcher manifest names the active
    # build; only that build is eligible here.
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Manifest
    )
    $manifestPath = Join-Path $Directory $Manifest
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
        $document = [xml]$text
    }
    catch { return $null }
    $current = [string]$document.root.current
    # The manifest value is vendor data: accept a plain directory name only.
    if (-not $current -or $current -match '[\\/:]|\.\.') { return $null }
    $candidate = Join-Path (Join-Path $Directory $current) $FileName
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    return $candidate
}

function Get-LatestAppExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        # Supplied only by installs whose newest directory can hold a staged
        # update instead of the active build.
        [string]$Manifest
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    if ($Manifest) {
        $installed = Get-ManifestBuildExecutable -Directory $Directory -FileName $FileName -Manifest $Manifest
        if ($installed) { return $installed }
    }
    $candidates = foreach ($folder in (Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction Stop)) {
        $path = Join-Path $folder.FullName $FileName
        if ($folder.Name -match '^\d+(?:\.\d+)*$' -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            # Numeric components also handle timestamp-named Shinny versions without Int32 overflow.
            $key = (($folder.Name -split '\.') | ForEach-Object { $_.PadLeft(24, '0') }) -join '.'
            [pscustomobject]@{ Path = $path; SortKey = $key }
        }
    }
    return ($candidates | Sort-Object SortKey -Descending | Select-Object -First 1).Path
}

function Wait-AppProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $process = Get-Process -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process) { return $process }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "The $Name process was not detected within $TimeoutSeconds seconds."
}

function Get-IbSessionProcesses {
    # TWS and IB Gateway hold the same IBKR login as IBKR Desktop, and IBKR
    # rejects a second trading-application login for one username. Returns the
    # direct launchers plus the IBC-managed Java process hosting a session.
    $names = @('tws', 'tws1', 'ibgateway', 'ibgateway1')
    $ibcIds = @()
    foreach ($application in @('Tws', 'Gateway')) {
        $ibcIds += @(Get-IbcProcesses -Application $application | ForEach-Object { [int]$_.ProcessId })
    }
    $sessions = @()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if (($names -notcontains $process.ProcessName) -and ($ibcIds -notcontains $process.Id)) { continue }
        $sessions += $process
    }
    return $sessions
}

function Test-IbSessionRunning {
    param([Parameter(Mandatory = $true)]$Process)
    try { return (-not $Process.HasExited) }
    catch { return $false }
}

function Stop-IbProcessSet {
    # Graceful close, bounded wait, then force. Returns the survivors so the
    # caller can fail instead of reporting a stop that did not happen.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Targets,
        [ValidateRange(1, 120)][int]$GraceSeconds = 20
    )
    foreach ($target in $Targets) {
        if (-not (Test-IbSessionRunning $target)) { continue }
        try { $null = $target.CloseMainWindow() } catch { }
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline -and @($Targets | Where-Object { Test-IbSessionRunning $_ }).Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
    $survivors = @($Targets | Where-Object { Test-IbSessionRunning $_ })
    foreach ($target in $survivors) {
        Write-AppLog "Forcing $($target.ProcessName) (PID $($target.Id)) to stop." 'apps'
        try { $target.Kill() } catch { }
    }
    foreach ($target in $survivors) {
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and (Test-IbSessionRunning $target)) {
            Start-Sleep -Milliseconds 100
        }
    }
    return @($survivors | Where-Object { Test-IbSessionRunning $_ })
}

function Stop-IbSessionProcesses {
    <#
    Signs TWS / IB Gateway out before IBKR Desktop starts: one IBKR login cannot
    serve both, so the desktop login would otherwise displace or fail.
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 120)][int]$GraceSeconds = 20)

    $targets = @(Get-IbSessionProcesses)
    if ($targets.Count -eq 0) {
        Write-AppLog 'No TWS / IB Gateway session is running.' 'apps'
        return
    }
    $labels = @($targets | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" })
    Write-AppLog ("Stopping the TWS / IB Gateway session first: " + ($labels -join ', ') + '.') 'apps'
    $remaining = @(Stop-IbProcessSet -Targets $targets -GraceSeconds $GraceSeconds)
    if ($remaining.Count -gt 0) {
        $pids = @($remaining | ForEach-Object { $_.Id })
        throw "Could not stop TWS / IB Gateway (PID(s): $($pids -join ', '))."
    }
    Write-AppLog 'TWS / IB Gateway stopped; the IBKR login is free for IBKR Desktop.' 'apps'
}

function Get-IbkrDesktopProcesses {
    # IBKR Desktop uses the same IBKR login as TWS / IB Gateway.
    return @(Get-Process -Name 'ntws' -ErrorAction SilentlyContinue)
}

function Stop-IbkrDesktopProcesses {
    # Signs IBKR Desktop out before TWS starts, mirroring Stop-IbSessionProcesses.
    [CmdletBinding()]
    param([ValidateRange(1, 120)][int]$GraceSeconds = 20)

    $targets = @(Get-IbkrDesktopProcesses)
    if ($targets.Count -eq 0) {
        Write-AppLog 'IBKR Desktop is not running.' 'apps'
        return
    }
    $labels = @($targets | ForEach-Object { "PID $($_.Id)" })
    Write-AppLog ("Stopping IBKR Desktop first (" + ($labels -join ', ') + '): it holds the same IBKR login as TWS.') 'apps'
    $remaining = @(Stop-IbProcessSet -Targets $targets -GraceSeconds $GraceSeconds)
    if ($remaining.Count -gt 0) {
        $pids = @($remaining | ForEach-Object { $_.Id })
        throw "Could not stop IBKR Desktop (PID(s): $($pids -join ', '))."
    }
    Write-AppLog 'IBKR Desktop stopped; the IBKR login is free for Trader Workstation.' 'apps'
}

function Start-ManagedApplication {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$WorkingDirectory,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )
    if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
        Write-AppLog "$Name is already running." 'apps'
        return
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Executable not found: $Executable" }
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Executable }
    $parameters = @{ FilePath = $Executable; WorkingDirectory = $WorkingDirectory; ErrorAction = 'Stop' }
    if ($Arguments.Count -gt 0) {
        $parameters.ArgumentList = ($Arguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' '
    }
    Write-AppLog "Starting $Name..." 'apps'
    Start-Process @parameters | Out-Null
    $null = Wait-AppProcess -Name $Name -TimeoutSeconds $TimeoutSeconds
    Write-AppLog "$Name process detected (authentication may still require manual action)." 'apps'
}

function Assert-NoIbLaunchConflict {
    # Starting one client never authorizes stopping another trading session.
    param([Parameter(Mandatory = $true)][ValidateSet('Tws', 'Desktop')][string]$Application)
    $conflicts = if ($Application -eq 'Tws') { @(Get-IbkrDesktopProcesses) } else { @(Get-IbSessionProcesses) }
    if (@($conflicts).Count -gt 0) {
        throw "Cannot start $Application while a conflicting IBKR client is running. Existing clients were preserved; explicitly stop the conflicting client before starting this one."
    }
}
