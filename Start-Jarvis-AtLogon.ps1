<#
.SYNOPSIS
  Starts JARVIS NEXUS at Windows sign-in without leaving a console window.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Server = Join-Path $Root 'ultra-server.mjs'
$Uri = 'http://127.0.0.1:3791'

if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) { throw "JARVIS core missing: $Server" }
try {
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 1 | Out-Null
}
catch {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -eq $node -or -not $node.Source) { throw 'Node.js 20+ is unavailable; JARVIS cannot start at sign-in.' }
    Start-Process -FilePath $node.Source -ArgumentList ('"{0}"' -f $Server) -WorkingDirectory $Root -WindowStyle Hidden
    Start-Sleep -Milliseconds 850
}
Start-Process $Uri
