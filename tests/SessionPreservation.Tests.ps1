# Pester fixtures never execute dependency imports or real application launches.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/common.ps1')
    foreach ($name in @('tws', 'ibkr-desktop')) {
        $text = [IO.File]::ReadAllText((Join-Path $script:Root "scripts/apps/start-$name.ps1"))
        $body = $text -replace '(?m)^\. \(Join-Path[^\r\n]+\r?\n', ''
        Set-Variable -Name ($name.Replace('-', '') + 'Starter') -Value ([scriptblock]::Create($body)) -Scope Script
    }
}

Describe 'IBKR starters preserve sessions before any launch or credential access' {
    BeforeEach {
        Mock Write-AppLog {}
        Mock Get-Process { @() }
        Mock Get-IbcProcesses { @() }
        Mock Get-IbSessionProcesses { @() }
        Mock Get-IbkrDesktopProcesses { @() }
        Mock New-IbcConfig { throw 'Credential access forbidden in fixtures' }
        Mock Start-Process { throw 'Application launch forbidden in fixtures' }
        Mock Start-ManagedApplication { throw 'Application launch forbidden in fixtures' }
        Mock Stop-IbSessionProcesses { throw 'Session shutdown forbidden in fixtures' }
        Mock Stop-IbkrDesktopProcesses { throw 'Session shutdown forbidden in fixtures' }
    }
    It 'blocks TWS before reading credentials or starting a process when Desktop runs' {
        Mock Get-IbkrDesktopProcesses { [pscustomobject]@{ Id = 10 } }
        { & $script:twsStarter } | Should -Throw '*Existing clients were preserved*'
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke New-IbcConfig -Times 0 -Exactly
        Should -Invoke Stop-IbkrDesktopProcesses -Times 0 -Exactly
    }
    It 'blocks Desktop before launch when TWS or Gateway runs' {
        Mock Get-IbSessionProcesses { [pscustomobject]@{ Id = 20 } }
        { & $script:ibkrdesktopStarter } | Should -Throw '*Existing clients were preserved*'
        Should -Invoke Start-ManagedApplication -Times 0 -Exactly
        Should -Invoke Stop-IbSessionProcesses -Times 0 -Exactly
    }
    It 'reuses an existing TWS without attempting credentials or stopping Desktop' {
        Mock Get-Process { [pscustomobject]@{ Id = 30 } }
        & $script:twsStarter
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke New-IbcConfig -Times 0 -Exactly
        Should -Invoke Get-IbkrDesktopProcesses -Times 0 -Exactly
        Should -Invoke Stop-IbkrDesktopProcesses -Times 0 -Exactly
    }
    It 'reuses an existing Desktop without checking or closing competing sessions' {
        Mock Get-Process { [pscustomobject]@{ Id = 40 } }
        Mock Start-ManagedApplication {}
        & $script:ibkrdesktopStarter
        Should -Invoke Get-IbSessionProcesses -Times 0 -Exactly
        Should -Invoke Stop-IbSessionProcesses -Times 0 -Exactly
        Should -Invoke Start-ManagedApplication -Times 1 -Exactly
    }
}
