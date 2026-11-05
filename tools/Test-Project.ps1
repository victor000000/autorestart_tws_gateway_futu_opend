#Requires -Version 5.1
<#
.SYNOPSIS
Run offline encoding, parser, analyzer, and Pester checks without starting apps.
.DESCRIPTION
Dependencies must first be installed explicitly with Install-TestDependencies.ps1.
Only the pinned manifests under ModulesPath are imported; Windows' bundled
Pester 3 is never used. No modules are installed by this runner. Test reports
contain synthetic fixture results and are written only under test-results/.
.PARAMETER SkipAnalyzer
Run the other checks without requiring PSScriptAnalyzer (local diagnosis only).
.PARAMETER SkipTests
Run the static checks without requiring Pester (local diagnosis only).
#>
[CmdletBinding()]
param(
    [string]$ModulesPath,
    [switch]$SkipAnalyzer,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ModulesPath) { $ModulesPath = Join-Path $projectRoot '.tools/Modules' }
$ModulesPath = [System.IO.Path]::GetFullPath($ModulesPath)
$dependencies = @()
if (-not $SkipAnalyzer) {
    $dependencies += @{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
}
if (-not $SkipTests) {
    $dependencies += @{ Name = 'Pester'; Version = '5.7.1' }
}
foreach ($dependency in $dependencies) {
    $manifest = Join-Path $ModulesPath ('{0}/{1}/{0}.psd1' -f $dependency.Name, $dependency.Version)
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Missing pinned $($dependency.Name) $($dependency.Version) at '$manifest'. Explicitly run tools/Install-TestDependencies.ps1 -ModulesPath '$ModulesPath' first. No dependency was installed."
    }
    $metadata = Import-PowerShellDataFile -LiteralPath $manifest
    if ([version]$metadata.ModuleVersion -ne [version]$dependency.Version) {
        throw "Wrong module version at '$manifest'; expected $($dependency.Version)."
    }
    Import-Module -Name $manifest -Force -ErrorAction Stop
    $loaded = Get-Module -Name $dependency.Name | Where-Object {
        $_.Version -eq [version]$dependency.Version -and
        [System.IO.Path]::GetFullPath($_.ModuleBase) -eq (Split-Path -Parent $manifest)
    }
    if (-not $loaded) { throw "Failed to import the pinned module from '$manifest'." }
}

# Scan only first-party PowerShell files, never private runtime/vendor trees.
# Files are parsed as text, not invoked or dot-sourced.
$extensions = @('.ps1', '.psm1', '.psd1')
$files = @(
    Get-ChildItem -LiteralPath $projectRoot -File | Where-Object { $_.Extension -in $extensions }
    foreach ($directory in @('src', 'scripts', 'config', 'tools', 'tests')) {
        $path = Join-Path $projectRoot $directory
        if (Test-Path -LiteralPath $path -PathType Container) {
            Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object {
                $_.Extension -in $extensions -and
                $_.FullName -notmatch '[\\/](?:\.git|\.tools|test-results|secrets|logs|ibc|ibc-source|node_modules|\.venv)[\\/]'
            }
        }
    }
) | Sort-Object -Property FullName -Unique
if (-not $files) { throw 'No first-party PowerShell files were found.' }

$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$staticFailures = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($projectRoot.Length + 1)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $staticFailures.Add("$relativePath must be UTF-8 with a BOM (Windows PowerShell 5.1 compatibility).")
        continue
    }
    try {
        $text = $strictUtf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    catch {
        $staticFailures.Add("$relativePath is not valid UTF-8: $($_.Exception.Message)")
        continue
    }
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($text, $file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        $staticFailures.Add(('{0}:{1}: {2}' -f $relativePath, $parseError.Extent.StartLineNumber, $parseError.Message))
    }
}
if ($staticFailures.Count -gt 0) {
    throw ("Encoding/parser validation failed:`n" + ($staticFailures -join "`n"))
}
Write-Host "Strict UTF-8 BOM and parser checks passed for $(@($files).Count) first-party files."
& (Join-Path $PSScriptRoot 'Sync-EntryPoints.ps1') -Check
Write-Host 'Compatibility wrappers match implementation parameters.'

if (-not $SkipAnalyzer) {
    $settingsPath = Join-Path $projectRoot 'config/PSScriptAnalyzerSettings.psd1'
    $diagnostics = @(
        foreach ($file in $files) {
            PSScriptAnalyzer\Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath -ErrorAction Stop
        }
    )
    if ($diagnostics.Count -gt 0) {
        $diagnostics | Select-Object ScriptName, Line, Severity, RuleName, Message | Format-Table -AutoSize | Out-Host
        throw "PSScriptAnalyzer found $($diagnostics.Count) diagnostic(s)."
    }
    Write-Host 'PSScriptAnalyzer passed the project rule set.'
}

if (-not $SkipTests) {
    $testsPath = Join-Path $projectRoot 'tests'
    if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) { throw "Missing tests directory '$testsPath'." }
    $resultsPath = Join-Path $projectRoot 'test-results'
    New-Item -ItemType Directory -Path $resultsPath -Force | Out-Null
    $engine = '{0}-{1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion.Major
    $configuration = Pester\New-PesterConfiguration
    $configuration.Run.Path = $testsPath
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $resultsPath "pester-$engine.xml"
    $result = Pester\Invoke-Pester -Configuration $configuration
    if ($result.TotalCount -eq 0 -or $result.Result -ne 'Passed') {
        throw "Pester did not pass: $($result.FailedCount) failed, $($result.TotalCount) total, status $($result.Result)."
    }
    Write-Host "Pester passed: $($result.PassedCount) tests. Synthetic report: $($configuration.TestResult.OutputPath.Value)"
}
