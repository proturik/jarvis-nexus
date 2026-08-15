Set-StrictMode -Version Latest
# Import the verification module only if it is not already loaded. Re-importing
# with -Force from inside this module would rebuild the module in this module's
# own session state and remove the caller's top-level instance (and its exported
# functions). When a caller has not loaded it, a -Force import here still works.
if (-not (Get-Module -Name Jarvis.PrivateChannel)) {
    Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force
}

# Must stay identical to the pinned fingerprint in Jarvis.PrivateChannel.psm1.
$script:ProductionPublicKeyFingerprint = 'A935F9AC016C656C695A53A988C5EAD5CE30D42F6D57550A35311D7D8C0B455D'

function Get-ReleaseField {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$Name)
    if ($Release -is [System.Collections.IDictionary]) {
        if (-not $Release.Contains($Name)) { throw "Release entry is missing '$Name'." }
        return $Release[$Name]
    }
    $property = $Release.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Release entry is missing '$Name'." }
    return $property.Value
}

function Test-UnsafeAddress {
    param([Parameter(Mandatory)][Net.IPAddress]$Address)
    if ([Net.IPAddress]::IsLoopback($Address)) { return $true }
    if ($Address -eq [Net.IPAddress]::Any -or $Address -eq [Net.IPAddress]::IPv6Any) { return $true }
    $check = $Address
    if ($check.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and $check.IsIPv4MappedToIPv6) { $check = $check.MapToIPv4() }
    if ($check.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $check.GetAddressBytes()
        if ($bytes[0] -eq 10) { return $true }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $true }
        if ($bytes[0] -ge 224 -and $bytes[0] -le 239) { return $true }
        if ($bytes[0] -eq 0) { return $true }
        if ($bytes[0] -eq 127) { return $true }
        return $false
    }
    if ($check.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($check.IsIPv6LinkLocal -or $check.IsIPv6SiteLocal -or $check.IsIPv6Multicast) { return $true }
        return $false
    }
    return $false
}

function Assert-NoUnsafeResolvedAddress {
    param([Parameter(Mandatory)][string]$HostName)
    $addresses = $null
    try { $addresses = [Net.Dns]::GetHostAddresses($HostName) } catch { throw "DNS resolution failed for download host '$HostName'." }
    if ($null -eq $addresses -or $addresses.Count -eq 0) { throw "Download host '$HostName' did not resolve to any address." }
    foreach ($address in $addresses) {
        if (Test-UnsafeAddress -Address $address) {
            throw "Download host '$HostName' resolves to a private or unsafe address."
        }
    }
}

function Assert-SafeDownloadUrl {
    param([Parameter(Mandatory)][string]$Url, [switch]$AllowLoopbackHttp)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "Download URL is not absolute: $Url" }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { throw 'Download URL must not contain credentials.' }
    if ($uri.Scheme -eq 'https') {
        Assert-NoUnsafeResolvedAddress -HostName $uri.Host
        return
    }
    if ($uri.Scheme -eq 'http' -and $AllowLoopbackHttp -and $uri.Host -eq '127.0.0.1') { return }
    throw 'Download URL must use HTTPS.'
}

function Get-JarvisWebResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][long]$MaxBytes,
        [string]$ExpectedSha256Hex = '',
        [ValidateRange(0, 32)][int]$MaxRedirects = 5,
        [switch]$AllowLoopbackHttp
    )
    if ($MaxBytes -le 0) { throw 'MaxBytes must be positive.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256Hex) -and $ExpectedSha256Hex -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'ExpectedSha256Hex must be a 64-hex SHA-256 value.'
    }
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $outputFull) { throw "Refusing to overwrite an existing file: $outputFull" }
    $outputDirectory = Split-Path -Parent $outputFull
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw "Output directory does not exist: $outputDirectory" }

    $response = $null
    $inputStream = $null
    $outputStream = $null
    $sha = $null
    $tempPath = $null
    try {
        $currentUrl = $Url
        $redirectsTaken = 0
        $downloadStarted = $false
        while (-not $downloadStarted) {
            $null = Assert-SafeDownloadUrl -Url $currentUrl -AllowLoopbackHttp:$AllowLoopbackHttp
            $request = [Net.HttpWebRequest]::Create($currentUrl)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $false
            $request.Proxy = $null
            $request.Timeout = 30000
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            $isRedirect = ($statusCode -eq 301 -or $statusCode -eq 302 -or $statusCode -eq 303 -or $statusCode -eq 307 -or $statusCode -eq 308)
            if ($isRedirect) {
                $location = $response.Headers['Location']
                $response.Dispose(); $response = $null
                if ([string]::IsNullOrWhiteSpace($location)) { throw 'Redirect response is missing a Location header.' }
                if ($redirectsTaken -ge $MaxRedirects) { throw "Too many redirects (limit $MaxRedirects)." }
                $redirectsTaken++
                $baseUri = New-Object System.Uri($currentUrl)
                $resolvedUri = New-Object System.Uri($baseUri, $location)
                $currentUrl = $resolvedUri.AbsoluteUri
                continue
            }
            if ($statusCode -lt 200 -or $statusCode -ge 300) { throw "Download failed with HTTP status $statusCode." }
            $downloadStarted = $true
        }

        $tempPath = $outputFull + '.tmp-' + [Guid]::NewGuid().ToString('N')
        $outputStream = New-Object IO.FileStream($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream = $response.GetResponseStream()
        $sha = [Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 65536
        [long]$totalBytes = 0
        while ($true) {
            $read = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $totalBytes += $read
            if ($totalBytes -gt $MaxBytes) { throw "Downloaded resource is too large (over $MaxBytes bytes)." }
            $outputStream.Write($buffer, 0, $read)
            $null = $sha.TransformBlock($buffer, 0, $read, $null, 0)
        }
        $null = $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $actualHash = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256Hex) -and $actualHash -ne $ExpectedSha256Hex.ToUpperInvariant()) {
            throw 'Downloaded resource SHA-256 does not match the expected value.'
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Dispose(); $inputStream = $null
        $sha.Dispose(); $sha = $null
        Move-Item -LiteralPath $tempPath -Destination $outputFull
        $tempPath = $null
        return $outputFull
    } finally {
        if ($null -ne $outputStream) { try { $outputStream.Dispose() } catch { } }
        if ($null -ne $inputStream) { try { $inputStream.Dispose() } catch { } }
        if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
        if ($null -ne $response) { try { $response.Dispose() } catch { } }
        if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) { try { Remove-Item -LiteralPath $tempPath -Force } catch { } }
    }
}

function Get-JarvisReleaseIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IndexUrl,
        [Parameter(Mandatory)][string]$IndexPath,
        [string]$PublicKeyPath = (Join-Path $PSScriptRoot 'public-key.xml'),
        [string]$PinnedPublicKeyFingerprint = $script:ProductionPublicKeyFingerprint,
        [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$CurrentVersion,
        [string]$ExpectedChannel = 'private',
        [switch]$AllowLoopbackHttp
    )
    $indexParent = Split-Path -Parent ([IO.Path]::GetFullPath($IndexPath))
    New-Item -ItemType Directory -Path $indexParent -Force | Out-Null
    Get-JarvisWebResource -Url $IndexUrl -OutputPath $IndexPath -MaxBytes 262144 -AllowLoopbackHttp:$AllowLoopbackHttp | Out-Null
    $verifyArgs = @{
        IndexPath = $IndexPath; PublicKeyPath = $PublicKeyPath; ExpectedChannel = $ExpectedChannel
        AllowLoopbackHttp = $AllowLoopbackHttp
    }
    if (-not [string]::IsNullOrWhiteSpace($PinnedPublicKeyFingerprint)) { $verifyArgs.PinnedPublicKeyFingerprint = $PinnedPublicKeyFingerprint }
    $verified = Test-JarvisReleaseIndex @verifyArgs
    if ($verified.ExpiresAt -le [DateTimeOffset]::UtcNow) { throw 'Release index has expired.' }
    $candidates = @($verified.Releases | Where-Object { [version]$_.Version -gt [version]$CurrentVersion })
    if ($candidates.Count -eq 0) { throw "No newer release is available than version $CurrentVersion." }
    $newest = $null
    foreach ($candidate in $candidates) {
        if ($null -eq $newest -or [version]$candidate.Version -gt [version]$newest.Version) { $newest = $candidate }
    }
    return [pscustomobject]@{
        IndexPath = [IO.Path]::GetFullPath($IndexPath)
        Version = $newest.Version; ReleaseId = $newest.ReleaseId
        EnvelopeUrl = $newest.EnvelopeUrl; PackageUrl = $newest.PackageUrl
        PackageBytes = $newest.PackageBytes; PackageSha256 = $newest.PackageSha256; EnvelopeSha256 = $newest.EnvelopeSha256
        PublishedAtUtc = $newest.PublishedAtUtc
    }
}

function Get-JarvisReleasePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [switch]$AllowLoopbackHttp
    )
    $version = [string](Get-ReleaseField -Release $Release -Name 'Version')
    $releaseId = [string](Get-ReleaseField -Release $Release -Name 'ReleaseId')
    $envelopeUrl = [string](Get-ReleaseField -Release $Release -Name 'EnvelopeUrl')
    $packageUrl = [string](Get-ReleaseField -Release $Release -Name 'PackageUrl')
    $packageBytes = [long](Get-ReleaseField -Release $Release -Name 'PackageBytes')
    $packageSha256 = [string](Get-ReleaseField -Release $Release -Name 'PackageSha256')
    $envelopeSha256 = [string](Get-ReleaseField -Release $Release -Name 'EnvelopeSha256')
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Release entry version is invalid.' }
    if ($releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'Release entry releaseId is invalid.' }
    if ($packageBytes -le 0) { throw 'Release entry packageBytes is invalid.' }
    $packageUri = $null
    if (-not [Uri]::TryCreate($packageUrl, [UriKind]::Absolute, [ref]$packageUri)) { throw 'Release entry packageUrl is invalid.' }
    $packageFileName = [Uri]::UnescapeDataString($packageUri.Segments[$packageUri.Segments.Count - 1])
    if ($packageFileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.zip$' -or
        $packageFileName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or
        $packageFileName.EndsWith('.') -or $packageFileName.EndsWith(' ')) { throw 'Package filename is unsafe.' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $envelopePath = Join-Path $OutputDirectory ($releaseId + '.update.json')
    $packagePath = Join-Path $OutputDirectory $packageFileName
    Get-JarvisWebResource -Url $envelopeUrl -OutputPath $envelopePath -MaxBytes 131072 `
        -ExpectedSha256Hex $envelopeSha256 -AllowLoopbackHttp:$AllowLoopbackHttp | Out-Null
    Get-JarvisWebResource -Url $packageUrl -OutputPath $packagePath -MaxBytes $packageBytes `
        -ExpectedSha256Hex $packageSha256 -AllowLoopbackHttp:$AllowLoopbackHttp | Out-Null
    $actualBytes = (Get-Item -LiteralPath $packagePath).Length
    if ($actualBytes -ne $packageBytes) { throw 'Downloaded package size does not match the release index.' }
    return [pscustomobject]@{
        EnvelopePath = [IO.Path]::GetFullPath($envelopePath)
        PackagePath = [IO.Path]::GetFullPath($packagePath)
        ReleaseId = $releaseId; Version = $version
    }
}

Export-ModuleMember -Function Get-JarvisWebResource, Get-JarvisReleaseIndex, Get-JarvisReleasePackage
