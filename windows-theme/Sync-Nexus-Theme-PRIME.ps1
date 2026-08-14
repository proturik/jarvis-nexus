<#
.SYNOPSIS
  Надёжный вход для синхронизации Windows с оформлением JARVIS NEXUS.

.DESCRIPTION
  Использует исходный скрипт для палитры и резервной копии, затем повторно
  задаёт три режима интерфейса через reg.exe. Это обход поведения некоторых
  сборок Windows, которые могут удалить эти DWORD после обновления темы.
  Меняются только параметры HKCU текущего пользователя.
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Restore', 'Status')]
    [string]$Mode = 'Status'
)

$ErrorActionPreference = 'Stop'
$OriginalScript = Join-Path $PSScriptRoot 'Sync-Nexus-Theme.ps1'
$PersonalizeKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$BackupPath = Join-Path $PSScriptRoot '..\data\windows-theme-backup.json'

function Get-Dword([string]$Name) {
    $value = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($null -eq $value) { return $null }
    return [int]$value
}

if ($Mode -eq 'Restore') {
    & $OriginalScript -Mode Restore
    exit $LASTEXITCODE
}

if ($Mode -eq 'Status') {
    [pscustomobject]@{
        BackupExists = Test-Path -LiteralPath $BackupPath
        AppsDarkMode = (Get-Dword 'AppsUseLightTheme') -eq 0
        SystemDarkMode = (Get-Dword 'SystemUsesLightTheme') -eq 0
        Transparency = (Get-Dword 'EnableTransparency') -eq 1
        Mode = 'Status only — no Windows settings were changed'
    } | Format-List
    exit 0
}

# The original script takes the one-time backup and applies NEXUS palette values.
& $OriginalScript -Mode Apply
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

foreach ($entry in @(
    @{ Name = 'AppsUseLightTheme'; Value = 0 },
    @{ Name = 'SystemUsesLightTheme'; Value = 0 },
    @{ Name = 'EnableTransparency'; Value = 1 }
)) {
    & reg.exe add $PersonalizeKey /v $entry.Name /t REG_DWORD /d $entry.Value /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Не удалось обновить $($entry.Name)." }
}

Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden -Wait
Write-Host 'JARVIS NEXUS PRIME applied: dark mode, transparency and NEXUS accent are active.'
