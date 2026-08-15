[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvelopePath,
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\update-state'),
    [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
    [string]$PinnedPublicKeyFingerprint = '',
    [ValidateRange(1, 8192)][int]$MaxFiles = 4096,
    [ValidateRange(1048576, 4294967296)][long]$MaxExpandedBytes = 1073741824,
    [switch]$Activate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force

function Assert-SafeExistingPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissingLeaf)
    $redirectedRoots = @(
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('UserProfile'),
        (Split-Path -Parent ([Environment]::GetFolderPath('UserProfile'))),
        ([Environment]::SystemDirectory | Split-Path -Parent)
    ) | ForEach-Object { if ($_) { [IO.Path]::GetFullPath($_).TrimEnd('\') } } | Where-Object { $_ } | Select-Object -Unique
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    $first = $true
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($redirectedRoots -contains $current) { break }
                throw "Reparse point is forbidden: $current"
            }
        } elseif (-not ($AllowMissingLeaf -and $first)) { throw "Required path is missing: $current" }
        $first = $false
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $full
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '')
    } finally { $sha.Dispose(); $Stream.Position = 0 }
}

function Expand-SafePayload {
    param([Parameter(Mandatory)][IO.Stream]$PackageStream, [Parameter(Mandatory)][string]$StageRoot)
    $payloadRoot = Join-Path $StageRoot 'payload'
    New-Item -ItemType Directory -Path $payloadRoot | Out-Null
    $payloadPrefix = [IO.Path]::GetFullPath($payloadRoot).TrimEnd('\') + '\'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $count = 0
    [long]$total = 0
    $archive = New-Object IO.Compression.ZipArchive($PackageStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith('payload/', [StringComparison]::Ordinal) -or $name.Contains(':') -or $name.StartsWith('/') -or $name.IndexOf([char]0) -ge 0) {
                throw "Unsafe ZIP entry: $name"
            }
            $relative = $name.Substring(8).TrimEnd('/')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $segments = @($relative.Split('/') | Where-Object { $_ -ne '' })
            if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count) { throw "Unsafe ZIP path: $name" }
            foreach ($segment in $segments) {
                if ($segment -notmatch '^[^<>:"/\\|?*\x00-\x1F]{1,120}$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                    throw "Unsafe Windows ZIP path segment: $segment"
                }
            }
            $destination = [IO.Path]::GetFullPath((Join-Path $payloadRoot ($segments -join '\')))
            if (-not $destination.StartsWith($payloadPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP entry escapes staging: $name" }
            if (-not $seen.Add($destination)) { throw "Duplicate ZIP entry: $name" }
            $isDirectory = $name.EndsWith('/')
            if ($isDirectory) { New-Item -ItemType Directory -Path $destination -Force | Out-Null; continue }
            $count++
            if ($count -gt $MaxFiles) { throw 'ZIP contains too many files.' }
            if ($entry.Length -lt 0) { throw 'ZIP entry has an invalid declared size.' }
            $parent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $input = $entry.Open()
            $output = New-Object IO.FileStream($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 262144
                [long]$entryWritten = 0
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryWritten += $read
                    $total += $read
                    if ($total -gt $MaxExpandedBytes) { throw 'ZIP expanded size exceeds the configured limit.' }
                    $output.Write($buffer, 0, $read)
                }
                if ($entryWritten -ne $entry.Length) { throw 'ZIP entry size does not match its declared length.' }
                if ($entry.CompressedLength -gt 0 -and $entryWritten -gt 10485760 -and ($entryWritten / $entry.CompressedLength) -gt 200) { throw 'ZIP compression ratio is unsafe.' }
            } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally { $archive.Dispose() }
    if ($count -eq 0) { throw 'ZIP payload is empty.' }
    [pscustomobject]@{ PayloadRoot = $payloadRoot; FileCount = $count; ExpandedBytes = $total }
}

$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$installParent = Split-Path -Parent $installFull
if ([string]::IsNullOrWhiteSpace($installParent) -or $installFull -eq [IO.Path]::GetPathRoot($installFull)) { throw 'InstallRoot is too broad.' }
Assert-SafeExistingPath -Path $installParent | Out-Null
if ($Activate) { Assert-SafeExistingPath -Path $installFull | Out-Null }

$lock = $null
$packageStream = $null
$stageRoot = Join-Path $installParent ('.jarvis-stage-' + [Guid]::NewGuid().ToString('N'))
$backupRoot = $null
$oldMoved = $false
$newMoved = $false
$keepStage = $false
try {
    $lock = Lock-JarvisUpdateState -StateRoot $StateRoot
    if ($Activate) { Test-JarvisProgramMarker -Directory $installFull }
    $state = Read-JarvisUpdateState -StateRoot $StateRoot
    $trustedFloor = if ([version]$state.HighestAcceptedVersion -gt [version]$CurrentVersion) { $state.HighestAcceptedVersion } else { $CurrentVersion }
    $envelopeArgs = @{ ExpectedKind = 'update'; EnvelopePath = $EnvelopePath; PackagePath = $PackagePath; CurrentVersion = $trustedFloor; PublicKeyPath = $PublicKeyPath }
    if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKeyFingerprint)) { $envelopeArgs.PinnedPublicKeyFingerprint = $PinnedPublicKeyFingerprint }
    $verified = Test-JarvisSignedEnvelope @envelopeArgs
    Test-JarvisUpdateCandidate -StateRoot $StateRoot -CandidateVersion $verified.Version -ReleaseId $verified.ReleaseId -CurrentVersion $CurrentVersion | Out-Null

    $packageStream = New-Object IO.FileStream([IO.Path]::GetFullPath($PackagePath), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $exclusiveHash = Get-StreamSha256 -Stream $packageStream
    if ($exclusiveHash -ne $verified.PackageHash) { throw 'Update package changed after signature verification.' }
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    Set-JarvisRestrictedAcl -Path $stageRoot | Out-Null
    $expanded = Expand-SafePayload -PackageStream $packageStream -StageRoot $stageRoot
    $packageStream.Dispose(); $packageStream = $null

    $stageMetadata = [ordered]@{
        schemaVersion = 1; version = $verified.Version; releaseId = $verified.ReleaseId
        packageSha256 = $exclusiveHash; fileCount = $expanded.FileCount; expandedBytes = $expanded.ExpandedBytes
        stagedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $stageRoot 'staged-update.json'), $stageMetadata, (New-Object Text.UTF8Encoding($false)))

    if (-not $Activate) {
        $keepStage = $true
        return [pscustomobject]@{ Ok=$true; Activated=$false; Version=$verified.Version; ReleaseId=$verified.ReleaseId; StagePath=$stageRoot; BackupPath=$null }
    }

    Test-JarvisProgramMarker -Directory $expanded.PayloadRoot
    $backupRoot = Join-Path $installParent ('.jarvis-backup-' + $verified.Version + '-' + [Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $installFull -Destination $backupRoot
    $oldMoved = $true
    Move-Item -LiteralPath $expanded.PayloadRoot -Destination $installFull
    $newMoved = $true
    Update-JarvisUpdateState -StateRoot $StateRoot -Version $verified.Version -ReleaseId $verified.ReleaseId -CurrentVersion $CurrentVersion -Lock $lock | Out-Null
    return [pscustomobject]@{ Ok=$true; Activated=$true; Version=$verified.Version; ReleaseId=$verified.ReleaseId; StagePath=$null; BackupPath=$backupRoot }
} catch {
    $originalError = $_
    $rollbackError = $null
    try {
        if ($oldMoved -and -not $newMoved -and -not (Test-Path -LiteralPath $installFull) -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $installFull
        } elseif ($oldMoved -and $newMoved -and (Test-Path -LiteralPath $backupRoot)) {
            $failedRoot = Join-Path $installParent ('.jarvis-failed-' + [Guid]::NewGuid().ToString('N'))
            if (Test-Path -LiteralPath $installFull) { Move-Item -LiteralPath $installFull -Destination $failedRoot }
            Move-Item -LiteralPath $backupRoot -Destination $installFull
        }
    } catch {
        $rollbackError = $_
    }
    if ($null -ne $rollbackError) {
        throw "Update failed and rollback also failed: $($originalError.Exception.Message) | rollback: $($rollbackError.Exception.Message)"
    }
    throw $originalError
} finally {
    if ($null -ne $packageStream) { try { $packageStream.Dispose() } catch { } }
    if ($null -ne $lock) { try { $lock.Dispose() } catch { } }
    if (-not $keepStage -and (Test-Path -LiteralPath $stageRoot)) { try { Remove-Item -LiteralPath $stageRoot -Recurse -Force } catch { } }
}
