<#!
.SYNOPSIS
  Синхронизирует личные настройки Windows с палитрой JARVIS NEXUS.

.DESCRIPTION
  Скрипт меняет только HKCU-настройки текущего пользователя: тёмный режим,
  прозрачность и акцентные цвета. Перед первым применением он сохраняет
  исходные значения в data\windows-theme-backup.json. Обои, приложения и
  системные службы не затрагиваются.
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Restore', 'Status')]
    [string]$Mode = 'Apply'
)

$ErrorActionPreference = 'Stop'
$ThemeDataDirectory = Join-Path $PSScriptRoot '..\data'
$BackupPath = Join-Path $ThemeDataDirectory 'windows-theme-backup.json'
$PersonalizePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$DwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'
$AccentPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'

$TrackedValues = @(
    @{ Path = $PersonalizePath; Name = 'AppsUseLightTheme' },
    @{ Path = $PersonalizePath; Name = 'SystemUsesLightTheme' },
    @{ Path = $PersonalizePath; Name = 'EnableTransparency' },
    @{ Path = $PersonalizePath; Name = 'ColorPrevalence' },
    @{ Path = $DwmPath; Name = 'ColorPrevalence' },
    @{ Path = $DwmPath; Name = 'AccentColor' },
    @{ Path = $DwmPath; Name = 'AccentColorInactive' },
    @{ Path = $AccentPath; Name = 'AccentPalette' },
    @{ Path = $AccentPath; Name = 'StartColorMenu' },
    @{ Path = $AccentPath; Name = 'AccentColorMenu' }
)

function Get-RegistrySnapshot {
    $snapshot = foreach ($tracked in $TrackedValues) {
        $key = Get-Item -LiteralPath $tracked.Path -ErrorAction SilentlyContinue
        if ($null -eq $key) {
            [pscustomobject]@{ Path = $tracked.Path; Name = $tracked.Name; Exists = $false; Kind = $null; Value = $null }
            continue
        }

        $rawValue = $key.GetValue($tracked.Name, $null, 'DoNotExpandEnvironmentNames')
        if ($null -eq $rawValue) {
            [pscustomobject]@{ Path = $tracked.Path; Name = $tracked.Name; Exists = $false; Kind = $null; Value = $null }
            continue
        }

        $kind = $key.GetValueKind($tracked.Name).ToString()
        $serialisedValue = if ($rawValue -is [byte[]]) { [Convert]::ToBase64String($rawValue) } else { $rawValue }
        [pscustomobject]@{ Path = $tracked.Path; Name = $tracked.Name; Exists = $true; Kind = $kind; Value = $serialisedValue }
    }
    return @($snapshot)
}

function Save-Backup {
    if (Test-Path -LiteralPath $BackupPath) { return }
    New-Item -ItemType Directory -Path $ThemeDataDirectory -Force | Out-Null
    [pscustomobject]@{
        CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Values = Get-RegistrySnapshot
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    Write-Host "Backup saved: $BackupPath"
}

function Set-Value([string]$Path, [string]$Name, [object]$Value, [string]$Type) {
    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Apply-NexusTheme {
    Save-Backup

    # Same palette as the JARVIS panel: Electric Cyan, Neon Orange and Electric Purple.
    Set-Value $PersonalizePath 'AppsUseLightTheme' 0 'DWord'
    Set-Value $PersonalizePath 'SystemUsesLightTheme' 0 'DWord'
    Set-Value $PersonalizePath 'EnableTransparency' 1 'DWord'
    Set-Value $PersonalizePath 'ColorPrevalence' 1 'DWord'
    Set-Value $DwmPath 'ColorPrevalence' 1 'DWord'
    Set-Value $DwmPath 'AccentColor' 0xFF00FFFF 'DWord'          # cyan in Windows ABGR
    Set-Value $DwmPath 'AccentColorInactive' 0xFFFF00AD 'DWord' # purple in Windows ABGR

    $nexusPalette = [byte[]](
        0xFF, 0xFF, 0x00, 0x00, # Electric Cyan
        0xFF, 0x00, 0x6E, 0xFF, # Neon Orange
        0xFF, 0xFF, 0x00, 0xAD, # Electric Purple
        0xFF, 0xFF, 0x00, 0xFF, # Hot Magenta
        0xFF, 0x14, 0xFF, 0x39, # Neon Green
        0xFF, 0xEE, 0xE7, 0x64, # Soft Cyan
        0xFF, 0x9A, 0x57, 0x2A, # Deep Blue
        0xFF, 0x19, 0x0D, 0x07  # NEXUS Dark
    )
    Set-Value $AccentPath 'AccentPalette' $nexusPalette 'Binary'
    Set-Value $AccentPath 'StartColorMenu' 0xFF00FFFF 'DWord'
    Set-Value $AccentPath 'AccentColorMenu' 0xFF00FFFF 'DWord'

    # Ask Windows to refresh personalisation without killing Explorer or closing folders.
    Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden -Wait
    Write-Host 'JARVIS NEXUS theme applied: dark mode, transparency and cyan/purple accent.'
}

function Restore-NexusTheme {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        throw "Backup not found: $BackupPath"
    }
    $backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    foreach ($entry in $backup.Values) {
        New-Item -Path $entry.Path -Force | Out-Null
        if (-not $entry.Exists) {
            Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
            continue
        }
        $value = if ($entry.Kind -eq 'Binary') { [Convert]::FromBase64String([string]$entry.Value) } else { $entry.Value }
        Set-Value $entry.Path $entry.Name $value $entry.Kind
    }
    Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden -Wait
    Write-Host 'Previous Windows theme values restored from the JARVIS backup.'
}

function Show-NexusStatus {
    $snapshot = Get-RegistrySnapshot
    $accent = $snapshot | Where-Object { $_.Path -eq $DwmPath -and $_.Name -eq 'AccentColor' }
    $darkMode = $snapshot | Where-Object { $_.Path -eq $PersonalizePath -and $_.Name -eq 'AppsUseLightTheme' }
    [pscustomobject]@{
        BackupExists = Test-Path -LiteralPath $BackupPath
        AppsDarkMode = $darkMode.Value -eq 0
        AccentColor = if ($accent.Exists) { ('0x{0:X8}' -f [uint32]$accent.Value) } else { 'System default' }
    } | Format-List
}

switch ($Mode) {
    'Apply' { Apply-NexusTheme }
    'Restore' { Restore-NexusTheme }
    'Status' { Show-NexusStatus }
}
