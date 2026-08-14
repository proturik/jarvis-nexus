<#
.SYNOPSIS
  Safely applies the JARVIS NEXUS wallpaper and dark user theme.

.DESCRIPTION
  The wallpaper is first copied to the current user's Pictures folder, then
  a per-user theme is generated with that durable path. It never relies on a
  Downloads path or a missing source file, preventing the black-background
  fallback seen with stale Windows custom themes.
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

function Get-CurrentWallpaper {
    return (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper
}

if ($Mode -eq 'Status') {
    [pscustomobject]@{
        SourceExists = Test-Path -LiteralPath $SourceWallpaper -PathType Leaf
        DurableWallpaper = $TargetWallpaper
        DurableWallpaperExists = Test-Path -LiteralPath $TargetWallpaper -PathType Leaf
        CurrentWallpaper = Get-CurrentWallpaper
        ThemePath = $ThemePath
        ThemeExists = Test-Path -LiteralPath $ThemePath -PathType Leaf
    } | Format-List
    exit 0
}

if (-not (Test-Path -LiteralPath $SourceWallpaper -PathType Leaf)) {
    throw "NEXUS wallpaper source is missing: $SourceWallpaper"
}

New-Item -ItemType Directory -Path $TargetDirectory, $ThemeDirectory -Force | Out-Null
$sourceHash = (Get-FileHash -LiteralPath $SourceWallpaper -Algorithm SHA256).Hash
$targetHash = if (Test-Path -LiteralPath $TargetWallpaper -PathType Leaf) { (Get-FileHash -LiteralPath $TargetWallpaper -Algorithm SHA256).Hash } else { $null }
if ($sourceHash -ne $targetHash) {
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

if (-not ('NexusWallpaperNative' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
public static class NexusWallpaperNative {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);
}
'@
}
if (-not [NexusWallpaperNative]::SystemParametersInfo(20, 0, $TargetWallpaper, 3)) {
    throw "Windows rejected wallpaper update. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

# Activating the generated theme is safe because it points at the verified target above.
Start-Process -FilePath $ThemePath -Wait
$currentWallpaper = Get-CurrentWallpaper
if ($currentWallpaper -ne $TargetWallpaper) {
    throw "Windows did not retain the NEXUS wallpaper path: $currentWallpaper"
}
Write-Host "JARVIS NEXUS desktop is active: $TargetWallpaper"
