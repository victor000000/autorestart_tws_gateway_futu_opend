BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepositoryRoot 'src/common.ps1')
    # Exclude only dependency imports; every external boundary below is faked.
    $text = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'scripts/apps/start-ibgateway.ps1'))
    $script:GatewayText = $text -replace '(?m)^\. \(Join-Path[^\r\n]+\r?\n', ''
    function Ensure-GatewayWindowHidden { param([int]$ProcessId) throw 'Real desktop access forbidden' }
}

Describe 'Gateway readiness controller with fully fake boundaries' {
    BeforeEach {
        $rootLiteral = "'" + $TestDrive.Replace("'", "''") + "'"
        $script:Gateway = [scriptblock]::Create($GatewayText.Replace('$ProjectRoot', $rootLiteral))
        $IbGatewayDir = Join-Path $TestDrive 'gateway'
        Mock Write-AppLog {}
        Mock Get-Process { @() }
        Mock Get-IbcGatewayProcesses { @() }
        Mock Get-CimInstance { @() }
        Mock Test-GatewayApiReady { $false }
        Mock New-IbcConfig { throw 'Credential access forbidden in tests' }
        Mock Get-DirectIbExecutable { throw 'No installed app access in tests' }
        Mock Start-Process { throw 'No real process launches in tests' }
        Mock Start-ProjectScript {}
        Mock Ensure-GatewayWindowHidden {}
        Mock Start-Sleep {}
        $script:Tick = 0
        Mock Get-Date { $script:Tick++; ([datetime]'2026-01-01').AddSeconds(10 * $script:Tick) }
    }
    It 'supplies executable extensions to IBC and restores the caller environment' {
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ibc') -Force
        Set-Content -LiteralPath (Join-Path $TestDrive 'ibc/StartGateway.bat') -Value 'rem synthetic fixture'
        Mock New-IbcConfig { $true }
        Mock Test-GatewayApiReady { $true }
        Mock Start-Process {
            ($env:PATHEXT -split ';') | Should -Contain '.EXE'
            ($env:PATHEXT -split ';') | Should -Contain '.BAT'
            ($env:PATHEXT -split ';') | Should -Contain '.CMD'
            ($env:PATHEXT -split ';') | Should -Contain '.CPL'
        }
        $original = $env:PATHEXT
        try {
            $env:PATHEXT = '.CPL'
            & $Gateway -TimeoutSeconds 1
            $env:PATHEXT | Should -BeExactly '.CPL'
            Should -Invoke Start-Process -Times 1
        }
        finally { $env:PATHEXT = $original }
    }
    It 'paper startup keeps the live batch unchanged and uses a separate configuration' {
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ibc') -Force
        $live = Join-Path $TestDrive 'ibc/StartGateway.bat'
        $original = "set CONFIG=C:\synthetic\live.ini`r`nset TRADING_MODE=live`r`n"
        [IO.File]::WriteAllText($live, $original)
        Mock New-IbcConfig { $true }
        Mock Test-GatewayApiReady { $true }
        Mock Start-Process {}
        & $Gateway -Paper -TimeoutSeconds 1
        [IO.File]::ReadAllText($live) | Should -BeExactly $original
        [IO.File]::ReadAllText((Join-Path $TestDrive 'ibc/StartPaperGateway.bat')) | Should -Match 'TRADING_MODE=paper'
        Should -Invoke New-IbcConfig -Times 1 -ParameterFilter { $TradingMode -eq 'paper' -and $Path -like '*ibc-paper-config.ini' }
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like '*StartPaperGateway.bat' }
    }
    It 'does not hide a running gateway whose login is incomplete' {
        Mock Get-IbcGatewayProcesses { [pscustomobject]@{ProcessId=100} }
        { & $Gateway -TimeoutSeconds 1 } | Should -Throw '*not ready*'
        Should -Invoke Ensure-GatewayWindowHidden -Times 0
        Should -Invoke Start-Process -Times 0
        Should -Invoke Start-ProjectScript -Times 0
    }
    It 'hides only after owned-listener readiness and starts the tray worker' {
        Mock Get-IbcGatewayProcesses { [pscustomobject]@{ProcessId=100} }
        Mock Test-GatewayApiReady { $true }
        & $Gateway -TimeoutSeconds 1
        Should -Invoke Ensure-GatewayWindowHidden -Times 1 -ParameterFilter { $ProcessId -eq 100 }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'gateway-tray.ps1' }
        Should -Invoke New-IbcConfig -Times 0
    }
    It 'recognizes an existing tray worker with a quoted File argument' {
        Mock Get-IbcGatewayProcesses { [pscustomobject]@{ProcessId=100} }
        Mock Test-GatewayApiReady { $true }
        Mock Get-CimInstance {
            [pscustomobject]@{CommandLine=('powershell.exe "-File" "' + (Join-Path $TestDrive 'gateway-tray.ps1') + '"')}
        }
        & $Gateway -TimeoutSeconds 1
        Should -Invoke Start-ProjectScript -Times 0
    }
    It 'does not launch IBC after config publication throws' {
        $directory = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ibc') -Force
        Set-Content -LiteralPath (Join-Path $directory.FullName 'StartGateway.bat') -Value 'synthetic file; never executed'
        { & $Gateway -TimeoutSeconds 1 } | Should -Throw '*Credential access forbidden*'
        Should -Invoke Start-Process -Times 0
    }
    It 'uses the direct renamed launcher only when explicitly requested' {
        Mock Get-DirectIbExecutable { 'C:\synthetic\ibgateway1.exe' }
        Mock Start-Process {}
        Mock Test-GatewayApiReady { $true }
        & $Gateway -TimeoutSeconds 1 -UseDirectExe
        Should -Invoke Get-DirectIbExecutable -Times 1 -ParameterFilter { $Name -eq 'ibgateway' }
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'C:\synthetic\ibgateway1.exe' }
    }
}

Describe 'Synthetic launcher log parsing' {
    BeforeEach {
        $script:LogFixtureDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        if (-not $LogFixtureDir.StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped TestDrive' }
        $null = New-Item -ItemType Directory -Path $LogFixtureDir -ErrorAction Stop
    }
    It 'finds authentication even after more than 500 later lines' {
        $lines = @('2026-01-01 12:00:00.100 INFO [thread] - Authentication completed') + @(1..600 | ForEach-Object { 'unrelated line' })
        Set-Content -LiteralPath (Join-Path $LogFixtureDir 'launcher.log') -Value $lines
        Test-IbGatewayLoggedIn -LogPath (Join-Path $LogFixtureDir 'launcher.log') -Since ([datetime]'2026-01-01 12:00:00') | Should -BeTrue
    }
    It 'ignores stale and malformed authentication timestamps' {
        Set-Content -LiteralPath (Join-Path $LogFixtureDir 'launcher.log') -Value @(
            '2020-01-01 12:00:00.100 INFO [thread] - Authentication completed'
            '2026-99-99 12:00:00.100 INFO [thread] - Authentication completed'
        )
        Test-IbGatewayLoggedIn -LogPath (Join-Path $LogFixtureDir 'launcher.log') -Since ([datetime]'2026-01-01 12:00:00') | Should -BeFalse
    }
}
