<#
.SYNOPSIS
  Compatibility core for the JARVIS IExpress installer.

.DESCRIPTION
  Uses only .NET SHA-256 and ZIP APIs so it works even if IExpress starts
  PowerShell without optional utility cmdlets such as Get-FileHash.
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
    $actualHash = Get-Sha256 $payloadPath
    if ($actualHash -ne ([string]$Manifest.payloadSha256).ToUpperInvariant()) { throw 'Payload integrity check failed. Stop installation and obtain a fresh installer.' }
    return $payloadPath
}

function New-Shortcut([string]$Path, [string]$TargetPath, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.Description = $Description
    $shortcut.Save()
}

function Install-Release {
    $manifest = Get-Manifest
    $payloadPath = Get-VerifiedPayload $manifest
    $installRoot = Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA'
    $extractRoot = Join-Path $env:TEMP ('JARVIS-NEXUS-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot -ErrorAction Stop | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($payloadPath, $extractRoot)
        foreach ($name in @('app', 'runtime', 'launcher')) {
            $source = Join-Path $extractRoot $name
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Payload folder missing: $name" }
            $destination = Join-Path $installRoot $name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $source '*') -Destination $destination -Recurse -Force
        }
        # Data and .env are never in the payload; existing local data survives updates.
        New-Item -ItemType Directory -Path (Join-Path $installRoot 'app\data') -Force | Out-Null
        $launcher = Join-Path $installRoot 'launcher\Start-Jarvis-RELEASE.cmd'
        New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'JARVIS NEXUS ULTRA.lnk') $launcher 'Launch JARVIS NEXUS ULTRA'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $installRoot 'release.json') -Encoding utf8
        return $installRoot
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot -PathType Container) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
    }
}

$root = Install-Release
Start-Process -FilePath (Join-Path $root 'launcher\Start-Jarvis-RELEASE.cmd')
