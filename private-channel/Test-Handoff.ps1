[CmdletBinding()]
param(
    [int]$TestPort = 31879,
    [int]$ForeignPort = 31878,
    [int]$IdlePort = 31877
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

$nodePath = ''
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($null -ne $nodeCommand) { $nodePath = [string]$nodeCommand.Source }
if ([string]::IsNullOrWhiteSpace($nodePath)) { throw 'Node.js is unavailable; hand-off tests cannot run.' }

$root = Join-Path $env:TEMP ('jarvis-handoff-test-' + [Guid]::NewGuid().ToString('N'))
$keyRoot = Join-Path $root 'test-owner-key'
$publicKeyOut = Join-Path $root 'public-key-test.xml'
New-Item -ItemType Directory -Path $root | Out-Null
$install = ''
$foreignRoot = ''
$ownedPids = @()
try {
    foreach ($p in @($TestPort, $ForeignPort)) {
        if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
            throw "Test port $p is already in use; pick different -TestPort / -ForeignPort values."
        }
    }

    # Throwaway owner key (never touches the production owner key).
    $createdKey = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKeyOut -KeySize 2048
    Assert-True ($createdKey.Ok) 'throwaway signing key must initialise'
    $handoffArgs = @{ PublicKeyPath = $publicKeyOut; PinnedPublicKeyFingerprint = $createdKey.PublicKeyFingerprint }

    # Disposable versioned program-only directory.
    $install = Join-Path $root 'app-current'
    New-Item -ItemType Directory -Path $install | Out-Null
    $serverCode = Get-FakeServerCode
    [IO.File]::WriteAllText((Join-Path $install $markerName), $markerContent, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'ultra-server.mjs'), $serverCode, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'version.txt'), '1.0.0', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $install 'dummy.txt'), 'old dummy', (New-Object Text.UTF8Encoding($false)))

    # 1. Start the fake program and assert health + precise attribution.
    $started = & (Join-Path $PSScriptRoot 'Start-JarvisProgram.ps1') -ProgramRoot $install -Port $TestPort -HealthTimeoutSeconds 60
    $ownedPids += [int]$started.Pid
    Assert-True ($started.Ok -and $started.Pid -gt 0) 'Start-JarvisProgram must report Ok with a PID'
    Assert-True ($started.Uri -eq "http://127.0.0.1:$TestPort") 'Start-JarvisProgram must report the health Uri'
    $oldBody = Wait-ServerBody -LocalPort $TestPort -Pattern 'version=1\.0\.0'
    Assert-True ($oldBody -match 'version=1\.0\.0') 'fake server must be live with version 1.0.0'
    $coreProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($started.Pid)"
    Assert-True ($null -ne $coreProc -and $coreProc.Name -eq 'node.exe') 'started process must be node.exe'
    Assert-True ($coreProc.CommandLine -match [regex]::Escape((Join-Path $install 'ultra-server.mjs'))) 'started process command line must reference the disposable program root'
    $oldPid = [int]$started.Pid

    # 2. Build and sign a NEW payload (new version.txt + marker + fresh server).
    $package = Join-Path $root 'jarvis-9.9.9.zip'
    New-TestZip $package @{
        'payload/ultra-server.mjs' = $serverCode
        'payload/version.txt' = '9.9.9'
        'payload/dummy.txt' = 'new dummy'
        "payload/$markerName" = $markerContent
    }
    $envelope = Join-Path $root 'update-9.9.9.json'
    $releaseId = 'test-' + [Guid]::NewGuid().ToString('N')
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $envelope -KeyRoot $keyRoot -PackagePath $package -Version '9.9.9' -ReleaseId $releaseId | Out-Null
    $stateRoot = Join-Path $root 'state'

    # 3. Hand-off: stop old core, activate the signed payload, start the new core.
    $handoff = & (Join-Path $PSScriptRoot 'Invoke-JarvisHandoff.ps1') -ProgramRoot $install -EnvelopePath $envelope -PackagePath $package `
        -CurrentVersion '1.0.0' -StateRoot $stateRoot -Port $TestPort -StopTimeoutSeconds 5 @handoffArgs
    Assert-True ($handoff.Ok -and $handoff.Activated -and $handoff.Restarted) 'hand-off must activate and restart'
    Assert-True ($handoff.BackupPath -match '\.jarvis-backup-') 'hand-off must return a rollback backup path'
    Assert-True (Test-Path -LiteralPath $handoff.BackupPath -PathType Container) 'rollback backup directory must exist'
    Assert-True ((Get-Content (Join-Path $install 'version.txt') -Raw).Trim() -eq '9.9.9') 'new payload must be live in the program root'
    Assert-True ((Get-Content (Join-Path $install 'dummy.txt') -Raw).Trim() -eq 'new dummy') 'new payload file must replace the old one'
    Assert-True ((Get-Content (Join-Path $handoff.BackupPath 'version.txt') -Raw).Trim() -eq '1.0.0') 'old payload must be preserved in the backup'
    Assert-True ($null -eq (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) 'old core PID must be gone after hand-off'
    $newBody = Wait-ServerBody -LocalPort $TestPort -Pattern 'version=9\.9\.9'
    Assert-True ($newBody -match 'version=9\.9\.9') 'restarted server must serve the NEW payload version'
    $newListener = Get-NetTCPConnection -LocalPort $TestPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert-True ($null -ne $newListener) 'new core must be listening on the test port'
    $newCorePid = [int]$newListener.OwningProcess
    $ownedPids += $newCorePid

    # 4. Stop the running program explicitly; only the attributed PID may die.
    $stopNew = & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $install -Port $TestPort -TimeoutSeconds 5
    Assert-True ($stopNew.Ok -and $stopNew.Stopped -ge 1) 'Stop-JarvisProgram must stop the running core'
    Assert-True ($stopNew.StoppedPids -contains $newCorePid) 'StoppedPids must contain the attributed core PID'
    Assert-True ($null -eq (Get-Process -Id $newCorePid -ErrorAction SilentlyContinue)) 'stopped core PID must be gone'

    # 5. Rollback still works after a hand-off.
    $rollback = & (Join-Path $PSScriptRoot 'Restore-JarvisUpdateBackup.ps1') -InstallRoot $install -BackupPath $handoff.BackupPath -StateRoot $stateRoot
    Assert-True ($rollback.Ok) 'rollback must succeed after hand-off'
    Assert-True ((Get-Content (Join-Path $install 'version.txt') -Raw).Trim() -eq '1.0.0') 'rollback must restore the old payload'

    # 6. Safety: Stop-JarvisProgram against a directory with no matching listener
    #    must not kill anything.
    $myPid = $PID
    $idleStop = $null
    try {
        $idleStop = & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $install -Port $IdlePort -TimeoutSeconds 5
    } catch {
        # Throwing (rather than killing) is also acceptable.
    }
    if ($null -ne $idleStop) {
        Assert-True ($idleStop.Ok -and $idleStop.StoppedPids.Count -eq 0) 'idle stop must report zero stopped processes'
    }
    Assert-True ($null -ne (Get-Process -Id $myPid -ErrorAction SilentlyContinue)) 'caller process must survive the idle stop'

    # 7. Safety: a foreign node.exe owning a port is NOT the JARVIS core and must
    #    never be stopped.
    $foreignRoot = Join-Path $root 'foreign-root'
    New-Item -ItemType Directory -Path $foreignRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $foreignRoot 'ultra-server.mjs'), $serverCode, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $foreignRoot 'version.txt'), 'foreign', (New-Object Text.UTF8Encoding($false)))
    $previousPort = $env:JARVIS_ULTRA_PORT
    $env:JARVIS_ULTRA_PORT = [string]$ForeignPort
    $foreignProc = $null
    try {
        $foreignProc = Start-Process -FilePath $nodePath -ArgumentList ('"{0}"' -f (Join-Path $foreignRoot 'ultra-server.mjs')) `
            -WorkingDirectory $foreignRoot -WindowStyle Hidden -PassThru
    } finally { $env:JARVIS_ULTRA_PORT = $previousPort }
    $ownedPids += [int]$foreignProc.Id
    $foreignBody = Wait-ServerBody -LocalPort $ForeignPort -Pattern 'foreign'
    Assert-True ($foreignBody -match 'foreign') 'foreign test server must come up'
    Assert-Fails { & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $install -Port $ForeignPort -TimeoutSeconds 5 } 'not the JARVIS core|refusing'
    Assert-True ($null -ne (Get-Process -Id $foreignProc.Id -ErrorAction SilentlyContinue)) 'foreign process must survive Stop-JarvisProgram'

    'HANDOFF_TESTS=PASS'
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
    foreach ($candidate in @($install, $foreignRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            try { & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $candidate -Port $TestPort -TimeoutSeconds 5 | Out-Null } catch { }
            try { & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $candidate -Port $ForeignPort -TimeoutSeconds 5 | Out-Null } catch { }
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
