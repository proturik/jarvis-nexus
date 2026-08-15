<#
.SYNOPSIS
  Opt-in process hand-off for a versioned program-only directory: stop the
  running JARVIS program, activate a signed update in place, and restart the
  program. On failure the updater rolls the previous directory back and the old
  program is restarted best-effort; the original error is always rethrown.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$EnvelopePath,
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\update-state'),
    [int]$Port = 3791,
    [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
    [string]$PinnedPublicKeyFingerprint = '',
    [int]$StopTimeoutSeconds = 30,
    [int]$HealthTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force

$installFull = [IO.Path]::GetFullPath($ProgramRoot).TrimEnd('\')
Test-JarvisProgramMarker -Directory $installFull

$stopCompleted = $false
try {
    $stop = & (Join-Path $PSScriptRoot 'Stop-JarvisProgram.ps1') -ProgramRoot $installFull -Port $Port -TimeoutSeconds $StopTimeoutSeconds
    $stopCompleted = $true

    $update = & (Join-Path $PSScriptRoot 'Invoke-JarvisStagedUpdate.ps1') -EnvelopePath $EnvelopePath -PackagePath $PackagePath `
        -InstallRoot $installFull -CurrentVersion $CurrentVersion -StateRoot $StateRoot -Activate `
        -PublicKeyPath $PublicKeyPath -PinnedPublicKeyFingerprint $PinnedPublicKeyFingerprint

    $start = & (Join-Path $PSScriptRoot 'Start-JarvisProgram.ps1') -ProgramRoot $installFull -Port $Port -HealthTimeoutSeconds $HealthTimeoutSeconds

    [pscustomobject]@{
        Ok = $update.Ok
        Activated = $update.Activated
        Version = $update.Version
        ReleaseId = $update.ReleaseId
        StagePath = $update.StagePath
        BackupPath = $update.BackupPath
        Restarted = $true
        Pid = $start.Pid
        Uri = $start.Uri
    }
} catch {
    if ($stopCompleted) {
        # The program was already stopped by us and the previous directory is
        # back in place (either never replaced or restored by the updater's
        # rollback). Best-effort restart of the previous program.
        try {
            & (Join-Path $PSScriptRoot 'Start-JarvisProgram.ps1') -ProgramRoot $installFull -Port $Port -HealthTimeoutSeconds $HealthTimeoutSeconds | Out-Null
        } catch {
            Write-Warning "Hand-off failed and restart of the previous program also failed: $($_.Exception.Message)"
        }
    }
    throw
}
