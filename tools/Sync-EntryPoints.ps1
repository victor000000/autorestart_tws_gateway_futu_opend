# Regenerate thin entry points after changing an implementation's parameters.
[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'config/entrypoints.psd1')
$encoding = New-Object Text.UTF8Encoding($true)
foreach ($name in ($manifest.Keys | Sort-Object)) {
    $relative = $manifest[$name]
    $implementation = Join-Path $root $relative
    if ($relative -like 'src/*') {
        $content = "# Compatibility bridge; implementation lives in src/.`n. (Join-Path `$PSScriptRoot '$relative')`n"
    }
    else {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($implementation, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Cannot generate a wrapper for invalid source: $relative" }
        $declaration = ''
        if ($ast.ParamBlock) { $declaration = $ast.ParamBlock.Extent.Text + "`n" }
        $content = @"
# Compatibility entry point. Edit the implementation, then run tools/Sync-EntryPoints.ps1.
$declaration`$ErrorActionPreference = 'Stop'
try {
    & (Join-Path `$PSScriptRoot '$relative') @PSBoundParameters @args
    if (-not `$?) { exit 1 }
}
catch {
    Write-Error `$_ -ErrorAction Continue
    exit 1
}
"@ + "`n"
    }
    $path = Join-Path $root $name
    if ($Check) {
        if ([IO.File]::ReadAllText($path).Replace("`r`n", "`n") -cne $content) {
            throw "Compatibility wrapper is stale: $name. Run tools/Sync-EntryPoints.ps1."
        }
    }
    else { [IO.File]::WriteAllText($path, $content, $encoding) }
}
