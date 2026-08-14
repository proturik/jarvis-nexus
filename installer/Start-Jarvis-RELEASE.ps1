[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $InstallRoot 'app'
$NodePath = Join-Path $InstallRoot 'runtime\node.exe'
$ServerPath = Join-Path $AppRoot 'ultra-server.mjs'
$Uri = 'http://127.0.0.1:3791'

if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "JARVIS runtime missing: $NodePath" }
if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { throw "JARVIS core missing: $ServerPath" }
New-Item -ItemType Directory -Path (Join-Path $AppRoot 'data') -Force | Out-Null

try {
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 1 | Out-Null
}
catch {
    Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $ServerPath) -WorkingDirectory $AppRoot -WindowStyle Hidden
    Start-Sleep -Milliseconds 650
}
Start-Process $Uri
