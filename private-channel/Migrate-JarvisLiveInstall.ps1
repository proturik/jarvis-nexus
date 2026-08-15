<#
.SYNOPSIS
  Migrates an existing mixed JARVIS NEXUS ULTRA install into a versioned
  program-only directory so the private updater can replace it in place.
  This is an opt-in, one-time, reversible operation.

.DESCRIPTION
  Layout before (themed-autostart install):
    <InstallRoot>\app\             <- program (server + public-ultra + assets + ...)
    <InstallRoot>\app\data\        <- user data (wrong place: inside the program dir)
    <InstallRoot>\runtime\node.exe
    <InstallRoot>\desktop-shell\   <- JarvisPet.exe + sense\JarvisSense.exe
    <InstallRoot>\launcher\        <- Start-Jarvis-RELEASE.ps1 / .cmd

  Layout after:
    <InstallRoot>\app\             <- versioned program-only dir (marker + version.txt)
    <InstallRoot>\data\            <- user data (survives updates)
    ... everything else unchanged ...

  The script:
    1. stops the JARVIS core + Pet + Sense precisely (never by image name),
    2. copies a full backup of app\, data\ and the launcher to a timestamped dir,
    3. moves app\data\* into <InstallRoot>\data\ (merge, never overwrite),
    4. writes .jarvis-program-marker and version.txt into app\,
    5. updates app\ultra-server.mjs from the repository (which honours
       JARVIS_DATA_DIR) and writes app\release.json for program identity,
    6. rewrites the launcher to set JARVIS_DATA_DIR and optionally JARVIS_INDEX_URL,
    7. restarts JARVIS and verifies the bootstrap endpoint.

  Without -Apply it only reports what it would change. Without -Restart it
  performs the file migration but leaves JARVIS stopped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$Version = '1.0.0',
    [string]$SourceRepo = '',
    [string]$UpdateIndexUrl = '',
    [int]$Port = 3791,
    [switch]$Apply,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRepo)) { $SourceRepo = (Join-Path $PSScriptRoot '..') }

$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$appRoot = Join-Path $installFull 'app'
$dataRoot = Join-Path $installFull 'data'
$launcherDir = Join-Path $installFull 'launcher'
$nodePath = Join-Path $installFull 'runtime\node.exe'
$serverPath = Join-Path $appRoot 'ultra-server.mjs'
$markerName = '.jarvis-program-marker'
$markerContent = 'JARVIS NEXUS ULTRA program directory v1'
$repoServer = Join-Path ([IO.Path]::GetFullPath($SourceRepo)) 'ultra-server.mjs'

foreach ($required in @($appRoot, $dataRoot, $launcherDir, $nodePath, $serverPath, $repoServer)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required path is missing: $required" }
}
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'data') -PathType Container)) {
    throw "Expected legacy data directory missing: $(Join-Path $appRoot 'data')"
}

$changes = @()

function Stop-LiveJarvis {
    param([string]$Install, [int]$LocalPort)
    $serverPathFull = Join-Path $Install 'app\ultra-server.mjs'
    $stopped = @()
    # Core: owner of the TCP listener on the port, confirmed to reference our server path.
    $listenerPids = @()
    try {
        $conns = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction Stop
        $listenerPids = @($conns | Select-Object -ExpandProperty OwningProcess -Unique)
    } catch {
        $lines = & netstat.exe -ano
        foreach ($line in $lines) {
            $text = [string]$line
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $parts = $text.Trim() -split '\s+'
            if ($parts.Count -ge 5 -and $parts[3] -match 'LISTEN' -and $parts[1] -match (":${LocalPort}$")) {
                $parsed = 0
                if ([int]::TryParse($parts[4], [ref]$parsed) -and $parsed -gt 0) { $listenerPids += $parsed }
            }
        }
        $listenerPids = @($listenerPids | Select-Object -Unique)
    }
    foreach ($candidate in $listenerPids) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$candidate" -ErrorAction SilentlyContinue
        if ($null -eq $proc) { throw "Port $LocalPort owner $candidate cannot be inspected; refusing to stop." }
        if ($proc.Name -ne 'node.exe') { throw "Port $LocalPort is owned by $($proc.Name), not the JARVIS core; refusing to stop." }
        if ([string]::IsNullOrWhiteSpace([string]$proc.CommandLine) -or [string]$proc.CommandLine.IndexOf($serverPathFull, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Port $LocalPort owner does not reference $serverPathFull; refusing to stop."
        }
        $stopped += [int]$candidate
    }
    # Siblings: only when their executable path is under the install root.
    foreach ($name in @('JarvisPet.exe', 'JarvisSense.exe')) {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            $path = [string]$p.ExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($path) -and $path.StartsWith($Install + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $stopped += [int]$p.ProcessId
            }
        }
    }
    $stopped = @($stopped | Select-Object -Unique)
    if ($null -eq $stopped) { $stopped = @() }
    foreach ($pidValue in $stopped) {
        if ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $pidValue -Force -ErrorAction Stop
        }
    }
    foreach ($pidValue in $stopped) {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 150
        }
    }
    return $stopped
}

function Start-LiveJarvis {
    param([string]$Install)
    $launcher = Join-Path $Install 'launcher\Start-Jarvis-RELEASE.ps1'
    & $launcher | Out-Null
}

$appDataDir = Join-Path $appRoot 'data'
$legacyDataFiles = @(Get-ChildItem -LiteralPath $appDataDir -Force | Where-Object { -not $_.PSIsContainer })
$legacyDataDirs = @(Get-ChildItem -LiteralPath $appDataDir -Force | Where-Object { $_.PSIsContainer })
$existingRootData = @(Get-ChildItem -LiteralPath $dataRoot -Force -ErrorAction SilentlyContinue)

$changes += "move $($legacyDataFiles.Count) file(s) and $($legacyDataDirs.Count) dir(s) from app\data to data\"
$changes += 'write .jarvis-program-marker and version.txt into app\'
$changes += 'update app\ultra-server.mjs from the repository'
$changes += "rewrite launcher to set JARVIS_DATA_DIR=$(Join-Path $installFull 'data')" + $(if ($UpdateIndexUrl) { " and JARVIS_INDEX_URL=$UpdateIndexUrl" } else { '' })
$changes += 'restart JARVIS and verify /api/bootstrap'

if (-not $Apply) {
    Write-Output 'DRY RUN - no changes made. Plan:'
    foreach ($change in $changes) { Write-Output ("  - " + $change) }
    return
}

Write-Output 'Stopping JARVIS...'
$stoppedPids = @(Stop-LiveJarvis -Install $installFull -LocalPort $Port)
Write-Output ("Stopped: " + ($(if ($stoppedPids.Count) { $stoppedPids -join ',' } else { 'none' })))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $installFull "backup-pre-versioned-$stamp"
try {
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $appRoot -Destination (Join-Path $backupRoot 'app') -Recurse -Force
    Copy-Item -LiteralPath $dataRoot -Destination (Join-Path $backupRoot 'data') -Recurse -Force
    Copy-Item -LiteralPath $launcherDir -Destination (Join-Path $backupRoot 'launcher') -Recurse -Force
    Write-Output ("Backup: " + $backupRoot)

    # 1. Move legacy app\data into the root data directory (merge, no overwrite).
    foreach ($item in @($legacyDataFiles) + @($legacyDataDirs)) {
        $dest = Join-Path $dataRoot $item.Name
        if (Test-Path -LiteralPath $dest) { throw "Refusing to overwrite existing data file during migration: $dest" }
        Move-Item -LiteralPath $item.FullName -Destination $dest
    }
    $remaining = @(Get-ChildItem -LiteralPath $appDataDir -Force)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $appDataDir -Force }

    # 2. Program identity.
    [IO.File]::WriteAllText((Join-Path $appRoot $markerName), $markerContent, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $appRoot 'version.txt'), $Version, (New-Object Text.UTF8Encoding($false)))
    $releaseJsonPath = Join-Path $installFull 'release.json'
    if (Test-Path -LiteralPath $releaseJsonPath -PathType Leaf) {
        # Rewrite without a BOM so the server's JSON.parse sees clean JSON.
        $releaseJsonText = [string](Get-Content -LiteralPath $releaseJsonPath -Raw -Encoding UTF8)
        $releaseJsonText = $releaseJsonText.TrimStart([char]0xFEFF)
        [IO.File]::WriteAllText((Join-Path $appRoot 'release.json'), $releaseJsonText, (New-Object Text.UTF8Encoding($false)))
    }

    # 3. Replace the server with the repository version (JARVIS_DATA_DIR support).
    Copy-Item -LiteralPath $repoServer -Destination $serverPath -Force

    # 4. Rewrite the launcher to pass JARVIS_DATA_DIR and optional update check.
    $launcherPath = Join-Path $launcherDir 'Start-Jarvis-RELEASE.ps1'
    $launcherText = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
    if ($launcherText -match [regex]::Escape('New-Item -ItemType Directory -Path (Join-Path $AppRoot ''data'') -Force | Out-Null')) {
        $launcherText = $launcherText.Replace(
            'New-Item -ItemType Directory -Path (Join-Path $AppRoot ''data'') -Force | Out-Null',
            "`$env:JARVIS_DATA_DIR = Join-Path `$InstallRoot 'data'`nNew-Item -ItemType Directory -Path `$env:JARVIS_DATA_DIR -Force | Out-Null"
        )
    } else {
        throw 'Could not locate the legacy data-directory line in the launcher; aborting before rewrite.'
    }
    # Point Sense at a stable sense-state root (outside app\) so its settings and
    # status survive program-dir replacement. Sense's SettingsStore prefers
    # <install-root>\app\data when app\ exists, so pass a root without an app\ child.
    if ($launcherText -match [regex]::Escape("Start-Process -FilePath `$SensePath -ArgumentList @('--install-root', ('\"{0}\"' -f `$InstallRoot))")) {
        $launcherText = $launcherText.Replace(
            "'{0}'`" -f `$InstallRoot)",
            "'{0}'`" -f `$SenseStateRoot)"
        )
        $launcherText = $launcherText.Replace(
            "Start-Process -FilePath `$SensePath -ArgumentList @('--install-root',",
            "New-Item -ItemType Directory -Path `$SenseStateRoot -Force | Out-Null`n    Start-Process -FilePath `$SensePath -ArgumentList @('--install-root',"
        )
    } else {
        throw 'Could not locate the Sense launch line in the launcher; aborting before rewrite.'
    }
    if ($UpdateIndexUrl) {
        $launcherText = $launcherText.Replace(
            "`$env:JARVIS_DATA_DIR = Join-Path `$InstallRoot 'data'",
            "`$env:JARVIS_DATA_DIR = Join-Path `$InstallRoot 'data'`n`$env:JARVIS_INDEX_URL = '$UpdateIndexUrl'"
        )
    }
    [IO.File]::WriteAllText($launcherPath, $launcherText, (New-Object Text.UTF8Encoding($false)))

    Write-Output 'Migration complete.'
    if ($Restart) {
        Write-Output 'Restarting JARVIS...'
        Start-LiveJarvis -Install $installFull
        Write-Output 'Restarted.'
    } else {
        Write-Output 'JARVIS left stopped (no -Restart).'
    }
    [pscustomobject]@{ Ok = $true; BackupRoot = $backupRoot; DataRoot = [IO.Path]::GetFullPath($dataRoot); Restarted = [bool]$Restart }
} catch {
    Write-Error ("Migration failed: " + $_.Exception.Message)
    Write-Output ("A full backup exists at: " + $backupRoot)
    throw
}
