<#
.SYNOPSIS
  Builds the JARVIS NEXUS ULTRA subscription installer (self-extracting IExpress EXE).

.DESCRIPTION
  Assembles a versioned, program-only install tree
  (app\, data\, sense-state\, runtime\, launcher\, desktop-shell\ and a root
  release.json), wraps it into a payload.zip together with a small
  integrity-checked installer, and produces an IExpress self-extracting EXE
  exactly like Build-Installer-ULTRA.ps1 (ASCII work root, SED file, /N /Q).

  The generated launcher enforces the optional subscription gate when it is
  present in app\private-channel, runs the signed auto-update check (without
  -AutoConfirm so the Update/Cancel dialog is the update notification),
  and only then starts the core and the optional native companions.

.PARAMETER NodeRuntime
  Optional path to a local node.exe (v20+). Fallbacks: <repo>\runtime\node.exe,
  then node/node.exe on PATH. Fails with a clear message if absent.

.PARAMETER OutputPath
  Optional full path for the generated EXE. Defaults to
  <installer>\dist-subscription\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe.

.PARAMETER WorkRoot
  Optional ASCII, space-free staging root. Defaults to C:\tmp\jarvis-iexpress.

.PARAMETER PurchaseUrl
  Optional purchase page URL baked into the generated launcher.

.PARAMETER IndexUrl
  Optional signed release index URL baked into the generated launcher.

.PARAMETER SkipIExpress
  Stops after staging (writes no EXE and no checksum). Useful for tests/audit.
#>
[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-iexpress',
    [string]$PurchaseUrl = 'https://proturik.github.io/jarvis-nexus/purchase.html',
    [string]$IndexUrl = 'https://proturik.github.io/jarvis-nexus/release-index.json',
    [switch]$SkipIExpress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Version = '1.3.0'
$ReleaseId = 'subscription-v12'
$ProductName = 'JARVIS NEXUS ULTRA'
$MarkerContent = 'JARVIS NEXUS ULTRA program directory v1'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)

function Fail {
    param([string]$Message)
    throw "JARVIS v12 installer: $Message"
}

function Need-Leaf {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "Missing $Label : $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Need-Dir {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "Missing $Label : $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
}

function Copy-Leaf {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $resolved = Need-Leaf $Source $Label
    Copy-Item -LiteralPath $resolved -Destination $DestinationDirectory -Force
}

function Copy-Tree {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $resolved = Need-Dir $Source $Label
    Copy-Item -LiteralPath $resolved -Destination $DestinationDirectory -Recurse -Force
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Assert-Parse {
    param([string]$Path, [string]$Label)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $first = $errors[0]
        Fail "PowerShell syntax error in $Label at line $($first.Extent.StartLineNumber): $($first.Message)"
    }
}

function Assert-IExpressSafe {
    param([string]$Path, [string]$Label)
    if ($Path -match '\s' -or $Path -match '[^\x20-\x7E]') {
        Fail "$Label must contain only ASCII characters and no spaces: $Path"
    }
}

function Get-LocalNode {
    param([string]$RequestedPath, [string]$ProjectRoot)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($RequestedPath) { $candidates.Add($RequestedPath) }

    $vendored = Join-Path $ProjectRoot 'runtime\node.exe'
    if (Test-Path -LiteralPath $vendored -PathType Leaf) { $candidates.Add($vendored) }

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $nodeCommand -and $nodeCommand.Source) { $candidates.Add([string]$nodeCommand.Source) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    Fail 'Node.js 20+ was not found. Pass a local node.exe with -NodeRuntime (this script never downloads dependencies).'
}

function Test-NodeVersion {
    param([string]$NodePath)

    $versionText = (& $NodePath --version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^v(?<major>\d+)\.') {
        Fail "Cannot execute Node runtime: $NodePath"
    }
    if ([int]$Matches.major -lt 20) { Fail "Node.js 20+ is required; found $versionText." }
    return $versionText
}

function Get-IExpress {
    $candidates = @(
        (Join-Path $env:WINDIR 'System32\iexpress.exe'),
        (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Fail 'IExpress was not found in this Windows installation.'
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot

if ([string]::IsNullOrWhiteSpace($PurchaseUrl) -or -not $PurchaseUrl.StartsWith('https://')) {
    Fail 'PurchaseUrl must be an absolute https:// URL.'
}
if ([string]::IsNullOrWhiteSpace($IndexUrl) -or -not $IndexUrl.StartsWith('https://')) {
    Fail 'IndexUrl must be an absolute https:// URL.'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $installerRoot 'dist-subscription\JARVIS-NEXUS-ULTRA-Subscription-Setup.exe'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "Refusing to overwrite existing output: $OutputPath" }
if ($OutputPath -match '\r|\n' -or $OutputPath -match '"') { Fail 'OutputPath contains an unsupported character.' }
Ensure-Dir (Split-Path -Parent $OutputPath)

$hashPath = "$OutputPath.sha256.txt"
if (Test-Path -LiteralPath $hashPath) { Fail "Refusing to overwrite existing checksum: $hashPath" }

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
Assert-IExpressSafe $WorkRoot 'WorkRoot'
Ensure-Dir $WorkRoot

$buildId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path $WorkRoot "JNU-SUB-v12-$buildId"
Assert-IExpressSafe $stageRoot 'IExpress staging directory'
if (Test-Path -LiteralPath $stageRoot) { Fail "Refusing to reuse staging directory: $stageRoot" }

$nodePath = Get-LocalNode -RequestedPath $NodeRuntime -ProjectRoot $projectRoot
$nodeVersion = Test-NodeVersion $nodePath

# Explicit allow-list of the versioned, program-only app tree. No server.mjs,
# OMEGA mode, data/, .env, .git, or node_modules are copied into the distribution.
$serverSource = Need-Leaf (Join-Path $projectRoot 'ultra-server.mjs') 'ULTRA server entrypoint'
Need-Leaf (Join-Path $projectRoot 'conversation-intelligence.mjs') 'conversation intelligence' | Out-Null
Need-Leaf (Join-Path $projectRoot 'poe2-build-coach.mjs') 'PoE2 build coach' | Out-Null
Need-Leaf (Join-Path $projectRoot 'jarvis-tools.mjs') 'built-in tools' | Out-Null
Need-Leaf (Join-Path $projectRoot 'knowledge-graph.mjs') 'knowledge graph' | Out-Null
Need-Leaf (Join-Path $projectRoot 'mcp-client.mjs') 'MCP client' | Out-Null
Need-Leaf (Join-Path $projectRoot 'mcp-servers.example.json') 'MCP example config' | Out-Null
Need-Leaf (Join-Path $projectRoot 'knowledge\jarvis-core.json') 'knowledge core' | Out-Null
Need-Dir (Join-Path $projectRoot 'public-ultra') 'public-ultra directory' | Out-Null
Need-Dir (Join-Path $projectRoot 'assets') 'assets directory' | Out-Null
Need-Dir (Join-Path $projectRoot 'windows-control') 'windows-control directory' | Out-Null
Need-Dir (Join-Path $projectRoot 'windows-theme') 'windows-theme directory' | Out-Null
Need-Dir (Join-Path $projectRoot 'private-channel') 'private-channel directory' | Out-Null

New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null
$payloadRoot = Join-Path $stageRoot 'payload-root'
$appPayload = Join-Path $payloadRoot 'app'
$dataPayload = Join-Path $payloadRoot 'data'
$senseStatePayload = Join-Path $payloadRoot 'sense-state'
$runtimePayload = Join-Path $payloadRoot 'runtime'
$launcherPayload = Join-Path $payloadRoot 'launcher'
$desktopShellPayload = Join-Path $payloadRoot 'desktop-shell'

New-Item -ItemType Directory -Path $appPayload, $runtimePayload, $launcherPayload, $desktopShellPayload -ErrorAction Stop | Out-Null
# Empty user-data roots (created here for the audit tree; the installer also
# creates them on install, and they never ship inside app\).
New-Item -ItemType Directory -Path $dataPayload, $senseStatePayload -ErrorAction Stop | Out-Null

Copy-Leaf $serverSource $appPayload 'ULTRA server entrypoint'
Copy-Leaf (Join-Path $projectRoot 'conversation-intelligence.mjs') $appPayload 'conversation intelligence'
Copy-Leaf (Join-Path $projectRoot 'poe2-build-coach.mjs') $appPayload 'PoE2 build coach'
Copy-Leaf (Join-Path $projectRoot 'jarvis-tools.mjs') $appPayload 'built-in tools'
Copy-Leaf (Join-Path $projectRoot 'knowledge-graph.mjs') $appPayload 'knowledge graph'
Copy-Leaf (Join-Path $projectRoot 'mcp-client.mjs') $appPayload 'MCP client'
Copy-Leaf (Join-Path $projectRoot 'mcp-servers.example.json') $appPayload 'MCP example config'
Copy-Tree (Join-Path $projectRoot 'public-ultra') $appPayload 'public-ultra directory'
Copy-Tree (Join-Path $projectRoot 'assets') $appPayload 'assets directory'
Copy-Tree (Join-Path $projectRoot 'windows-control') $appPayload 'windows-control directory'
Copy-Tree (Join-Path $projectRoot 'windows-theme') $appPayload 'windows-theme directory'

$knowledgePayload = Join-Path $appPayload 'knowledge'
Ensure-Dir $knowledgePayload
Copy-Leaf (Join-Path $projectRoot 'knowledge\jarvis-core.json') $knowledgePayload 'knowledge core'

# Full private-channel bundle: client updater (verifier, state, downloader,
# hand-off, prompts, public key) plus the optional subscription gate.
Copy-Tree (Join-Path $projectRoot 'private-channel') $appPayload 'private-channel directory'

# Program identity: the marker and version.txt make this a versioned
# program-only directory the updater can replace atomically.
Write-Utf8NoBom (Join-Path $appPayload '.jarvis-program-marker') $MarkerContent
Write-Utf8NoBom (Join-Path $appPayload 'version.txt') $Version
Write-Utf8NoBom (Join-Path $appPayload 'release.json') '{"releaseId":"subscription-v12","version":"1.3.0"}'

# Bundled runtime.
Copy-Item -LiteralPath $nodePath -Destination (Join-Path $runtimePayload 'node.exe') -Force

# Optional native companions, only when they exist in the source tree.
$petCandidates = @(
    (Join-Path $projectRoot 'desktop-shell\dist\JarvisPet.exe'),
    (Join-Path $projectRoot 'desktop-shell\JarvisPet.exe')
)
$petSource = $petCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $petSource) {
    Copy-Item -LiteralPath $petSource -Destination (Join-Path $desktopShellPayload 'JarvisPet.exe') -Force
}

$senseCandidates = @(
    (Join-Path $projectRoot 'sensors\dist\JarvisSense\JarvisSense.exe'),
    (Join-Path $projectRoot 'desktop-shell\sense\JarvisSense.exe')
)
$senseSource = $senseCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $senseSource) {
    $sensePayload = Join-Path $desktopShellPayload 'sense'
    Ensure-Dir $sensePayload
    Copy-Item -LiteralPath $senseSource -Destination (Join-Path $sensePayload 'JarvisSense.exe') -Force
    $senseInternal = Join-Path (Split-Path -Parent $senseSource) '_internal'
    if (Test-Path -LiteralPath $senseInternal -PathType Container) {
        Copy-Item -LiteralPath $senseInternal -Destination $sensePayload -Recurse -Force
    }
}

# Install-level manifest (kept separate from app\release.json, which is the
# versioned program identity consumed by ultra-server.mjs).
$rootManifest = [ordered]@{
    product = $ProductName
    version = $Version
    releaseId = $ReleaseId
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    entrypoint = 'ultra-server.mjs'
    port = 3791
    mode = 'ULTRA-subscription'
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    purchaseUrl = $PurchaseUrl
    indexUrl = $IndexUrl
    dataPolicy = 'User data lives in data\ and sense-state\ and is never overwritten by the installer or by updates.'
}
Write-Utf8NoBom (Join-Path $payloadRoot 'release.json') ($rootManifest | ConvertTo-Json -Depth 4)

# ---------------------------------------------------------------------------
# Generated launcher (UTF-8 no BOM, StrictMode Latest, ErrorActionPreference
# Stop, never kills processes by image name).
# ---------------------------------------------------------------------------
$launcherTemplate = @'
<#
.SYNOPSIS
  Starts the installed JARVIS NEXUS ULTRA subscription install only after the
  subscription gate passes, then checks for a signed update, starts the core
  and the optional native companions. Never stops processes by image name.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $InstallRoot 'app'
$NodePath = Join-Path $InstallRoot 'runtime\node.exe'
$ServerPath = Join-Path $AppRoot 'ultra-server.mjs'
$PetPath = Join-Path $InstallRoot 'desktop-shell\JarvisPet.exe'
$SensePath = Join-Path $InstallRoot 'desktop-shell\sense\JarvisSense.exe'
$SenseStateRoot = Join-Path $InstallRoot 'sense-state'
$DataRoot = Join-Path $InstallRoot 'data'
$BootstrapUri = 'http://127.0.0.1:3791/api/bootstrap'
$PurchaseUrl = '__PURCHASE_URL__'
$UpdateIndexUrl = '__INDEX_URL__'

foreach ($required in @($NodePath, $ServerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "JARVIS NEXUS ULTRA component is missing: $required"
    }
}

# User data lives outside the versioned program directory so updates can replace
# app\ atomically without touching conversations, memory, settings or Sense state.
$env:JARVIS_DATA_DIR = $DataRoot
New-Item -ItemType Directory -Path $env:JARVIS_DATA_DIR -Force | Out-Null

# --- Subscription gate (optional but enforced when shipped) ---
# If the package includes a subscription gate it must pass before anything starts.
$SubscriptionGate = Join-Path $AppRoot 'private-channel\Invoke-JarvisSubscriptionCheck.ps1'
if (Test-Path -LiteralPath $SubscriptionGate -PathType Leaf) {
    $gatePowerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $gatePowerShell -PathType Leaf)) {
        $gatePowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    & $gatePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $SubscriptionGate -InstallRoot $AppRoot -DataRoot $DataRoot -PurchaseUrl $PurchaseUrl
    $gateExit = $LASTEXITCODE
    if ($gateExit -ne 0) {
        Write-Error "JARVIS NEXUS ULTRA subscription check failed (exit code $gateExit). Install a valid license and try again."
        exit $gateExit
    }
}

# --- Local brain bootstrap (Ollama + qwen3:8b) ---
# First launch downloads and installs the brain automatically; no user setup.
$BrainInstaller = Join-Path $AppRoot 'private-channel\Install-JarvisBrain.ps1'
if (Test-Path -LiteralPath $BrainInstaller -PathType Leaf) {
    try {
        & $BrainInstaller
    }
    catch {
        Write-Warning "JARVIS brain install failed: $($_.Exception.Message)"
    }
}

# --- Signed auto-update check (fully automatic: downloads, verifies and
#     activates with the progress HUD; no user interaction required) ---
$UpdaterScript = Join-Path $AppRoot 'private-channel\Invoke-JarvisUpdate.ps1'
if (Test-Path -LiteralPath $UpdaterScript -PathType Leaf) {
    try {
        & $UpdaterScript -ProgramRoot $AppRoot -IndexUrl $UpdateIndexUrl -DataRoot $DataRoot -StateRoot (Join-Path $InstallRoot 'update-state') -Port 3791 -AutoConfirm -Progress | Out-Null
    }
    catch {
        Write-Warning "JARVIS update check failed: $($_.Exception.Message)"
    }
}

function Test-JarvisEndpoint {
    try {
        $boot = Invoke-RestMethod -Uri $BootstrapUri -TimeoutSec 1
        return ($null -ne $boot.settings -and [string]$boot.settings.assistantName -eq 'JARVIS')
    }
    catch { return $false }
}

function Test-ExactProcessRunning {
    param([string]$ExecutablePath, [string]$ProcessName)
    $expectedPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    $processes = Get-CimInstance -ClassName Win32_Process -Filter "Name='$ProcessName'" -ErrorAction SilentlyContinue
    return ($null -ne ($processes | Where-Object {
        $_.ExecutablePath -and [string]::Equals([System.IO.Path]::GetFullPath($_.ExecutablePath), $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1))
}

if (-not (Test-JarvisEndpoint)) {
    Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $ServerPath) -WorkingDirectory $AppRoot -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-JarvisEndpoint)) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-JarvisEndpoint)) { throw 'The JARVIS NEXUS ULTRA server did not become ready on its local endpoint.' }
}

if ((Test-Path -LiteralPath $PetPath -PathType Leaf) -and -not (Test-ExactProcessRunning -ExecutablePath $PetPath -ProcessName 'JarvisPet.exe')) {
    Start-Process -FilePath $PetPath -WorkingDirectory (Split-Path -Parent $PetPath)
}

if ((Test-Path -LiteralPath $SensePath -PathType Leaf) -and -not (Test-ExactProcessRunning -ExecutablePath $SensePath -ProcessName 'JarvisSense.exe')) {
    New-Item -ItemType Directory -Path $SenseStateRoot -Force | Out-Null
    Start-Process -FilePath $SensePath -ArgumentList @('--install-root', ('"{0}"' -f $SenseStateRoot)) -WorkingDirectory (Split-Path -Parent $SensePath) -WindowStyle Hidden
}

# --- Background update watcher (auto-notify + auto-update with progress HUD) ---
# Runs hidden while JARVIS is running; checks the signed channel on an interval,
# shows a tray notification when a new release exists, then updates automatically.
$UpdateWatcher = Join-Path $AppRoot 'private-channel\Start-JarvisUpdateWatcher.ps1'
if (Test-Path -LiteralPath $UpdateWatcher -PathType Leaf) {
    $watcherPowerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $watcherPowerShell -PathType Leaf)) {
        $watcherPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    Start-Process -FilePath $watcherPowerShell -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $UpdateWatcher),'-ProgramRoot',('"{0}"' -f $AppRoot),'-IndexUrl',('"{0}"' -f $UpdateIndexUrl),'-DataRoot',('"{0}"' -f $DataRoot),'-StateRoot',('"{0}"' -f (Join-Path $InstallRoot 'update-state')),'-Port','3791') -WindowStyle Hidden | Out-Null
}
'@

$purchaseUrlLiteral = "'" + $PurchaseUrl.Replace("'", "''") + "'"
$indexUrlLiteral = "'" + $IndexUrl.Replace("'", "''") + "'"
$launcherText = $launcherTemplate.Replace("'__PURCHASE_URL__'", $purchaseUrlLiteral).Replace("'__INDEX_URL__'", $indexUrlLiteral)
$launcherText = $launcherText.TrimEnd("`n", "`r") + "`n"
$launcherPath = Join-Path $launcherPayload 'Start-Jarvis-RELEASE.ps1'
Write-Utf8NoBom $launcherPath $launcherText
Assert-Parse $launcherPath 'generated launcher'

$launcherCmdText = @'
@echo off
setlocal EnableExtensions
set "JARVIS_HOME=%~dp0"

if not exist "%JARVIS_HOME%Start-Jarvis-RELEASE.ps1" (
  echo JARVIS NEXUS ULTRA: launcher script is missing.
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%JARVIS_HOME%Start-Jarvis-RELEASE.ps1"
exit /b %ERRORLEVEL%
'@
$launcherCmdText = $launcherCmdText.TrimEnd("`n", "`r") + "`r`n"
Write-Utf8NoBom (Join-Path $launcherPayload 'Start-Jarvis-RELEASE.cmd') $launcherCmdText

# ---------------------------------------------------------------------------
# Embedded integrity-checked installer (console; keeps user data intact).
# ---------------------------------------------------------------------------
$installerCmdText = @'
@echo off
setlocal EnableExtensions
set "JARVIS_INSTALLER_DIR=%~dp0"

if not exist "%JARVIS_INSTALLER_DIR%Install-Jarvis-SUBSCRIPTION.ps1" (
  echo JARVIS NEXUS ULTRA: installer script is missing.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%JARVIS_INSTALLER_DIR%Install-Jarvis-SUBSCRIPTION.ps1" %*
exit /b %ERRORLEVEL%
'@
$installerCmdText = $installerCmdText.TrimEnd("`n", "`r") + "`r`n"
Write-Utf8NoBom (Join-Path $stageRoot 'Install-Jarvis-SUBSCRIPTION.cmd') $installerCmdText

$installerPs1Text = @'
<#
.SYNOPSIS
  Installs the JARVIS NEXUS ULTRA subscription package for the current user.
  Program-only directories are written fresh; data\ and sense-state\ are created
  when absent and are never overwritten.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProductName = 'JARVIS NEXUS ULTRA'
$InstallerRoot = $PSScriptRoot
$PayloadZip = Join-Path $InstallerRoot 'payload.zip'
$ManifestPath = Join-Path $InstallerRoot 'installer-manifest.json'

function Fail {
    param([string]$Message)
    throw "$ProductName installer: $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
}

function Copy-PayloadDirectory {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Fail "package is missing: $Source"
    }
    Ensure-Directory $Destination
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-DesktopShortcut {
    param([string]$Path, [string]$Launcher, [string]$WorkingDirectory)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return $false }
    $quote = [char]34
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $quote + $Launcher + $quote
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,102"
    $shortcut.Description = 'Launch JARVIS NEXUS ULTRA'
    $shortcut.Save()
    return $true
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $manifest.payloadSha256 -or -not $manifest.version -or $manifest.entrypoint -ne 'ultra-server.mjs') {
    Fail 'installer manifest is invalid or targets an unsupported mode.'
}
if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) { Fail 'installation payload is missing.' }

$actualHash = (Get-FileHash -LiteralPath $PayloadZip -Algorithm SHA256).Hash.ToUpperInvariant()
$expectedHash = ([string]$manifest.payloadSha256).Trim().ToUpperInvariant()
if ($actualHash -ne $expectedHash) { Fail 'payload integrity check failed.' }

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$installRoot = Join-Path $localAppData $ProductName
$appRoot = Join-Path $installRoot 'app'
$runtimeRoot = Join-Path $installRoot 'runtime'
$launcherRoot = Join-Path $installRoot 'launcher'
$desktopShellRoot = Join-Path $installRoot 'desktop-shell'
$extractionRoot = Join-Path $InstallerRoot ('JNU-sub-' + [guid]::NewGuid().ToString('N'))

Ensure-Directory $installRoot

$result = $null
try {
    try {
        Expand-Archive -LiteralPath $PayloadZip -DestinationPath $extractionRoot -ErrorAction Stop
    }
    catch {
        Fail "could not expand the installation payload: $($_.Exception.Message)"
    }

    $packageApp = Join-Path $extractionRoot 'app'
    $packageRuntime = Join-Path $extractionRoot 'runtime'
    $packageLauncher = Join-Path $extractionRoot 'launcher'
    $packageDesktopShell = Join-Path $extractionRoot 'desktop-shell'

    foreach ($required in @(
        (Join-Path $packageApp 'ultra-server.mjs'),
        (Join-Path $packageApp '.jarvis-program-marker'),
        (Join-Path $packageApp 'version.txt'),
        (Join-Path $packageRuntime 'node.exe'),
        (Join-Path $packageLauncher 'Start-Jarvis-RELEASE.ps1'),
        (Join-Path $packageLauncher 'Start-Jarvis-RELEASE.cmd')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Fail "package safety check failed: missing $required" }
    }
    if (Test-Path -LiteralPath (Join-Path $packageApp 'data') -PathType Container) { Fail 'package safety check failed: it must not contain user data.' }
    if (Test-Path -LiteralPath (Join-Path $packageApp '.env') -PathType Leaf) { Fail 'package safety check failed: it must not contain a user .env file.' }
    if (Test-Path -LiteralPath (Join-Path $packageApp 'server.mjs') -PathType Leaf) { Fail 'package safety check failed: only ultra-server.mjs is allowed.' }

    Copy-PayloadDirectory -Source $packageApp -Destination $appRoot
    Copy-PayloadDirectory -Source $packageRuntime -Destination $runtimeRoot
    Copy-PayloadDirectory -Source $packageLauncher -Destination $launcherRoot
    if (Test-Path -LiteralPath $packageDesktopShell -PathType Container) {
        Copy-PayloadDirectory -Source $packageDesktopShell -Destination $desktopShellRoot
    }

    foreach ($userDataDir in @('data', 'sense-state', 'update-state')) {
        Ensure-Directory (Join-Path $installRoot $userDataDir)
    }

    $rootRelease = Join-Path $extractionRoot 'release.json'
    if (Test-Path -LiteralPath $rootRelease -PathType Leaf) {
        Copy-Item -LiteralPath $rootRelease -Destination (Join-Path $installRoot 'release.json') -Force
    }

    $launcher = Join-Path $launcherRoot 'Start-Jarvis-RELEASE.ps1'
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $desktopLink = Join-Path $desktop "$ProductName.lnk"
    $desktopShortcutCreated = New-DesktopShortcut -Path $desktopLink -Launcher $launcher -WorkingDirectory $installRoot

    $result = [pscustomobject]@{
        InstallRoot = $installRoot
        Version = [string]$manifest.version
        ReleaseId = [string]$manifest.releaseId
        DesktopShortcutCreated = $desktopShortcutCreated
    }
}
finally {
    if (Test-Path -LiteralPath $extractionRoot -PathType Container) {
        Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "$ProductName installed to $($result.InstallRoot)"
Write-Host "Launcher: $($result.InstallRoot)\launcher\Start-Jarvis-RELEASE.cmd"
if ($Quiet) { exit 0 }
'@
$installerPs1Path = Join-Path $stageRoot 'Install-Jarvis-SUBSCRIPTION.ps1'
Write-Utf8NoBom $installerPs1Path $installerPs1Text
Assert-Parse $installerPs1Path 'embedded installer'

# ---------------------------------------------------------------------------
# Payload ZIP + integrity manifest.
# ---------------------------------------------------------------------------
$payloadZip = Join-Path $stageRoot 'payload.zip'
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal -ErrorAction Stop
$payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()

$installerManifest = [ordered]@{
    product = $ProductName
    version = $Version
    releaseId = $ReleaseId
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    entrypoint = 'ultra-server.mjs'
    port = 3791
    mode = 'ULTRA-subscription'
    payloadFile = 'payload.zip'
    payloadSha256 = $payloadHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    dataPolicy = 'User data and .env are excluded from the package and preserved during installs and updates.'
}
$manifestPath = Join-Path $stageRoot 'installer-manifest.json'
Write-Utf8NoBom $manifestPath ($installerManifest | ConvertTo-Json -Depth 4)
Set-Content -LiteralPath (Join-Path $stageRoot 'payload.sha256') -Value "$payloadHash  payload.zip" -Encoding ascii

# ---------------------------------------------------------------------------
# SED + IExpress invocation (mirrors Build-Installer-ULTRA.ps1 exactly).
# ---------------------------------------------------------------------------
$packageFiles = @(
    'Install-Jarvis-SUBSCRIPTION.cmd',
    'Install-Jarvis-SUBSCRIPTION.ps1',
    'installer-manifest.json',
    'payload.sha256',
    'payload.zip'
)
$sedName = 'JARVIS-NEXUS-SUBSCRIPTION.sed'
$sedPath = Join-Path $stageRoot $sedName
$sedLines = [System.Collections.Generic.List[string]]::new()
$sedLines.Add('[Version]')
$sedLines.Add('Class=IEXPRESS')
$sedLines.Add('SEDVersion=3')
$sedLines.Add('')
$sedLines.Add('[Options]')
$sedLines.Add('PackagePurpose=InstallApp')
$sedLines.Add('ShowInstallProgramWindow=0')
$sedLines.Add('HideExtractAnimation=1')
$sedLines.Add('UseLongFileName=1')
$sedLines.Add('InsideCompressed=1')
$sedLines.Add('CAB_FixedSize=0')
$sedLines.Add('CAB_ResvCodeSigning=0')
$sedLines.Add('RebootMode=N')
$sedLines.Add('InstallPrompt=')
$sedLines.Add('DisplayLicense=')
$sedLines.Add('FinishMessage=')
$sedLines.Add("TargetName=$OutputPath")
$sedLines.Add('FriendlyName=JARVIS NEXUS ULTRA Subscription Installer')
$sedLines.Add('AppLaunched=Install-Jarvis-SUBSCRIPTION.cmd')
$sedLines.Add('PostInstallCmd=<None>')
$sedLines.Add('AdminQuietInstCmd=Install-Jarvis-SUBSCRIPTION.cmd /quiet')
$sedLines.Add('UserQuietInstCmd=Install-Jarvis-SUBSCRIPTION.cmd /quiet')
$sedLines.Add('SourceFiles=SourceFiles')
$sedLines.Add('')
$sedLines.Add('[Strings]')
for ($index = 0; $index -lt $packageFiles.Count; $index++) {
    $sedLines.Add(('FILE{0}="{1}"' -f $index, $packageFiles[$index]))
}
$sedLines.Add('')
$sedLines.Add('[SourceFiles]')
$sedLines.Add("SourceFiles0=$stageRoot\")
$sedLines.Add('')
$sedLines.Add('[SourceFiles0]')
for ($index = 0; $index -lt $packageFiles.Count; $index++) {
    $sedLines.Add(('%FILE{0}%=' -f $index))
}
$sedLines | Set-Content -LiteralPath $sedPath -Encoding ascii

$outputHash = $null
if (-not $SkipIExpress) {
    $iexpressPath = Get-IExpress

    # IExpress syntax must be exactly: iexpress.exe /N /Q <SED filename>.
    # Use a no-space staging directory and pass the full SED path.
    Push-Location -LiteralPath $stageRoot
    try {
        $iexpressOutput = & $iexpressPath /N /Q $sedPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $detail = '(no output)'
            if ($iexpressOutput) { $detail = ($iexpressOutput | Out-String).Trim() }
            Fail "IExpress exited with code $LASTEXITCODE. Inspect the preserved SED: $sedPath. Output: $detail"
        }
    }
    finally {
        Pop-Location
    }

    # IExpress can return before the target file is visible; wait for it (same
    # pattern the v11 builder uses) and then verify it is a real PE executable.
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Fail "IExpress did not create the expected setup file: $OutputPath"
    }

    $stub = New-Object byte[] 2
    $stubStream = [System.IO.File]::OpenRead($OutputPath)
    try {
        $stubRead = $stubStream.Read($stub, 0, 2)
    }
    finally {
        $stubStream.Dispose()
    }
    if ($stubRead -ne 2 -or $stub[0] -ne 0x4D -or $stub[1] -ne 0x5A) {
        Fail "IExpress output is not a valid PE executable: $OutputPath"
    }

    $outputHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
    Set-Content -LiteralPath $hashPath -Value "$outputHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
}

# ---------------------------------------------------------------------------
# Build summary.
# ---------------------------------------------------------------------------
$summary = [pscustomobject]@{
    Ok = $true
    Product = $ProductName
    Version = $Version
    ReleaseId = $ReleaseId
    NodeVersion = $nodeVersion
    StagingRoot = $stageRoot
    PayloadRoot = $payloadRoot
    PayloadZipPath = $payloadZip
    PayloadSha256 = $payloadHash
    InstallerManifestPath = $manifestPath
    LauncherPath = $launcherPath
    LauncherCmdPath = (Join-Path $launcherPayload 'Start-Jarvis-RELEASE.cmd')
    PurchaseUrl = $PurchaseUrl
    IndexUrl = $IndexUrl
    SkipIExpress = [bool]$SkipIExpress
    ExePath = $OutputPath
    ExeSha256 = $outputHash
    Sha256Path = $hashPath
}

Write-Host ''
Write-Host 'JARVIS NEXUS ULTRA subscription installer staged.' -ForegroundColor Cyan
Write-Host "Staging (preserved): $stageRoot"
Write-Host "Payload root:        $payloadRoot"
if (-not $SkipIExpress) {
    Write-Host "EXE:    $OutputPath"
    Write-Host "SHA256: $hashPath"
}
else {
    Write-Host 'IExpress was skipped (-SkipIExpress): no EXE was written.'
}

return $summary
