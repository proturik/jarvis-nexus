<#
.SYNOPSIS
  Opt-in process hand-off: identify and stop the JARVIS NEXUS ULTRA core and any
  sibling JARVIS processes that belong to a specific versioned program-only
  directory, without ever killing unrelated processes.

.DESCRIPTION
  The JARVIS core is identified precisely by the process that owns the TCP
  listener on -Port (Get-NetTCPConnection, with a netstat -ano fallback), and is
  only stopped after confirming it is node.exe whose command line references the
  -ProgramRoot\ultra-server.mjs file. Sibling processes (JarvisPet.exe /
  JarvisSense.exe) are only stopped when their command line (or executable path)
  contains a path under -ProgramRoot or the documented JARVIS executable paths
  discovered in desktop-shell/ and sensors/. If any port-owning process cannot be
  attributed to JARVIS, nothing is stopped and an error is thrown.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [int]$Port = 3791,
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ListenerPids {
    param([int]$LocalPort)
    $pids = @()
    $handled = $false
    try {
        $connections = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction Stop
        $pids = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
        $handled = $true
    } catch {
        # Get-NetTCPConnection unavailable or reported no matches; fall back below.
    }
    if (-not $handled) {
        $lines = & netstat.exe -ano
        foreach ($line in $lines) {
            $text = [string]$line
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $parts = $text.Trim() -split '\s+'
            if ($parts.Count -ge 5 -and $parts[3] -match 'LISTEN' -and $parts[1] -match (":${LocalPort}$")) {
                $parsed = 0
                if ([int]::TryParse($parts[4], [ref]$parsed) -and $parsed -gt 0) { $pids += $parsed }
            }
        }
        $pids = @($pids | Select-Object -Unique)
    }
    return ,$pids
}

$installFull = [IO.Path]::GetFullPath($ProgramRoot).TrimEnd('\')
$serverPath = Join-Path $installFull 'ultra-server.mjs'
$corePids = @()

# 1. Anchor: the process that owns the TCP listener on -Port must be the JARVIS core.
$listenerPids = Get-ListenerPids -LocalPort $Port
foreach ($candidate in $listenerPids) {
    $proc = $null
    try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$candidate" -ErrorAction Stop } catch { }
    if ($null -eq $proc) {
        throw "Port $Port reports owning process $candidate but it cannot be inspected via Win32_Process; refusing to stop anything."
    }
    if ($proc.Name -ne 'node.exe') {
        throw "Port $Port is owned by PID $candidate ($($proc.Name)), which is not the JARVIS core; refusing to stop it."
    }
    $cmdline = [string]$proc.CommandLine
    if ([string]::IsNullOrWhiteSpace($cmdline) -or $cmdline.IndexOf($serverPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Port $Port PID $candidate is node.exe but its command line does not reference the JARVIS core at $serverPath; refusing to stop it."
    }
    $corePids += [int]$candidate
}
$corePids = @($corePids | Select-Object -Unique)

# 2. Siblings: stop JarvisPet / JarvisSense only when clearly under -ProgramRoot.
$siblingPids = @()
$documentedPaths = @(
    (Join-Path $installFull 'desktop-shell\JarvisPet.exe'),
    (Join-Path $installFull 'desktop-shell\sense\JarvisSense.exe')
)
foreach ($exeName in @('JarvisPet.exe', 'JarvisSense.exe')) {
    $procs = @()
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction Stop) } catch { $procs = @() }
    foreach ($p in $procs) {
        $matchText = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($matchText)) { $matchText = [string]$p.ExecutablePath }
        if ([string]::IsNullOrWhiteSpace($matchText)) { continue }
        $attributed = $false
        foreach ($doc in $documentedPaths) {
            if ($matchText.IndexOf($doc, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $attributed = $true; break }
        }
        if (-not $attributed -and $matchText.IndexOf($installFull, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $attributed = $true
        }
        if ($attributed) { $siblingPids += [int]$p.ProcessId }
    }
}
$siblingPids = @($siblingPids | Select-Object -Unique)

$targetPids = @(@($corePids) + @($siblingPids) | Select-Object -Unique)
if ($targetPids.Count -eq 0) {
    return [pscustomobject]@{ Ok = $true; StoppedPids = @(); Stopped = 0; CorePid = $null }
}

# 3. Graceful shutdown attempt for windowed processes, then a bounded wait.
foreach ($tp in $targetPids) {
    $proc = Get-Process -Id $tp -ErrorAction SilentlyContinue
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited -and $proc.MainWindowHandle -ne 0) { $proc.CloseMainWindow() | Out-Null }
        } catch { }
    }
}
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
foreach ($tp in $targetPids) {
    while ($null -ne (Get-Process -Id $tp -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 150
    }
}

# 4. Escalate to Stop-Process only for the confirmed PIDs that are still alive.
$remaining = @($targetPids | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
foreach ($rp in $remaining) {
    if ($null -ne (Get-Process -Id $rp -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $rp -Force -ErrorAction Stop
        } catch {
            if ($null -ne (Get-Process -Id $rp -ErrorAction SilentlyContinue)) { throw }
        }
    }
}
$confirmDeadline = [DateTime]::UtcNow.AddSeconds(8)
foreach ($rp in $remaining) {
    while ($null -ne (Get-Process -Id $rp -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $confirmDeadline) {
        Start-Sleep -Milliseconds 150
    }
    if ($null -ne (Get-Process -Id $rp -ErrorAction SilentlyContinue)) {
        throw "JARVIS process did not stop after escalation: $rp"
    }
}

[pscustomobject]@{
    Ok = $true
    StoppedPids = $targetPids
    Stopped = $targetPids.Count
    CorePid = if ($corePids.Count -gt 0) { $corePids[0] } else { $null }
}
