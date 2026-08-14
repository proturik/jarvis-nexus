<#
.SYNOPSIS
  Verified, IExpress-compatible installation core for JARVIS NEXUS.
#>
[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-Manifest {
    $manifestPath = Join-Path $PSScriptRoot 'installer-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Installer manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $payloadName = [string]$manifest.payloadFile
    if ([string]::IsNullOrWhiteSpace($payloadName) -or [System.IO.Path]::GetFileName($payloadName) -ne $payloadName) { throw 'Installer manifest payload is invalid.' }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.payloadSha256)) { throw 'Installer manifest checksum is missing.' }
    return $manifest
}

function Get-VerifiedPayload([object]$Manifest) {
    $payloadPath = Join-Path $PSScriptRoot ([string]$Manifest.payloadFile)
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw 'Installer payload is missing.' }
    if ((Get-Sha256 $payloadPath) -ne ([string]$Manifest.payloadSha256).ToUpperInvariant()) { throw 'Payload integrity check failed. Stop installation and obtain a fresh installer.' }
    return $payloadPath
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Payload folder missing: $Source" }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function New-Shortcut([string]$Path, [string]$TargetPath, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.Description = $Description
    $shortcut.Save()
}

$manifest = Get-Manifest
$payloadPath = Get-VerifiedPayload $manifest
$installRoot = Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA'
$extractRoot = Join-Path $env:TEMP ('JARVIS-NEXUS-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $extractRoot -ErrorAction Stop | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($payloadPath, $extractRoot)
    foreach ($name in @('app', 'runtime', 'launcher')) {
        Copy-DirectoryContents (Join-Path $extractRoot $name) (Join-Path $installRoot $name)
    }
    # Data and .env never exist in the payload. Existing local data remains untouched.
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'app\data') -Force | Out-Null
    $serverPath = Join-Path $installRoot 'app\ultra-server.mjs'
    $nodePath = Join-Path $installRoot 'runtime\node.exe'
    $launcher = Join-Path $installRoot 'launcher\Start-Jarvis-RELEASE.cmd'
    foreach ($required in @($serverPath, $nodePath, $launcher)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Post-install verification failed: $required" }
    }
    New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'JARVIS NEXUS ULTRA.lnk') $launcher 'Launch JARVIS NEXUS ULTRA'
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $installRoot 'release.json') -Encoding utf8
}
finally {
    if (Test-Path -LiteralPath $extractRoot -PathType Container) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
}

Start-Process -FilePath $launcher
