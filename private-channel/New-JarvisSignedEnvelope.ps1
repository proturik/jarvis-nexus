[CmdletBinding(DefaultParameterSetName = 'license')]
param(
    [Parameter(Mandatory)][ValidateSet('license', 'update')][string]$Kind,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$KeyRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'),
    [Parameter(Mandatory, ParameterSetName = 'license')][string[]]$InstallId,
    [Parameter(ParameterSetName = 'license')][string]$LicenseId = ('license-' + [Guid]::NewGuid().ToString('N')),
    [Parameter(ParameterSetName = 'license')][string[]]$Feature = @('core', 'voice', 'vision'),
    [Parameter(Mandatory, ParameterSetName = 'update')][string]$PackagePath,
    [Parameter(Mandatory, ParameterSetName = 'update')][string]$Version,
    [Parameter(Mandatory, ParameterSetName = 'update')][string]$ReleaseId,
    [ValidateRange(0, 3650)][int]$ValidDays = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security -ErrorAction Stop

function Assert-NoExistingReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $redirectedRoots = @(
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('UserProfile'),
        (Split-Path -Parent ([Environment]::GetFolderPath('UserProfile'))),
        ([Environment]::SystemDirectory | Split-Path -Parent)
    ) | ForEach-Object { if ($_) { [IO.Path]::GetFullPath($_).TrimEnd('\') } } | Where-Object { $_ } | Select-Object -Unique
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($redirectedRoots -contains $current) { break }
                throw "Reparse points are forbidden in release-package paths: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-StreamSha256Hex {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '')
    } finally { $sha.Dispose(); $Stream.Position = 0 }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

if (Test-Path -LiteralPath $OutputPath) { throw 'Refusing to overwrite an existing signed envelope.' }
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
$packageStream = $null
$tempPath = $null
try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
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

    $now = [DateTimeOffset]::UtcNow
    $effectiveValidDays = if ($PSBoundParameters.ContainsKey('ValidDays')) { $ValidDays } elseif ($Kind -eq 'license') { 365 } else { 7 }
    if ($effectiveValidDays -lt 1) { throw 'ValidDays must be at least 1.' }
    if ($Kind -eq 'update' -and $effectiveValidDays -gt 31) { throw 'Update manifests cannot be valid for more than 31 days.' }
    $common = [ordered]@{
        kind = $Kind; schemaVersion = 1; issuer = 'JARVIS NEXUS PRIVATE'
        keyFingerprint = $publicFingerprint; notBefore = $now.AddMinutes(-1).ToString('o')
        issuedAt = $now.ToString('o'); expiresAt = $now.AddDays($effectiveValidDays).ToString('o')
    }
    if ($Kind -eq 'license') {
        if ($LicenseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{5,79}$') { throw 'LicenseId format is invalid.' }
        $ids = @($InstallId | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($ids.Count -eq 0 -or $ids.Count -gt 16) { throw 'A licence must authorise between 1 and 16 install IDs.' }
        foreach ($id in $ids) { if ($id -notmatch '^install-[A-Za-z0-9_-]{12,80}$') { throw "Unsafe install ID: $id" } }
        $features = @($Feature | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
        if ($features.Count -eq 0 -or $features.Count -gt 32) { throw 'A licence must contain between 1 and 32 features.' }
        foreach ($name in $features) { if ($name -notmatch '^[a-z][a-z0-9._-]{1,39}$') { throw "Unsafe feature name: $name" } }
        $common.licenseId = $LicenseId; $common.installIds = $ids; $common.features = $features
    } else {
        if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Version must be numeric semantic versioning, for example 1.2.3.' }
        if ($ReleaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'ReleaseId format is invalid.' }
        if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw 'Update package does not exist.' }
        $packageFull = [IO.Path]::GetFullPath($PackagePath)
        Assert-NoExistingReparsePoint -Path $packageFull
        $packageName = [IO.Path]::GetFileName($packageFull)
        if ($packageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.zip$' -or
            $packageName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Update package filename is unsafe.' }
        $packageStream = New-Object IO.FileStream($packageFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($packageStream.Length -le 0) { throw 'Update package is empty.' }
        $packageHash = Get-StreamSha256Hex -Stream $packageStream
        $common.channel = 'private'; $common.version = $Version; $common.releaseId = $ReleaseId
        $common.package = [ordered]@{
            file = $packageName; bytes = $packageStream.Length; sha256 = $packageHash
        }
    }

    $payloadBytes = [Text.Encoding]::UTF8.GetBytes(($common | ConvertTo-Json -Depth 8 -Compress))
    $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    $envelope = [ordered]@{
        schemaVersion = 1; algorithm = 'RS256'; keyFingerprint = $publicFingerprint
        payloadBase64 = [Convert]::ToBase64String($payloadBytes)
        signatureBase64 = [Convert]::ToBase64String($signature)
    } | ConvertTo-Json -Compress
    $outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $tempPath = $OutputPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tempPath, $envelope, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $OutputPath
    $tempPath = $null
    [pscustomobject]@{
        Ok = $true; Kind = $Kind; OutputPath = [IO.Path]::GetFullPath($OutputPath)
        KeyFingerprint = $publicFingerprint
        Id = if ($Kind -eq 'license') { $LicenseId } else { $ReleaseId }
        ExpiresAt = $common.expiresAt
    }
} finally {
    foreach ($bytes in @($privateBytes, $protectedBytes, $payloadBytes)) {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ($null -ne $packageStream) { $packageStream.Dispose() }
    if ($null -ne $rsa) { $rsa.Dispose() }
    if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force }
    [Array]::Clear($entropy, 0, $entropy.Length)
}
