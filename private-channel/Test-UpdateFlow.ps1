[CmdletBinding()]
param(
    [int]$HttpPort = 0,
    [int]$TestPort = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$markerName = '.jarvis-program-marker'
$markerContent = 'JARVIS NEXUS ULTRA program directory v1'

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "Unexpected failure: $($_.Exception.Message)"
    }
    throw "Expected failure matching '$Pattern'."
}

# --- Loopback HTTP server helpers (HttpListener in a Start-Job) ---
function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Start-TestHttpServer {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][hashtable]$Routes,
        [Parameter(Mandatory)][string]$StopFile
    )
    $job = Start-Job -ArgumentList $Port, $Routes, $StopFile -ScriptBlock {
        param($Port, $Routes, $StopFile)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $listener = New-Object System.Net.HttpListener
        try {
            $listener.IgnoreWriteExceptions = $true
            $listener.Prefixes.Add("http://127.0.0.1:$Port/")
            $listener.Start()
            while (-not (Test-Path -LiteralPath $StopFile)) {
                $context = $null
                try {
                    $context = $listener.GetContext()
                } catch {
                    if (-not $listener.IsListening) { break }
                    continue
                }
                $response = $context.Response
                try {
                    $path = $context.Request.Url.AbsolutePath
                    if ($Routes.ContainsKey($path) -and $Routes[$path] -is [hashtable]) {
                        $route = $Routes[$path]
                        if ($route.ContainsKey('redirect')) {
                            $response.StatusCode = 302
                            $response.RedirectLocation = [string]$route['redirect']
                            $response.ContentLength64 = 0
                        } elseif ($route.ContainsKey('file')) {
                            $file = [string]$route['file']
                            if (Test-Path -LiteralPath $file -PathType Leaf) {
                                $bytes = [IO.File]::ReadAllBytes($file)
                                $response.StatusCode = 200
                                $response.ContentType = 'application/octet-stream'
                                $response.ContentLength64 = $bytes.Length
                                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                            } else {
                                $response.StatusCode = 404
                                $response.ContentLength64 = 0
                            }
                        } else {
                            $response.StatusCode = 404
                            $response.ContentLength64 = 0
                        }
                    } else {
                        $response.StatusCode = 404
                        $response.ContentLength64 = 0
                    }
                } catch {
                    # Per-request errors are isolated so the server keeps serving.
                } finally {
                    try { $response.Close() } catch { }
                }
            }
        } finally {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
    }
    return $job
}

function Wait-TestHttpServerReady {
    param([int]$Port, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            $client.Close()
            return
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            if ($client -is [IDisposable]) { try { $client.Dispose() } catch { } }
        }
    }
    throw 'Test HTTP server did not become ready.'
}

function Stop-TestHttpServer {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$StopFile, [Parameter(Mandatory)][int]$Port)
    if (Test-Path -LiteralPath $StopFile) { Remove-Item -LiteralPath $StopFile -Force }
    [IO.File]::WriteAllText($StopFile, 'stop', (New-Object Text.UTF8Encoding($false)))
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("GET /__stop__ HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Flush()
        $stream.Dispose()
        $client.Dispose()
    } catch { }
    try { Wait-Job -Job $Job -Timeout 15 -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Stop-Job -Job $Job -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# The fake JARVIS core is identical to the one used by Test-Handoff: a tiny node
# http server keyed off JARVIS_ULTRA_PORT that serves the version from version.txt.
function Get-FakeServerCode {
    return @'
import http from 'node:http';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const port = Number.parseInt(process.env.JARVIS_ULTRA_PORT || '31879', 10);
let version = 'unknown';
try { version = readFileSync(path.join(here, 'version.txt'), 'utf8').trim(); } catch (e) { }

http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('JARVIS NEXUS ULTRA test server version=' + version + '\n');
}).listen(port, '127.0.0.1');
'@
}

function Get-ServerResponse {
    param([int]$LocalPort)
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/" -UseBasicParsing -TimeoutSec 3
    return [string]$resp.Content
}

function Wait-ServerBody {
    param([int]$LocalPort, [string]$Pattern, [int]$Tries = 40)
    for ($i = 0; $i -lt $Tries; $i++) {
        try {
            $body = Get-ServerResponse -LocalPort $LocalPort
            if ($body -match $Pattern) { return $body }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    return ''
}

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}

$nodePath = ''
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($null -ne $nodeCommand) { $nodePath = [string]$nodeCommand.Source }
if ([string]::IsNullOrWhiteSpace($nodePath)) { throw 'Node.js is unavailable; update-flow tests cannot run.' }

$root = Join-Path $env:TEMP ('jarvis-update-flow-test-' + [Guid]::NewGuid().ToString('N'))
$keyRoot = Join-Path $root 'test-owner-key'
$publicKeyOut = Join-Path $root 'public-key-test.xml'
New-Item -ItemType Directory -Path $root | Out-Null

$serverJob = $null
$httpPort = 0
$testPort = 0
$stopFile = $null
$ownedPids = @()
$install = ''
$unmarkedDir = ''
$dataRoot = ''

try {
    if ($HttpPort -le 0) { $httpPort = Get-FreeLoopbackPort } else { $httpPort = $HttpPort }
    if ($TestPort -le 0) { $testPort = Get-FreeLoopbackPort } else { $testPort = $TestPort }
    if ($httpPort -eq $testPort) { throw 'HTTP server port and test program port must differ.' }

    # Throwaway signing key (never the production owner key).
    $createdKey = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKeyOut -KeySize 2048
    Assert-True ($createdKey.Ok -and $createdKey.Created) 'throwaway signing key must initialise'

    # Release 9.9.9: package payload, signed update manifest, signed release index.
    $serverCode = Get-FakeServerCode
    $package = Join-Path $root 'jarvis-9.9.9.zip'
    New-TestZip $package @{
        'payload/ultra-server.mjs' = $serverCode
        'payload/version.txt' = '9.9.9'
        'payload/dummy.txt' = 'new dummy'
        "payload/$markerName" = $markerContent
    }
    $releaseId = 'jarvis-9.9.9'
    $envelope = Join-Path $root 'update-9.9.9.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $envelope -KeyRoot $keyRoot -PackagePath $package -Version '9.9.9' -ReleaseId $releaseId | Out-Null

    $releaseEntry = [ordered]@{
        version = '9.9.9'; releaseId = $releaseId
        envelopeUrl = "http://127.0.0.1:$httpPort/releases/jarvis-9.9.9.update.json"
        packageUrl = "http://127.0.0.1:$httpPort/releases/jarvis-9.9.9.zip"
        packageBytes = (Get-Item -LiteralPath $package).Length
        packageSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToUpperInvariant()
        envelopeSha256 = (Get-FileHash -LiteralPath $envelope -Algorithm SHA256).Hash.ToUpperInvariant()
        publishedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
    }
    $releasesJsonPath = Join-Path $root 'releases.json'
    Write-Utf8NoBom -Path $releasesJsonPath -Text (@{ releases = @($releaseEntry) } | ConvertTo-Json -Depth 8)
    $indexPath = Join-Path $root 'index.json'
    $indexResult = & (Join-Path $PSScriptRoot 'New-JarvisReleaseIndex.ps1') -OutputPath $indexPath -KeyRoot $keyRoot -ReleasesJsonPath $releasesJsonPath -ValidDays 7 -AllowLoopbackHttp
    Assert-True ($indexResult.Ok -and $indexResult.ReleaseCount -eq 1) 'owner must build the release index'

    $routes = @{
        '/index.json' = @{ file = $indexPath }
        '/releases/jarvis-9.9.9.update.json' = @{ file = $envelope }
        '/releases/jarvis-9.9.9.zip' = @{ file = $package }
    }
    $stopFile = Join-Path $root 'server-stop'
    $serverJob = Start-TestHttpServer -Port $httpPort -Routes $routes -StopFile $stopFile
    Wait-TestHttpServerReady -Port $httpPort

    $stateRoot = Join-Path $root 'state'
    $updateArgs = @{
        IndexUrl = "http://127.0.0.1:$httpPort/index.json"
        StateRoot = $stateRoot
        Port = $testPort
        PublicKeyPath = $publicKeyOut
        PinnedPublicKeyFingerprint = $createdKey.PublicKeyFingerprint
        StopTimeoutSeconds = 10
        HealthTimeoutSeconds = 60
    }

    # Disposable versioned program-only directory (1.0.0) + separate DataRoot.
    $install = Join-Path $root 'app-current'
    New-Item -ItemType Directory -Path $install | Out-Null
    [IO.File]::WriteAllText((Join-Path $install $markerName), $markerContent, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'ultra-server.mjs'), $serverCode, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'version.txt'), '1.0.0', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'dummy.txt'), 'old dummy', (New-Object Text.UTF8Encoding($false)))

    $dataRoot = Join-Path $root 'data'
    New-Item -ItemType Directory -Path $dataRoot | Out-Null
    $conversationsContent = '{"conversations":[{"id":"convo-1","turn":2}]}'
    $profileContent = '{"name":"jarvis-test-profile","theme":"dark"}'
    [IO.File]::WriteAllText((Join-Path $dataRoot 'conversations.json'), $conversationsContent, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $dataRoot 'profile.json'), $profileContent, (New-Object Text.UTF8Encoding($false)))

    # 1. No-update path: newest index version is not newer than the current version.
    $noUpdate = & (Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1') -ProgramRoot $install -CurrentVersion '9.9.9' -AutoConfirm -AllowLoopbackHttp @updateArgs
    Assert-True ($noUpdate.Ok -and -not $noUpdate.UpdateAvailable) 'no-update path must report Ok with UpdateAvailable=false'

    # 2. Skipped path: no program marker → Ok with Skipped, never throws, even with a newer release in the index.
    $unmarkedDir = Join-Path $root 'not-a-program'
    New-Item -ItemType Directory -Path $unmarkedDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $unmarkedDir 'dummy.txt'), 'dummy', (New-Object Text.UTF8Encoding($false)))
    $skipped = & (Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1') -ProgramRoot $unmarkedDir -CurrentVersion '1.0.0' -AutoConfirm -AllowLoopbackHttp @updateArgs
    Assert-True ($skipped.Ok -and -not $skipped.UpdateAvailable -and $skipped.Skipped) 'unmarked program dir must be skipped without throwing'
    Assert-True ($skipped.Skipped -eq 'not a versioned program directory') 'skip reason must match the documented text'

    # Negative: marked dir with no version.txt and no -CurrentVersion must throw a clear error.
    $noVersionDir = Join-Path $root 'no-version'
    New-Item -ItemType Directory -Path $noVersionDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $noVersionDir $markerName), $markerContent, (New-Object Text.UTF8Encoding($false)))
    Assert-Fails { & (Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1') -ProgramRoot $noVersionDir -AutoConfirm -AllowLoopbackHttp @updateArgs } 'Cannot determine the current JARVIS version'

    # 3. Full update + data survival: start the current fake program, then update.
    $started = & (Join-Path $PSScriptRoot 'Start-JarvisProgram.ps1') -ProgramRoot $install -Port $testPort -DataRoot $dataRoot -HealthTimeoutSeconds 60
    $ownedPids += [int]$started.Pid
    Assert-True ($started.Ok -and $started.Pid -gt 0) 'fake program must start'
    $oldBody = Wait-ServerBody -LocalPort $testPort -Pattern 'version=1\.0\.0'
    Assert-True ($oldBody -match 'version=1\.0\.0') 'fake server must serve 1.0.0 before the update'
    $oldPid = [int]$started.Pid

    $result = & (Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1') -ProgramRoot $install -DataRoot $dataRoot -AutoConfirm -AllowLoopbackHttp @updateArgs
    Assert-True ($result.Ok -and $result.UpdateAvailable -and $result.Activated) 'full update must activate'
    Assert-True ($result.Version -eq '9.9.9' -and $result.ReleaseId -eq $releaseId) 'update must report the 9.9.9 release'
    Assert-True ($result.Pid -gt 0 -and $result.Uri -eq "http://127.0.0.1:$testPort") 'update must report the restarted program'
    Assert-True ((Get-Content (Join-Path $install 'version.txt') -Raw).Trim() -eq '9.9.9') 'program dir must now report version 9.9.9'
    Assert-True ((Get-Content (Join-Path $install 'dummy.txt') -Raw).Trim() -eq 'new dummy') 'new payload must replace the old dummy file'
    Assert-True ($null -eq (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) 'old program PID must be gone after hand-off'
    $ownedPids += [int]$result.Pid

    Assert-True ((Get-Content (Join-Path $dataRoot 'conversations.json') -Raw) -eq $conversationsContent) 'conversations.json must be unchanged'
    Assert-True ((Get-Content (Join-Path $dataRoot 'profile.json') -Raw) -eq $profileContent) 'profile.json must be unchanged'
    $installFull = [IO.Path]::GetFullPath($install).TrimEnd('\')
    $dataFull = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\')
    Assert-True (-not $dataFull.StartsWith($installFull + '\', [StringComparison]::OrdinalIgnoreCase)) 'DataRoot must not live under ProgramRoot'

    $newBody = Wait-ServerBody -LocalPort $testPort -Pattern 'version=9\.9\.9'
    Assert-True ($newBody -match 'version=9\.9\.9') 'restarted server must serve 9.9.9'

    # 4. Anti-replay: the same release must not re-activate (version.txt is now 9.9.9).
    $replay = & (Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1') -ProgramRoot $install -DataRoot $dataRoot -AutoConfirm -AllowLoopbackHttp @updateArgs
    Assert-True ($replay.Ok -and -not $replay.UpdateAvailable -and -not $replay.Activated) 'same release must not re-activate'
    Assert-True ((Get-Content (Join-Path $install 'version.txt') -Raw).Trim() -eq '9.9.9') 'version must remain 9.9.9 after replay attempt'

    'UPDATE_FLOW_TESTS=PASS'
} finally {
    foreach ($pidValue in @($ownedPids | Sort-Object -Unique)) {
        if ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
        }
        $pidDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $pidDeadline) {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -ne $serverJob) { try { Stop-TestHttpServer -Job $serverJob -StopFile $stopFile -Port $httpPort } catch { } }
    foreach ($candidate in @($install, $unmarkedDir)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            try { & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $candidate -Port $testPort -TimeoutSeconds 5 | Out-Null } catch { }
        }
    }
    if (Test-Path -LiteralPath $root) {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            try {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
                break
            } catch {
                Start-Sleep -Milliseconds 300
            }
        }
    }
}
