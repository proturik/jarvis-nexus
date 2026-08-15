Set-StrictMode -Version Latest

$script:ProductionPublicKeyFingerprint = 'A935F9AC016C656C695A53A988C5EAD5CE30D42F6D57550A35311D7D8C0B455D'

function Get-RequiredProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Signed payload is missing '$Name'." }
    return $property.Value
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function ConvertFrom-JarvisJson {
    param([Parameter(Mandatory)][string]$Json)
    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey('DateKind')) { return $Json | ConvertFrom-Json -DateKind String }
    return $Json | ConvertFrom-Json
}

function Read-BoundedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$MaxBytes, [Parameter(Mandatory)][string]$Label)
    $stream = New-Object IO.FileStream([IO.Path]::GetFullPath($Path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] ($MaxBytes + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt $MaxBytes) { throw "$Label is too large." }
        $result = New-Object byte[] $count
        if ($count -gt 0) { [Array]::Copy($buffer, $result, $count) }
        return $result
    } finally { $stream.Dispose() }
}

function ConvertTo-RequiredUtcTime {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)
    $raw = [string]$Value
    if ($raw -notmatch '(?:Z|\+00:00)$') { throw "Signed payload timestamp '$Name' must explicitly use UTC." }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $raw,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) { throw "Signed payload has an invalid '$Name' timestamp." }
    return $parsed.ToUniversalTime()
}

function Test-IntegralValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    $type = $Value.GetType()
    return $type -eq [byte] -or $type -eq [sbyte] -or $type -eq [int16] -or $type -eq [uint16] -or `
        $type -eq [int] -or $type -eq [uint] -or $type -eq [int64] -or $type -eq [uint64]
}

function Test-ReleaseIndexUrl {
    param([Parameter(Mandatory)][string]$Url, [string]$Field = 'URL', [switch]$AllowLoopbackHttp)
    if ($Url.Length -gt 2048) { throw "Release index $Field is too long." }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "Release index $Field is not an absolute URL." }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { throw "Release index $Field must not contain credentials." }
    if ($uri.Scheme -eq 'https') { return }
    if ($uri.Scheme -eq 'http' -and $AllowLoopbackHttp -and $uri.Host -eq '127.0.0.1') { return }
    throw "Release index $Field must use HTTPS."
}

function Test-JarvisSignedEnvelopeCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('license', 'update', 'index')][string]$ExpectedKind,
        [Parameter(Mandatory)][string]$EnvelopePath,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$PinnedPublicKeyFingerprint,
        [string]$InstallId,
        [string]$PackagePath,
        [string]$ExpectedChannel = 'private',
        [string]$CurrentVersion,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow,
        [switch]$AllowLoopbackHttp
    )

    foreach ($path in @($EnvelopePath, $PublicKeyPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required verification file is missing: $path" }
    }
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $envelopeBytes = Read-BoundedFile -Path $EnvelopePath -MaxBytes 131072 -Label 'Signed envelope'
    try { $envelopeText = $strictUtf8.GetString($envelopeBytes) }
    catch { throw 'Signed envelope is not strict UTF-8.' }
    try { $envelope = ConvertFrom-JarvisJson $envelopeText }
    catch { throw 'Signed envelope is not valid JSON.' }
    if ([int](Get-RequiredProperty $envelope 'schemaVersion') -ne 1) { throw 'Unsupported signed-envelope schema.' }
    if ([string](Get-RequiredProperty $envelope 'algorithm') -ne 'RS256') { throw 'Unsupported signature algorithm.' }
    try {
        $payloadBytes = [Convert]::FromBase64String([string](Get-RequiredProperty $envelope 'payloadBase64'))
        $signatureBytes = [Convert]::FromBase64String([string](Get-RequiredProperty $envelope 'signatureBase64'))
    } catch { throw 'Signed envelope contains invalid base64.' }
    if ($payloadBytes.Length -eq 0 -or $payloadBytes.Length -gt 65536) { throw 'Signed payload size is invalid.' }
    if ($signatureBytes.Length -lt 256 -or $signatureBytes.Length -gt 1024) { throw 'Signature size is invalid.' }

    $publicBytes = Read-BoundedFile -Path $PublicKeyPath -MaxBytes 16384 -Label 'Public key'
    $actualFingerprint = Get-Sha256Hex $publicBytes
    if ($actualFingerprint -ne $PinnedPublicKeyFingerprint.ToUpperInvariant()) { throw 'Public signing key fingerprint is not trusted.' }
    try { $publicXml = $strictUtf8.GetString($publicBytes) }
    catch { throw 'Public key is not strict UTF-8.' }
    if ($publicXml -notmatch '<RSAKeyValue>' -or $publicXml -notmatch '<Modulus>' -or $publicXml -notmatch '<Exponent>') {
        throw 'Public key is not a supported RSA XML public key.'
    }
    if ($publicXml -match '<(?:D|P|Q|DP|DQ|InverseQ)>') { throw 'Public key file must not contain private RSA parameters.' }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($publicXml)
        if ($rsa.KeySize -lt 2048) { throw 'Public signing key is weaker than RSA-2048.' }
        $sha256Oid = [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        if (-not $rsa.VerifyData($payloadBytes, $sha256Oid, $signatureBytes)) { throw 'Signature verification failed.' }
    } finally { $rsa.Dispose() }

    try { $payloadText = $strictUtf8.GetString($payloadBytes) }
    catch { throw 'Signed payload is not strict UTF-8.' }
    try { $payload = ConvertFrom-JarvisJson $payloadText }
    catch { throw 'Signed payload is not valid JSON.' }
    $kind = [string](Get-RequiredProperty $payload 'kind')
    if ($kind -ne $ExpectedKind) { throw "Expected '$ExpectedKind' payload, received '$kind'." }
    if ([int](Get-RequiredProperty $payload 'schemaVersion') -ne 1) { throw 'Unsupported signed-payload schema.' }
    if ([string](Get-RequiredProperty $payload 'issuer') -ne 'JARVIS NEXUS PRIVATE') { throw 'Signed payload issuer is not trusted.' }
    if ([string](Get-RequiredProperty $payload 'keyFingerprint') -ne $actualFingerprint) { throw 'Signed payload key fingerprint mismatch.' }

    $notBefore = ConvertTo-RequiredUtcTime (Get-RequiredProperty $payload 'notBefore') 'notBefore'
    $issuedAt = ConvertTo-RequiredUtcTime (Get-RequiredProperty $payload 'issuedAt') 'issuedAt'
    $expiresAt = ConvertTo-RequiredUtcTime (Get-RequiredProperty $payload 'expiresAt') 'expiresAt'
    if ($expiresAt -le $notBefore -or $issuedAt -lt $notBefore -or $issuedAt -gt $expiresAt) { throw 'Signed payload validity window is inconsistent.' }
    $clockSkew = [TimeSpan]::FromMinutes(5)
    if ($NowUtc -lt $notBefore.Subtract($clockSkew)) { throw 'Signed payload is not active yet.' }
    if ($NowUtc -gt $expiresAt.Add($clockSkew)) { throw 'Signed payload has expired.' }
    if ($issuedAt -gt $NowUtc.Add($clockSkew)) { throw 'Signed payload claims a future issue time.' }

    if ($kind -eq 'license') {
        if (($expiresAt - $issuedAt).TotalDays -gt 3651) { throw 'Licence validity period is too long.' }
        if ([string]::IsNullOrWhiteSpace($InstallId)) { throw 'InstallId is required for licence verification.' }
        $licenseId = [string](Get-RequiredProperty $payload 'licenseId')
        if ($licenseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{5,79}$') { throw 'Licence ID format is invalid.' }
        $allowed = @((Get-RequiredProperty $payload 'installIds')) | ForEach-Object { [string]$_ }
        if ($allowed -notcontains $InstallId) { throw 'This installation is not authorised by the licence.' }
        $tier = 'lifetime'
        if ($null -ne $payload.PSObject.Properties['tier']) { $tier = ([string]$payload.tier).ToLowerInvariant() }
        if ($tier -notin @('monthly', 'yearly', 'lifetime')) { throw 'Licence tier is invalid.' }
        $validDays = ($expiresAt - $issuedAt).TotalDays
        if ($tier -eq 'monthly' -and $validDays -gt 31) { throw 'Licence validity period does not match its tier.' }
        if ($tier -eq 'yearly' -and $validDays -gt 366) { throw 'Licence validity period does not match its tier.' }
        if ($tier -eq 'lifetime' -and $validDays -gt 3651) { throw 'Licence validity period does not match its tier.' }
        return [pscustomobject]@{
            Ok = $true; Kind = 'license'; LicenseId = $licenseId; Tier = $tier
            Issuer = 'JARVIS NEXUS PRIVATE'; KeyFingerprint = $actualFingerprint
            Features = @((Get-RequiredProperty $payload 'features')); ExpiresAt = $expiresAt
        }
    }

    if ($kind -eq 'index') {
        if (($expiresAt - $issuedAt).TotalDays -gt 31) { throw 'Release index validity period is too long.' }
        if ([string](Get-RequiredProperty $payload 'channel') -ne $ExpectedChannel) { throw 'Release index channel is not authorised.' }
        $indexVersion = Get-RequiredProperty $payload 'indexVersion'
        if (-not (Test-IntegralValue $indexVersion)) { throw 'Release index version must be an integer.' }
        if ([long]$indexVersion -ne 1) { throw 'Release index version must be exactly 1.' }
        $releases = @((Get-RequiredProperty $payload 'releases'))
        if ($releases.Count -lt 1 -or $releases.Count -gt 64) { throw 'Release index must contain between 1 and 64 releases.' }
        $seenReleaseIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $seenVersions = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $parsedReleases = @()
        foreach ($entry in $releases) {
            $version = [string](Get-RequiredProperty $entry 'version')
            if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Release index entry version is invalid.' }
            $releaseId = [string](Get-RequiredProperty $entry 'releaseId')
            if ($releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'Release index entry releaseId is invalid.' }
            $envelopeUrl = [string](Get-RequiredProperty $entry 'envelopeUrl')
            $packageUrl = [string](Get-RequiredProperty $entry 'packageUrl')
            Test-ReleaseIndexUrl -Url $envelopeUrl -Field 'envelopeUrl' -AllowLoopbackHttp:$AllowLoopbackHttp
            Test-ReleaseIndexUrl -Url $packageUrl -Field 'packageUrl' -AllowLoopbackHttp:$AllowLoopbackHttp
            $packageBytesValue = Get-RequiredProperty $entry 'packageBytes'
            if (-not (Test-IntegralValue $packageBytesValue)) { throw 'Release index entry packageBytes is invalid.' }
            $packageBytes = [long]$packageBytesValue
            if ($packageBytes -le 0 -or $packageBytes -gt 4294967296) { throw 'Release index entry packageBytes must be between 1 byte and 4 GiB.' }
            $packageSha256 = ([string](Get-RequiredProperty $entry 'packageSha256')).ToUpperInvariant()
            $envelopeSha256 = ([string](Get-RequiredProperty $entry 'envelopeSha256')).ToUpperInvariant()
            if ($packageSha256 -notmatch '^[0-9A-F]{64}$') { throw 'Release index entry packageSha256 is invalid.' }
            if ($envelopeSha256 -notmatch '^[0-9A-F]{64}$') { throw 'Release index entry envelopeSha256 is invalid.' }
            $publishedAtUtc = ConvertTo-RequiredUtcTime (Get-RequiredProperty $entry 'publishedAtUtc') 'publishedAtUtc'
            if (-not $seenReleaseIds.Add($releaseId)) { throw "Release index contains a duplicate releaseId: $releaseId" }
            if (-not $seenVersions.Add($version)) { throw "Release index contains a duplicate version: $version" }
            $parsedReleases += [pscustomobject]@{
                Version = $version; ReleaseId = $releaseId; EnvelopeUrl = $envelopeUrl; PackageUrl = $packageUrl
                PackageBytes = $packageBytes; PackageSha256 = $packageSha256; EnvelopeSha256 = $envelopeSha256
                PublishedAtUtc = $publishedAtUtc
            }
        }
        return [pscustomobject]@{
            Ok = $true; Kind = 'index'; Channel = [string](Get-RequiredProperty $payload 'channel')
            KeyFingerprint = $actualFingerprint; ExpiresAt = $expiresAt; Releases = $parsedReleases
        }
    }

    if (($expiresAt - $issuedAt).TotalDays -gt 31) { throw 'Update manifest validity period is too long.' }
    if ([string](Get-RequiredProperty $payload 'channel') -ne $ExpectedChannel) { throw 'Update channel is not authorised.' }
    $version = [string](Get-RequiredProperty $payload 'version')
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Update version must use numeric semantic versioning.' }
    if ($CurrentVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'CurrentVersion is required and must use numeric semantic versioning.' }
    if ([version]$version -le [version]$CurrentVersion) { throw 'Update is replayed, equal to, or older than the installed version.' }
    if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw 'Update package is missing.'
    }
    $releaseId = [string](Get-RequiredProperty $payload 'releaseId')
    if ($releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'ReleaseId format is invalid.' }
    $package = Get-RequiredProperty $payload 'package'
    $expectedFile = [string](Get-RequiredProperty $package 'file')
    if ($expectedFile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.zip$' -or
        $expectedFile -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or
        $expectedFile.EndsWith('.') -or $expectedFile.EndsWith(' ')) { throw 'Update package filename is unsafe.' }
    if ([IO.Path]::GetFileName($PackagePath) -cne $expectedFile) { throw 'Update package filename does not match the signed payload.' }
    $expectedBytes = [long](Get-RequiredProperty $package 'bytes')
    $actualBytes = (Get-Item -LiteralPath $PackagePath).Length
    if ($expectedBytes -le 0 -or $actualBytes -ne $expectedBytes) { throw 'Update package size does not match the signed payload.' }
    $expectedHash = ([string](Get-RequiredProperty $package 'sha256')).ToUpperInvariant()
    if ($expectedHash -notmatch '^[0-9A-F]{64}$') { throw 'Signed update hash is invalid.' }
    $actualHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Update package SHA-256 does not match the signed payload.' }
    return [pscustomobject]@{
        Ok = $true; Kind = 'update'; Version = $version; ReleaseId = $releaseId
        Channel = [string](Get-RequiredProperty $payload 'channel'); KeyFingerprint = $actualFingerprint
        PackageHash = $actualHash; ExpiresAt = $expiresAt
    }
}

function Test-JarvisSignedEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('license', 'update', 'index')][string]$ExpectedKind,
        [Parameter(Mandatory)][string]$EnvelopePath,
        [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
        [string]$PinnedPublicKeyFingerprint = $script:ProductionPublicKeyFingerprint,
        [string]$InstallId,
        [string]$PackagePath,
        [string]$ExpectedChannel = 'private',
        [string]$CurrentVersion,
        [switch]$AllowLoopbackHttp
    )
    Test-JarvisSignedEnvelopeCore -ExpectedKind $ExpectedKind -EnvelopePath $EnvelopePath -PublicKeyPath $PublicKeyPath `
        -PinnedPublicKeyFingerprint $PinnedPublicKeyFingerprint -InstallId $InstallId -PackagePath $PackagePath `
        -ExpectedChannel $ExpectedChannel -CurrentVersion $CurrentVersion -AllowLoopbackHttp:$AllowLoopbackHttp
}

function Test-JarvisReleaseIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IndexPath,
        [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
        [string]$PinnedPublicKeyFingerprint = $script:ProductionPublicKeyFingerprint,
        [string]$ExpectedChannel = 'private',
        [switch]$AllowLoopbackHttp
    )
    Test-JarvisSignedEnvelopeCore -ExpectedKind 'index' -EnvelopePath $IndexPath -PublicKeyPath $PublicKeyPath `
        -PinnedPublicKeyFingerprint $PinnedPublicKeyFingerprint -ExpectedChannel $ExpectedChannel `
        -AllowLoopbackHttp:$AllowLoopbackHttp
}

Export-ModuleMember -Function Test-JarvisSignedEnvelope, Test-JarvisReleaseIndex
