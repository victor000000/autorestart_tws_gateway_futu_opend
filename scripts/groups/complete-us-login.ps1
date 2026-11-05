# UI-login workers run sequentially because they share the physical desktop.
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src/common.ps1')
$failures = @()
foreach ($name in @('login-futubull.ps1', 'login-thinkorswim.ps1')) {
    try {
        $worker = Start-ProjectScript -Name $name -PassThru
        Wait-ProjectProcesses -Processes @($worker) -TimeoutSeconds 600
    }
    catch { $failures += $name }
}
if ($failures.Count) { throw "Login workers require attention: $($failures -join ', '). See local logs." }
