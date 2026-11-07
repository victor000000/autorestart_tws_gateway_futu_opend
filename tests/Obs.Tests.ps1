# Pester 5; imports ONLY function ASTs, never production script bodies.
# OBS is never launched and the real %APPDATA%\obs-studio is never read.
BeforeAll {
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
    foreach ($file in @('src/obs.ps1', 'src/process-runner.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ProjectRoot $file), [ref]$tokens, [ref]$errors)
        if ($errors) { throw ($errors | Out-String) }
        foreach ($definition in $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    $script:OriginalAppData = $env:APPDATA
    $script:StarterAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:ProjectRoot 'scripts/apps/start-obs.ps1'), [ref]$null, [ref]$null)
    # Fail-closed stub: production logging writes to the real file system.
    function Write-AppLog { param($Message, $LogName) }
}

AfterAll {
    $env:APPDATA = $script:OriginalAppData
}

Describe 'OBS recording state read from the OBS log' {
    BeforeEach {
        $env:APPDATA = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) -Force).FullName
        $script:LogDirectory = Join-Path $env:APPDATA 'obs-studio/logs'
        New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        $script:LogPath = Join-Path $script:LogDirectory '2026-10-27 08-47-23.txt'
    }

    It 'reports an active recording with the exact output file' {
        @(
            '08:47:23.337: ==== Startup complete ==============================================='
            '08:55:19.255: ==== Recording Start ==============================================='
            "08:55:19.255: [mp4 output: 'simple_file_output'] Writing Hybrid MP4/MOV file 'C:/Users/example/Videos/2026-10-27 08-55-19.mp4'..."
        ) | Set-Content -LiteralPath $script:LogPath -Encoding UTF8

        $state = Get-ObsRecordingState -LogPath $script:LogPath

        $state.Recording | Should -BeTrue
        $state.OutputFile | Should -BeExactly 'C:/Users/example/Videos/2026-10-27 08-55-19.mp4'
    }

    It 'reads the log while OBS keeps it open for writing' {
        @(
            '09:00:02.000: ==== Recording Start ==============================================='
            "09:00:02.000: [mp4 output: 'simple_file_output'] Writing Hybrid MP4/MOV file 'C:/Users/example/Videos/live.mp4'..."
        ) | Set-Content -LiteralPath $script:LogPath -Encoding UTF8
        # OBS holds its live log open with write access; a read-only share is refused.
        $handle = [IO.File]::Open($script:LogPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            $state = Get-ObsRecordingState -LogPath $script:LogPath

            $state.Recording | Should -BeTrue
            $state.OutputFile | Should -BeExactly 'C:/Users/example/Videos/live.mp4'
        }
        finally { $handle.Dispose() }
    }

    It 'reports a stopped recording after the stop marker' {
        @(
            '08:55:19.255: ==== Recording Start ==============================================='
            "08:55:19.255: [mp4 output: 'simple_file_output'] Writing Hybrid MP4/MOV file 'C:/Users/example/Videos/2026-10-27 08-55-19.mp4'..."
            '21:59:36.444: Stopping recording due to hotkey'
            '21:59:37.158: ==== Recording Stop ================================================'
        ) | Set-Content -LiteralPath $script:LogPath -Encoding UTF8

        $state = Get-ObsRecordingState -LogPath $script:LogPath

        $state.Recording | Should -BeFalse
    }

    It 'surfaces a recording failure instead of looking healthy' {
        '09:00:01.000: Failed to start recording: encoder unavailable' |
            Set-Content -LiteralPath $script:LogPath -Encoding UTF8

        $state = Get-ObsRecordingState -LogPath $script:LogPath

        $state.Recording | Should -BeFalse
        $state.Failure | Should -Match 'Failed to start recording'
    }

    It 'treats a missing log as not recording rather than an error' {
        $state = Get-ObsRecordingState -LogPath (Join-Path $TestDrive 'absent.txt')

        $state.Recording | Should -BeFalse
        $state.OutputFile | Should -BeNullOrEmpty
    }

    It 'reads only the log created by the new OBS process' {
        $previous = Join-Path $script:LogDirectory '2026-10-26 20-54-55.txt'
        @(
            '21:08:01.169: ==== Recording Start ==============================================='
            "21:08:01.169: [mp4 output: 'simple_file_output'] Writing Hybrid MP4/MOV file 'C:/Users/example/Videos/old.mp4'..."
        ) | Set-Content -LiteralPath $previous -Encoding UTF8
        (Get-Item -LiteralPath $previous).LastWriteTime = (Get-Date).AddHours(-12)
        @(
            '09:00:02.000: ==== Recording Start ==============================================='
            "09:00:02.000: [mp4 output: 'simple_file_output'] Writing Hybrid MP4/MOV file 'C:/Users/example/Videos/new.mp4'..."
        ) | Set-Content -LiteralPath $script:LogPath -Encoding UTF8

        $state = Wait-ObsRecordingStart -ExistingLogPaths @($previous) -Since (Get-Date).AddSeconds(-30) -TimeoutSeconds 5

        $state.OutputFile | Should -BeExactly 'C:/Users/example/Videos/new.mp4'
    }

    It 'gives up instead of returning a stale recording' {
        $script:Clock = [datetime]'2026-10-27 09:00:00'
        Mock Get-Date { $script:Clock }
        Mock Start-Sleep { $script:Clock = $script:Clock.AddSeconds(30) }

        $state = Wait-ObsRecordingStart -ExistingLogPaths @() -Since $script:Clock -TimeoutSeconds 20

        $state | Should -BeNullOrEmpty
    }
}

Describe 'OBS launch arguments reach the application' {
    It 'forwards the recording switch to a new OBS launch' {
        Mock Import-PowerShellDataFile {
            @{ obs = @{ ProcessName = 'obs64'; Executable = 'C:\fake\obs64.exe' } }
        }
        Mock Get-Process { $null }
        Mock Start-ManagedApplication {
            param($Name, $Executable, $WorkingDirectory, $Arguments, $TimeoutSeconds)
            $script:CapturedArguments = $Arguments
        }
        $ProjectRoot = $TestDrive

        $launched = Start-ConfiguredApplication -Name 'obs' -Arguments @('--startrecording') -PassThru

        $launched | Should -BeTrue
        $script:CapturedArguments | Should -Be @('--startrecording')
    }

    It 'does not launch or pass switches to an already-running OBS' {
        Mock Import-PowerShellDataFile {
            @{ obs = @{ ProcessName = 'obs64'; Executable = 'C:\fake\obs64.exe' } }
        }
        Mock Get-Process { [pscustomobject]@{ Id = 100; ProcessName = 'obs64' } }
        Mock Start-ManagedApplication { throw 'Must not launch an existing application.' }
        $ProjectRoot = $TestDrive

        $launched = Start-ConfiguredApplication -Name 'obs' -Arguments @('--startrecording') -PassThru

        $launched | Should -BeFalse
        Assert-MockCalled Start-ManagedApplication -Scope It -Times 0 -Exactly
    }
}

Describe 'OBS starter contract' {
    It 'offers -NoRecord and requests --startrecording by default' {
        $parameters = @($script:StarterAst.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameters | Should -Contain 'TimeoutSeconds'
        $parameters | Should -Contain 'NoRecord'
        $literals = @($script:StarterAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { $_.Value })
        $literals | Should -Contain '--startrecording'
    }
}

Describe 'Existing OBS recording verification fails closed' {
    BeforeAll {
        # Execute only the existing-process verification branch; no starter body.
        $source = [IO.File]::ReadAllText((Join-Path $script:ProjectRoot 'scripts/apps/start-obs.ps1'))
        $offset = $source.IndexOf('# An already-running OBS')
        if ($offset -lt 0) { throw 'Missing isolated verification branch' }
        $script:VerifyExistingObs = [scriptblock]::Create($source.Substring($offset))
    }
    BeforeEach {
        Mock Write-AppLog {}
        Mock Get-ObsLogFiles { [pscustomobject]@{ FullName = 'synthetic.txt'; LastWriteTime = Get-Date } }
        Mock Get-ObsRecordingState { [pscustomobject]@{ Recording = $true; OutputFile = 'test.mp4'; Failure = $null } }
    }
    It 'rejects an unavailable log rather than succeeding with unknown recording' {
        Mock Get-ObsLogFiles { @() }
        { & $script:VerifyExistingObs } | Should -Throw '*cannot be verified*'
        Should -Invoke Write-AppLog -Times 0 -Exactly
    }
    It 'rejects a start marker without an output file' {
        Mock Get-ObsRecordingState { [pscustomobject]@{ Recording = $true; OutputFile = $null; Failure = $null } }
        { & $script:VerifyExistingObs } | Should -Throw
    }
    It 'rejects recording failure even after a start marker' {
        Mock Get-ObsRecordingState { [pscustomobject]@{ Recording = $true; OutputFile = 'test.mp4'; Failure = 'Recording failed' } }
        { & $script:VerifyExistingObs } | Should -Throw
    }
    It 'reports success only with a recording and an output file' {
        & $script:VerifyExistingObs
        Should -Invoke Write-AppLog -Times 1 -Exactly -ParameterFilter { $Message -like '*already running and recording*' }
    }
}

Describe 'OBS failure and recovery ordering' {
    It 'invalidates a previously started recording on failure and recovers only on a new start' {
        $path = Join-Path $TestDrive 'recording.txt'
        @('==== Recording Start', "Writing MP4 file 'old.mp4'", 'Recording failed') |
            Set-Content -LiteralPath $path -Encoding UTF8
        $state = Get-ObsRecordingState -LogPath $path
        $state.Recording | Should -BeFalse
        $state.Failure | Should -Not -BeNullOrEmpty
        @('==== Recording Start', "Writing MP4 file 'new.mp4'") | Add-Content -LiteralPath $path -Encoding UTF8
        $state = Get-ObsRecordingState -LogPath $path
        $state.Recording | Should -BeTrue
        $state.Failure | Should -BeNullOrEmpty
        $state.OutputFile | Should -Be 'new.mp4'
    }
}
