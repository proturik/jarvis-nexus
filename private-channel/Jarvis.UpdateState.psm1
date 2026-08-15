Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security -ErrorAction Stop

$script:StateFileName = 'update-state.dpapi'
$script:LockFileName = 'update.lock'
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('JARVIS NEXUS UPDATE STATE v1')
$script:ProgramMarkerName = '.jarvis-program-marker'
$script:ProgramMarkerContent = 'JARVIS NEXUS ULTRA program directory v1'

function Assert-NoReparseInPath {
    param([Parameter(Mandatory)][string]$Path)
    $redirectedRoots = @(
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('UserProfile'),
        (Split-Path -Parent ([Environment]::GetFolderPath('UserProfile'))),
        ([Environment]::SystemDirectory | Split-Path -Parent)
    ) | ForEach-Object { if ($_) { [IO.Path]::GetFullPath($_).TrimEnd('\') } } | Where-Object { $_ } | Select-Object -Unique
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($redirectedRoots -contains $current) { break }
                throw "Reparse points are forbidden in update-state paths: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-JarvisProgramMarkerName {
    return $script:ProgramMarkerName
}

function Get-JarvisProgramMarkerContent {
    return $script:ProgramMarkerContent
}

function Test-JarvisProgramMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)
    $markerPath = Join-Path $Directory $script:ProgramMarkerName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw "Program directory marker is missing in: $Directory" }
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Program directory marker is a reparse point in: $Directory" }
    $expected = [Text.Encoding]::ASCII.GetBytes($script:ProgramMarkerContent)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($markerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt 256) { throw 'Program directory marker is too large.' }
        $buffer = New-Object byte[] ([int]$stream.Length)
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -ne $buffer.Length) { throw 'Program directory marker could not be read completely.' }
        if ([Convert]::ToBase64String($buffer) -ne [Convert]::ToBase64String($expected)) { throw "Program directory marker mismatch in: $Directory" }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Set-JarvisRestrictedAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparseInPath -Path $fullPath
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $fullPath /inheritance:r /grant:r "*${ownerSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to restrict directory ACL (icacls exit $LASTEXITCODE)." }
    return $fullPath
}

function Initialize-StateRoot {
    param([Parameter(Mandatory)][string]$StateRoot)
    $fullRoot = [IO.Path]::GetFullPath($StateRoot)
    Assert-NoReparseInPath -Path $fullRoot
    New-Item -ItemType Directory -Path $fullRoot -Force | Out-Null
    Assert-NoReparseInPath -Path $fullRoot
    Set-JarvisRestrictedAcl -Path $fullRoot | Out-Null
    return $fullRoot
}

function ConvertFrom-StrictJson {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try { $json = $utf8.GetString($Bytes) } catch { throw 'Protected update state is not strict UTF-8.' }
    try {
        $command = Get-Command ConvertFrom-Json
        if ($command.Parameters.ContainsKey('DateKind')) { return $json | ConvertFrom-Json -DateKind String }
        return $json | ConvertFrom-Json
    } catch { throw 'Protected update state is not valid JSON.' }
}

function New-EmptyState {
    [pscustomobject]@{
        SchemaVersion = 1
        HighestAcceptedVersion = '0.0.0'
        AcceptedReleaseIds = @()
        TrustedUtc = [DateTimeOffset]::MinValue
    }
}

function Read-BoundedStateBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $MaxBytes) { throw 'Protected update state is too large.' }
        $buffer = New-Object byte[] ([int]$stream.Length)
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -ne $buffer.Length) { throw 'Protected update state could not be read completely.' }
        return ,$buffer
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-ProtectedStateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $protectedBytes = Read-BoundedStateBytes -Path $Path -MaxBytes 16384
    $plainBytes = $null
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes, $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $state = ConvertFrom-StrictJson -Bytes $plainBytes
    } catch {
        throw "Protected update state cannot be read or was tampered with: $($_.Exception.Message)"
    } finally {
        if ($null -ne $plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($null -ne $protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    }
    if ([int]$state.schemaVersion -ne 1) { throw 'Unsupported update-state schema.' }
    $version = [string]$state.highestAcceptedVersion
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Protected update state contains an invalid version.' }
    $releaseIds = @($state.acceptedReleaseIds | ForEach-Object { [string]$_ })
    if ($releaseIds.Count -gt 32 -or @($releaseIds | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$' }).Count) {
        throw 'Protected update state contains invalid release IDs.'
    }
    $trusted = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$state.trustedUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$trusted)) { throw 'Protected update state contains invalid trusted time.' }
    [pscustomobject]@{
        SchemaVersion = 1
        HighestAcceptedVersion = $version
        AcceptedReleaseIds = $releaseIds
        TrustedUtc = $trusted.ToUniversalTime()
    }
}

function Read-JarvisUpdateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    $fullRoot = Initialize-StateRoot -StateRoot $StateRoot
    $statePath = Join-Path $fullRoot $script:StateFileName
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return New-EmptyState }
    Assert-NoReparseInPath -Path $statePath
    ConvertFrom-ProtectedStateFile -Path $statePath
}

function Lock-JarvisUpdateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    $fullRoot = Initialize-StateRoot -StateRoot $StateRoot
    $lockPath = Join-Path $fullRoot $script:LockFileName
    Assert-NoReparseInPath -Path $lockPath
    try {
        return New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw 'Another JARVIS update operation is already running.' }
}

function Test-JarvisUpdateCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$CandidateVersion,
        [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )
    foreach ($value in @($CandidateVersion, $CurrentVersion)) {
        if ($value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Update versions must use numeric semantic versioning.' }
    }
    if ($ReleaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'ReleaseId format is invalid.' }
    $state = Read-JarvisUpdateState -StateRoot $StateRoot
    $floor = if ([version]$state.HighestAcceptedVersion -gt [version]$CurrentVersion) {
        $state.HighestAcceptedVersion
    } else { $CurrentVersion }
    if ([version]$CandidateVersion -le [version]$floor) { throw "Update $CandidateVersion is not newer than trusted floor $floor." }
    if ($state.AcceptedReleaseIds -contains $ReleaseId) { throw 'ReleaseId was already accepted.' }
    if ($state.TrustedUtc -ne [DateTimeOffset]::MinValue -and $NowUtc -lt $state.TrustedUtc.Subtract([TimeSpan]::FromMinutes(5))) {
        throw 'System clock moved behind the protected trusted time.'
    }
    [pscustomobject]@{ Ok = $true; TrustedFloorVersion = $floor; State = $state }
}

function Update-JarvisUpdateState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow,
        [IO.FileStream]$Lock
    )
    $ownLock = $null
    try {
        if ($null -eq $Lock) { $ownLock = Lock-JarvisUpdateState -StateRoot $StateRoot }
        $candidate = Test-JarvisUpdateCandidate -StateRoot $StateRoot -CandidateVersion $Version -ReleaseId $ReleaseId `
            -CurrentVersion $CurrentVersion -NowUtc $NowUtc
        $ids = @($candidate.State.AcceptedReleaseIds) + @($ReleaseId)
        if ($ids.Count -gt 32) { $ids = @($ids | Select-Object -Last 32) }
        $trustedUtc = if ($candidate.State.TrustedUtc -gt $NowUtc) { $candidate.State.TrustedUtc } else { $NowUtc }
        $payload = [ordered]@{
            schemaVersion = 1
            highestAcceptedVersion = $Version
            acceptedReleaseIds = $ids
            trustedUtc = $trustedUtc.ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress
        $plainBytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $protectedBytes = $null
        $tempPath = $null
        try {
            $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
                $plainBytes, $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $fullRoot = Initialize-StateRoot -StateRoot $StateRoot
            $statePath = Join-Path $fullRoot $script:StateFileName
            $tempPath = $statePath + '.tmp-' + [Guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllBytes($tempPath, $protectedBytes)
            ConvertFrom-ProtectedStateFile -Path $tempPath | Out-Null
            Move-Item -LiteralPath $tempPath -Destination $statePath -Force
            $tempPath = $null
        } finally {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
            if ($null -ne $protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
            if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force }
        }
    } finally {
        if ($null -ne $ownLock) { $ownLock.Dispose() }
    }
}

Export-ModuleMember -Function Read-JarvisUpdateState, Lock-JarvisUpdateState, Test-JarvisUpdateCandidate, Update-JarvisUpdateState, Get-JarvisProgramMarkerName, Get-JarvisProgramMarkerContent, Test-JarvisProgramMarker, Set-JarvisRestrictedAcl
