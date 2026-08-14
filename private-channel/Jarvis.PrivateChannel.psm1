Set-StrictMode -Version Latest

function Get-RequiredProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Signed payload is missing '$Name'." }
    return $property.Value
}

function ConvertTo-RequiredUtcTime {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) { throw "Signed payload has an invalid '$Name' timestamp." }
    return $parsed.ToUniversalTime()
}

function Test-JarvisSignedEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('license', 'update')][string]$ExpectedKind,
        [Parameter(Mandatory)][string]$EnvelopePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [string]$InstallId,
        [string]$PackagePath,
        [string]$ExpectedChannel = 'private',
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    foreach ($path in @($EnvelopePath, $PublicKeyPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required verification file is missing: $path" }
    }
    if ((Get-Item -LiteralPath $EnvelopePath).Length -gt 131072) { throw 'Signed envelope is too large.' }
    if ((Get-Item -LiteralPath $PublicKeyPath).Length -gt 16384) { throw 'Public key file is too large.' }

    $envelope = Get-Content -LiteralPath $EnvelopePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int](Get-RequiredProperty $envelope 'schemaVersion') -ne 1) { throw 'Unsupported signed-envelope schema.' }
    if ([string](Get-RequiredProperty $envelope 'algorithm') -ne 'RS256') { throw 'Unsupported signature algorithm.' }
    try {
        $payloadBytes = [Convert]::FromBase64String([string](Get-RequiredProperty $envelope 'payloadBase64'))
        $signatureBytes = [Convert]::FromBase64String([string](Get-RequiredProperty $envelope 'signatureBase64'))
    } catch { throw 'Signed envelope contains invalid base64.' }
    if ($payloadBytes.Length -eq 0 -or $payloadBytes.Length -gt 65536) { throw 'Signed payload size is invalid.' }
    if ($signatureBytes.Length -lt 256 -or $signatureBytes.Length -gt 1024) { throw 'Signature size is invalid.' }

    $publicXml = Get-Content -LiteralPath $PublicKeyPath -Raw -Encoding UTF8
    if ($publicXml -notmatch '<RSAKeyValue>' -or $publicXml -notmatch '<Modulus>' -or $publicXml -notmatch '<Exponent>') {
        throw 'Public key is not a supported RSA XML public key.'
    }
    if ($publicXml -match '<(?:D|P|Q|DP|DQ|InverseQ)>') { throw 'Public key file must not contain private RSA parameters.' }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($publicXml)
        $sha256Oid = [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        if (-not $rsa.VerifyData($payloadBytes, $sha256Oid, $signatureBytes)) { throw 'Signature verification failed.' }
    } finally { $rsa.Dispose() }

    try { $payload = [Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json } catch { throw 'Signed payload is not valid UTF-8 JSON.' }
    $kind = [string](Get-RequiredProperty $payload 'kind')
    if ($kind -ne $ExpectedKind) { throw "Expected '$ExpectedKind' payload, received '$kind'." }
    if ([int](Get-RequiredProperty $payload 'schemaVersion') -ne 1) { throw 'Unsupported signed-payload schema.' }

    $notBefore = ConvertTo-RequiredUtcTime (Get-RequiredProperty $payload 'notBefore') 'notBefore'
    $expiresAt = ConvertTo-RequiredUtcTime (Get-RequiredProperty $payload 'expiresAt') 'expiresAt'
    if ($expiresAt -le $notBefore) { throw 'Signed payload expiry must be after its start time.' }
    $clockSkew = [TimeSpan]::FromMinutes(5)
    if ($NowUtc -lt $notBefore.Subtract($clockSkew)) { throw 'Signed payload is not active yet.' }
    if ($NowUtc -gt $expiresAt.Add($clockSkew)) { throw 'Signed payload has expired.' }

    if ($kind -eq 'license') {
        if ([string]::IsNullOrWhiteSpace($InstallId)) { throw 'InstallId is required for licence verification.' }
        $licenseId = [string](Get-RequiredProperty $payload 'licenseId')
        if ($licenseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{5,79}$') { throw 'Licence ID format is invalid.' }
        $allowed = @((Get-RequiredProperty $payload 'installIds')) | ForEach-Object { [string]$_ }
        if ($allowed -notcontains $InstallId) { throw 'This installation is not authorised by the licence.' }
        return [pscustomobject]@{
            Ok = $true; Kind = 'license'; LicenseId = $licenseId
            Issuer = [string](Get-RequiredProperty $payload 'issuer')
            Features = @((Get-RequiredProperty $payload 'features'))
            ExpiresAt = $expiresAt
        }
    }

    if ([string](Get-RequiredProperty $payload 'channel') -ne $ExpectedChannel) { throw 'Update channel is not authorised.' }
    $version = [string](Get-RequiredProperty $payload 'version')
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') { throw 'Update version is not valid semantic versioning.' }
    if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw 'Update package is missing.'
    }
    $package = Get-RequiredProperty $payload 'package'
    $expectedFile = [string](Get-RequiredProperty $package 'file')
    if ([IO.Path]::GetFileName($expectedFile) -ne $expectedFile -or $expectedFile -match '[\\/]') { throw 'Update package filename is unsafe.' }
    if ([IO.Path]::GetFileName($PackagePath) -ne $expectedFile) { throw 'Update package filename does not match the signed payload.' }
    $expectedBytes = [long](Get-RequiredProperty $package 'bytes')
    $actualBytes = (Get-Item -LiteralPath $PackagePath).Length
    if ($expectedBytes -le 0 -or $actualBytes -ne $expectedBytes) { throw 'Update package size does not match the signed payload.' }
    $expectedHash = ([string](Get-RequiredProperty $package 'sha256')).ToUpperInvariant()
    if ($expectedHash -notmatch '^[0-9A-F]{64}$') { throw 'Signed update hash is invalid.' }
    $actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Update package SHA-256 does not match the signed payload.' }
    return [pscustomobject]@{
        Ok = $true; Kind = 'update'; Version = $version
        ReleaseId = [string](Get-RequiredProperty $payload 'releaseId')
        Channel = [string](Get-RequiredProperty $payload 'channel')
        PackageHash = $actualHash; ExpiresAt = $expiresAt
    }
}

Export-ModuleMember -Function Test-JarvisSignedEnvelope

