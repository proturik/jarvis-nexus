<#!
.SYNOPSIS
  Финальный совместимый вход темы NEXUS для Windows DWORD-акцентов.
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Restore', 'Status')]
    [string]$Mode = 'Status'
)

$ErrorActionPreference = 'Stop'
$OriginalScript = Join-Path $PSScriptRoot 'Sync-Nexus-Theme.ps1'
if ($Mode -ne 'Status') {
    & $OriginalScript -Mode $Mode
    exit $LASTEXITCODE
}

$backupPath = Join-Path $PSScriptRoot '..\data\windows-theme-backup.json'
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
$appsDark = (Get-ItemProperty -LiteralPath $personalize -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue).AppsUseLightTheme
$accentRaw = (Get-ItemProperty -LiteralPath $dwm -Name 'AccentColor' -ErrorAction SilentlyContinue).AccentColor

if ($null -eq $accentRaw) {
    $accentHex = 'System default'
} else {
    $accentNumber = [Int64]$accentRaw
    if ($accentNumber -lt 0) { $accentNumber += 4294967296 }
    $accentHex = '0x{0:X8}' -f [UInt32]$accentNumber
}

[pscustomobject]@{
    BackupExists = Test-Path -LiteralPath $backupPath
    AppsDarkMode = $appsDark -eq 0
    AccentColor = $accentHex
    Mode = 'Status only — no Windows settings were changed'
} | Format-List
