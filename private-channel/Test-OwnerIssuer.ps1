[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force
$privateChannelModule = Get-Module Jarvis.PrivateChannel

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure matching '$Pattern'."
}
function Test-WithPinnedKey {
    param([hashtable]$Arguments)
    & $privateChannelModule { param($values) Test-JarvisSignedEnvelopeCore @values } $Arguments
}

$root = Join-Path $env:TEMP ('jarvis-owner-issuer-test-' + [Guid]::NewGuid().ToString('N'))
$keyRoot = Join-Path $root 'keys'
$publicKey = Join-Path $root 'public-key.xml'
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $created = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKey -KeySize 2048
    Assert-True ($created.Ok -and $created.Created) 'first key initialisation must create a key'
    Assert-True ((Test-Path -LiteralPath (Join-Path $keyRoot 'private-signing-key.dpapi')) -and -not (Select-String -LiteralPath (Join-Path $keyRoot 'private-signing-key.dpapi') -SimpleMatch '<D>' -Quiet)) 'private key must be DPAPI encrypted'
    $reopened = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKey -KeySize 2048
    Assert-True (-not $reopened.Created -and $reopened.PublicKeyFingerprint -eq $created.PublicKeyFingerprint) 'initialisation must reuse the existing key'

    $installId = 'install-' + [Guid]::NewGuid().ToString('N')
    $licensePath = Join-Path $root 'friend-license.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind license -OutputPath $licensePath -KeyRoot $keyRoot -InstallId $installId -LicenseId 'friend-test-001' | Out-Null
    $licenseArgs = @{ ExpectedKind='license'; EnvelopePath=$licensePath; PublicKeyPath=$publicKey; PinnedPublicKeyFingerprint=$created.PublicKeyFingerprint; InstallId=$installId }
    $license = Test-WithPinnedKey $licenseArgs
    Assert-True ($license.Ok -and $license.LicenseId -eq 'friend-test-001') 'owner-issued licence must verify'
    $wrongLicenseArgs = $licenseArgs.Clone(); $wrongLicenseArgs.InstallId = 'install-' + [Guid]::NewGuid().ToString('N')
    Assert-Fails { Test-WithPinnedKey $wrongLicenseArgs } 'not authorised'

    $packagePath = Join-Path $root 'jarvis-private-1.1.0.zip'
    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('owner issuer package test'))
    $updatePath = Join-Path $root 'update.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $updatePath -KeyRoot $keyRoot -PackagePath $packagePath -Version '1.1.0' -ReleaseId 'private-1.1.0' | Out-Null
    $updateArgs = @{ ExpectedKind='update'; EnvelopePath=$updatePath; PublicKeyPath=$publicKey; PinnedPublicKeyFingerprint=$created.PublicKeyFingerprint; PackagePath=$packagePath; CurrentVersion='1.0.0' }
    $update = Test-WithPinnedKey $updateArgs
    Assert-True ($update.Ok -and $update.Version -eq '1.1.0') 'owner-issued update must verify'
    $replayArgs = $updateArgs.Clone(); $replayArgs.CurrentVersion = '1.1.0'
    Assert-Fails { Test-WithPinnedKey $replayArgs } 'replayed|equal to|older'
    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('tampered owner package'))
    Assert-Fails { Test-WithPinnedKey $updateArgs } 'size|SHA-256'
    'OWNER_ISSUER_TESTS=PASS'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
