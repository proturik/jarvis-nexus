<#
.SYNOPSIS
  Starts the installed JARVIS server and opens it as a standalone Edge app window.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $InstallRoot 'app'
$NodePath = Join-Path $InstallRoot 'runtime\node.exe'
$ServerPath = Join-Path $AppRoot 'ultra-server.mjs'
$Uri = 'http://127.0.0.1:3791'
$BootstrapUri = "$Uri/api/bootstrap"

function Test-JarvisEndpoint {
    try {
        $boot = Invoke-RestMethod -Uri $BootstrapUri -TimeoutSec 1
        return $null -ne $boot.settings -and [string]$boot.settings.assistantName -eq 'JARVIS' -and $null -ne $boot.system
    }
    catch { return $false }
}

if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "JARVIS runtime missing: $NodePath" }
if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { throw "JARVIS core missing: $ServerPath" }
New-Item -ItemType Directory -Path (Join-Path $AppRoot 'data') -Force | Out-Null

if (-not (Test-JarvisEndpoint)) {
    Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $ServerPath) -WorkingDirectory $AppRoot -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-JarvisEndpoint)) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-JarvisEndpoint)) { throw 'JARVIS server did not become ready on its local endpoint.' }
}

$edgeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$edge = $edgeCandidates | Select-Object -First 1
if ($edge) {
    $appPattern = [regex]::Escape("--app=$Uri")
    $alreadyOpen = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $appPattern } | Select-Object -First 1
    if ($null -eq $alreadyOpen) {
        Start-Process -FilePath $edge -ArgumentList @("--app=$Uri", '--no-first-run', '--disable-session-crashed-bubble', '--window-size=1060,760')
    }
}
else {
    # Windows 10/11 normally includes Edge. This is a readable fallback rather than a hidden failure.
    Start-Process $Uri
}
