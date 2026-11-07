BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepositoryRoot 'src/common.ps1')
}

Describe 'Pure credential selection and serialization' {
    It 'returns the requested structured field exactly' {
        Get-CredentialFieldValue -Entry ([pscustomobject]@{username='demo';password='Case+Sensitive/='}) -Field password |
            Should -BeExactly 'Case+Sensitive/='
    }
    It 'never substitutes a password for a missing username' {
        { Get-CredentialFieldValue -Entry ([pscustomobject]@{notes='password: secret'}) -Field username } | Should -Throw
    }
    It 'rejects unsupported field names' {
        { Get-CredentialFieldValue -Entry ([pscustomobject]@{password='demo'}) -Field account } | Should -Throw
    }
    It 'preserves punctuation in a notes password' {
        Get-CredentialFieldValue -Entry ([pscustomobject]@{notes="password: a+b=c/d!`nother: ignored"}) | Should -BeExactly 'a+b=c/d!'
    }
    It 'rejects malformed DPAPI hex before cryptography' -ForEach @('', 'a', 'zz', '010x') {
        { ConvertFrom-DpapiHexString -Hex $_ } | Should -Throw
    }
    It 'escapes properties backslashes instead of consuming them' {
        ConvertTo-JavaPropertyValue -Value 'a\b\' | Should -BeExactly 'a\\b\\'
    }
    It 'escapes all properties whitespace and unicode' {
        ConvertTo-JavaPropertyValue -Value " a`t中`r`n" | Should -BeExactly '\ a\t\u4e2d\r\n'
    }
    It 'does not invent escapes for literal equals and colons in values' {
        ConvertTo-JavaPropertyValue -Value 'a=b:c#d!' | Should -BeExactly 'a=b:c#d!'
    }
}

Describe 'IBC configuration publication' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Get-StoredCredentials { [pscustomobject]@{ibkr_tws_gateway=[pscustomobject]@{username='demo';password='Dummy+Password'}} }
        Mock Get-OnePasswordIbkrCredentials { throw 'Live 1Password access forbidden in tests' }
        Mock Write-PrivateTextFile {}
    }
    It 'uses the local store without invoking 1Password' {
        New-IbcConfig -Path (Join-Path $TestDrive 'ibc.ini') | Should -BeTrue
        Should -Invoke Get-OnePasswordIbkrCredentials -Times 0
        Should -Invoke Write-PrivateTextFile -Times 1 -ParameterFilter {
            $Text -like '*IbLoginId=demo*' -and $Text -like '*IbPassword=Dummy+Password*'
        }
    }
    It 'explicit paper configuration uses paper mode and the workspace API port' {
        Mock Get-StoredCredentials { [pscustomobject]@{ibkr_tws_gateway_paper=[pscustomobject]@{username='paper-demo';password='dummy'}} }
        New-IbcConfig -Path (Join-Path $TestDrive 'paper.ini') -TradingMode paper | Should -BeTrue
        Should -Invoke Write-PrivateTextFile -Times 1 -ParameterFilter {
            $Text -like '*TradingMode=paper*' -and $Text -like '*OverrideTwsApiPort=4002*' -and $Text -notlike '*TradingMode=live*' -and
            $Text -like '*ExistingSessionDetectedAction=secondary*' -and $Text -like '*ReadOnlyApi=yes*' -and
            $Text -like '*ReloginAfterSecondFactorAuthenticationTimeout=no*'
        }
    }
    It 'never falls back to live credentials for paper startup' {
        { New-IbcConfig -Path (Join-Path $TestDrive 'paper.ini') -TradingMode paper } | Should -Throw '*Dedicated IBKR paper credentials unavailable*'
        Should -Invoke Get-OnePasswordIbkrCredentials -Times 0
        Should -Invoke Write-PrivateTextFile -Times 0
    }
    It 'does not authorize startup after a write error' {
        Mock Write-PrivateTextFile { throw 'Synthetic permission failure' }
        { New-IbcConfig -Path (Join-Path $TestDrive 'ibc.ini') } | Should -Throw '*Synthetic permission failure*'
    }
    It 'falls back to the CLI only when no complete local credential exists' {
        Mock Get-StoredCredentials { $null }
        Mock Get-OnePasswordIbkrCredentials { @{Username='fallback';Password='dummy'} }
        New-IbcConfig -Path (Join-Path $TestDrive 'ibc.ini') | Should -BeTrue
        Should -Invoke Get-OnePasswordIbkrCredentials -Times 1
    }
    It 'rejects credential forms that IBC would trim or change' -ForEach @(' leading', 'trailing ', "line`nbreak") {
        $script:InvalidPassword = $_
        Mock Get-StoredCredentials { [pscustomobject]@{ibkr_tws_gateway=[pscustomobject]@{username='demo';password=$script:InvalidPassword}} }
        { New-IbcConfig -Path (Join-Path $TestDrive 'ibc.ini') } | Should -Throw '*cannot contain*'
        Should -Invoke Write-PrivateTextFile -Times 0
    }
    It 'does not write a config with missing credentials' {
        Mock Get-StoredCredentials { $null }
        Mock Get-OnePasswordIbkrCredentials { $null }
        New-IbcConfig -Path (Join-Path $TestDrive 'ibc.ini') | Should -BeFalse
        Should -Invoke Write-PrivateTextFile -Times 0
    }
}

Describe 'Filesystem discovery using synthetic fixtures' {
    BeforeEach {
        $script:FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $FixtureRoot
    }
    It 'chooses numeric versions rather than lexical ordering' {
        foreach ($name in '9.9', '10.0', '1.10', 'notes') {
            $directory = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $name) -Force
            Set-Content -LiteralPath (Join-Path $directory.FullName 'app.exe') -Value 'fixture'
        }
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe | Should -Be (Join-Path $FixtureRoot '10.0/app.exe')
    }
    It 'chooses 1.10 over 1.9 and ignores incomplete updates' {
        foreach ($name in '1.9', '1.10', '99.0') { $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $name) -Force }
        foreach ($name in '1.9', '1.10') { Set-Content -LiteralPath (Join-Path $FixtureRoot "$name/app.exe") -Value 'fixture' }
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe | Should -Be (Join-Path $FixtureRoot '1.10/app.exe')
    }
    It 'handles timestamp version components without Int32 overflow' {
        foreach ($name in '20260921113525', '20261013084301') {
            $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $name) -Force
            Set-Content -LiteralPath (Join-Path $FixtureRoot "$name/app.exe") -Value 'fixture'
        }
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe | Should -Be (Join-Path $FixtureRoot '20261013084301/app.exe')
    }
    It 'chooses the installed build named by the launcher manifest' {
        foreach ($name in '20261013084301', '20261023213909') {
            $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $name) -Force
            Set-Content -LiteralPath (Join-Path $FixtureRoot "$name/app.exe") -Value 'fixture'
        }
        Set-Content -LiteralPath (Join-Path $FixtureRoot 'dir.xml') -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<root><current>20261013084301</current><next_dir>20261023213909</next_dir></root>
'@
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe -Manifest dir.xml |
            Should -Be (Join-Path $FixtureRoot '20261013084301/app.exe')
    }
    It 'falls back to numeric ordering when the manifest names a missing build' {
        $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot '20261013084301') -Force
        Set-Content -LiteralPath (Join-Path $FixtureRoot '20261013084301/app.exe') -Value 'fixture'
        Set-Content -LiteralPath (Join-Path $FixtureRoot 'dir.xml') -Value '<root><current>20261023213909</current></root>'
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe -Manifest dir.xml |
            Should -Be (Join-Path $FixtureRoot '20261013084301/app.exe')
    }
    It 'ignores a malformed manifest instead of failing discovery' {
        $null = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot '10.0') -Force
        Set-Content -LiteralPath (Join-Path $FixtureRoot '10.0/app.exe') -Value 'fixture'
        Set-Content -LiteralPath (Join-Path $FixtureRoot 'dir.xml') -Value 'not xml at all'
        Get-LatestAppExecutable -Directory $FixtureRoot -FileName app.exe -Manifest dir.xml |
            Should -Be (Join-Path $FixtureRoot '10.0/app.exe')
    }
    It 'rejects a manifest value that escapes the install directory' {
        $outside = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'outside') -Force
        Set-Content -LiteralPath (Join-Path $outside.FullName 'app.exe') -Value 'fixture'
        $install = New-Item -ItemType Directory -Path (Join-Path $FixtureRoot 'install') -Force
        Set-Content -LiteralPath (Join-Path $install.FullName 'dir.xml') -Value '<root><current>..\outside</current></root>'
        Get-LatestAppExecutable -Directory $install.FullName -FileName app.exe -Manifest dir.xml | Should -BeNullOrEmpty
    }
    It 'returns no workbook for a missing directory' {
        Get-LatestWorkbook -Directory (Join-Path $FixtureRoot 'missing') | Should -BeNullOrEmpty
    }
    It 'excludes the most recent Office lock file' {
        Set-Content -LiteralPath (Join-Path $FixtureRoot 'real.xlsx') -Value fixture
        Set-Content -LiteralPath (Join-Path $FixtureRoot '~$real.xlsx') -Value fixture
        Get-LatestWorkbook -Directory $FixtureRoot | Select-Object -ExpandProperty Name | Should -BeExactly 'real.xlsx'
    }
    It 'accepts the launcher name that IBC renamed' {
        Set-Content -LiteralPath (Join-Path $FixtureRoot 'tws1.exe') -Value fixture
        Get-DirectIbExecutable -Directory $FixtureRoot -Name tws | Should -Be (Join-Path $FixtureRoot 'tws1.exe')
    }
    It 'throws for a missing direct launcher' {
        { Get-DirectIbExecutable -Directory $FixtureRoot -Name absent } | Should -Throw
    }
}

Describe 'Managed startup and API identity boundaries' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Start-Process { throw 'Live process launches forbidden in tests' }
        Mock Get-Process { $null }
        Mock Start-Sleep {}
        Mock Test-PortListening { throw 'Live port probes forbidden in tests' }
        Mock Get-NetTCPConnection { @() }
        Mock Get-CimInstance { @() }
    }
    It 'does not launch an already running application' {
        Mock Get-Process { [pscustomobject]@{Id=100;ProcessName='demo'} }
        Start-ManagedApplication -Name demo -Executable missing.exe
        Should -Invoke Start-Process -Times 0
    }
    It 'throws before launch for a missing executable' {
        { Start-ManagedApplication -Name demo -Executable (Join-Path $TestDrive 'absent.exe') } | Should -Throw '*Executable not found*'
        Should -Invoke Start-Process -Times 0
    }
    It 'propagates launch failures' {
        $path = Join-Path $TestDrive 'demo.exe'; Set-Content -LiteralPath $path -Value fixture
        { Start-ManagedApplication -Name demo -Executable $path } | Should -Throw '*forbidden*'
    }
    It 'reports a process timeout using a fake clock without sleeping' {
        $script:tick = 0
        Mock Get-Date { $script:tick++; ([datetime]'2026-01-01').AddSeconds($script:tick * 5) }
        { Wait-AppProcess -Name demo -TimeoutSeconds 1 } | Should -Throw '*not detected*'
    }
    It 'rejects a listener belonging to another process' {
        Mock Get-NetTCPConnection { [pscustomobject]@{OwningProcess=999} }
        Test-ProcessPortOwner -Port 4001 -ProcessIds @(100) | Should -BeFalse
        Should -Invoke Test-PortListening -Times 0
    }
    It 'accepts a listener only after matching its owning process' {
        Mock Get-NetTCPConnection { [pscustomobject]@{OwningProcess=100} }
        Mock Test-PortListening { $true }
        Test-ProcessPortOwner -Port 4001 -ProcessIds @(100) | Should -BeTrue
    }
    It 'rejects readiness when discovery is denied' {
        Mock Get-NetTCPConnection { throw 'denied' }
        Test-ProcessPortOwner -Port 4001 -ProcessIds @(100) | Should -BeFalse
    }
    It 'does not mistake TWS, a similarly named class, or a jar path for Gateway' {
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ProcessId=1;CommandLine='java ibcalpha.ibc.IbcTws config live'}
                [pscustomobject]@{ProcessId=2;CommandLine='java ibcalpha.ibc.IbcGateway config live'}
                [pscustomobject]@{ProcessId=3;CommandLine='java ibcalpha.ibc.IbcGatewayOther config live'}
                [pscustomobject]@{ProcessId=4;CommandLine='java -cp C:\IbcGateway.jar OtherMain'}
            )
        }
        @(Get-IbcGatewayProcesses).Count | Should -Be 1
        (Get-IbcGatewayProcesses).ProcessId | Should -Be 2
    }
}

Describe 'Atomic private fixture publication' {
    It 'creates and replaces complete files with synthetic data' {
        $path = Join-Path $TestDrive 'private/dummy.ini'
        Write-PrivateTextFile -Path $path -Text 'first-dummy'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'first-dummy'
        Write-PrivateTextFile -Path $path -Text 'second-dummy'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'second-dummy'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File).Count | Should -Be 1
        $acl = Get-Acl -LiteralPath $path
        $acl.AreAccessRulesProtected | Should -BeTrue
        $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
        foreach ($rule in $acl.Access) {
            $rule.IsInherited | Should -BeFalse
            $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value | Should -BeIn $allowed
        }
    }
    It 'preserves the previous file if securing staging fails' {
        $path = Join-Path $TestDrive 'existing.ini'
        Set-Content -LiteralPath $path -Value 'old-dummy' -NoNewline
        Mock Protect-PrivateFile { throw 'synthetic ACL failure' }
        { Write-PrivateTextFile -Path $path -Text 'new-dummy' } | Should -Throw '*ACL failure*'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'old-dummy'
    }
}

Describe 'Logging path regression' {
    It 'does not use a colliding workbook logDir variable' {
        $original = $ProjectRoot
        try {
            $ProjectRoot = $TestDrive
            $logDir = Join-Path $TestDrive 'workbook-dir'
            Write-AppLog -Message 'synthetic logging test' -LogName apps
            Test-Path -LiteralPath (Join-Path $TestDrive 'logs/apps.log') | Should -BeTrue
            Test-Path -LiteralPath $logDir | Should -BeFalse
        }
        finally { $ProjectRoot = $original }
    }
}

Describe 'IBKR Desktop session exclusivity' {
    BeforeAll {
        function New-FakeIbSession {
            param(
                [Parameter(Mandatory = $true)][int]$Id,
                [Parameter(Mandatory = $true)][string]$Name,
                [switch]$IgnoresClose,
                [switch]$SurvivesKill
            )
            $fake = [pscustomobject]@{
                Id = $Id; ProcessName = $Name; HasExited = $false
                IgnoresClose = [bool]$IgnoresClose; SurvivesKill = [bool]$SurvivesKill
                CloseRequested = $false; KillRequested = $false
            }
            $fake | Add-Member ScriptMethod CloseMainWindow {
                $this.CloseRequested = $true
                if (-not $this.IgnoresClose) { $this.HasExited = $true }
                return $true
            }
            $fake | Add-Member ScriptMethod Kill {
                $this.KillRequested = $true
                if (-not $this.SurvivesKill) { $this.HasExited = $true }
            }
            return $fake
        }
    }
    BeforeEach {
        Mock Write-AppLog {}
        Mock Start-Sleep {}
    }
    It 'reports that nothing had to be stopped when no session is running' {
        Mock Get-Process { @([pscustomobject]@{ Id = 1; ProcessName = 'ntws' }) }
        Mock Get-IbcProcesses { @() }
        Stop-IbSessionProcesses
        Should -Invoke Write-AppLog -Times 1 -Exactly -ParameterFilter { $Message -like 'No TWS / IB Gateway*' }
    }
    It 'closes direct TWS and gateway launchers before IBKR Desktop starts' {
        $script:tws = New-FakeIbSession 10 'tws'
        $script:gateway = New-FakeIbSession 20 'ibgateway1'
        Mock Get-Process { @($script:tws, $script:gateway) }
        Mock Get-IbcProcesses { @() }
        Stop-IbSessionProcesses
        $script:tws.CloseRequested | Should -BeTrue
        $script:gateway.CloseRequested | Should -BeTrue
        $script:tws.KillRequested | Should -BeFalse
    }
    It 'closes an IBC-managed Java session selected by its exact marker' {
        $script:java = New-FakeIbSession 42 'java'
        Mock Get-Process { @($script:java) }
        Mock Get-IbcProcesses {
            if ($Application -eq 'Gateway') { return @([pscustomobject]@{ ProcessId = 42 }) }
            return @()
        }
        Stop-IbSessionProcesses
        $script:java.CloseRequested | Should -BeTrue
    }
    It 'forces a session that ignores the graceful close' {
        $script:gateway = New-FakeIbSession 30 'ibgateway' -IgnoresClose
        Mock Get-Process { @($script:gateway) }
        Mock Get-IbcProcesses { @() }
        $script:tick = 0
        Mock Get-Date { $script:tick++; ([datetime]'2026-01-01').AddSeconds($script:tick * 25) }
        Stop-IbSessionProcesses -GraceSeconds 10
        $script:gateway.KillRequested | Should -BeTrue
    }
    It 'throws instead of claiming success when a session survives force' {
        $script:gateway = New-FakeIbSession 31 'ibgateway' -IgnoresClose -SurvivesKill
        Mock Get-Process { @($script:gateway) }
        Mock Get-IbcProcesses { @() }
        $script:tick = 0
        Mock Get-Date { $script:tick++; ([datetime]'2026-01-01').AddSeconds($script:tick * 25) }
        { Stop-IbSessionProcesses -GraceSeconds 10 } | Should -Throw '*Could not stop TWS / IB Gateway*'
    }
    It 'guards the desktop launch without stopping TWS or Gateway' {
        $source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'scripts/apps/start-ibkr-desktop.ps1'))
        $stopIndex = $source.IndexOf('Assert-NoIbLaunchConflict -Application Desktop')
        $launchIndex = $source.IndexOf('Start-ManagedApplication')
        $stopIndex | Should -BeGreaterThan -1
        $launchIndex | Should -BeGreaterThan -1
        $stopIndex | Should -BeLessThan $launchIndex
    }
    It 'reports that the desktop was not running when there is nothing to stop' {
        Mock Get-Process { @() }
        Stop-IbkrDesktopProcesses
        Should -Invoke Write-AppLog -Times 1 -Exactly -ParameterFilter { $Message -like 'IBKR Desktop is not running.*' }
    }
    It 'closes IBKR Desktop before TWS takes the same login' {
        $script:desktop = New-FakeIbSession 50 'ntws'
        Mock Get-Process { @($script:desktop) }
        Stop-IbkrDesktopProcesses
        $script:desktop.CloseRequested | Should -BeTrue
        $script:desktop.KillRequested | Should -BeFalse
    }
    It 'throws instead of claiming success when the desktop survives force' {
        $script:desktop = New-FakeIbSession 51 'ntws' -IgnoresClose -SurvivesKill
        Mock Get-Process { @($script:desktop) }
        $script:tick = 0
        Mock Get-Date { $script:tick++; ([datetime]'2026-01-01').AddSeconds($script:tick * 25) }
        { Stop-IbkrDesktopProcesses -GraceSeconds 10 } | Should -Throw '*Could not stop IBKR Desktop*'
    }
    It 'guards the TWS launch without stopping Desktop' {
        $source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'scripts/apps/start-tws.ps1'))
        $stopIndex = $source.IndexOf('Assert-NoIbLaunchConflict -Application Tws')
        $launchIndex = $source.IndexOf('Start-Process')
        $stopIndex | Should -BeGreaterThan -1
        $launchIndex | Should -BeGreaterThan -1
        $stopIndex | Should -BeLessThan $launchIndex
    }
}

Describe 'Start commands preserve conflicting IBKR sessions' {
    BeforeEach {
        Mock Get-IbkrDesktopProcesses { @() }
        Mock Get-IbSessionProcesses { @() }
        Mock Stop-Process { throw 'Unexpected stop' }
    }
    It 'allows launch when no conflicting session exists' {
        { Assert-NoIbLaunchConflict -Application Tws } | Should -Not -Throw
        { Assert-NoIbLaunchConflict -Application Desktop } | Should -Not -Throw
    }
    It 'refuses TWS when Desktop is running without stopping it' {
        Mock Get-IbkrDesktopProcesses { [pscustomobject]@{ Id = 5 } }
        { Assert-NoIbLaunchConflict -Application Tws } | Should -Throw '*Existing clients were preserved*'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
    It 'refuses Desktop when a direct or IBC session is running without stopping it' {
        Mock Get-IbSessionProcesses { [pscustomobject]@{ Id = 6 } }
        { Assert-NoIbLaunchConflict -Application Desktop } | Should -Throw '*Existing clients were preserved*'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}
