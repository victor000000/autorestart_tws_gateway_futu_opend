# Lists UI Automation elements by control type (e.g. MenuItem, Button, Edit).
# Example: powershell -File uia-list.ps1 -ControlType MenuItem

[CmdletBinding()]
param(
    [string]$ControlType = 'MenuItem',
    [int]$Limit = 40
)

$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$ct = [System.Windows.Automation.ControlType]::$ControlType
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
$items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
"count: $($items.Count)"
$i = 0
foreach ($e in $items) {
    if ($i -ge $Limit) { break }
    $r = $e.Current.BoundingRectangle
    "[$i] '$($e.Current.Name)' id='$($e.Current.AutomationId)' rect=$([int]$r.X),$([int]$r.Y) $([int]$r.Width)x$([int]$r.Height)"
    $i++
}
