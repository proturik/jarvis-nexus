<#
.SYNOPSIS
  Opt-in process hand-off: verify a versioned program-only directory and start
  the JARVIS NEXUS ULTRA core (node ultra-server.mjs) from it, waiting until the
  listener on -Port answers. Never opens a browser.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [int]$Port = 3791,
    [string]$NodePath = '',
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\data'),
    [int]$HealthTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force

$installFull = [IO.Path]::GetFullPath($ProgramRoot).TrimEnd('\')
$serverPath = Join-Path $installFull 'ultra-server.mjs'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw "JARVIS core is missing: $serverPath" }
Test-JarvisProgramMarker -Directory $installFull
$dataFull = [IO.Path]::GetFullPath($DataRoot)
New-Item -ItemType Directory -Path $dataFull -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -eq $nodeCommand -or [string]::IsNullOrWhiteSpace([string]$nodeCommand.Source)) {
        throw 'Node.js is unavailable; the JARVIS core cannot be started.'
    }
    $NodePath = [string]$nodeCommand.Source
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node executable not found: $NodePath" }

function Test-Health {
    param([int]$LocalPort)
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$LocalPort/")
        $request.Method = 'GET'
        $request.Timeout = 800
        $request.ReadWriteTimeout = 800
        try {
            $response = $request.GetResponse()
        } catch {
            $response = $_.Exception.Response
            if ($null -eq $response) { return $false }
        }
        $code = [int]$response.StatusCode
        return ($code -ge 200 -and $code -le 499)
    } finally {
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }
}

# The real ultra-server.mjs reads the port and the data location from the
# environment; mirror that so the started core listens on the selected port and
# keeps user data in the stable -DataRoot (never inside the versioned program dir).
$previousPortEnv = $env:JARVIS_ULTRA_PORT
$previousDataDir = $env:JARVIS_DATA_DIR
$previousEnvFile = $env:JARVIS_ENV_FILE
$env:JARVIS_ULTRA_PORT = [string]$Port
$env:JARVIS_DATA_DIR = $dataFull
$envFileCandidates = @((Join-Path $dataFull '.env'), (Join-Path $installFull '.env'))
$envFile = $envFileCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $envFile) { $env:JARVIS_ENV_FILE = $envFile } else { $env:JARVIS_ENV_FILE = $null }
$process = $null
try {
    $process = Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $serverPath) `
        -WorkingDirectory $installFull -WindowStyle Hidden -PassThru
} finally {
    $env:JARVIS_ULTRA_PORT = $previousPortEnv
    $env:JARVIS_DATA_DIR = $previousDataDir
    $env:JARVIS_ENV_FILE = $previousEnvFile
}
if ($null -eq $process) { throw 'Start-Process returned no process handle; the JARVIS core could not be started.' }
$startedPid = [int]$process.Id

$deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
$healthy = $false
while ([DateTime]::UtcNow -lt $deadline -and -not $healthy) {
    if (Test-Health -LocalPort $Port) { $healthy = $true; break }
    if ($null -eq (Get-Process -Id $startedPid -ErrorAction SilentlyContinue)) {
        throw "JARVIS core process (PID $startedPid) exited before becoming healthy on port $Port."
    }
    Start-Sleep -Milliseconds 250
}
if (-not $healthy) {
    try {
        if ($null -ne (Get-Process -Id $startedPid -ErrorAction SilentlyContinue)) { Stop-Process -Id $startedPid -Force -ErrorAction SilentlyContinue }
    } catch { }
    throw "JARVIS core (PID $startedPid) did not become healthy on http://127.0.0.1:$Port within $HealthTimeoutSeconds seconds."
}

[pscustomobject]@{ Ok = $true; Pid = $startedPid; Uri = "http://127.0.0.1:$Port" }
