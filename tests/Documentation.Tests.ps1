BeforeAll {
    $script:Checker = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Test-Documentation.ps1'
}
Describe 'Offline documentation validation' {
    BeforeEach {
        $script:Fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path (Join-Path $Fixture 'docs') -Force
    }
    It 'accepts local heading links and never follows an external URL' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '# Guide', '[part](docs/part.md#some-heading)', '[outside](https://invalid.example)'
        Set-Content -LiteralPath (Join-Path $Fixture 'docs/part.md') -Encoding UTF8 -Value '# Some heading'
        { & $Checker -ProjectPath $Fixture } | Should -Not -Throw
    }
    It 'rejects a missing relative file' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '[missing](docs/absent.md)'
        { & $Checker -ProjectPath $Fixture } | Should -Throw '*missing link*'
    }
    It 'rejects an incorrect heading anchor' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '# Guide', '[missing](#wrong)'
        { & $Checker -ProjectPath $Fixture } | Should -Throw '*missing anchor*'
    }
    It 'rejects an unknown inline command' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '`missing-tool.ps1`'
        { & $Checker -ProjectPath $Fixture } | Should -Throw '*missing command*'
    }
    It 'parses PowerShell fences without executing their commands' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '```powershell', 'throw "Must not execute"', '```'
        { & $Checker -ProjectPath $Fixture } | Should -Not -Throw
    }
    It 'rejects invalid PowerShell example syntax' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '```powershell', 'if (', '```'
        { & $Checker -ProjectPath $Fixture } | Should -Throw '*PowerShell example*'
    }
    It 'handles duplicate headings with GitHub suffixes' {
        Set-Content -LiteralPath (Join-Path $Fixture 'README.md') -Encoding UTF8 -Value '# Guide', '# Guide', '[second](#guide-1)'
        { & $Checker -ProjectPath $Fixture } | Should -Not -Throw
    }
}
