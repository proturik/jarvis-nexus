[CmdletBinding()]
param(
    [string]$KeyRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'),
    [string]$PublicKeyOut,
    [ValidateRange(2048, 4096)][int]$KeySize = 3072
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($PublicKeyOut)) { $PublicKeyOut = Join-Path $PSScriptRoot 'public-key.xml' }

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
                throw "Reparse points are forbidden in signing-key paths: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
$resolvedKeyRoot = [IO.Path]::GetFullPath($KeyRoot).TrimEnd('\') + '\'
Assert-NoExistingReparsePoint -Path $repoRoot
Assert-NoExistingReparsePoint -Path $resolvedKeyRoot
if ($resolvedKeyRoot.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The private signing-key directory must be outside the Git repository.'
}

$privatePath = Join-Path $KeyRoot 'private-signing-key.dpapi'
$metadataPath = Join-Path $KeyRoot 'signing-key.json'
$entropy = [Text.Encoding]::UTF8.GetBytes('JARVIS NEXUS PRIVATE SIGNING KEY v1')
$rsa = $null
$privateBytes = $null
$protectedBytes = $null
try {
    New-Item -ItemType Directory -Path $KeyRoot -Force | Out-Null
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $KeyRoot /inheritance:r /grant:r "*${ownerSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to restrict signing-key directory ACL (icacls exit $LASTEXITCODE)." }

    if (Test-Path -LiteralPath $privatePath -PathType Leaf) {
        $protectedBytes = [IO.File]::ReadAllBytes($privatePath)
        $privateBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($privateBytes))
        if ($rsa.KeySize -lt 2048) { throw 'Existing signing key is weaker than RSA-2048.' }
        $created = $false
    } else {
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider $KeySize
        $rsa.PersistKeyInCsp = $false
        $privateBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $privateBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $privateTemp = $privatePath + '.tmp-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($privateTemp, $protectedBytes)
        Move-Item -LiteralPath $privateTemp -Destination $privatePath
        $created = $true
    }

    $publicXml = $rsa.ToXmlString($false)
    $publicBytes = [Text.Encoding]::UTF8.GetBytes($publicXml)
    $fingerprint = Get-Sha256Hex $publicBytes
    $publicDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($PublicKeyOut))
    New-Item -ItemType Directory -Path $publicDirectory -Force | Out-Null
    $publicTemp = $PublicKeyOut + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllBytes($publicTemp, $publicBytes)
    Move-Item -LiteralPath $publicTemp -Destination $PublicKeyOut -Force

    $metadata = [ordered]@{
        schemaVersion = 1; algorithm = 'RS256'; keySize = $rsa.KeySize
        publicKeyFingerprint = $fingerprint
        createdAt = if ($created) { [DateTimeOffset]::UtcNow.ToString('o') } elseif (Test-Path -LiteralPath $metadataPath) {
            try { (Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json).createdAt } catch { $null }
        } else { $null }
    }
    if ([string]::IsNullOrWhiteSpace([string]$metadata.createdAt)) { $metadata.createdAt = [DateTimeOffset]::UtcNow.ToString('o') }
    $metadataText = $metadata | ConvertTo-Json -Compress
    $metadataTemp = $metadataPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($metadataTemp, $metadataText, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $metadataTemp -Destination $metadataPath -Force

    [pscustomobject]@{
        Ok = $true; Created = $created; Algorithm = 'RS256'; KeySize = $rsa.KeySize
        PublicKeyFingerprint = $fingerprint; PublicKeyPath = [IO.Path]::GetFullPath($PublicKeyOut)
        ProtectedBy = 'Windows DPAPI CurrentUser'; PrivateKeyPath = [IO.Path]::GetFullPath($privatePath)
    }
} finally {
    if ($null -ne $privateBytes) { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    if ($null -ne $protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    if ($null -ne $rsa) { $rsa.Dispose() }
    [Array]::Clear($entropy, 0, $entropy.Length)
}
