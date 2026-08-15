<#
.SYNOPSIS
  Shows a non-blocking Windows tray-balloon notification that a new JARVIS
  NEXUS version is available. UI-only; it never calls the updater.

.DESCRIPTION
  Used for background update checks while JARVIS is already running. The
  balloon stays for -DurationSeconds (default 12) and then the script exits.
  Clicking the balloon icon is non-functional in a plain console script; pair
  this with Show-JarvisUpdatePrompt.ps1 when the user acts on the notification.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-JarvisUpdateNotification.ps1 -CurrentVersion 1.0.1 -NewVersion 1.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CurrentVersion,
    [Parameter(Mandatory)][string]$NewVersion,
    [int]$DurationSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ($DurationSeconds -lt 4 -or $DurationSeconds -gt 300) { throw 'DurationSeconds must be between 4 and 300.' }

$icon = $null
$iconPath = Join-Path $PSScriptRoot '..\assets\jarvis-nexus.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    try { $icon = New-Object System.Drawing.Icon($iconPath) } catch { $icon = $null }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
try {
    $notify.Text = 'JARVIS NEXUS ULTRA'
    $notify.Visible = $true
    if ($null -ne $icon) { $notify.Icon = $icon } else { $notify.Icon = [System.Drawing.SystemIcons]::Information }
    $notify.BalloonTipTitle = 'Доступно обновление JARVIS'
    $notify.BalloonTipText = "Текущая версия: $CurrentVersion`nНовая версия: $NewVersion"
    $notify.BalloonTipIcon = 'Info'
    $notify.ShowBalloonTip($DurationSeconds * 1000)
    Start-Sleep -Seconds $DurationSeconds
} finally {
    try { $notify.Visible = $false } catch { }
    try { $notify.Dispose() } catch { }
    if ($null -ne $icon) { try { $icon.Dispose() } catch { } }
}
