<#
.SYNOPSIS
  Starts JARVIS NEXUS at Windows sign-in without leaving a console window.
  User data is kept in a stable data directory (JARVIS_DATA_DIR) that the
  private updater never replaces, and an optional pre-start update check can
  be enabled by passing -UpdateIndexUrl.
#>
[CmdletBinding()]
param(
    # Optional. When set, a signed release index is checked (and, if newer,
    # downloaded and activated via the private hand-off) before the core starts.
    [string]$UpdateIndexUrl = '',
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\data')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Server = Join-Path $Root 'ultra-server.mjs'
$Uri = 'http://127.0.0.1:3791'

if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) { throw "JARVIS core missing: $Server" }

$dataFull = [IO.Path]::GetFullPath($DataRoot)
New-Item -ItemType Directory -Path $dataFull -Force | Out-Null

function Test-Running {
    try { Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 1 | Out-Null; return $true } catch { return $false }
}

$running = Test-Running

if (-not $running) {
    # Optional pre-start update check. Safe for the mixed live install: the
    # updater skips (no-op) unless the directory is a marked program directory.
    if (-not [string]::IsNullOrWhiteSpace($UpdateIndexUrl)) {
        $updater = Join-Path $Root 'private-channel\Invoke-JarvisUpdate.ps1'
        if (Test-Path -LiteralPath $updater -PathType Leaf) {
            try {
                & $updater -ProgramRoot $Root -IndexUrl $UpdateIndexUrl -DataRoot $dataFull -AutoConfirm | Out-Null
            } catch {
                Write-Warning "JARVIS update check failed: $($_.Exception.Message)"
            }
        }
    }

    # The hand-off may have started the core; start it ourselves only if needed.
    $running = Test-Running
}

if (-not $running) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -eq $node -or -not $node.Source) { throw 'Node.js 20+ is unavailable; JARVIS cannot start at sign-in.' }

    $previousDataDir = $env:JARVIS_DATA_DIR
    $env:JARVIS_DATA_DIR = $dataFull
    try {
        Start-Process -FilePath $node.Source -ArgumentList ('"{0}"' -f $Server) -WorkingDirectory $Root -WindowStyle Hidden
    } finally {
        $env:JARVIS_DATA_DIR = $previousDataDir
    }
    Start-Sleep -Milliseconds 850
}
Start-Process $Uri
