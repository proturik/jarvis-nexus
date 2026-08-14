<#!
.SYNOPSIS
  Совместимый вход темы NEXUS ULTRA.

.DESCRIPTION
  Apply и Restore делегируются исходному безопасному скрипту. Status исправляет
  отображение Windows DWORD-акцента на системах, где PowerShell читает его как
  отрицательный Int32. Никакие параметры не меняются при -Mode Status.
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

$accentHex = if ($null -eq $accentRaw) {
    'System default'
} else {
    $bytes = [BitConverter]::GetBytes([int]$accentRaw)
    '0x{0:X8}' -f [BitConverter]::ToUInt32($bytes, 0)
}

[pscustomobject]@{
    BackupExists = Test-Path -LiteralPath $backupPath
    AppsDarkMode = $appsDark -eq 0
    AccentColor = $accentHex
    Mode = 'Status only — no Windows settings were changed'
} | Format-List
