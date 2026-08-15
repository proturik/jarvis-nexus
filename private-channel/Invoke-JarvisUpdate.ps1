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

  -CheckOnly only reports whether a newer release exists (used by the
  background watcher) and never downloads or changes anything.

  -Progress shows the WinForms progress HUD (percentage + remaining time) while
  the update downloads and installs; state is exchanged through a JSON file.
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
    [switch]$CheckOnly,
    [switch]$Progress,
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

if ($CheckOnly) {
    return [pscustomobject]@{ Ok = $true; UpdateAvailable = $true; Version = $release.Version; ReleaseId = $release.ReleaseId }
}

if (-not $AutoConfirm) {
    $confirmed = & (Join-Path $PSScriptRoot 'Show-JarvisUpdatePrompt.ps1') -CurrentVersion $CurrentVersion -NewVersion ([string]$release.Version)
    if (-not $confirmed) {
        return [pscustomobject]@{ Ok = $true; UpdateAvailable = $true; Declined = $true; Version = $release.Version }
    }
}

$statusFile = Join-Path $StateRoot 'update-progress.json'
$progressProcess = $null
if ($Progress) {
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $progressScript = Join-Path $PSScriptRoot 'Show-JarvisUpdateProgress.ps1'
    if (Test-Path -LiteralPath $progressScript -PathType Leaf) {
        $progressPowerShell = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $progressPowerShell -PathType Leaf)) {
            $progressPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        $progressProcess = Start-Process -FilePath $progressPowerShell `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $progressScript + '" -StatusFile "' + $statusFile + '"') `
            -PassThru -WindowStyle Hidden
    }
}

$progressCallback = $null
if ($Progress) {
    $progressCallback = {
        param($info)
        $state = [ordered]@{
            State = 'downloading'
            Version = [string]$release.Version
            Percent = [int]$info.Percent
            RemainingSeconds = [int]$info.RemainingSeconds
            Message = ''
        }
        try {
            $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusFile -Encoding UTF8
        } catch { }
    }
}

try {
    $downloadDirectory = Join-Path $DataRoot 'downloads'
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
    $downloaded = Get-JarvisReleasePackage -Release $release -OutputDirectory $downloadDirectory `
        -AllowLoopbackHttp:$AllowLoopbackHttp -ProgressCallback $progressCallback

    if ($Progress) {
        $state = [ordered]@{ State = 'installing'; Version = [string]$release.Version; Percent = 100; RemainingSeconds = 0; Message = '' }
        try { $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusFile -Encoding UTF8 } catch { }
    }

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

    if ($Progress) {
        $state = [ordered]@{ State = 'done'; Version = [string]$release.Version; Percent = 100; RemainingSeconds = 0; Message = '' }
        try { $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusFile -Encoding UTF8 } catch { }
    }

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
} catch {
    if ($Progress) {
        $state = [ordered]@{ State = 'error'; Version = [string]$release.Version; Percent = 0; RemainingSeconds = 0; Message = clean($_.Exception.Message, 240) }
        try { $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusFile -Encoding UTF8 } catch { }
    }
    throw
} finally {
    if ($Progress -and $null -ne $progressProcess) {
        try { $null = $progressProcess.WaitForExit(3000) } catch { }
    }
}
