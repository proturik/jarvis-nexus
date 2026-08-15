<#
.SYNOPSIS
  End-to-end update orchestrator for the JARVIS NEXUS private update channel:
  check for a newer signed release, prompt for consent (unless -AutoConfirm),
  download the verified manifest and package, and hand the running program off
  to the new version in place.

.DESCRIPTION
  Safe to call from the live launcher: when the target directory is not yet a
  versioned program-only directory (no valid .jarvis-program-marker), the call
  returns immediately with Ok=$true / UpdateAvailable=$false instead of throwing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$IndexUrl,
    [string]$CurrentVersion = '',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\update-state'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\data'),
    [int]$Port = 3791,
    [string]$PublicKeyPath = '',
    [string]$PinnedPublicKeyFingerprint = '',
    [int]$StopTimeoutSeconds = 30,
    [int]$HealthTimeoutSeconds = 60,
    [switch]$AutoConfirm,
    # Test-only: permit loopback HTTP (http://127.0.0.1) for index/package URLs.
    [switch]$AllowLoopbackHttp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.ReleaseIndex.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = Join-Path $PSScriptRoot 'public-key.xml' }

$installFull = [IO.Path]::GetFullPath($ProgramRoot).TrimEnd('\')

# Guard for the live "mixed" install: a directory that is not yet a versioned
# program-only directory cannot be updated in place. Any marker failure means
# "skip" rather than an error, so the live launcher can call this unconditionally.
try {
    Test-JarvisProgramMarker -Directory $installFull
} catch {
    return [pscustomobject]@{ Ok = $true; UpdateAvailable = $false; Activated = $false; Skipped = 'not a versioned program directory' }
}

$version = $CurrentVersion
if ([string]::IsNullOrWhiteSpace($version)) {
    $versionFile = Join-Path $installFull 'version.txt'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "Cannot determine the current JARVIS version: -CurrentVersion was not provided and version.txt is missing in $installFull."
    }
    $version = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
}
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Current version '$version' is not a valid numeric semantic version (expected 1.2.3)."
}
$CurrentVersion = $version

$indexPath = Join-Path $StateRoot 'release-index.json'
if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force }

$indexArgs = @{
    IndexUrl = $IndexUrl
    IndexPath = $indexPath
    CurrentVersion = $CurrentVersion
    PublicKeyPath = $PublicKeyPath
    AllowLoopbackHttp = [bool]$AllowLoopbackHttp
}
if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKeyFingerprint)) {
    $indexArgs.PinnedPublicKeyFingerprint = $PinnedPublicKeyFingerprint
}

$release = $null
try {
    $release = Get-JarvisReleaseIndex @indexArgs
} catch {
    if ($_.Exception.Message -match 'No newer release is available than version') {
        return [pscustomobject]@{ Ok = $true; UpdateAvailable = $false; Activated = $false }
    }
    throw
}

if (-not $AutoConfirm) {
    $confirmed = & (Join-Path $PSScriptRoot 'Show-JarvisUpdatePrompt.ps1') -CurrentVersion $CurrentVersion -NewVersion ([string]$release.Version)
    if (-not $confirmed) {
        return [pscustomobject]@{ Ok = $true; UpdateAvailable = $true; Declined = $true; Version = $release.Version }
    }
}

$downloadDirectory = Join-Path $DataRoot 'downloads'
New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
$downloaded = Get-JarvisReleasePackage -Release $release -OutputDirectory $downloadDirectory -AllowLoopbackHttp:$AllowLoopbackHttp

$handoffArgs = @{
    ProgramRoot = $installFull
    EnvelopePath = $downloaded.EnvelopePath
    PackagePath = $downloaded.PackagePath
    CurrentVersion = $CurrentVersion
    StateRoot = $StateRoot
    DataRoot = $DataRoot
    Port = $Port
    PublicKeyPath = $PublicKeyPath
    PinnedPublicKeyFingerprint = $PinnedPublicKeyFingerprint
    StopTimeoutSeconds = $StopTimeoutSeconds
    HealthTimeoutSeconds = $HealthTimeoutSeconds
}
$handoff = & (Join-Path $PSScriptRoot 'Invoke-JarvisHandoff.ps1') @handoffArgs

return [pscustomobject]@{
    Ok = $true
    UpdateAvailable = $true
    Activated = $handoff.Activated
    Version = $release.Version
    ReleaseId = $release.ReleaseId
    StagePath = $handoff.StagePath
    BackupPath = $handoff.BackupPath
    Restarted = $handoff.Restarted
    Pid = $handoff.Pid
    Uri = $handoff.Uri
}
