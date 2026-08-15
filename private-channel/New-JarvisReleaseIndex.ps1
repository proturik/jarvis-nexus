[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$KeyRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'),
    [ValidateRange(1, 31)][int]$ValidDays = 7,
    [Parameter(Mandatory)][string]$ReleasesJsonPath,
    [switch]$AllowLoopbackHttp,
    [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security -ErrorAction Stop

function Get-Sha256Hex {
    param([byte[]]$Bytes)
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

function Get-ReleaseField {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Name)
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Release index entry is missing '$Name'." }
    return $property.Value
}

function ConvertTo-RequiredUtcTime {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)
    $raw = [string]$Value
    if ($raw -notmatch '(?:Z|\+00:00)$') { throw "Release timestamp '$Name' must explicitly use UTC." }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $raw,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) { throw "Release index has an invalid '$Name' timestamp." }
    return $parsed.ToUniversalTime()
}

function Assert-HttpsReleaseUrl {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Field)
    if ($Url.Length -gt 2048) { throw "Release index $Field is too long." }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "Release index $Field is not an absolute URL." }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { throw "Release index $Field must not contain credentials." }
    if ($uri.Scheme -eq 'https') { return }
    if ($uri.Scheme -eq 'http' -and $AllowLoopbackHttp -and $uri.Host -eq '127.0.0.1') { return }
    throw "Release index $Field must use HTTPS."
}

if (Test-Path -LiteralPath $OutputPath) { throw 'Refusing to overwrite an existing release index.' }
$privatePath = Join-Path $KeyRoot 'private-signing-key.dpapi'
$metadataPath = Join-Path $KeyRoot 'signing-key.json'
foreach ($required in @($privatePath, $metadataPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Owner signing key is not initialised: $required" }
}

$entropy = [Text.Encoding]::UTF8.GetBytes('JARVIS NEXUS PRIVATE SIGNING KEY v1')
$protectedBytes = $null
$privateBytes = $null
$payloadBytes = $null
$rsa = $null
$tempPath = $null
try {
    $releasesText = Get-Content -LiteralPath $ReleasesJsonPath -Raw -Encoding UTF8
    try { $releasesJson = ConvertFrom-JarvisJson $releasesText } catch { throw 'Releases JSON file is not valid JSON.' }
    $releases = @($releasesJson)
    if ($releasesJson -is [pscustomobject] -and $null -ne $releasesJson.PSObject.Properties['releases']) {
        $releases = @($releasesJson.releases)
    }
    if ($releases.Count -lt 1 -or $releases.Count -gt 64) { throw 'Release index must contain between 1 and 64 releases.' }
    $seenReleaseIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seenVersions = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $validatedReleases = @()
    foreach ($entry in $releases) {
        $version = [string](Get-ReleaseField -Entry $entry -Name 'version')
        if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Release index entry has an invalid version: $version" }
        $releaseId = [string](Get-ReleaseField -Entry $entry -Name 'releaseId')
        if ($releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw "Release index entry has an invalid releaseId: $releaseId" }
        $envelopeUrl = [string](Get-ReleaseField -Entry $entry -Name 'envelopeUrl')
        $packageUrl = [string](Get-ReleaseField -Entry $entry -Name 'packageUrl')
        Assert-HttpsReleaseUrl -Url $envelopeUrl -Field 'envelopeUrl'
        Assert-HttpsReleaseUrl -Url $packageUrl -Field 'packageUrl'
        try { $packageBytes = [long](Get-ReleaseField -Entry $entry -Name 'packageBytes') } catch { throw 'Release index entry packageBytes is invalid.' }
        if ($packageBytes -le 0 -or $packageBytes -gt 4294967296) { throw "Release index entry packageBytes must be between 1 byte and 4 GiB: $packageBytes" }
        $packageSha256 = ([string](Get-ReleaseField -Entry $entry -Name 'packageSha256')).ToUpperInvariant()
        $envelopeSha256 = ([string](Get-ReleaseField -Entry $entry -Name 'envelopeSha256')).ToUpperInvariant()
        if ($packageSha256 -notmatch '^[0-9A-F]{64}$') { throw "Release index entry packageSha256 is invalid: $packageSha256" }
        if ($envelopeSha256 -notmatch '^[0-9A-F]{64}$') { throw "Release index entry envelopeSha256 is invalid: $envelopeSha256" }
        $publishedAtUtc = [string](Get-ReleaseField -Entry $entry -Name 'publishedAtUtc')
        $null = ConvertTo-RequiredUtcTime -Value $publishedAtUtc -Name 'publishedAtUtc'
        if (-not $seenReleaseIds.Add($releaseId)) { throw "Duplicate releaseId in release index: $releaseId" }
        if (-not $seenVersions.Add($version)) { throw "Duplicate version in release index: $version" }
        $validatedReleases += [pscustomobject]@{
            version = $version; releaseId = $releaseId; envelopeUrl = $envelopeUrl; packageUrl = $packageUrl
            packageBytes = $packageBytes; packageSha256 = $packageSha256; envelopeSha256 = $envelopeSha256
            publishedAtUtc = $publishedAtUtc
        }
    }

    $metadata = ConvertFrom-JarvisJson (Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8)
    $protectedBytes = [IO.File]::ReadAllBytes($privatePath)
    $privateBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($privateBytes))
    if ($rsa.KeySize -lt 2048) { throw 'Signing key is weaker than RSA-2048.' }
    $publicFingerprint = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($false)))
    if ($publicFingerprint -ne [string]$metadata.publicKeyFingerprint) { throw 'Signing-key metadata fingerprint mismatch.' }

    $now = $NowUtc.ToUniversalTime()
    $common = [ordered]@{
        kind = 'index'; schemaVersion = 1; issuer = 'JARVIS NEXUS PRIVATE'
        keyFingerprint = $publicFingerprint; notBefore = $now.AddMinutes(-1).ToString('o')
        issuedAt = $now.ToString('o'); expiresAt = $now.AddDays($ValidDays).ToString('o')
        channel = 'private'; indexVersion = 1; releases = $validatedReleases
    }
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes(($common | ConvertTo-Json -Depth 10 -Compress))
    $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    $envelope = [ordered]@{
        schemaVersion = 1; algorithm = 'RS256'; keyFingerprint = $publicFingerprint
        payloadBase64 = [Convert]::ToBase64String($payloadBytes)
        signatureBase64 = [Convert]::ToBase64String($signature)
    } | ConvertTo-Json -Compress
    $outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $tempPath = $OutputPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tempPath, $envelope, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $OutputPath
    $tempPath = $null
    [pscustomobject]@{
        Ok = $true; Kind = 'index'; OutputPath = [IO.Path]::GetFullPath($OutputPath)
        KeyFingerprint = $publicFingerprint; ReleaseCount = $validatedReleases.Count
        ExpiresAt = $common.expiresAt
    }
} finally {
    foreach ($bytes in @($privateBytes, $protectedBytes, $payloadBytes)) {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ($null -ne $rsa) { $rsa.Dispose() }
    if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force }
    [Array]::Clear($entropy, 0, $entropy.Length)
}
