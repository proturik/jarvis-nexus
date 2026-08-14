[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = $PSScriptRoot
$appRoot = Join-Path $installRoot 'app'
$node = Join-Path $installRoot 'runtime\node.exe'
$entrypoint = Join-Path $appRoot 'ultra-server.mjs'
$url = 'http://127.0.0.1:3791'

if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
    throw "JARVIS NEXUS ULTRA cannot find its bundled runtime: $node"
}
if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
    throw "JARVIS NEXUS ULTRA cannot find its only supported entrypoint: $entrypoint"
}

function Test-UltraOnline {
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect('127.0.0.1', 3791, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) {
            $client.Dispose()
            return $false
        }
        $client.EndConnect($async)
        $client.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

if (-not (Test-UltraOnline)) {
    $logDirectory = Join-Path $installRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logDirectory -ErrorAction Stop | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stdout = Join-Path $logDirectory "ultra-$timestamp.out.log"
    $stderr = Join-Path $logDirectory "ultra-$timestamp.err.log"
    Start-Process -FilePath $node -ArgumentList @($entrypoint) -WorkingDirectory $appRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-UltraOnline)) {
        Start-Sleep -Milliseconds 250
    }
}

Start-Process $url
