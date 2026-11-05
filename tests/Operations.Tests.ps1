# Pester 5; imports ONLY function ASTs, never production script bodies/UI imports.
BeforeAll {
$repoRoot = Split-Path $PSScriptRoot -Parent
$operationFiles = @('gateway-tray', 'stop-extra-apps', 'stop-trading-apps')
foreach ($name in $operationFiles) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot "scripts/operations/$name.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    foreach ($definition in $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
foreach ($name in @('setup-autostart-task', 'enable-win-autologon')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot "scripts/setup/$name.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    foreach ($definition in $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
}

# Fail-closed dependency stubs. These do not import common.ps1 or reach the OS.
function Write-AppLog { param($Message, $LogName) }
function Get-IbcGatewayProcesses { throw 'Unmocked gateway query.' }
function Test-GatewayApiReady { throw 'Unmocked readiness query.' }
function Get-ProcessWindowList { param($ProcessId); throw 'Unmocked window query.' }
function Stop-Process {
    [CmdletBinding()]
    param($InputObject, $Id, [switch]$Force)
    throw 'Unmocked process stop.'
}
# Untyped fake scheduler boundary avoids validating fake objects as real CIM tasks.
function Register-ScheduledTask {
    [CmdletBinding()]
    param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description, [switch]$Force)
    throw 'Unmocked task registration.'
}

function New-OperationsFakeProcess {
    param([int]$Id, [string]$Name, [datetime]$StartTime = [datetime]'2026-01-01')
    $fake = [pscustomobject]@{
        Id = $Id; ProcessName = $Name; StartTime = $StartTime
        HasExited = $false; CloseRequested = $false
    }
    $fake | Add-Member ScriptMethod CloseMainWindow { $this.CloseRequested = $true; return $false }
    return $fake
}
}

Describe 'Extra-app stop safety' {
    BeforeEach {
        $script:fakeProcesses = @()
        Mock Write-AppLog {}
        Mock Start-Sleep { throw 'Unexpected wait in unit test.' }
        Mock Stop-Process { throw 'Unexpected force stop.' }
        Mock Get-Process {
            if ($Id) {
                $found = @($script:fakeProcesses | Where-Object { $_.Id -in $Id })
                if (-not $found.Count) { Write-Error 'Process gone' -Category ObjectNotFound -ErrorAction Stop }
                return $found
            }
            return $script:fakeProcesses
        }
    }
    It 'selects exact names including ntws, never prefixes, Excel or OBS' {
        $names = @('TradingView', 'thinkorswim', 'ntws', 'mytrader_spqh', 'AlgoMaster', 'Q73N', 'FTNN',
            'TradingViewUpdater', 'ntws-helper', 'FTNNBackup', 'EXCEL', 'obs64')
        $counter = 100
        $script:fakeProcesses = @($names | ForEach-Object { New-OperationsFakeProcess (++$counter) $_ })
        $snapshots = @(Get-ExtraProcessSnapshot)
        $snapshots.Count | Should -Be 7
        @($snapshots.Name) -contains 'ntws' | Should -Be $true
        @($snapshots.Name) -contains 'EXCEL' | Should -Be $false
    }
    It 'does not close or force a reused PID' {
        $original = New-OperationsFakeProcess 100 'FTNN'
        $script:fakeProcesses = @($original)
        $snapshot = @(Get-ExtraProcessSnapshot)[0]
        $script:fakeProcesses = @(New-OperationsFakeProcess 100 'FTNN' ([datetime]'2026-01-02'))
        Stop-ExtraProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0
        $original.CloseRequested | Should -Be $false
        Assert-MockCalled Stop-Process -Scope It -Times 0 -Exactly
    }
    It 'forces only the original process object, never a newly matching instance' {
        $original = New-OperationsFakeProcess 100 'FTNN'
        $script:fakeProcesses = @($original)
        $snapshot = @(Get-ExtraProcessSnapshot)[0]
        $script:fakeProcesses += New-OperationsFakeProcess 200 'FTNN'
        Mock Stop-Process { $script:fakeProcesses = @($script:fakeProcesses | Where-Object { $_.Id -ne 100 }) }
        Stop-ExtraProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0
        $original.CloseRequested | Should -Be $true
        $script:fakeProcesses[0].Id | Should -Be 200
        Assert-MockCalled Stop-Process -Scope It -Times 1 -Exactly -ParameterFilter { $InputObject -eq $original -and $Force }
    }
    It 'throws if a target survives force instead of claiming success' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 100 'FTNN')
        $snapshot = @(Get-ExtraProcessSnapshot)[0]
        Mock Stop-Process {}
        { Stop-ExtraProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0 } | Should -Throw
    }
    It 'propagates force permission errors' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 100 'FTNN')
        $snapshot = @(Get-ExtraProcessSnapshot)[0]
        { Stop-ExtraProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0 } | Should -Throw
    }
    It 'captures the complete target set only once' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 100 'FTNN')
        Mock Stop-ExtraProcessSnapshot {
            $script:fakeProcesses += New-OperationsFakeProcess 200 'FTNN'
        }
        Stop-ExtraApps
        Assert-MockCalled Stop-ExtraProcessSnapshot -Scope It -Times 1 -Exactly
        Assert-MockCalled Get-Process -Scope It -Times 1 -Exactly
    }
}

Describe 'Trading-process stop safety' {
    BeforeEach {
        $script:fakeProcesses = @()
        $script:ibcMatches = @()
        Mock Write-AppLog {}
        Mock Start-Sleep { throw 'Unexpected wait in unit test.' }
        Mock Stop-Process { throw 'Unexpected force stop.' }
        Mock Get-IbcGatewayProcesses { return $script:ibcMatches }
        Mock Get-Process {
            if ($Id) {
                $found = @($script:fakeProcesses | Where-Object { $_.Id -in $Id })
                if (-not $found.Count) { Write-Error 'Process gone' -Category ObjectNotFound -ErrorAction Stop }
                return $found
            }
            return $script:fakeProcesses
        }
        Mock Request-TradingProcessClose { $Snapshot.Process.CloseRequested = $true }
    }
    It 'captures Futu, both direct gateway names, and only marker-selected Java' {
        $script:fakeProcesses = @(
            (New-OperationsFakeProcess 1 'Futu_OpenD'), (New-OperationsFakeProcess 2 'ibgateway'),
            (New-OperationsFakeProcess 3 'ibgateway1'), (New-OperationsFakeProcess 4 'java'),
            (New-OperationsFakeProcess 5 'java'), (New-OperationsFakeProcess 6 'tws'))
        $script:ibcMatches = @([pscustomobject]@{ ProcessId = 4 })
        $snapshots = @(Get-TradingProcessSnapshot)
        $snapshots.Count | Should -Be 4
        @($snapshots | Where-Object IsIbc).Id | Should -Be 4
    }
    It 'respects the Futu-only target' {
        $script:fakeProcesses = @((New-OperationsFakeProcess 1 'Futu_OpenD'), (New-OperationsFakeProcess 2 'ibgateway'))
        @(Get-TradingProcessSnapshot -Target Futu).Count | Should -Be 1
        Assert-MockCalled Get-IbcGatewayProcesses -Scope It -Times 0 -Exactly
    }
    It 'does not touch a PID reused after capture' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 4 'java')
        $script:ibcMatches = @([pscustomobject]@{ ProcessId = 4 })
        $snapshot = @(Get-TradingProcessSnapshot)[0]
        $script:fakeProcesses = @(New-OperationsFakeProcess 4 'java' ([datetime]'2026-01-02'))
        Stop-TradingProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0
        Assert-MockCalled Request-TradingProcessClose -Scope It -Times 0 -Exactly
        Assert-MockCalled Stop-Process -Scope It -Times 0 -Exactly
    }
    It 'requires the exact IBC marker again before force' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 4 'java')
        $script:ibcMatches = @([pscustomobject]@{ ProcessId = 4 })
        $snapshot = @(Get-TradingProcessSnapshot)[0]
        Mock Request-TradingProcessClose { $script:ibcMatches = @() }
        { Stop-TradingProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0 } | Should -Throw
        Assert-MockCalled Stop-Process -Scope It -Times 0 -Exactly
    }
    It 'requests graceful shutdown before forcing the captured IBC object' {
        $original = New-OperationsFakeProcess 4 'java'
        $script:fakeProcesses = @($original)
        $script:ibcMatches = @([pscustomobject]@{ ProcessId = 4 })
        $snapshot = @(Get-TradingProcessSnapshot)[0]
        Mock Stop-Process {
            if (-not $InputObject.CloseRequested) { throw 'Force preceded graceful close.' }
            $script:fakeProcesses = @()
        }
        Stop-TradingProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0
        Assert-MockCalled Stop-Process -Scope It -Times 1 -Exactly -ParameterFilter { $InputObject -eq $original -and $Force }
    }
    It 'throws if a trading process survives force' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 2 'ibgateway')
        $snapshot = @(Get-TradingProcessSnapshot)[0]
        Mock Stop-Process {}
        { Stop-TradingProcessSnapshot $snapshot -GraceSeconds 0 -ForceSeconds 0 } | Should -Throw
    }
    It 'waits the graceful timeout before forcing a surviving gateway' {
        $script:fakeProcesses = @(New-OperationsFakeProcess 2 'ibgateway')
        $snapshot = @(Get-TradingProcessSnapshot)[0]
        $script:clock = [datetime]'2026-01-01T12:00:00'
        $script:forceAt = $null
        Mock Get-Date { $script:clock }
        Mock Start-Sleep { $script:clock = $script:clock.AddSeconds(15) }
        Mock Stop-Process { $script:forceAt = $script:clock; $script:fakeProcesses = @() }
        Stop-TradingProcessSnapshot $snapshot -GraceSeconds 15 -ForceSeconds 0
        $script:forceAt | Should -Be ([datetime]'2026-01-01T12:00:15')
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly
    }
}

Describe 'Gateway tray lifecycle without a UI' {
    BeforeEach {
        Mock Get-IbcGatewayProcesses { @([pscustomobject]@{ ProcessId = 4 }) }
        Mock Get-Process {}
        Mock Test-GatewayApiReady { $false }
        Mock Show-GatewayWindows { 1 }
        Mock Write-Warning {}
    }
    It 'does not mark a bare open socket as API-ready' {
        Get-GatewayState | Should -Be 'waiting'
        Assert-MockCalled Test-GatewayApiReady -Scope It -Times 1 -Exactly
    }
    It 'marks an owner-validated gateway API as ready' {
        Mock Test-GatewayApiReady { $true }
        Get-GatewayState | Should -Be 'up'
    }
    It 'does not probe API readiness when no gateway exists' {
        Mock Get-IbcGatewayProcesses { @() }
        Get-GatewayState | Should -Be 'down'
        Assert-MockCalled Test-GatewayApiReady -Scope It -Times 0 -Exactly
    }
    It 'restores windows and disposes every owned resource even after a cleanup failure' {
        $events = New-Object 'System.Collections.Generic.List[string]'
        function New-TestResource($Name, [switch]$FailStop) {
            $resource = [pscustomobject]@{ Name = $Name; Events = $events; FailStop = [bool]$FailStop; Visible = $true }
            $resource | Add-Member ScriptMethod Dispose { $this.Events.Add("dispose:$($this.Name)") }
            $resource | Add-Member ScriptMethod Stop { $this.Events.Add('stop'); if ($this.FailStop) { throw 'stop failed' } }
            $resource | Add-Member ScriptMethod ReleaseMutex { $this.Events.Add('release') }
            return $resource
        }
        $timer = New-TestResource timer -FailStop
        $notify = New-TestResource notify
        Close-GatewayTray -Timer $timer -Notify $notify -Menu (New-TestResource menu) -Icon (New-TestResource icon) -Mutex (New-TestResource mutex) -OwnsMutex $true -WarningAction SilentlyContinue
        $notify.Visible | Should -Be $false
        ($events -join ',') | Should -Be 'stop,dispose:timer,dispose:notify,dispose:menu,dispose:icon,release,dispose:mutex'
        Assert-MockCalled Show-GatewayWindows -Scope It -Times 1 -Exactly
    }
    It 'does not restore another tray owner windows or release its mutex' {
        $mutex = [pscustomobject]@{ Disposed = $false; Released = $false }
        $mutex | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $mutex | Add-Member ScriptMethod ReleaseMutex { $this.Released = $true }
        Close-GatewayTray -Mutex $mutex -OwnsMutex $false
        $mutex.Disposed | Should -Be $true
        $mutex.Released | Should -Be $false
        Assert-MockCalled Show-GatewayWindows -Scope It -Times 0 -Exactly
    }
    It 'wires the Exit item and protects the entire tray lifetime with finally' {
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts/operations/gateway-tray.ps1'))
        $source | Should -Match '\$exitItem\.Add_Click\(\{ \[System.Windows.Forms.Application\]::Exit\(\) \}\)'
        $source | Should -Match '(?s)finally\s*\{\s*Close-GatewayTray'
        $source | Should -Match "Start-ProjectScript -Name 'start-ibgateway.ps1'"
    }
    It 'gracefully posts WM_CLOSE for hidden gateway windows without a synchronous send' {
        $source = (Get-Command Request-TradingProcessClose).Definition
        $source | Should -Match 'PostMessage'
        $source | Should -Not -Match '\$window.Visible'
        $source | Should -Not -Match '\]::SendMessage'
    }
}

Describe 'Restart sequencing in a fake project tree' {
    BeforeEach {
        $fakeRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'scripts/operations') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'src') -Force | Out-Null
        $global:OperationsTestEvents = New-Object 'System.Collections.Generic.List[string]'
        $global:OperationsTestFailStop = ''
        @'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
function Start-ProjectScript { param($Name); $global:OperationsTestEvents.Add("start:$Name") }
'@ | Set-Content -LiteralPath (Join-Path $fakeRoot 'src/common.ps1') -Encoding UTF8
        foreach ($name in @('stop-extra-apps', 'stop-trading-apps')) {
            @"
param(`$Target)
`$global:OperationsTestEvents.Add('$name')
if (`$global:OperationsTestFailStop -eq '$name') { throw 'mock stop failure' }
if (`$global:OperationsTestFailStop -eq 'exit:$name') { exit 1 }
"@ | Set-Content -LiteralPath (Join-Path $fakeRoot "$name.ps1") -Encoding UTF8
        }
        foreach ($name in @('restart-all-apps', 'restart-trading-apps')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/operations/$name.ps1") -Destination (Join-Path $fakeRoot "scripts/operations/$name.ps1")
        }
    }
    AfterEach {
        Remove-Variable OperationsTestEvents, OperationsTestFailStop -Scope Global -ErrorAction SilentlyContinue
    }
    It 'stops extra apps and gateways before launching the stable root entry point' {
        & (Join-Path $fakeRoot 'scripts/operations/restart-all-apps.ps1')
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-extra-apps,stop-trading-apps,start:autostart-trading-apps.ps1'
    }
    It 'restarts gateway services without stopping extra apps' {
        & (Join-Path $fakeRoot 'scripts/operations/restart-trading-apps.ps1')
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-trading-apps,start:autostart-trading-apps.ps1'
    }
    It 'never launches after an extra-app stop failure' {
        $global:OperationsTestFailStop = 'stop-extra-apps'
        { & (Join-Path $fakeRoot 'scripts/operations/restart-all-apps.ps1') } | Should -Throw
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-extra-apps'
    }
    It 'never launches after a gateway stop failure' {
        $global:OperationsTestFailStop = 'stop-trading-apps'
        { & (Join-Path $fakeRoot 'scripts/operations/restart-trading-apps.ps1') } | Should -Throw
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-trading-apps'
    }
    It 'gates restart-all when a compatibility stop wrapper exits nonzero' {
        $global:OperationsTestFailStop = 'exit:stop-extra-apps'
        { & (Join-Path $fakeRoot 'scripts/operations/restart-all-apps.ps1') } | Should -Throw
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-extra-apps'
    }
    It 'gates gateway restart when a compatibility stop wrapper exits nonzero' {
        $global:OperationsTestFailStop = 'exit:stop-trading-apps'
        { & (Join-Path $fakeRoot 'scripts/operations/restart-trading-apps.ps1') } | Should -Throw
        ($global:OperationsTestEvents -join ',') | Should -Be 'stop-trading-apps'
    }
}

Describe 'Manual scheduled-task setup is opt-in and truthful' {
    BeforeEach {
        $ProjectRoot = $repoRoot
        $script:registeredSettings = $null
        Mock Write-AppLog {}
        Mock New-ScheduledTaskAction { [pscustomobject]@{} }
        Mock New-ScheduledTaskTrigger { [pscustomobject]@{ Delay = '' } }
        Mock New-ScheduledTaskSettingsSet { [pscustomobject]@{ Enabled = $true } }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{} }
        Mock Register-ScheduledTask { $script:registeredSettings = $Settings }
    }
    It 'creates disabled settings by default, including on repeat registration' {
        Register-TradingAutostartTask
        $script:registeredSettings.Enabled | Should -Be $false
        Assert-MockCalled Register-ScheduledTask -Scope It -Times 1 -Exactly -ParameterFilter { $Force -and -not $Settings.Enabled }
    }
    It 'enables only with the explicit Enable switch' {
        Register-TradingAutostartTask -Enable
        $script:registeredSettings.Enabled | Should -Be $true
    }
    It 'turns nonterminating registration errors into thrown failures without a Startup fallback' {
        Mock Register-ScheduledTask { Write-Error 'Mock scheduler denied access.' }
        { Register-TradingAutostartTask 2>$null } | Should -Throw
        Assert-MockCalled Write-AppLog -Scope It -Times 0 -Exactly
    }
}

Describe 'Manual Windows autologon reports registry failures truthfully' {
    BeforeEach {
        $ProjectRoot = $TestDrive
        $script:registryWrites = New-Object 'System.Collections.Generic.List[string]'
        $script:resultText = ''
        Mock Test-Path { $true }
        Mock New-Item {}
        Mock Get-ItemProperty { [pscustomobject]@{} }
        Mock Remove-ItemProperty {}
        Mock Set-ItemProperty { $script:registryWrites.Add("$Name=$Value") }
        Mock New-ItemProperty {}
        Mock Set-Content { $script:resultText = "$Value" }
    }
    It 'enables last, after all credential and passwordless writes succeed' {
        Set-WindowsAutologon -UserEmail 'test@example.invalid' -Password 'not-a-real-password'
        $script:registryWrites[0] | Should -Be 'AutoAdminLogon=0'
        $script:registryWrites[$script:registryWrites.Count - 1] | Should -Be 'AutoAdminLogon=1'
        $script:resultText | Should -Match '^OK enabled'
    }
    It 'does not report success when a registry write emits a nonterminating error' {
        Mock Set-ItemProperty { Write-Error 'Mock registry denied access.' }
        { Set-WindowsAutologon -UserEmail 'test@example.invalid' -Password 'not-a-real-password' } | Should -Throw
        $script:resultText | Should -Match '^FAILED:'
        $script:registryWrites.Count | Should -Be 0
    }
    It 'throws rather than swallowing a credential-removal failure while disabling' {
        Mock Get-ItemProperty { [pscustomobject]@{ DefaultPassword = 'fake' } }
        Mock Remove-ItemProperty { Write-Error 'Mock registry removal denied.' }
        { Set-WindowsAutologon -Disable } | Should -Throw
        $script:resultText | Should -Match '^FAILED:'
    }
    It 'treats an absent credential property as benign without suppressing provider errors' {
        Set-WindowsAutologon -Disable
        $script:resultText | Should -Match '^OK disabled'
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
    }
    It 'does not enable when the passwordless provider fails' {
        Mock New-ItemProperty { Write-Error 'Mock passwordless key failure.' }
        { Set-WindowsAutologon -UserEmail 'test@example.invalid' -Password 'not-a-real-password' } | Should -Throw
        @($script:registryWrites) -contains 'AutoAdminLogon=1' | Should -Be $false
        $script:resultText | Should -Match '^FAILED:'
    }
    It 'validates credentials before registry modification' {
        { Set-WindowsAutologon -UserEmail 'test@example.invalid' } | Should -Throw
        Assert-MockCalled Set-ItemProperty -Scope It -Times 0 -Exactly
    }
}
