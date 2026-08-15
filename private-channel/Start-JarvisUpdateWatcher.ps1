<#
.SYNOPSIS
  Background update watcher: checks the signed release channel on an interval,
  shows a tray notification when a new version is available, then auto-updates
  with the progress HUD (percentage + remaining time). Runs hidden until told to
  stop.

.DESCRIPTION
  Launched by the JARVIS launcher. It never modifies anything while the current
  version is the newest one. When a newer signed release appears it notifies the
  user once, then runs the full auto-update (download, verify, hand-off). The
  check interval is -IntervalSeconds (default 15 minutes); the first check is
  immediate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$IndexUrl,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\data'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\update-state'),
    [int]$Port = 3791,
    [string]$PublicKeyPath = '',
    [int]$IntervalSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) { $PublicKeyPath = Join-Path $PSScriptRoot 'public-key.xml' }

if ($IntervalSeconds -lt 60) { $IntervalSeconds = 60 }

$updaterScript = Join-Path $PSScriptRoot 'Invoke-JarvisUpdate.ps1'
$notificationScript = Join-Path $PSScriptRoot 'Show-JarvisUpdateNotification.ps1'
if (-not (Test-Path -LiteralPath $updaterScript -PathType Leaf)) { Write-Error 'Invoke-JarvisUpdate.ps1 is missing.'; exit 1 }

$notifiedFor = @{}

while ($true) {
    try {
        $result = & $updaterScript -ProgramRoot $ProgramRoot -IndexUrl $IndexUrl -DataRoot $DataRoot -StateRoot $StateRoot -Port $Port -PublicKeyPath $PublicKeyPath -CheckOnly
        if ($result -and $result.UpdateAvailable) {
            $newVersion = [string]$result.Version
            $currentVersion = ''
            $versionFile = Join-Path $ProgramRoot 'version.txt'
            if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
                $currentVersion = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
            }
            if (-not $notifiedFor.ContainsKey($newVersion)) {
                $notifiedFor[$newVersion] = $true
                # Show the «Обновить сейчас» button. On press the updater
                # downloads, verifies, installs and restarts with the progress HUD;
                # on «Позже» it returns and we ask again next session.
                & $updaterScript -ProgramRoot $ProgramRoot -IndexUrl $IndexUrl -DataRoot $DataRoot -StateRoot $StateRoot -Port $Port -PublicKeyPath $PublicKeyPath | Out-Null
            }
        }
    } catch {
        # A failed check must never kill the watcher.
    }
    Start-Sleep -Seconds $IntervalSeconds
}
