<#
.SYNOPSIS
  IExpress-compatible safe JARVIS NEXUS desktop setup.

.DESCRIPTION
  Windows may persist an applied custom theme as Custom.theme even when it
  was launched from a named .theme file. This module verifies the durable
  wallpaper reference rather than treating that normal Windows behaviour as
  an installation failure.
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Status')]
    [string]$Mode = 'Apply'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
$SourceWallpaper = Join-Path $AppRoot 'assets\nexus-command-deck-wallpaper.png'
$TargetDirectory = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'JARVIS-NEXUS'
$TargetWallpaper = Join-Path $TargetDirectory 'nexus-command-deck-wallpaper.png'
$ThemeDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
$ThemePath = Join-Path $ThemeDirectory 'JARVIS-NEXUS-SAFE.theme'
$ThemesRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
$PersonalizeRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-CurrentWallpaper {
    return (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper
}

function Test-ThemeWallpaperReference([string]$CurrentTheme) {
    if ([string]::Equals($CurrentTheme, $ThemePath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::IsNullOrWhiteSpace($CurrentTheme) -or -not (Test-Path -LiteralPath $CurrentTheme -PathType Leaf)) { return $false }
    try {
        $text = Get-Content -LiteralPath $CurrentTheme -Raw
        $desktop = [regex]::Match($text, '(?ms)^\[Control Panel\\Desktop\]\s*(?<body>.*?)(?=^\[|\z)')
        if (-not $desktop.Success) { return $false }
        $wallpaper = [regex]::Match($desktop.Groups['body'].Value, '(?mi)^\s*Wallpaper\s*=\s*(?<value>.+?)\s*$')
        if (-not $wallpaper.Success) { return $false }
        $reference = $wallpaper.Groups['value'].Value.Trim().Trim('"')
        $expanded = [Environment]::ExpandEnvironmentVariables($reference)
        return [string]::Equals($expanded, $TargetWallpaper, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-DarkMode {
    $personalize = Get-ItemProperty -LiteralPath $PersonalizeRegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $personalize) { return $false }
    $apps = $personalize.PSObject.Properties['AppsUseLightTheme']
    $system = $personalize.PSObject.Properties['SystemUsesLightTheme']
    return $null -ne $apps -and $null -ne $system -and [int]$apps.Value -eq 0 -and [int]$system.Value -eq 0
}

if ($Mode -eq 'Status') {
    [pscustomobject]@{
        SourceExists = Test-Path -LiteralPath $SourceWallpaper -PathType Leaf
        DurableWallpaper = $TargetWallpaper
        DurableWallpaperExists = Test-Path -LiteralPath $TargetWallpaper -PathType Leaf
        CurrentWallpaper = Get-CurrentWallpaper
        CurrentTheme = (Get-ItemProperty -LiteralPath $ThemesRegistryPath -ErrorAction SilentlyContinue).CurrentTheme
        ThemePath = $ThemePath
        DarkMode = Test-DarkMode
    } | Format-List
    exit 0
}

if (-not (Test-Path -LiteralPath $SourceWallpaper -PathType Leaf)) { throw "NEXUS wallpaper source is missing: $SourceWallpaper" }
New-Item -ItemType Directory -Path $TargetDirectory, $ThemeDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $TargetWallpaper -PathType Leaf) -or (Get-Sha256 $SourceWallpaper) -ne (Get-Sha256 $TargetWallpaper)) {
    Copy-Item -LiteralPath $SourceWallpaper -Destination $TargetWallpaper -Force
}

$themeText = @"
; JARVIS NEXUS per-user theme. Wallpaper path is intentionally durable.
[Theme]
DisplayName=JARVIS NEXUS
ThemeId={$([guid]::NewGuid().ToString().ToUpperInvariant())}

[Control Panel\Desktop]
Wallpaper=$TargetWallpaper
Pattern=
MultimonBackgrounds=0
PicturePosition=4

[Control Panel\Colors]
Background=5 10 20

[VisualStyles]
Path=%SystemRoot%\resources\themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
AutoColorization=0
ColorizationColor=0xC400FFFF
SystemMode=Dark
AppMode=Dark

[MasterThemeSelector]
MTSM=RJSPBS
"@
Set-Content -LiteralPath $ThemePath -Value $themeText -Encoding utf8

New-Item -Path $PersonalizeRegistryPath -Force | Out-Null
Set-ItemProperty -LiteralPath $PersonalizeRegistryPath -Name AppsUseLightTheme -Type DWord -Value 0
Set-ItemProperty -LiteralPath $PersonalizeRegistryPath -Name SystemUsesLightTheme -Type DWord -Value 0

if (-not ('NexusWallpaperNativeV3' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
public static class NexusWallpaperNativeV3 {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);
}
'@
}
if (-not [NexusWallpaperNativeV3]::SystemParametersInfo(20, 0, $TargetWallpaper, 3)) {
    throw "Windows rejected wallpaper update. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

Start-Process -FilePath $ThemePath -Wait
$active = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $currentWallpaper = Get-CurrentWallpaper
    $currentTheme = (Get-ItemProperty -LiteralPath $ThemesRegistryPath -ErrorAction SilentlyContinue).CurrentTheme
    if ([string]::Equals($currentWallpaper, $TargetWallpaper, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-ThemeWallpaperReference $currentTheme) -and (Test-DarkMode)) {
        $active = $true
        break
    }
    Start-Sleep -Milliseconds 200
}
if (-not $active) { throw 'Windows did not activate the verified NEXUS wallpaper and dark theme.' }
Write-Host "JARVIS NEXUS desktop is active: $TargetWallpaper"
