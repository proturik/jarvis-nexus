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

$testRoot = Join-Path $env:TEMP ('jarvis-private-channel-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$rsa = $null
try {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
    $rsa.PersistKeyInCsp = $false
    $publicKeyPath = Join-Path $testRoot 'public-key.xml'
    $publicBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($false))
    [IO.File]::WriteAllBytes($publicKeyPath, $publicBytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($publicBytes))).Replace('-', '') } finally { $sha.Dispose() }

    function Write-SignedEnvelope {
        param($Payload, [string]$Path)
        $payloadBytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 8 -Compress))
        $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
        $envelope = [ordered]@{
            schemaVersion = 1; algorithm = 'RS256'; keyFingerprint = $fingerprint
            payloadBase64 = [Convert]::ToBase64String($payloadBytes)
            signatureBase64 = [Convert]::ToBase64String($signature)
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($Path, $envelope, [Text.UTF8Encoding]::new($false))
    }

    $now = [DateTimeOffset]::UtcNow
    $common = [ordered]@{
        schemaVersion = 1; issuer = 'JARVIS NEXUS PRIVATE'; keyFingerprint = $fingerprint
        notBefore = $now.AddMinutes(-1).ToString('o'); issuedAt = $now.ToString('o')
    }
    $installId = 'install-test-7f2f6ba9'
    $licensePath = Join-Path $testRoot 'license.json'
    $licensePayload = [ordered]@{} + $common
    $licensePayload.kind = 'license'; $licensePayload.licenseId = 'friend-license-001'
    $licensePayload.installIds = @($installId); $licensePayload.features = @('core', 'voice', 'vision')
    $licensePayload.expiresAt = $now.AddDays(30).ToString('o')
    Write-SignedEnvelope $licensePayload $licensePath
    $licenseArgs = @{ ExpectedKind='license'; EnvelopePath=$licensePath; PublicKeyPath=$publicKeyPath; PinnedPublicKeyFingerprint=$fingerprint; InstallId=$installId }
    $validLicense = Test-WithPinnedKey $licenseArgs
    Assert-True ($validLicense.Ok -and $validLicense.LicenseId -eq 'friend-license-001') 'valid licence must pass'
    $wrongArgs = $licenseArgs.Clone(); $wrongArgs.InstallId = 'install-another-user-1234'
    Assert-Fails { Test-WithPinnedKey $wrongArgs } 'not authorised'
    $untrustedKeyArgs = $licenseArgs.Clone(); $untrustedKeyArgs.PinnedPublicKeyFingerprint = ('0' * 64)
    Assert-Fails { Test-WithPinnedKey $untrustedKeyArgs } 'fingerprint is not trusted'

    $packagePath = Join-Path $testRoot 'jarvis-update.zip'
    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('private update package test bytes'))
    $updatePath = Join-Path $testRoot 'update.json'
    $updatePayload = [ordered]@{} + $common
    $updatePayload.kind = 'update'; $updatePayload.channel = 'private'; $updatePayload.version = '1.1.0'
    $updatePayload.releaseId = 'private-test-1'; $updatePayload.expiresAt = $now.AddDays(7).ToString('o')
    $updatePayload.package = [ordered]@{
        file = [IO.Path]::GetFileName($packagePath); bytes = (Get-Item -LiteralPath $packagePath).Length
        sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    }
    Write-SignedEnvelope $updatePayload $updatePath
    $updateArgs = @{ ExpectedKind='update'; EnvelopePath=$updatePath; PublicKeyPath=$publicKeyPath; PinnedPublicKeyFingerprint=$fingerprint; PackagePath=$packagePath; CurrentVersion='1.0.0' }
    $validUpdate = Test-WithPinnedKey $updateArgs
    Assert-True ($validUpdate.Ok -and $validUpdate.Version -eq '1.1.0') 'valid update must pass'
    $replayArgs = $updateArgs.Clone(); $replayArgs.CurrentVersion = '1.1.0'
    Assert-Fails { Test-WithPinnedKey $replayArgs } 'replayed|equal to|older'

    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('tampered package'))
    Assert-Fails { Test-WithPinnedKey $updateArgs } 'size|SHA-256'

    $tamperedPath = Join-Path $testRoot 'tampered-envelope.json'
    $tampered = Get-Content -LiteralPath $licensePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $changedPayload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tampered.payloadBase64)) + ' '
    $tampered.payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($changedPayload))
    [IO.File]::WriteAllText($tamperedPath, ($tampered | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $tamperedArgs = $licenseArgs.Clone(); $tamperedArgs.EnvelopePath = $tamperedPath
    Assert-Fails { Test-WithPinnedKey $tamperedArgs } 'Signature verification failed'
    'PRIVATE_CHANNEL_TESTS=PASS'
} finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
