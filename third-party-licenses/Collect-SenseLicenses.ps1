[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

function Copy-DirectoryExact {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required license directory is missing: $Source"
    }
    $sourceItem = Get-Item -LiteralPath $Source -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are forbidden in license sources: $Source"
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are forbidden in license sources: $($item.FullName)"
        }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-DirectoryExact -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Read-PackageMetadata {
    param([string]$DistInfoPath)
    $metadataPath = Join-Path $DistInfoPath 'METADATA'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Package metadata is missing: $metadataPath"
    }
    $name = $null
    $version = $null
    foreach ($line in [System.IO.File]::ReadLines($metadataPath)) {
        if (-not $name -and $line.StartsWith('Name: ')) { $name = $line.Substring(6).Trim() }
        if (-not $version -and $line.StartsWith('Version: ')) { $version = $line.Substring(9).Trim() }
        if ($name -and $version) { break }
    }
    if (-not $name -or -not $version) { throw "Invalid package metadata: $metadataPath" }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$') {
        throw "Unsafe package name or version in metadata: $metadataPath"
    }
    [pscustomobject]@{ Name = $name; Version = $version }
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectRoot).Path
$resolvedOutputParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputDirectory))
if (-not (Test-Path -LiteralPath $resolvedOutputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $resolvedOutputParent | Out-Null
}
$fullOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $fullOutput) {
    throw "OutputDirectory already exists; refusing to overwrite: $fullOutput"
}

$staticRoot = Join-Path $resolvedProject 'third-party-licenses\static'
$sitePackages = Join-Path $resolvedProject '.venv-sense\Lib\site-packages'
$requiredStatic = @(
    'ISAIR-JARVIS-LICENSE.txt',
    'VOSK-APACHE-2.0.txt',
    'SILERO-CC-BY-NC-SA-4.0.txt',
    'PORTAUDIO-LICENSE.txt',
    'PYTHON-SOUNDDEVICE-LICENSE.txt',
    'PYTHON-3.12.13-LICENSE.txt',
    'OPENSSL-3.5.7-LICENSE.txt',
    'LIBFFI-LICENSE.txt',
    'GCC-RUNTIME-LIBRARY-EXCEPTION-3.1.txt',
    'MINGW-W64-LICENSE.txt',
    'MICROSOFT-RUNTIME-NOTICE.md'
)
$packagePatterns = @(
    'mss-*.dist-info',
    'numpy-*.dist-info',
    'sounddevice-*.dist-info',
    'torch-*.dist-info',
    'pillow-*.dist-info',
    'certifi-*.dist-info',
    'charset_normalizer-*.dist-info',
    'tqdm-*.dist-info',
    'setuptools-*.dist-info',
    'markupsafe-*.dist-info',
    'cffi-*.dist-info'
)

foreach ($file in $requiredStatic) {
    $path = Join-Path $staticRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required static notice is missing: $path" }
}
if (-not (Test-Path -LiteralPath $sitePackages -PathType Container)) {
    throw "Sense build environment is missing: $sitePackages"
}

New-Item -ItemType Directory -Path $fullOutput | Out-Null
$staticOut = Join-Path $fullOutput 'static'
New-Item -ItemType Directory -Path $staticOut | Out-Null
foreach ($file in $requiredStatic) {
    Copy-Item -LiteralPath (Join-Path $staticRoot $file) -Destination (Join-Path $staticOut $file)
}

$packagesOut = Join-Path $fullOutput 'python-packages'
New-Item -ItemType Directory -Path $packagesOut | Out-Null
$inventoryPackages = @()
foreach ($pattern in $packagePatterns) {
    $matches = @(Get-ChildItem -LiteralPath $sitePackages -Directory | Where-Object { $_.Name -like $pattern })
    if ($matches.Count -ne 1) { throw "Expected exactly one package for $pattern, found $($matches.Count)." }
    $distInfo = $matches[0]
    $metadata = Read-PackageMetadata -DistInfoPath $distInfo.FullName
    $licenseSource = Join-Path $distInfo.FullName 'licenses'
    $licenseDestination = [IO.Path]::GetFullPath((Join-Path $packagesOut ($metadata.Name + '-' + $metadata.Version)))
    $packagesPrefix = [IO.Path]::GetFullPath($packagesOut).TrimEnd('\') + '\'
    if (-not $licenseDestination.StartsWith($packagesPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package license destination escapes the output directory: $licenseDestination"
    }
    Copy-DirectoryExact -Source $licenseSource -Destination $licenseDestination
    $licenseFiles = @(Get-ChildItem -LiteralPath $licenseDestination -Recurse -File)
    if ($licenseFiles.Count -lt 1) { throw "No license files copied for $($metadata.Name)." }
    $inventoryPackages += [pscustomobject]@{
        name = $metadata.Name
        version = $metadata.Version
        licenseFileCount = $licenseFiles.Count
    }
}

$allFiles = @(Get-ChildItem -LiteralPath $fullOutput -Recurse -File)
$inventory = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = 'local Sense build environment'
    staticNoticeCount = $requiredStatic.Count
    packages = $inventoryPackages
    totalLicenseFilesBeforeInventory = $allFiles.Count
}
$inventoryPath = Join-Path $fullOutput 'inventory.json'
$json = $inventory | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($inventoryPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

[pscustomobject]@{
    OutputDirectory = $fullOutput
    PackageCount = $inventoryPackages.Count
    LicenseFileCount = (@(Get-ChildItem -LiteralPath $fullOutput -Recurse -File)).Count
}
