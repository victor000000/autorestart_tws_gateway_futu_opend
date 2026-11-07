# Offline documentation checks; no vendor/runtime/credential access.
[CmdletBinding()]
param([string]$ProjectPath)
if (-not $ProjectPath) { $ProjectPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ProjectPath)
$files = @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File)
$docs = Join-Path $root 'docs'
if (Test-Path -LiteralPath $docs -PathType Container) {
    $files += @(Get-ChildItem -LiteralPath $docs -Filter '*.md' -File -Recurse)
}
if ($files.Count -eq 0) { throw 'No owned Markdown documentation found.' }
$failures = New-Object 'System.Collections.Generic.List[string]'
$anchors = @{}
foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($block in [regex]::Matches($text, '(?ms)^```powershell[^\r\n]*\r?\n(.*?)^```')) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$errors)
        foreach ($errorItem in $errors) { $failures.Add("$($file.Name): PowerShell example: $($errorItem.Message)") }
    }
    $plain = [regex]::Replace($text, '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*', '')
    $ids = @(); $seen = @{}
    foreach ($heading in [regex]::Matches($plain, '(?m)^#{1,6}\s+(.+?)\s*#*\s*$')) {
        $slug = $heading.Groups[1].Value.ToLowerInvariant() -replace '[^\p{L}\p{N}_ -]', '' -replace ' ', '-'
        $id = $slug
        if ($seen.ContainsKey($slug)) { $seen[$slug]++; $id = "$slug-$($seen[$slug])" } else { $seen[$slug] = 0 }
        $ids += $id
    }
    $anchors[$file.FullName] = $ids
}
$links = 0
foreach ($file in $files) {
    $text = [regex]::Replace([IO.File]::ReadAllText($file.FullName), '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*', '')
    foreach ($link in [regex]::Matches($text, '\[[^\]\r\n]*\]\(([^)\s]+)\)')) {
        $target = [Uri]::UnescapeDataString($link.Groups[1].Value.Trim([char[]]'<>'))
        if ($target -match '^(?:[a-z]+:|//)') { continue }
        $links++
        $parts = $target -split '#', 2
        $path = if ($parts[0]) { [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $parts[0])) } else { $file.FullName }
        if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("$($file.Name): link outside repository: $target"); continue
        }
        if (-not (Test-Path -LiteralPath $path)) { $failures.Add("$($file.Name): missing link: $target"); continue }
        if ($parts.Count -eq 2 -and $parts[1] -and $anchors.ContainsKey($path) -and $anchors[$path] -notcontains $parts[1]) {
            $failures.Add("$($file.Name): missing anchor: $target")
        }
    }
    foreach ($command in [regex]::Matches($text, '`([a-z][\w-]+\.ps1)`', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $name = $command.Groups[1].Value
        if (-not (Test-Path -LiteralPath (Join-Path $root $name)) -and -not (Test-Path -LiteralPath (Join-Path $root "tools/$name"))) {
            $failures.Add("$($file.Name): missing command reference: $name")
        }
    }
}
if ($failures.Count) { throw ("Documentation checks failed:`n" + ($failures -join "`n")) }
Write-Host "Documentation checks passed: $($files.Count) Markdown files, $links relative links, PowerShell examples parsed without execution."
