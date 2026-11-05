# UI Automation helper: locate elements by AutomationId or Name and optionally
# invoke them. Useful for Chromium/Electron apps whose windows do not accept
# synthetic clicks reliably.
#
# Examples:
#   powershell -File uia-helper.ps1 -AutomationId main-menu-button -Invoke
#   powershell -File uia-helper.ps1 -Name "Settings"

[CmdletBinding()]
param(
    [string]$AutomationId,
    [string]$Name,
    [switch]$Invoke,
    [int]$ProcessId = 0,
    [ValidateRange(1, 1000)][int]$Limit = 10
)

$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if ($Invoke -and $ProcessId -le 0) { throw '-Invoke requires an explicit -ProcessId.' }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = [System.Windows.Automation.AutomationElement]::RootElement

if ($AutomationId) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutomationId)
}
elseif ($Name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
}
else {
    throw 'Specify -AutomationId or -Name'
}

if ($ProcessId -gt 0) {
    $processCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $cond = New-Object System.Windows.Automation.AndCondition($cond, $processCondition)
}
$found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
if ($Invoke -and $found.Count -ne 1) { throw "Invocation requires exactly one match; found $($found.Count)." }
$i = 0
foreach ($el in $found) {
    if ($i -ge $Limit) { break }
    $r = $el.Current.BoundingRectangle
    "[$i] Name='$($el.Current.Name)' Class='$($el.Current.ClassName)' Id='$($el.Current.AutomationId)' Rect=$([int]$r.X),$([int]$r.Y) $([int]$r.Width)x$([int]$r.Height)"
    if ($Invoke) {
        try {
            $p = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $p.Invoke()
            '   -> Invoked'
        }
        catch {
            throw 'The selected UI element could not be invoked.'
        }
    }
    $i++
}
if ($found.Count -eq 0) { 'no match' }
