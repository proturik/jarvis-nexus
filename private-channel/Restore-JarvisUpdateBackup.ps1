[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$BackupPath,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\update-state')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.UpdateState.psm1') -Force

$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$backupFull = [IO.Path]::GetFullPath($BackupPath).TrimEnd('\')
$parent = Split-Path -Parent $installFull
if ((Split-Path -Parent $backupFull) -ne $parent -or (Split-Path -Leaf $backupFull) -notmatch '^\.jarvis-backup-[A-Za-z0-9._-]+$') {
    throw 'BackupPath is not a JARVIS backup beside InstallRoot.'
}
foreach ($path in @($installFull, $backupFull)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Required rollback directory is missing: $path" }
    if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Rollback refuses reparse point: $path" }
}
$lock = $null
$failedRoot = Join-Path $parent ('.jarvis-failed-' + [Guid]::NewGuid().ToString('N'))
$currentMoved = $false
try {
    $lock = Lock-JarvisUpdateState -StateRoot $StateRoot
    Test-JarvisProgramMarker -Directory $backupFull
    Move-Item -LiteralPath $installFull -Destination $failedRoot
    $currentMoved = $true
    Move-Item -LiteralPath $backupFull -Destination $installFull
    [pscustomobject]@{ Ok=$true; RestoredPath=$installFull; FailedReleasePath=$failedRoot }
} catch {
    if ($currentMoved -and -not (Test-Path -LiteralPath $installFull) -and (Test-Path -LiteralPath $failedRoot)) {
        Move-Item -LiteralPath $failedRoot -Destination $installFull
    }
    throw
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
