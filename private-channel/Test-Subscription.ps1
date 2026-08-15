[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.Subscription.psm1') -Force

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$root = Join-Path $env:TEMP ('jarvis-subscription-test-' + [Guid]::NewGuid().ToString('N'))
$keyRoot = Join-Path $root 'keys'
$publicKey = Join-Path $root 'public-key.xml'
$legacyRsa = $null
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $created = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKey -KeySize 2048
    Assert-True ($created.Ok -and $created.Created) 'test signing key must be created'
    $fingerprint = [string]$created.PublicKeyFingerprint
    $installId = 'install-' + [Guid]::NewGuid().ToString('N')

    # Positive: issue monthly, yearly and lifetime licences and verify each.
    $monthlyPath = Join-Path $root 'license-monthly.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSubscriptionLicense.ps1') -InstallId $installId -Tier monthly -LicenseId 'sub-monthly-001' -OutputPath $monthlyPath -KeyRoot $keyRoot | Out-Null
    $monthly = Test-JarvisSubscription -LicensePath $monthlyPath -InstallId $installId -PublicKeyPath $publicKey -PinnedPublicKeyFingerprint $fingerprint
    Assert-True ($monthly.Licensed -and $monthly.Tier -eq 'monthly') 'monthly licence must verify'
    Assert-True ($monthly.LicenseId -eq 'sub-monthly-001') 'monthly licence must keep its LicenseId'
    Assert-True ($monthly.Features -contains 'voice') 'monthly licence must include the default features'

    $yearlyPath = Join-Path $root 'license-yearly.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSubscriptionLicense.ps1') -InstallId $installId -Tier yearly -LicenseId 'sub-yearly-001' -OutputPath $yearlyPath -KeyRoot $keyRoot | Out-Null
    $yearly = Test-JarvisSubscription -LicensePath $yearlyPath -InstallId $installId -PublicKeyPath $publicKey -PinnedPublicKeyFingerprint $fingerprint
    Assert-True ($yearly.Licensed -and $yearly.Tier -eq 'yearly') 'yearly licence must verify'
    Assert-True ($yearly.LicenseId -eq 'sub-yearly-001') 'yearly licence must keep its LicenseId'

    $lifetimePath = Join-Path $root 'license-lifetime.json'
    & (Join-Path $PSScriptRoot 'New-JarvisSubscriptionLicense.ps1') -InstallId $installId -Tier lifetime -LicenseId 'sub-lifetime-001' -OutputPath $lifetimePath -KeyRoot $keyRoot | Out-Null
    $lifetime = Test-JarvisSubscription -LicensePath $lifetimePath -InstallId $installId -PublicKeyPath $publicKey -PinnedPublicKeyFingerprint $fingerprint
    Assert-True ($lifetime.Licensed -and $lifetime.Tier -eq 'lifetime') 'lifetime licence must verify'
    Assert-True ($lifetime.LicenseId -eq 'sub-lifetime-001') 'lifetime licence must keep its LicenseId'

    # ExpiresAt ordering: monthly <= yearly <= lifetime.
    Assert-True ($monthly.ExpiresAt -le $yearly.ExpiresAt) 'monthly expiry must not be later than yearly expiry'
    Assert-True ($yearly.ExpiresAt -le $lifetime.ExpiresAt) 'yearly expiry must not be later than lifetime expiry'

    # Test-JarvisSubscriptionFile.
    Assert-True (Test-JarvisSubscriptionFile -LicensePath $monthlyPath) 'existing licence file must be reported'
    Assert-True (-not (Test-JarvisSubscriptionFile -LicensePath (Join-Path $root 'does-not-exist.json'))) 'missing licence file must be reported as absent'

    # Negative: tampered licence envelope must fail verification.
    $tamperedPath = Join-Path $root 'license-tampered.json'
    $tampered = Get-Content -LiteralPath $monthlyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $changedPayload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tampered.payloadBase64)) + ' '
    $tampered.payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($changedPayload))
    [IO.File]::WriteAllText($tamperedPath, ($tampered | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    Assert-Fails { Test-JarvisSubscription -LicensePath $tamperedPath -InstallId $installId -PublicKeyPath $publicKey -PinnedPublicKeyFingerprint $fingerprint } 'Signature verification failed'

    # Negative: wrong install ID must fail.
    Assert-Fails { Test-JarvisSubscription -LicensePath $monthlyPath -InstallId ('install-' + [Guid]::NewGuid().ToString('N')) -PublicKeyPath $publicKey -PinnedPublicKeyFingerprint $fingerprint } 'not authorised'

    # Negative: monthly licence with 100 validity days must be refused at issuance.
    $badMonthlyPath = Join-Path $root 'license-monthly-100.json'
    Assert-Fails {
        & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind license -OutputPath $badMonthlyPath -KeyRoot $keyRoot -InstallId $installId -LicenseId 'sub-monthly-bad' -Tier monthly -ValidDays 100
    } 'more than 31 days'

    # Backward compatibility + expired licence, signed with a second in-memory key.
    $legacyRsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
    $legacyRsa.PersistKeyInCsp = $false
    $legacyPublicKey = Join-Path $root 'legacy-public-key.xml'
    $legacyPublicBytes = [Text.Encoding]::UTF8.GetBytes($legacyRsa.ToXmlString($false))
    [IO.File]::WriteAllBytes($legacyPublicKey, $legacyPublicBytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $legacyFingerprint = ([BitConverter]::ToString($sha.ComputeHash($legacyPublicBytes))).Replace('-', '') } finally { $sha.Dispose() }

    function Write-LegacyEnvelope {
        param($Payload, [string]$Path)
        $payloadBytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 8 -Compress))
        $signature = $legacyRsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
        $envelope = [ordered]@{
            schemaVersion = 1; algorithm = 'RS256'; keyFingerprint = $legacyFingerprint
            payloadBase64 = [Convert]::ToBase64String($payloadBytes)
            signatureBase64 = [Convert]::ToBase64String($signature)
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($Path, $envelope, (New-Object Text.UTF8Encoding($false)))
    }

    $now = [DateTimeOffset]::UtcNow
    $legacyCommon = [ordered]@{
        schemaVersion = 1; issuer = 'JARVIS NEXUS PRIVATE'; keyFingerprint = $legacyFingerprint
        notBefore = $now.AddMinutes(-1).ToString('o'); issuedAt = $now.ToString('o')
    }

    $legacyPath = Join-Path $root 'license-legacy.json'
    $legacyPayload = [ordered]@{} + $legacyCommon
    $legacyPayload.kind = 'license'; $legacyPayload.licenseId = 'legacy-license-001'
    $legacyPayload.installIds = @($installId); $legacyPayload.features = @('core', 'voice', 'vision')
    $legacyPayload.expiresAt = $now.AddDays(365).ToString('o')
    Write-LegacyEnvelope $legacyPayload $legacyPath
    $legacy = Test-JarvisSubscription -LicensePath $legacyPath -InstallId $installId -PublicKeyPath $legacyPublicKey -PinnedPublicKeyFingerprint $legacyFingerprint
    Assert-True ($legacy.Licensed -and $legacy.Tier -eq 'lifetime') 'tierless licence must verify as lifetime'

    $expiredPath = Join-Path $root 'license-expired.json'
    $expiredPayload = [ordered]@{} + $legacyCommon
    $expiredPayload.kind = 'license'; $expiredPayload.licenseId = 'expired-license-001'
    $expiredPayload.installIds = @($installId); $expiredPayload.features = @('core')
    $expiredPayload.notBefore = $now.AddDays(-41).ToString('o')
    $expiredPayload.issuedAt = $now.AddDays(-40).ToString('o')
    $expiredPayload.expiresAt = $now.AddDays(-1).ToString('o')
    Write-LegacyEnvelope $expiredPayload $expiredPath
    Assert-Fails { Test-JarvisSubscription -LicensePath $expiredPath -InstallId $installId -PublicKeyPath $legacyPublicKey -PinnedPublicKeyFingerprint $legacyFingerprint } 'expired'

    'SUBSCRIPTION_TESTS=PASS'
} finally {
    if ($null -ne $legacyRsa) { $legacyRsa.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
