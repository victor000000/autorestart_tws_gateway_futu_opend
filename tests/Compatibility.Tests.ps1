BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepositoryRoot 'src/common.ps1')
}

Describe 'Group contracts and worker results' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Start-Sleep {}
        Mock Start-ProjectScript { [pscustomobject]@{Id=123} }
        Mock Wait-ProjectProcesses {}
    }
    It 'starts maintenance API applications and OBS recording' {
        Invoke-AppGroup -Name maintenance
        Should -Invoke Start-ProjectScript -Times 3
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'start-futu-opend.ps1' }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'start-ibgateway.ps1' }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'start-obs.ps1' }
        Should -Invoke Wait-ProjectProcesses -Times 0
    }
    It 'uses TWS instead of IBKR Desktop and serializes US logins' {
        Invoke-AppGroup -Name us
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'start-tws.ps1' }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'complete-us-login.ps1' }
        Should -Invoke Start-ProjectScript -Times 0 -ParameterFilter { $Name -eq 'start-ibkr-desktop.ps1' }
        Should -Invoke Start-ProjectScript -Times 0 -ParameterFilter { $Name -eq 'login-thinkorswim.ps1' }
    }
    It 'waits and aggregates workers only when requested' {
        Invoke-AppGroup -Name maintenance -Wait
        Should -Invoke Wait-ProjectProcesses -Times 1 -ParameterFilter { $Processes.Count -eq 3 }
    }
    It 'propagates a failed dispatch rather than logging success' {
        Mock Start-ProjectScript { throw 'synthetic dispatch failure' }
        { Invoke-AppGroup -Name maintenance } | Should -Throw '*dispatch failure*'
    }
}

Describe 'Process argument quoting and allowed entry points' {
    It 'quotes spaces and empty arguments' {
        ConvertTo-NativeArgument -Value 'a b' | Should -BeExactly '"a b"'
        ConvertTo-NativeArgument -Value '' | Should -BeExactly '""'
    }
    It 'doubles a trailing backslash before its closing quote' {
        ConvertTo-NativeArgument -Value 'C:\space dir\' | Should -BeExactly '"C:\space dir\\"'
    }
    It 'escapes a literal quote' {
        ConvertTo-NativeArgument -Value 'a"b' | Should -BeExactly '"a\"b"'
    }
    It 'rejects multiline and null arguments' {
        { ConvertTo-NativeArgument -Value "x`ny" } | Should -Throw
        { ConvertTo-NativeArgument -Value ("x" + [char]0) } | Should -Throw
    }
    It 'rejects unknown entry points without launching anything' {
        Mock Start-Process { throw 'No real processes allowed' }
        { Start-ProjectScript -Name '../secrets/anything.ps1' } | Should -Throw '*Unknown command*'
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects attempts to execute a dot-source helper as a command' {
        { Start-ProjectScript -Name 'common.ps1' } | Should -Throw '*Unknown command*'
    }
    It 'builds a quoted -File command and explicit working directory' {
        Mock Get-PowerShellExecutable { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        Mock Start-Process { [pscustomobject]@{Id=42} }
        Start-ProjectScript -Name 'start-excel.ps1' -ScriptArguments @('-TimeoutSeconds','12') -PassThru |
            Select-Object -ExpandProperty Id | Should -Be 42
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $ArgumentList -like '*"-File"*"start-excel.ps1"*' -or
            ($ArgumentList -like '*"-File"*' -and $ArgumentList -like '*start-excel.ps1"*' -and $WorkingDirectory -eq $RepositoryRoot)
        }
    }
    It 'never forwards an empty argument to a worker' {
        Mock Get-PowerShellExecutable { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        Mock Start-Process { [pscustomobject]@{Id=43} }
        # An empty suppression result binds as one empty string; the child would
        # read it as a positional value and fail its parameter validation.
        Start-ProjectScript -Name 'start-excel.ps1' -ScriptArguments $null
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $ArgumentList -notmatch '""\s*$' }
    }
}

Describe 'Waiting for inert worker objects' {
    BeforeEach { Mock Get-Date { [datetime]'2026-01-01' } }
    It 'succeeds for workers that exit with zero' {
        $worker = [pscustomobject]@{Id=1;ExitCode=0}
        $worker | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $true }
        $worker | Add-Member ScriptMethod Refresh {}
        { Wait-ProjectProcesses -Processes @($worker) } | Should -Not -Throw
    }
    It 'throws for nonzero worker exits' {
        $worker = [pscustomobject]@{Id=1;ExitCode=7}
        $worker | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $true }
        $worker | Add-Member ScriptMethod Refresh {}
        { Wait-ProjectProcesses -Processes @($worker) } | Should -Throw '*workers failed*'
    }
    It 'throws without killing the app when the wait times out' {
        $worker = [pscustomobject]@{Id=1;ExitCode=$null}
        $worker | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        Mock Stop-Process { throw 'Must not kill applications' }
        { Wait-ProjectProcesses -Processes @($worker) -TimeoutSeconds 1 } | Should -Throw '*deadline*'
        Should -Invoke Stop-Process -Times 0
    }
}

Describe 'Starter auto-login defaults' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Start-Sleep {}
        Mock Wait-ProjectProcesses {}
        Mock Start-ProjectScript { [pscustomobject]@{Id=1} }
    }
    It 'runs the configured login worker for an individual starter' {
        Invoke-AppLogin -Entry 'start-shinny.ps1'
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter {
            $Name -eq 'login-zsqh-clients.ps1' -and ($ScriptArguments -join ' ') -eq '-Apps Q73N'
        }
    }
    It 'does nothing for a starter without a login definition' {
        Invoke-AppLogin -Entry 'start-wh6.ps1'
        Should -Invoke Start-ProjectScript -Times 0
    }
    It 'reports an empty suppression as an empty array, not null' {
        $suppression = Get-LoginSuppression -Entry 'start-excel.ps1' -GroupEntries @('start-excel.ps1')
        ($null -eq $suppression) | Should -BeFalse
        @($suppression).Count | Should -Be 0
    }
    It 'suppresses a starter login already covered by the group worker' {
        Invoke-AppGroup -Name cn
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter {
            $Name -eq 'start-shinny.ps1' -and $ScriptArguments -contains '-NoLogin'
        }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter {
            $Name -eq 'start-yongchun.ps1' -and $ScriptArguments -contains '-NoLogin'
        }
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter { $Name -eq 'login-zsqh-clients.ps1' }
    }
    It 'keeps the starter login in a group without a covering worker' {
        Invoke-AppGroup -Name extra
        Should -Invoke Start-ProjectScript -Times 1 -ParameterFilter {
            $Name -eq 'start-futubull.ps1' -and $ScriptArguments -notcontains '-NoLogin'
        }
    }
}

Describe 'Configured application launch reporting' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Get-LatestAppExecutable { 'C:\fake\Q73N.exe' }
    }
    It 'reports reuse without launching when the process exists' {
        Mock Get-Process { [pscustomobject]@{Id=1} }
        Mock Start-ManagedApplication { throw 'must not launch' }
        Start-ConfiguredApplication -Name 'shinny' -PassThru | Should -BeFalse
    }
    It 'reports a launch when no process exists' {
        Mock Get-Process { $null }
        Mock Start-ManagedApplication {}
        Start-ConfiguredApplication -Name 'shinny' -PassThru | Should -BeTrue
    }
}

Describe 'Compatibility entry points in an inert sandbox' {
    BeforeEach {
        # WSL may inherit PATHEXT=.CPL; native test-host invocation needs .EXE.
        $script:PreviousPathExt = $env:PATHEXT
        $env:PATHEXT = (@('.EXE') + @($env:PATHEXT -split ';') | Select-Object -Unique) -join ';'
        $script:Sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString() + ' with spaces')
        $script:Target = Join-Path $Sandbox 'scripts/apps'
        $null = New-Item -ItemType Directory -Path $Target -Force
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'start-ibkr-desktop.ps1') -Destination $Sandbox
        $script:HostPath = (Get-Process -Id $PID).Path
    }
    AfterEach { $env:PATHEXT = $script:PreviousPathExt }
    It 'forwards named parameters and defaults without running the real implementation' {
        Set-Content -LiteralPath (Join-Path $Target 'start-ibkr-desktop.ps1') -Value 'param([string]$InstallDir = "C:\ntws", [int]$TimeoutSeconds = 60); "$InstallDir|$TimeoutSeconds"' -Encoding UTF8
        $result = & $HostPath -NoProfile -WindowStyle Hidden -File (Join-Path $Sandbox 'start-ibkr-desktop.ps1') -InstallDir 'synthetic path with spaces' -TimeoutSeconds 12
        $LASTEXITCODE | Should -Be 0
        $result | Should -BeExactly 'synthetic path with spaces|12'
    }
    It 'returns a nonzero exit for a failed implementation' {
        Set-Content -LiteralPath (Join-Path $Target 'start-ibkr-desktop.ps1') -Value 'param([string]$InstallDir, [int]$TimeoutSeconds); throw "synthetic failure"' -Encoding UTF8
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $null = & $HostPath -NoProfile -WindowStyle Hidden -File (Join-Path $Sandbox 'start-ibkr-desktop.ps1') 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        $exitCode | Should -Be 1
    }
}
