<#
.SYNOPSIS
  Verifies the subscription installer builder and its staging output. Runs on
  both Windows PowerShell 5.1 and PowerShell 7+. Stage/test only in TEMP; the
  repository's real dist-* directories are never used.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
$tempRoots = [System.Collections.Generic.List[string]]::new()

function Record-Failure {
    param([string]$Message)
    $failures.Add($Message)
    Write-Host "  FAIL: $Message" -ForegroundColor Red
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
    }
    else {
        Record-Failure $Message
    }
}

function Get-TempChild {
    param([string]$Name)
    $path = Join-Path $env:TEMP $Name
    $tempRoots.Add($path)
    return $path
}

try {
    $installerRoot = $PSScriptRoot
    $builder = Join-Path $installerRoot 'Build-Installer-SUBSCRIPTION-v12.ps1'
    Assert-True (Test-Path -LiteralPath $builder -PathType Leaf) 'builder file exists'

    $workRoot = Get-TempChild ('jarvis-sub-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workRoot -ErrorAction Stop | Out-Null

    # Resolve node (same rules as the builder) so the runs are deterministic.
    $nodePath = $null
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $nodeCommand -and $nodeCommand.Source) { $nodePath = [string]$nodeCommand.Source }

    $builderArgs = @{}
    if ($nodePath) { $builderArgs['NodeRuntime'] = $nodePath }

    # ------------------------------------------------------------------
    # 1) Stage-only run (no IExpress) and assert the staging layout.
    # ------------------------------------------------------------------
    $stageOutputPath = Join-Path $workRoot 'stage-only\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe'
    $stageResult = & $builder -SkipIExpress -WorkRoot $workRoot -OutputPath $stageOutputPath @builderArgs

    Assert-True ($null -ne $stageResult) 'stage-only run returned a build summary'
    if ($null -ne $stageResult) {
        Assert-True ([bool]$stageResult.SkipIExpress) 'stage-only run reported SkipIExpress'
        Assert-True (Test-Path -LiteralPath $stageResult.PayloadRoot -PathType Container) 'staging payload root exists'

        $payloadRoot = [string]$stageResult.PayloadRoot
        if (Test-Path -LiteralPath $payloadRoot -PathType Container) {
            $appRoot = Join-Path $payloadRoot 'app'

            # Program marker content is exact.
            $markerPath = Join-Path $appRoot '.jarvis-program-marker'
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                $markerBytes = [System.IO.File]::ReadAllBytes($markerPath)
                $expectedMarker = [System.Text.Encoding]::ASCII.GetBytes('JARVIS NEXUS ULTRA program directory v1')
                Assert-True ([Convert]::ToBase64String($markerBytes) -eq [Convert]::ToBase64String($expectedMarker)) 'app\.jarvis-program-marker content is exact'
            }
            else {
                Record-Failure 'app\.jarvis-program-marker is missing'
            }

            # version.txt == 1.0.0
            $versionPath = Join-Path $appRoot 'version.txt'
            if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
                $versionText = ([string](Get-Content -LiteralPath $versionPath -Raw)).Trim()
                Assert-True ($versionText -eq '1.0.0') 'app\version.txt == 1.0.0'
            }
            else {
                Record-Failure 'app\version.txt is missing'
            }

            # app\release.json carries the subscription identity.
            $appReleasePath = Join-Path $appRoot 'release.json'
            if (Test-Path -LiteralPath $appReleasePath -PathType Leaf) {
                $appReleaseRaw = [string](Get-Content -LiteralPath $appReleasePath -Raw)
                $appReleaseText = $appReleaseRaw.Trim()
                Assert-True ($appReleaseText -eq '{"releaseId":"subscription-v12","version":"1.0.0"}') 'app\release.json has releaseId subscription-v12 / version 1.0.0'
            }
            else {
                Record-Failure 'app\release.json is missing'
            }

            # Private-channel client bundle.
            $channelRoot = Join-Path $appRoot 'private-channel'
            Assert-True (Test-Path -LiteralPath (Join-Path $channelRoot 'Jarvis.PrivateChannel.psm1') -PathType Leaf) 'app\private-channel\Jarvis.PrivateChannel.psm1 exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $channelRoot 'Invoke-JarvisUpdate.ps1') -PathType Leaf) 'app\private-channel\Invoke-JarvisUpdate.ps1 exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $channelRoot 'public-key.xml') -PathType Leaf) 'app\private-channel\public-key.xml exists'

            # Empty user-data roots.
            $dataDir = Join-Path $payloadRoot 'data'
            $senseDir = Join-Path $payloadRoot 'sense-state'
            $dataOk = (Test-Path -LiteralPath $dataDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $dataDir -Force).Count -eq 0)
            $senseOk = (Test-Path -LiteralPath $senseDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $senseDir -Force).Count -eq 0)
            Assert-True $dataOk 'data\ exists and is empty'
            Assert-True $senseOk 'sense-state\ exists and is empty'

            # Program files.
            Assert-True (Test-Path -LiteralPath (Join-Path $appRoot 'ultra-server.mjs') -PathType Leaf) 'app\ultra-server.mjs exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $appRoot 'conversation-intelligence.mjs') -PathType Leaf) 'app\conversation-intelligence.mjs exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $appRoot 'poe2-build-coach.mjs') -PathType Leaf) 'app\poe2-build-coach.mjs exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $appRoot 'knowledge\jarvis-core.json') -PathType Leaf) 'app\knowledge\jarvis-core.json exists'
            Assert-True (Test-Path -LiteralPath (Join-Path $payloadRoot 'runtime\node.exe') -PathType Leaf) 'runtime\node.exe exists'

            # Launcher (UTF-8 no BOM + required invocations).
            $launcherPath = Join-Path $payloadRoot 'launcher\Start-Jarvis-RELEASE.ps1'
            $launcherCmdPath = Join-Path $payloadRoot 'launcher\Start-Jarvis-RELEASE.cmd'
            Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf) 'launcher\Start-Jarvis-RELEASE.ps1 exists'
            Assert-True (Test-Path -LiteralPath $launcherCmdPath -PathType Leaf) 'launcher\Start-Jarvis-RELEASE.cmd exists'
            if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
                $launcherBytes = [System.IO.File]::ReadAllBytes($launcherPath)
                $hasBom = ($launcherBytes.Length -ge 3 -and $launcherBytes[0] -eq 0xEF -and $launcherBytes[1] -eq 0xBB -and $launcherBytes[2] -eq 0xBF)
                Assert-True (-not $hasBom) 'generated launcher is UTF-8 without BOM'

                $launcherText = [string](Get-Content -LiteralPath $launcherPath -Raw)
                Assert-True $launcherText.Contains('Invoke-JarvisSubscriptionCheck.ps1') 'launcher contains the subscription gate invocation'
                Assert-True $launcherText.Contains('-PurchaseUrl') 'launcher passes -PurchaseUrl to the subscription gate'
                Assert-True $launcherText.Contains('Invoke-JarvisUpdate.ps1') 'launcher contains the auto-update invocation'
                Assert-True $launcherText.Contains('-IndexUrl') 'launcher passes -IndexUrl to the updater'
                Assert-True $launcherText.Contains('-StateRoot') 'launcher passes -StateRoot to the updater'
                Assert-True $launcherText.Contains('-Port 3791') 'launcher passes -Port 3791 to the updater'

                # The actual updater invocation must not auto-confirm (comments
                # may mention -AutoConfirm, so inspect the invocation line itself).
                $updateInvocationLines = @($launcherText -split "`r?`n" | Where-Object { $_ -match '\-ProgramRoot' })
                $updateInvocationOk = ($updateInvocationLines.Count -ge 1)
                foreach ($line in $updateInvocationLines) {
                    if ($line -match '\-AutoConfirm') { $updateInvocationOk = $false }
                }
                Assert-True $updateInvocationOk 'launcher update invocation is not auto-confirmed'

                Assert-True (-not $launcherText.Contains('Stop-Process -Name')) 'launcher never kills processes by image name'
            }

            # node --check on the staged server entrypoint, when node is available.
            if ($nodePath) {
                $serverPath = Join-Path $appRoot 'ultra-server.mjs'
                if (Test-Path -LiteralPath $serverPath -PathType Leaf) {
                    & $nodePath --check $serverPath 2>&1 | Out-Null
                    Assert-True ($LASTEXITCODE -eq 0) 'node --check passes on ultra-server.mjs'
                }
            }
            else {
                Write-Host '  SKIP: node not available; skipping --check'
            }
        }
    }

    # ------------------------------------------------------------------
    # 2) Full build into TEMP and verify EXE + checksum.
    # ------------------------------------------------------------------
    $outputPath = Join-Path $workRoot 'out\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe'
    $fullResult = & $builder -WorkRoot $workRoot -OutputPath $outputPath @builderArgs

    Assert-True ($null -ne $fullResult) 'full build returned a build summary'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'EXE exists'
    $checksumPath = "$outputPath.sha256.txt"
    Assert-True (Test-Path -LiteralPath $checksumPath -PathType Leaf) 'checksum file exists'
    if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        $actualHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $checksumLine = [string](Get-Content -LiteralPath $checksumPath -Raw)
        $expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()
        Assert-True ($actualHash -eq $expectedHash) 'EXE sha256 matches the .sha256.txt file'
    }
}
finally {
    foreach ($root in $tempRoots) {
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "INSTALLER_SUBSCRIPTION_TESTS=FAIL ($($failures.Count) failure(s))"
    exit 1
}
Write-Host 'INSTALLER_SUBSCRIPTION_TESTS=PASS'
exit 0
