<#
.SYNOPSIS
  Resolves and launches installed Windows applications for JARVIS.
.DESCRIPTION
  Searches only Start Menu .lnk files. User text is never executed as a shell
  command. Every shortcut is revalidated before launch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Resolve', 'Launch', 'LaunchUrl')]
    [string]$Action,
    [ValidateLength(1, 80)]
    [string]$Name,
    [string]$Shortcut,
    [ValidateLength(1, 2048)]
    [string]$Url
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$BlockedTargets = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe')

function Get-StartMenuRoots {
    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
    return @($roots | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)
}

function Normalize-NexusName([string]$Value) {
    $text = ([string]$Value).ToLowerInvariant().Replace([char]0, ' ')
    $text = [regex]::Replace($text, '[^\p{L}\p{Nd}]+', ' ')
    return [regex]::Replace($text, '\s+', ' ').Trim()
}

function Test-NexusShortcutRoot([string]$Value, [string[]]$Roots) {
    if (-not $Value) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Value) } catch { return $false }
    foreach ($root in $Roots) {
        $prefix = $root.TrimEnd('\') + '\'
        if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-NexusTarget([string]$Target, [string]$Arguments) {
    if (-not $Target -or -not (Test-Path -LiteralPath $Target -PathType Leaf)) { return $false }
    $fileName = [System.IO.Path]::GetFileName($Target).ToLowerInvariant()
    if ($BlockedTargets -contains $fileName) { return $false }
    if ($fileName -eq 'explorer.exe') {
        return $Arguments -match '(?i)^\s*shell:AppsFolder\\[A-Za-z0-9._-]+![A-Za-z0-9._-]+\s*$'
    }
    return [System.IO.Path]::GetExtension($Target).Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-NexusShortcut([string]$Path, [string[]]$Roots, $Shell) {
    if (-not (Test-NexusShortcutRoot $Path $Roots)) { return $null }
    if (-not [System.IO.Path]::GetExtension($Path).Equals('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    try {
        $link = $Shell.CreateShortcut($Path)
        $target = [string]$link.TargetPath
        $arguments = [string]$link.Arguments
        if (-not (Test-NexusTarget $target $arguments)) { return $null }
        $label = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        if (-not $label -or $label -match '(?i)(?:\\bcmd\\b|command prompt|powershell|terminal|shell|bash)') { return $null }
        return [pscustomobject]@{
            label = $label
            shortcut = [System.IO.Path]::GetFullPath($Path)
            target = [System.IO.Path]::GetFullPath($target)
            arguments = $arguments
        }
    }
    catch { return $null }
}

function Get-NexusDistance([string]$Left, [string]$Right) {
    if ($Left -eq $Right) { return 0 }
    if (-not $Left) { return $Right.Length }
    if (-not $Right) { return $Left.Length }
    $previous = 0..$Right.Length
    for ($i = 1; $i -le $Left.Length; $i += 1) {
        $current = New-Object int[] ($Right.Length + 1)
        $current[0] = $i
        for ($j = 1; $j -le $Right.Length; $j += 1) {
            $cost = if ($Left[$i - 1] -eq $Right[$j - 1]) { 0 } else { 1 }
            $current[$j] = [Math]::Min([Math]::Min($current[$j - 1] + 1, $previous[$j] + 1), $previous[$j - 1] + $cost)
        }
        $previous = $current
    }
    return $previous[$Right.Length]
}

function Get-NexusScore([string]$Query, [string]$Label) {
    $candidate = Normalize-NexusName $Label
    if (-not $candidate) { return 0 }
    if ($Query -eq $candidate) { return 100 }
    if ($candidate.Contains($Query) -or $Query.Contains($candidate)) { return 88 }
    $longest = [Math]::Max($Query.Length, $candidate.Length)
    if ($longest -le 3) { return 0 }
    $similarity = 1.0 - ((Get-NexusDistance $Query $candidate) / $longest)
    if ($similarity -ge 0.76) { return [int]($similarity * 80) }
    return 0
}

function Resolve-NexusApps([string]$Query) {
    $normalized = Normalize-NexusName $Query
    if (-not $normalized) { throw 'Application name is required.' }
    $roots = Get-StartMenuRoots
    if ($roots.Count -eq 0) { throw 'Start Menu folders are unavailable.' }
    $shell = New-Object -ComObject WScript.Shell
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 2500)) {
            $item = Get-NexusShortcut $file.FullName $roots $shell
            if ($null -eq $item) { continue }
            $score = Get-NexusScore $normalized $item.label
            if ($score -ge 60) { $found.Add([pscustomobject]@{ label = $item.label; shortcut = $item.shortcut; score = $score }) }
        }
    }
    return @($found | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'label'; Descending = $false } | Group-Object label | ForEach-Object { $_.Group[0] } | Select-Object -First 5)
}

if ($Action -eq 'Resolve') {
    if (-not $Name) { throw 'Application name is required.' }
    [pscustomobject]@{ ok = $true; candidates = @(Resolve-NexusApps $Name) } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

if ($Action -eq 'LaunchUrl') {
    if (-not $Name) { throw 'Browser name is required.' }
    if (-not $Url) { throw 'URL is required.' }
    try { $safeUri = [Uri]$Url } catch { throw 'URL is invalid.' }
    if ($safeUri.Scheme -ne 'https' -or -not $safeUri.DnsSafeHost -or $safeUri.UserInfo) { throw 'Only credential-free HTTPS URLs are allowed.' }
    $resolved = @(Resolve-NexusApps $Name)
    if ($resolved.Count -eq 0) { throw "Browser not found: $Name" }
    if ($resolved.Count -gt 1 -and $resolved[0].score -lt 85) { throw "Browser match is ambiguous: $Name" }
    $Shortcut = $resolved[0].shortcut
}
elseif (-not $Shortcut) { throw 'Shortcut is required.' }
$roots = Get-StartMenuRoots
$shell = New-Object -ComObject WScript.Shell
$safeShortcut = Get-NexusShortcut $Shortcut $roots $shell
if ($null -eq $safeShortcut) { throw 'Shortcut is not an allowed Start Menu application.' }
$launch = @{ FilePath = $safeShortcut.target; WorkingDirectory = (Split-Path -Parent $safeShortcut.target); PassThru = $true; ErrorAction = 'Stop' }
if ($Action -eq 'LaunchUrl') {
    $arguments = @()
    if ($safeShortcut.arguments) { $arguments += $safeShortcut.arguments }
    $arguments += $safeUri.AbsoluteUri
    $launch.ArgumentList = $arguments
}
elseif ($safeShortcut.arguments) { $launch.ArgumentList = $safeShortcut.arguments }
$beforeHandles = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [int64]$_.MainWindowHandle })
$process = Start-Process @launch
$confirmed = $null
$deadline = [DateTime]::UtcNow.AddSeconds(8)
do {
    Start-Sleep -Milliseconds 250
    try { $process.Refresh() } catch { }
    if (-not $process.HasExited) { $confirmed = $process; break }
    $visible = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle })
    $labelName = Normalize-NexusName $safeShortcut.label
    $targetName = Normalize-NexusName ([System.IO.Path]::GetFileNameWithoutExtension($safeShortcut.target))
    $confirmed = $visible | Where-Object {
        $titleName = Normalize-NexusName $_.MainWindowTitle
        $processName = Normalize-NexusName $_.ProcessName
        $titleName.Contains($labelName) -or $processName -eq $targetName -or $beforeHandles -notcontains [int64]$_.MainWindowHandle
    } | Select-Object -First 1
} while (-not $confirmed -and [DateTime]::UtcNow -lt $deadline)
if (-not $confirmed) { throw 'Application launch could not be verified by a running process or visible window.' }
[pscustomobject]@{ ok = $true; label = $safeShortcut.label; process = $confirmed.ProcessName; window = $confirmed.MainWindowTitle; url = $(if ($Action -eq 'LaunchUrl') { $safeUri.AbsoluteUri } else { $null }) } | ConvertTo-Json -Compress -Depth 3