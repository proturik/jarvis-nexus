[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$testRoot = Join-Path $env:TEMP ('jarvis-private-channel-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$rsa = $null
try {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
    $rsa.PersistKeyInCsp = $false
    $publicKeyPath = Join-Path $testRoot 'public-key.xml'
    [IO.File]::WriteAllText($publicKeyPath, $rsa.ToXmlString($false), [Text.UTF8Encoding]::new($false))

    function Write-SignedEnvelope {
        param($Payload, [string]$Path)
        $payloadJson = $Payload | ConvertTo-Json -Depth 8 -Compress
        $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadJson)
        $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
        $envelope = [ordered]@{
            schemaVersion = 1; algorithm = 'RS256'
            payloadBase64 = [Convert]::ToBase64String($payloadBytes)
            signatureBase64 = [Convert]::ToBase64String($signature)
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($Path, $envelope, [Text.UTF8Encoding]::new($false))
    }

    $now = [DateTimeOffset]::UtcNow
    $installId = 'install-test-7f2f6ba9'
    $licensePath = Join-Path $testRoot 'license.json'
    Write-SignedEnvelope ([ordered]@{
        kind = 'license'; schemaVersion = 1; issuer = 'JARVIS NEXUS PRIVATE'
        licenseId = 'friend-license-001'; installIds = @($installId)
        features = @('core', 'voice', 'vision')
        notBefore = $now.AddMinutes(-1).ToString('o'); expiresAt = $now.AddDays(30).ToString('o')
    }) $licensePath
    $validLicense = Test-JarvisSignedEnvelope -ExpectedKind license -EnvelopePath $licensePath -PublicKeyPath $publicKeyPath -InstallId $installId
    Assert-True ($validLicense.Ok -and $validLicense.LicenseId -eq 'friend-license-001') 'valid licence must pass'
    Assert-Fails { Test-JarvisSignedEnvelope -ExpectedKind license -EnvelopePath $licensePath -PublicKeyPath $publicKeyPath -InstallId 'another-install' } 'not authorised'

    $packagePath = Join-Path $testRoot 'jarvis-update.zip'
    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('private update package test bytes'))
    $updatePath = Join-Path $testRoot 'update.json'
    Write-SignedEnvelope ([ordered]@{
        kind = 'update'; schemaVersion = 1; channel = 'private'; version = '1.1.0'; releaseId = 'private-test-1'
        notBefore = $now.AddMinutes(-1).ToString('o'); issuedAt = $now.ToString('o'); expiresAt = $now.AddDays(7).ToString('o')
        package = [ordered]@{
            file = [IO.Path]::GetFileName($packagePath); bytes = (Get-Item -LiteralPath $packagePath).Length
            sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        }
    }) $updatePath
    $validUpdate = Test-JarvisSignedEnvelope -ExpectedKind update -EnvelopePath $updatePath -PublicKeyPath $publicKeyPath -PackagePath $packagePath
    Assert-True ($validUpdate.Ok -and $validUpdate.Version -eq '1.1.0') 'valid update must pass'

    [IO.File]::WriteAllBytes($packagePath, [Text.Encoding]::UTF8.GetBytes('tampered package'))
    Assert-Fails { Test-JarvisSignedEnvelope -ExpectedKind update -EnvelopePath $updatePath -PublicKeyPath $publicKeyPath -PackagePath $packagePath } 'size|SHA-256'

    $tamperedPath = Join-Path $testRoot 'tampered-envelope.json'
    $tampered = Get-Content -LiteralPath $licensePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $changedPayload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tampered.payloadBase64)) + ' '
    $tampered.payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($changedPayload))
    [IO.File]::WriteAllText($tamperedPath, ($tampered | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Assert-Fails { Test-JarvisSignedEnvelope -ExpectedKind license -EnvelopePath $tamperedPath -PublicKeyPath $publicKeyPath -InstallId $installId } 'Signature verification failed'

    'PRIVATE_CHANNEL_TESTS=PASS'
} finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
