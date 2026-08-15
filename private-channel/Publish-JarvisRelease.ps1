<#
.SYNOPSIS
  Owner-side release publisher for the JARVIS NEXUS private update channel.
  Assembles a versioned program-only directory into a payload ZIP, signs the
  update manifest, records the release in releases.json and signs the release
  index. The output layout is ready to be published on GitHub Pages.

.DESCRIPTION
  ProgramRoot must already be a versioned program-only directory: it must
  contain .jarvis-program-marker and a version.txt whose trimmed content equals
  -Version. Files copied into the payload exclude any data/ directory and any
  .env file, because user data and secrets never belong in an update package.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Publish-JarvisRelease.ps1 `
    -ProgramRoot C:\JARVIS\app-1.1.0 -Version 1.1.0 -ReleaseId jarvis-1.1.0 `
    -SiteRoot .\site -PublicUrlBase https://USER.github.io/jarvis-nexus
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$SiteRoot,
    [Parameter(Mandatory)][string]$PublicUrlBase,
    [string]$KeyRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\owner-secrets'),
    [ValidateRange(1, 31)][int]$ValidDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

$markerName = '.jarvis-program-marker'
$markerContent = 'JARVIS NEXUS ULTRA program directory v1'

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Version must use numeric semantic versioning, e.g. 1.2.3.' }
if ($ReleaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'ReleaseId format is invalid.' }
if ($PublicUrlBase -notmatch '^https://[^/\s]+' -or $PublicUrlBase.EndsWith('/')) {
    throw 'PublicUrlBase must be an absolute https:// URL without a trailing slash.'
}

$programFull = [IO.Path]::GetFullPath($ProgramRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $programFull -PathType Container)) { throw "Program directory does not exist: $programFull" }
if (-not (Test-Path -LiteralPath (Join-Path $programFull $markerName) -PathType Leaf)) {
    throw "Program directory has no $markerName marker. Prepare a versioned program-only directory first."
}
$versionFile = Join-Path $programFull 'version.txt'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { throw "Program directory has no version.txt." }
if (([string](Get-Content -LiteralPath $versionFile -Raw)).Trim() -cne $Version) {
    throw "Program directory version.txt does not equal -Version '$Version'."
}

# Load the marker checker (exact bytes) to refuse an inconsistent marker early.
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force
Test-JarvisProgramMarker -Directory $programFull

$releaseDirectory = Join-Path ([IO.Path]::GetFullPath($SiteRoot)) "releases\$ReleaseId"
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
$zipPath = Join-Path $releaseDirectory "$ReleaseId.zip"
$manifestPath = Join-Path $releaseDirectory "$ReleaseId.update.json"
if (Test-Path -LiteralPath $zipPath) { throw "Refusing to overwrite an existing release package: $zipPath" }
if (Test-Path -LiteralPath $manifestPath) { throw "Refusing to overwrite an existing manifest: $manifestPath" }

# 1. Build payload/ under a fresh stage directory, then ZIP it.
$stage = Join-Path $env:TEMP ('jarvis-publish-' + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $stage 'payload'
$tempZip = Join-Path $stage "$ReleaseId.zip"
try {
    New-Item -ItemType Directory -Path $payloadRoot | Out-Null
    Get-ChildItem -LiteralPath $programFull -Force | Copy-Item -Destination $payloadRoot -Recurse -Force

    # Strip anything that must never ship in an update package.
    $dataDir = Join-Path $payloadRoot 'data'
    if (Test-Path -LiteralPath $dataDir -PathType Container) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
    $envFile = Join-Path $payloadRoot '.env'
    if (Test-Path -LiteralPath $envFile) { Remove-Item -LiteralPath $envFile -Force }
    $privateChannel = Join-Path $payloadRoot 'private-channel'
    if (Test-Path -LiteralPath $privateChannel -PathType Container) { Remove-Item -LiteralPath $privateChannel -Recurse -Force }

    # Ship the client-side updater inside the program directory so every install
    # can check and apply updates at startup. Owner-only and test scripts are
    # never bundled; the production public key travels with the client.
    $bundleRoot = Join-Path $payloadRoot 'private-channel'
    New-Item -ItemType Directory -Path $bundleRoot | Out-Null
    $repoChannel = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) 'private-channel'
    $clientFiles = @(
        'Jarvis.PrivateChannel.psm1',
        'Jarvis.UpdateState.psm1',
        'Jarvis.ReleaseIndex.psm1',
        'Invoke-JarvisUpdate.ps1',
        'Invoke-JarvisHandoff.ps1',
        'Invoke-JarvisStagedUpdate.ps1',
        'Restore-JarvisUpdateBackup.ps1',
        'Stop-JarvisProgram.ps1',
        'Start-JarvisProgram.ps1',
        'Show-JarvisUpdatePrompt.ps1',
        'public-key.xml'
    )
    foreach ($name in $clientFiles) {
        $source = Join-Path $repoChannel $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Client updater file is missing from the repository: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $bundleRoot $name) -Force
    }

    $stream = New-Object IO.FileStream($tempZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force)) {
            $relative = $file.FullName.Substring($payloadRoot.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry('payload/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $input = New-Object IO.FileStream($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally { $zip.Dispose() }
    Move-Item -LiteralPath $tempZip -Destination $zipPath
    $tempZip = $null

    # 2. Sign the update manifest.
    & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $manifestPath `
        -KeyRoot $KeyRoot -PackagePath $zipPath -Version $Version -ReleaseId $ReleaseId -ValidDays $ValidDays | Out-Null

    # 3. Record the release and re-sign the index.
    $releasesJsonPath = Join-Path ([IO.Path]::GetFullPath($SiteRoot)) 'releases.json'
    $releases = @()
    if (Test-Path -LiteralPath $releasesJsonPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $releasesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $existing.PSObject.Properties['releases']) { $releases = @($existing.releases) } else { $releases = @($existing) }
    }
    $entry = [ordered]@{
        version = $Version
        releaseId = $ReleaseId
        envelopeUrl = "$PublicUrlBase/releases/$ReleaseId/$ReleaseId.update.json"
        packageUrl = "$PublicUrlBase/releases/$ReleaseId/$ReleaseId.zip"
        packageBytes = (Get-Item -LiteralPath $zipPath).Length
        packageSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        envelopeSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
        publishedAtUtc = [DateTimeOffset]::UtcNow.ToUniversalTime().ToString('o')
    }
    $releases = @($releases | Where-Object { $null -ne $_.PSObject.Properties['releaseId'] -and [string]$_.releaseId -ne $ReleaseId }) + @($entry)
    $releasesJsonText = @{ releases = @($releases) } | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($releasesJsonPath, $releasesJsonText, (New-Object Text.UTF8Encoding($false)))

    $indexPath = Join-Path ([IO.Path]::GetFullPath($SiteRoot)) 'release-index.json'
    if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force }
    & (Join-Path $PSScriptRoot 'New-JarvisReleaseIndex.ps1') -OutputPath $indexPath -KeyRoot $KeyRoot `
        -ReleasesJsonPath $releasesJsonPath -ValidDays $ValidDays | Out-Null

    [pscustomobject]@{
        Ok = $true
        Version = $Version
        ReleaseId = $ReleaseId
        ZipPath = [IO.Path]::GetFullPath($zipPath)
        ManifestPath = [IO.Path]::GetFullPath($manifestPath)
        IndexPath = [IO.Path]::GetFullPath($indexPath)
        PackageSha256 = $entry.packageSha256
        EnvelopeSha256 = $entry.envelopeSha256
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
