[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force

function Assert-True { param([bool]$Value,[string]$Message); if(-not $Value){throw "ASSERTION FAILED: $Message"} }
function Assert-Fails { param([scriptblock]$Action,[string]$Pattern); try{& $Action|Out-Null}catch{if($_.Exception.Message -match $Pattern){return};throw};throw "Expected failure: $Pattern" }

function New-TestZip {
    param([string]$Path,[hashtable]$Entries)
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach($name in $Entries.Keys){
            $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
            try{$writer.Write([string]$Entries[$name])}finally{$writer.Dispose()}
        }
    } finally {$zip.Dispose();$stream.Dispose()}
}

$root=Join-Path $env:TEMP ('jarvis-updater-test-'+[Guid]::NewGuid().ToString('N'))
$keyRoot=Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'
New-Item -ItemType Directory -Path $root | Out-Null
try {
    & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') | Out-Null
    $install=Join-Path $root 'current-app'; New-Item -ItemType Directory -Path $install | Out-Null
    [IO.File]::WriteAllText((Join-Path $install 'old.txt'),'old',(New-Object Text.UTF8Encoding($false)))
    $stateRoot=Join-Path $root 'state'
    $package=Join-Path $root 'jarvis-9.9.9.zip'
    New-TestZip $package @{ 'payload/new.txt'='new'; 'payload/sub/version.txt'='9.9.9' }
    $envelope=Join-Path $root 'update-9.9.9.json'
    $releaseId='test-'+[Guid]::NewGuid().ToString('N')
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $envelope -KeyRoot $keyRoot -PackagePath $package -Version '9.9.9' -ReleaseId $releaseId | Out-Null
    $staged=& (Join-Path $PSScriptRoot 'Invoke-JarvisStagedUpdate.ps1') -EnvelopePath $envelope -PackagePath $package -InstallRoot $install -CurrentVersion '1.0.0' -StateRoot $stateRoot
    Assert-True ($staged.Ok -and -not $staged.Activated -and (Test-Path (Join-Path $staged.StagePath 'payload\new.txt'))) 'stage-only mode must preserve verified payload'
    Assert-True (Test-Path (Join-Path $install 'old.txt')) 'stage-only mode must not change current app'
    $result=& (Join-Path $PSScriptRoot 'Invoke-JarvisStagedUpdate.ps1') -EnvelopePath $envelope -PackagePath $package -InstallRoot $install -CurrentVersion '1.0.0' -StateRoot $stateRoot -Activate
    Assert-True ($result.Ok -and $result.Activated) 'signed update must activate'
    Assert-True ((Test-Path (Join-Path $install 'new.txt')) -and -not (Test-Path (Join-Path $install 'old.txt'))) 'new payload must replace current app'
    Assert-True (Test-Path (Join-Path $result.BackupPath 'old.txt')) 'old app must remain in rollback backup'
    $state=Read-JarvisUpdateState -StateRoot $stateRoot
    Assert-True ($state.HighestAcceptedVersion -eq '9.9.9' -and $state.AcceptedReleaseIds -contains $releaseId) 'protected state must record accepted release'
    Assert-Fails { & (Join-Path $PSScriptRoot 'Invoke-JarvisStagedUpdate.ps1') -EnvelopePath $envelope -PackagePath $package -InstallRoot $install -CurrentVersion '1.0.0' -StateRoot $stateRoot } 'not newer|already accepted|replayed'

    $rollback=& (Join-Path $PSScriptRoot 'Restore-JarvisUpdateBackup.ps1') -InstallRoot $install -BackupPath $result.BackupPath -StateRoot $stateRoot
    Assert-True ($rollback.Ok -and (Test-Path (Join-Path $install 'old.txt'))) 'rollback must restore old app'
    $stateAfterRollback=Read-JarvisUpdateState -StateRoot $stateRoot
    Assert-True ($stateAfterRollback.HighestAcceptedVersion -eq '9.9.9') 'rollback must not lower anti-replay floor'

    $badPackage=Join-Path $root 'jarvis-10.0.0.zip'
    New-TestZip $badPackage @{ 'payload/../../escape.txt'='bad' }
    $badEnvelope=Join-Path $root 'update-10.0.0.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $badEnvelope -KeyRoot $keyRoot -PackagePath $badPackage -Version '10.0.0' -ReleaseId ('test-'+[Guid]::NewGuid().ToString('N')) | Out-Null
    Assert-Fails { & (Join-Path $PSScriptRoot 'Invoke-JarvisStagedUpdate.ps1') -EnvelopePath $badEnvelope -PackagePath $badPackage -InstallRoot $install -CurrentVersion '1.0.0' -StateRoot $stateRoot } 'Unsafe ZIP path|escapes staging'
    Assert-True (-not (Test-Path (Join-Path $root 'escape.txt'))) 'zip-slip file must never be written'

    $statePath=Join-Path $stateRoot 'update-state.dpapi'
    $bytes=[IO.File]::ReadAllBytes($statePath); $bytes[0]=$bytes[0] -bxor 0x5A; [IO.File]::WriteAllBytes($statePath,$bytes)
    Assert-Fails { Read-JarvisUpdateState -StateRoot $stateRoot } 'tampered|cannot be read'
    'STAGED_UPDATER_TESTS=PASS'
} finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
