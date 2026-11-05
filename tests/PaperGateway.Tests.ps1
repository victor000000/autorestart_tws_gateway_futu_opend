BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepositoryRoot 'src/common.ps1')
}

Describe 'Exact dedicated IBC process selection' {
    It 'rejects live, similarly named configs and partial argument matches' {
        $path = Join-Path $TestDrive 'paper.ini'
        Mock Get-IbcProcesses {
            @(
                [pscustomobject]@{ ProcessId=1; CommandLine=('java ibcalpha.ibc.IbcGateway "' + $path + '" paper') },
                [pscustomobject]@{ ProcessId=2; CommandLine=('java ibcalpha.ibc.IbcGateway "' + $path + '.backup" live') },
                [pscustomobject]@{ ProcessId=3; CommandLine='java ibcalpha.ibc.IbcGateway live.ini live' }
            )
        }
        $selected = @(Get-IbcGatewayProcesses -ConfigPath $path)
        $selected.Count | Should -Be 1
        $selected[0].ProcessId | Should -Be 1
    }
}

Describe 'Paper startup with fake host and credentials' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive 'project'
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'ibc') -Force
        $script:LiveBatch = Join-Path $Root 'ibc/StartGateway.bat'
        $script:LiveText = "set CONFIG=C:\synthetic\live.ini`r`nset TRADING_MODE=live`r`nset TWS_SETTINGS_PATH=C:\synthetic\live-settings`r`nset LOG_PATH=C:\synthetic\live-logs`r`nset TWSUSERID=`r`nset TWSPASSWORD=`r`n"
        [IO.File]::WriteAllText($LiveBatch, $LiveText)
        Mock Get-IbcGatewayProcesses { @() }
        Mock Get-NetTCPConnection { @() }
        Mock New-IbcConfig { $true }
        Mock Start-Process {}
        Mock Test-ProcessPortOwner { $false }
        Mock Write-AppLog {}
        Mock Start-Sleep {}
        $script:Tick = 0
        Mock Get-Date { $script:Tick++; ([datetime]'2026-01-01').AddSeconds(10 * $script:Tick) }
    }
    It 'prepares isolated paths without launching or probing a broker' {
        Start-IsolatedPaperGateway -ProjectDirectory $Root -PrepareOnly
        [IO.File]::ReadAllText($LiveBatch) | Should -BeExactly $LiveText
        $batch = [IO.File]::ReadAllText((Join-Path $Root 'ibc/StartPaperGateway.bat'))
        $batch | Should -Match 'TRADING_MODE=paper'
        $batch | Should -Match 'TWS_SETTINGS_PATH=.*settings-paper'
        $batch | Should -Match 'LOG_PATH=.*ibc-paper'
        $batch | Should -Not -Match 'live-settings|live-logs|live.ini'
        Should -Invoke New-IbcConfig -Times 1 -ParameterFilter {
            $TradingMode -eq 'paper' -and $Path -like '*ibc-paper-config.ini' -and $SettingsPath -like '*settings-paper'
        }
        Should -Invoke Start-Process -Times 0
        Should -Invoke Test-ProcessPortOwner -Times 0
    }
    It 'launches paper alongside live and tests only paper process IDs on 4002' {
        $script:Queries = 0
        Mock Get-IbcGatewayProcesses {
            if (-not $ConfigPath) { return @([pscustomobject]@{ProcessId=100}) }
            $script:Queries++
            if ($script:Queries -gt 1) { return @([pscustomobject]@{ProcessId=200}) }
            return @()
        }
        Mock Test-ProcessPortOwner { $true } -ParameterFilter { $Port -eq 4002 -and $ProcessIds.Count -eq 1 -and $ProcessIds[0] -eq 200 }
        Start-IsolatedPaperGateway -ProjectDirectory $Root -TimeoutSeconds 1
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like '*StartPaperGateway.bat' -and $WindowStyle -eq 'Hidden' }
        Should -Invoke Test-ProcessPortOwner -Times 1 -ParameterFilter { $Port -eq 4002 -and $ProcessIds[0] -eq 200 }
        [IO.File]::ReadAllText($LiveBatch) | Should -BeExactly $LiveText
    }
    It 'does not accept the live listener as paper readiness or relaunch an existing paper process' {
        Mock Get-IbcGatewayProcesses { @([pscustomobject]@{ProcessId=200}) }
        { Start-IsolatedPaperGateway -ProjectDirectory $Root -TimeoutSeconds 1 } | Should -Throw '*4002 is not ready*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Test-ProcessPortOwner -Times 1 -ParameterFilter { $Port -eq 4002 -and $ProcessIds[0] -eq 200 }
    }
    It 'does not rewrite a running paper configuration even in prepare-only mode' {
        Mock Get-IbcGatewayProcesses { @([pscustomobject]@{ProcessId=200}) }
        { Start-IsolatedPaperGateway -ProjectDirectory $Root -PrepareOnly } | Should -Throw '*already running*'
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'fails before writing when another process occupies 4002' {
        Mock Get-NetTCPConnection { @([pscustomobject]@{OwningProcess=999; LocalPort=4002}) }
        { Start-IsolatedPaperGateway -ProjectDirectory $Root -PrepareOnly } | Should -Throw '*already owned*'
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'fails closed if listener ownership cannot be inspected' {
        Mock Get-NetTCPConnection { throw 'synthetic listener inspection failure' }
        { Start-IsolatedPaperGateway -ProjectDirectory $Root -PrepareOnly } | Should -Throw '*listener inspection failure*'
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'never falls back to direct launch after unavailable credentials' {
        Mock New-IbcConfig { $false }
        { Start-IsolatedPaperGateway -ProjectDirectory $Root } | Should -Throw '*credentials are unavailable*'
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects incomplete templates before reading credentials' {
        [IO.File]::WriteAllText($LiveBatch, 'set TRADING_MODE=live')
        { Start-IsolatedPaperGateway -ProjectDirectory $Root } | Should -Throw '*exactly one CONFIG*'
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects inline credentials in a template before copying it' {
        [IO.File]::WriteAllText($LiveBatch, $LiveText + "set TWSPASSWORD=synthetic`r`n")
        { Start-IsolatedPaperGateway -ProjectDirectory $Root } | Should -Throw '*inline login credentials*'
        Should -Invoke New-IbcConfig -Times 0
        Should -Invoke Start-Process -Times 0
    }
}
