<#
.SYNOPSIS
  IExpress-compatible safe JARVIS NEXUS desktop setup.
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

if ($Mode -eq 'Status') {
    [pscustomobject]@{
        SourceExists = Test-Path -LiteralPath $SourceWallpaper -PathType Leaf
        DurableWallpaper = $TargetWallpaper
        DurableWallpaperExists = Test-Path -LiteralPath $TargetWallpaper -PathType Leaf
        CurrentWallpaper = Get-CurrentWallpaper
        CurrentTheme = (Get-ItemProperty -LiteralPath $ThemesRegistryPath -ErrorAction SilentlyContinue).CurrentTheme
        ThemePath = $ThemePath
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

if (-not ('NexusWallpaperNativeV2' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
public static class NexusWallpaperNativeV2 {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);
}
'@
}
if (-not [NexusWallpaperNativeV2]::SystemParametersInfo(20, 0, $TargetWallpaper, 3)) {
    throw "Windows rejected wallpaper update. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

Start-Process -FilePath $ThemePath -Wait
$active = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $currentWallpaper = Get-CurrentWallpaper
    $currentTheme = (Get-ItemProperty -LiteralPath $ThemesRegistryPath -ErrorAction SilentlyContinue).CurrentTheme
    if ([string]::Equals($currentWallpaper, $TargetWallpaper, [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($currentTheme, $ThemePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $active = $true
        break
    }
    Start-Sleep -Milliseconds 200
}
if (-not $active) { throw 'Windows did not activate the verified NEXUS wallpaper and theme.' }
Write-Host "JARVIS NEXUS desktop is active: $TargetWallpaper"
