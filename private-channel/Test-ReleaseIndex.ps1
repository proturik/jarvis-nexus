[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Jarvis.PrivateChannel.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Jarvis.ReleaseIndex.psm1') -Force

function Assert-True { param([bool]$Value, [string]$Message); if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

# HTTP server helpers.
#
# The listener must run off the main thread: HttpListener.GetContext() blocks,
# so a foreground call would deadlock the test. Start-Job runs the listener in a
# child runspace/process and works identically on PS 5.1 and pwsh 7. Because
# Stop-Job can hang on a job parked in GetContext(), shutdown is two-phase:
# write a stop file, then fire one real HTTP request so GetContext() returns and
# the job's loop notices the stop file and exits on its own.
function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Start-TestHttpServer {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][hashtable]$Routes,
        [Parameter(Mandatory)][string]$StopFile
    )
    $job = Start-Job -ArgumentList $Port, $Routes, $StopFile -ScriptBlock {
        param($Port, $Routes, $StopFile)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $listener = New-Object System.Net.HttpListener
        try {
            $listener.IgnoreWriteExceptions = $true
            $listener.Prefixes.Add("http://127.0.0.1:$Port/")
            $listener.Start()
            while (-not (Test-Path -LiteralPath $StopFile)) {
                $context = $null
                try {
                    $context = $listener.GetContext()
                } catch {
                    if (-not $listener.IsListening) { break }
                    continue
                }
                $response = $context.Response
                try {
                    $path = $context.Request.Url.AbsolutePath
                    if ($Routes.ContainsKey($path) -and $Routes[$path] -is [hashtable]) {
                        $route = $Routes[$path]
                        if ($route.ContainsKey('redirect')) {
                            $response.StatusCode = 302
                            $response.RedirectLocation = [string]$route['redirect']
                            $response.ContentLength64 = 0
                        } elseif ($route.ContainsKey('file')) {
                            $file = [string]$route['file']
                            if (Test-Path -LiteralPath $file -PathType Leaf) {
                                $bytes = [IO.File]::ReadAllBytes($file)
                                $response.StatusCode = 200
                                $response.ContentType = 'application/octet-stream'
                                $response.ContentLength64 = $bytes.Length
                                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                            } else {
                                $response.StatusCode = 404
                                $response.ContentLength64 = 0
                            }
                        } else {
                            $response.StatusCode = 404
                            $response.ContentLength64 = 0
                        }
                    } else {
                        $response.StatusCode = 404
                        $response.ContentLength64 = 0
                    }
                } catch {
                    # Per-request errors are isolated so the server keeps serving.
                } finally {
                    try { $response.Close() } catch { }
                }
            }
        } finally {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
    }
    return $job
}

function Wait-TestHttpServerReady {
    param([int]$Port, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            $client.Close()
            return
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            if ($client -is [IDisposable]) { try { $client.Dispose() } catch { } }
        }
    }
    throw 'Test HTTP server did not become ready.'
}

function Stop-TestHttpServer {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$StopFile, [Parameter(Mandatory)][int]$Port)
    if (Test-Path -LiteralPath $StopFile) { Remove-Item -LiteralPath $StopFile -Force }
    [IO.File]::WriteAllText($StopFile, 'stop', (New-Object Text.UTF8Encoding($false)))
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("GET /__stop__ HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Flush()
        $stream.Dispose()
        $client.Dispose()
    } catch { }
    try { Wait-Job -Job $Job -Timeout 15 -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Stop-Job -Job $Job -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

$testRoot = Join-Path $env:TEMP ('jarvis-release-index-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$serverJob = $null
$port = 0
$stopFile = $null
try {
    $keyRoot = Join-Path $testRoot 'keys'
    $publicKeyOut = Join-Path $testRoot 'public-key.xml'
    $created = & (Join-Path $PSScriptRoot 'Initialize-JarvisSigningKey.ps1') -KeyRoot $keyRoot -PublicKeyOut $publicKeyOut -KeySize 2048
    Assert-True ($created.Ok -and $created.Created) 'test key must be created'

    function New-TestReleaseArtifacts {
        param([string]$Version)
        $package = Join-Path $testRoot ("jarvis-$Version.zip")
        [IO.File]::WriteAllBytes($package, [Text.Encoding]::UTF8.GetBytes("jarvis release index package v$Version payload bytes"))
        $envelope = Join-Path $testRoot ("update-$Version.json")
        $releaseId = "jarvis-$Version"
        & (Join-Path $PSScriptRoot 'New-JarvisSignedEnvelope.ps1') -Kind update -OutputPath $envelope -KeyRoot $keyRoot -PackagePath $package -Version $Version -ReleaseId $releaseId | Out-Null
        return [pscustomobject]@{
            Version = $Version; PackagePath = $package; EnvelopePath = $envelope; ReleaseId = $releaseId
            PackageBytes = (Get-Item -LiteralPath $package).Length
            PackageSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToUpperInvariant()
            EnvelopeSha256 = (Get-FileHash -LiteralPath $envelope -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    }

    $rel150 = New-TestReleaseArtifacts '1.5.0'
    $rel200 = New-TestReleaseArtifacts '2.0.0'
    $rel210 = New-TestReleaseArtifacts '2.1.0'

    $port = Get-FreeLoopbackPort
    $stopFile = Join-Path $testRoot 'server-stop'

    $releaseEntries = @(
        [ordered]@{
            version = $rel150.Version; releaseId = $rel150.ReleaseId
            envelopeUrl = "http://127.0.0.1:$port/releases/jarvis-1.5.0.update.json"
            packageUrl = "http://127.0.0.1:$port/releases/jarvis-1.5.0.zip"
            packageBytes = $rel150.PackageBytes; packageSha256 = $rel150.PackageSha256; envelopeSha256 = $rel150.EnvelopeSha256
            publishedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        },
        [ordered]@{
            version = $rel200.Version; releaseId = $rel200.ReleaseId
            envelopeUrl = "http://127.0.0.1:$port/releases/jarvis-2.0.0.update.json"
            packageUrl = "http://127.0.0.1:$port/releases/jarvis-2.0.0.zip"
            packageBytes = $rel200.PackageBytes; packageSha256 = $rel200.PackageSha256; envelopeSha256 = $rel200.EnvelopeSha256
            publishedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        },
        [ordered]@{
            version = $rel210.Version; releaseId = $rel210.ReleaseId
            envelopeUrl = "http://127.0.0.1:$port/releases/jarvis-2.1.0.update.json"
            packageUrl = "http://127.0.0.1:$port/releases/jarvis-2.1.0.zip"
            packageBytes = $rel210.PackageBytes; packageSha256 = $rel210.PackageSha256; envelopeSha256 = $rel210.EnvelopeSha256
            publishedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        }
    )
    $releasesJsonPath = Join-Path $testRoot 'releases.json'
    Write-Utf8NoBom -Path $releasesJsonPath -Text (@{ releases = $releaseEntries } | ConvertTo-Json -Depth 8)

    $goodIndexPath = Join-Path $testRoot 'index.json'
    $goodIndex = & (Join-Path $PSScriptRoot 'New-JarvisReleaseIndex.ps1') -OutputPath $goodIndexPath -KeyRoot $keyRoot `
        -ReleasesJsonPath $releasesJsonPath -ValidDays 7 -AllowLoopbackHttp
    Assert-True ($goodIndex.Ok -and $goodIndex.ReleaseCount -eq 3) 'owner must build a release index'

    $verifiedIndex = Test-JarvisReleaseIndex -IndexPath $goodIndexPath -PublicKeyPath $publicKeyOut `
        -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -AllowLoopbackHttp
    Assert-True ($verifiedIndex.Ok -and $verifiedIndex.Kind -eq 'index' -and $verifiedIndex.Releases.Count -eq 3) 'signed release index must verify'

    $expiredIndexPath = Join-Path $testRoot 'index-expired.json'
    & (Join-Path $PSScriptRoot 'New-JarvisReleaseIndex.ps1') -OutputPath $expiredIndexPath -KeyRoot $keyRoot `
        -ReleasesJsonPath $releasesJsonPath -ValidDays 1 -NowUtc ([DateTimeOffset]::UtcNow.AddDays(-2)) -AllowLoopbackHttp | Out-Null

    $tamperedIndexPath = Join-Path $testRoot 'index-tampered.json'
    $tampered = Get-Content -LiteralPath $goodIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tamperedPayload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tampered.payloadBase64)) + ' '
    $tampered.payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tamperedPayload))
    Write-Utf8NoBom -Path $tamperedIndexPath -Text ($tampered | ConvertTo-Json -Compress)

    $oversizedIndexPath = Join-Path $testRoot 'index-oversized.bin'
    [IO.File]::WriteAllBytes($oversizedIndexPath, (New-Object byte[] 524288))

    $unsafeEntries = @(
        [ordered]@{
            version = '5.0.0'; releaseId = 'jarvis-unsafe-5.0.0'
            envelopeUrl = "http://127.0.0.1:$port/releases/jarvis-2.1.0.update.json"
            packageUrl = "http://127.0.0.1:$port/CON.zip"
            packageBytes = $rel210.PackageBytes; packageSha256 = $rel210.PackageSha256; envelopeSha256 = $rel210.EnvelopeSha256
            publishedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        }
    )
    $unsafeJsonPath = Join-Path $testRoot 'releases-unsafe.json'
    Write-Utf8NoBom -Path $unsafeJsonPath -Text (@{ releases = $unsafeEntries } | ConvertTo-Json -Depth 8)
    $unsafeNameIndexPath = Join-Path $testRoot 'index-unsafe-name.json'
    & (Join-Path $PSScriptRoot 'New-JarvisReleaseIndex.ps1') -OutputPath $unsafeNameIndexPath -KeyRoot $keyRoot `
        -ReleasesJsonPath $unsafeJsonPath -ValidDays 7 -AllowLoopbackHttp | Out-Null

    $routes = @{
        '/index.json' = @{ file = $goodIndexPath }
        '/index-tampered.json' = @{ file = $tamperedIndexPath }
        '/index-expired.json' = @{ file = $expiredIndexPath }
        '/index-oversized.bin' = @{ file = $oversizedIndexPath }
        '/index-unsafe-name.json' = @{ file = $unsafeNameIndexPath }
        '/redirect-http-private' = @{ redirect = 'http://10.255.255.1/evil' }
        '/redirect-https-private' = @{ redirect = 'https://10.255.255.1/evil' }
        "/releases/jarvis-1.5.0.zip" = @{ file = $rel150.PackagePath }
        "/releases/jarvis-1.5.0.update.json" = @{ file = $rel150.EnvelopePath }
        "/releases/jarvis-2.0.0.zip" = @{ file = $rel200.PackagePath }
        "/releases/jarvis-2.0.0.update.json" = @{ file = $rel200.EnvelopePath }
        "/releases/jarvis-2.1.0.zip" = @{ file = $rel210.PackagePath }
        "/releases/jarvis-2.1.0.update.json" = @{ file = $rel210.EnvelopePath }
    }

    $serverJob = Start-TestHttpServer -Port $port -Routes $routes -StopFile $stopFile
    Wait-TestHttpServerReady -Port $port

    # Positive: newest release newer than current is selected, package + envelope download and hash out.
    $goodDownloadPath = Join-Path $testRoot 'idx-good-download.json'
    $release = Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $goodDownloadPath `
        -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
    Assert-True ($release.Version -eq '2.1.0' -and $release.ReleaseId -eq $rel210.ReleaseId) 'newest release newer than current must be selected'
    Assert-True (Test-Path -LiteralPath $release.IndexPath) 'downloaded index must be written to disk'

    $outputDir = Join-Path $testRoot 'out-positive'
    $downloaded = Get-JarvisReleasePackage -Release $release -OutputDirectory $outputDir -AllowLoopbackHttp
    Assert-True ($downloaded.Version -eq '2.1.0' -and $downloaded.ReleaseId -eq $rel210.ReleaseId) 'downloaded release identity must be correct'
    Assert-True ([IO.Path]::GetFileName($downloaded.EnvelopePath) -eq ($rel210.ReleaseId + '.update.json')) 'envelope filename must use releaseId'
    Assert-True ([IO.Path]::GetFileName($downloaded.PackagePath) -eq 'jarvis-2.1.0.zip') 'package filename must come from the last URL segment'
    Assert-True ((Test-Path -LiteralPath $downloaded.PackagePath) -and (Test-Path -LiteralPath $downloaded.EnvelopePath)) 'package and envelope must land in the output directory'
    Assert-True ((Get-FileHash -LiteralPath $downloaded.PackagePath -Algorithm SHA256).Hash.ToUpperInvariant() -eq $rel210.PackageSha256) 'downloaded package hash must match the index'
    Assert-True ((Get-FileHash -LiteralPath $downloaded.EnvelopePath -Algorithm SHA256).Hash.ToUpperInvariant() -eq $rel210.EnvelopeSha256) 'downloaded envelope hash must match the index'
    $originalPackageBytes = [IO.File]::ReadAllBytes($rel210.PackagePath)
    $downloadedPackageBytes = [IO.File]::ReadAllBytes($downloaded.PackagePath)
    Assert-True (([BitConverter]::ToString($originalPackageBytes)) -eq ([BitConverter]::ToString($downloadedPackageBytes))) 'downloaded package bytes must equal the served package'

    # A plain hashtable release entry must also be accepted.
    $releaseHash = @{
        Version = $release.Version; ReleaseId = $release.ReleaseId; EnvelopeUrl = $release.EnvelopeUrl; PackageUrl = $release.PackageUrl
        PackageBytes = $release.PackageBytes; PackageSha256 = $release.PackageSha256; EnvelopeSha256 = $release.EnvelopeSha256
    }
    $hashOut = Join-Path $testRoot 'out-hashtable'
    $downloadedHash = Get-JarvisReleasePackage -Release $releaseHash -OutputDirectory $hashOut -AllowLoopbackHttp
    Assert-True ((Test-Path -LiteralPath $downloadedHash.PackagePath) -and $downloadedHash.Version -eq '2.1.0' -and $downloadedHash.ReleaseId -eq $rel210.ReleaseId) 'hashtable release entry must download'

    # Negative: tampered index body.
    $tamperPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index-tampered.json" -IndexPath $tamperPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
    } 'Signature verification failed'

    # Negative: wrong pinned key.
    $wrongKeyPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $wrongKeyPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint ('0' * 64) -CurrentVersion '1.0.0' -AllowLoopbackHttp
    } 'fingerprint is not trusted'

    # Negative: expired index.
    $expiredPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index-expired.json" -IndexPath $expiredPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
    } 'expired'

    # Negative: non-HTTPS URL refused without the loopback switch.
    $noHttpsPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $noHttpsPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0'
    } 'must use HTTPS'

    # Negative: redirect to a plain-HTTP private IP is rejected on the scheme check.
    $redir1Path = Join-Path $testRoot ('w-' + [Guid]::NewGuid().ToString('N') + '.bin')
    Assert-Fails {
        Get-JarvisWebResource -Url "http://127.0.0.1:$port/redirect-http-private" -OutputPath $redir1Path `
            -MaxBytes 262144 -AllowLoopbackHttp
    } 'must use HTTPS'

    # Negative: redirect to an HTTPS private IP is rejected by DNS resolution.
    $redir2Path = Join-Path $testRoot ('w-' + [Guid]::NewGuid().ToString('N') + '.bin')
    Assert-Fails {
        Get-JarvisWebResource -Url "http://127.0.0.1:$port/redirect-https-private" -OutputPath $redir2Path `
            -MaxBytes 262144 -AllowLoopbackHttp
    } 'resolves to a private'

    # Negative: oversized index is rejected by the size cap before verification.
    $bigPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index-oversized.bin" -IndexPath $bigPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
    } 'too large'

    # Negative: unsafe package filename (CON.zip) rejected before any download.
    $unsafePath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        $unsafeRelease = Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index-unsafe-name.json" -IndexPath $unsafePath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
        Get-JarvisReleasePackage -Release $unsafeRelease -OutputDirectory (Join-Path $testRoot ('out-' + [Guid]::NewGuid().ToString('N'))) -AllowLoopbackHttp
    } 'filename is unsafe'

    # Negative: no release newer than the current version.
    $nonePath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $nonePath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '9.9.9' -AllowLoopbackHttp
    } 'No newer release'

    # Negative: package hash/size mismatch is rejected.
    [IO.File]::WriteAllBytes($rel210.PackagePath, [Text.Encoding]::UTF8.GetBytes('tampered package body that changes the hash'))
    $mismatchPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        $mismatchRelease = Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $mismatchPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
        Get-JarvisReleasePackage -Release $mismatchRelease -OutputDirectory (Join-Path $testRoot ('out-' + [Guid]::NewGuid().ToString('N'))) -AllowLoopbackHttp
    } 'SHA-256 does not match'

    # Negative: oversized package is rejected by the packageBytes cap.
    [IO.File]::WriteAllBytes($rel210.PackagePath, (New-Object byte[] 65537))
    $oversizePath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        $oversizeRelease = Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $oversizePath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
        Get-JarvisReleasePackage -Release $oversizeRelease -OutputDirectory (Join-Path $testRoot ('out-' + [Guid]::NewGuid().ToString('N'))) -AllowLoopbackHttp
    } 'too large'

    # Negative: truncated package is rejected by the hash check.
    [IO.File]::WriteAllBytes($rel210.PackagePath, [Text.Encoding]::UTF8.GetBytes('x'))
    $shortPath = Join-Path $testRoot ('idx-' + [Guid]::NewGuid().ToString('N') + '.json')
    Assert-Fails {
        $shortRelease = Get-JarvisReleaseIndex -IndexUrl "http://127.0.0.1:$port/index.json" -IndexPath $shortPath `
            -PublicKeyPath $publicKeyOut -PinnedPublicKeyFingerprint $created.PublicKeyFingerprint -CurrentVersion '1.0.0' -AllowLoopbackHttp
        Get-JarvisReleasePackage -Release $shortRelease -OutputDirectory (Join-Path $testRoot ('out-' + [Guid]::NewGuid().ToString('N'))) -AllowLoopbackHttp
    } 'SHA-256 does not match'

    'RELEASE_INDEX_TESTS=PASS'
} finally {
    if ($null -ne $serverJob) { try { Stop-TestHttpServer -Job $serverJob -StopFile $stopFile -Port $port } catch { } }
    if (Test-Path -LiteralPath $testRoot) { try { Remove-Item -LiteralPath $testRoot -Recurse -Force } catch { } }
}
