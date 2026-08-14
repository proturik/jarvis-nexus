[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$IExpressWorkRoot = (Join-Path $PSScriptRoot 'build-ultra')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Build {
    param([string]$Message)
    throw "JARVIS NEXUS ULTRA installer: $Message"
}

function Require-Leaf {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Build "missing $($Label): $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Require-Directory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Stop-Build "missing $($Label): $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-NewDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
}

function Copy-Leaf {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $sourcePath = Require-Leaf $Source $Label
    Copy-Item -LiteralPath $sourcePath -Destination $DestinationDirectory -Force
}

function Copy-Directory {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $sourcePath = Require-Directory $Source $Label
    Copy-Item -LiteralPath $sourcePath -Destination $DestinationDirectory -Recurse -Force
}

function Get-LocalNode {
function Assert-CleanPayloadTree {
    param([string]$Path, [string]$Label)

    $root = Require-Directory $Path $Label
    $blockedNames = @(
        '.env', 'data', 'conversation', 'conversations', 'conversations.json',
        'profile', 'profiles', 'profile.json', 'memory', 'memories', 'memory.json',
        'tasks', 'task', 'tasks.json', 'events', 'event', 'events.json',
        'backup', 'backups', 'log', 'logs', 'server.mjs', 'omega-server.mjs',
        'public-omega', 'omega'
    )
    $blockedExtensions = @('.log', '.bak', '.backup', '.tmp', '.sqlite', '.db')

    $forbidden = Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {
        $leaf = $_.Name.ToLowerInvariant()
        $extension = [System.IO.Path]::GetExtension($leaf)
        ($leaf -in $blockedNames) -or
        ($extension -in $blockedExtensions) -or
        ($leaf -like '*omega*')
    } | Select-Object -First 1

    if ($null -ne $forbidden) {
        Stop-Build "$Label contains prohibited user, backup, log, OMEGA, or credential content: $($forbidden.FullName)"
    }
}

    param([string]$RequestedPath, [string]$ProjectRoot)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($RequestedPath) {
        $candidates.Add($RequestedPath)
    }

    $vendored = Join-Path $ProjectRoot 'runtime\node.exe'
    if (Test-Path -LiteralPath $vendored -PathType Leaf) {
        $candidates.Add($vendored)
    }

    $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $systemNode) {
        $systemNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -ne $systemNode -and $systemNode.Source) {
        $candidates.Add($systemNode.Source)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    Stop-Build 'Node.js 20+ was not found. Pass a local node.exe with -NodeRuntime; this script never downloads dependencies.'
}

function Test-NodeVersion {
    param([string]$NodePath)

    $version = (& $NodePath --version 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(?<major>\d+)\.') {
        Stop-Build "cannot execute Node runtime: $NodePath"
    }
    if ([int]$Matches.major -lt 20) {
        Stop-Build "Node.js 20+ is required; found $version."
    }
    return $version
}

function Get-IExpress {
    $candidates = @(
        (Join-Path $env:WINDIR 'System32\iexpress.exe'),
        (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Stop-Build 'IExpress was not found in this Windows installation.'
}

function Assert-IExpressSafeDirectory {
    param([string]$Path, [string]$Label)
    if ($Path -match '\s' -or $Path -match '[^\x20-\x7E]') {
        Stop-Build "$Label must contain only ASCII characters and no spaces: $Path"
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $first = $parseErrors[0]
        Stop-Build "syntax error in $Path at line $($first.Extent.StartLineNumber): $($first.Message)"
    }
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot
$templates = @(
    (Join-Path $installerRoot 'Install-Jarvis-ULTRA.cmd'),
    (Join-Path $installerRoot 'Install-Jarvis-ULTRA.ps1'),
    (Join-Path $installerRoot 'Start-Jarvis-ULTRA.cmd'),
    (Join-Path $installerRoot 'Start-Jarvis-ULTRA.ps1')
)
foreach ($template in $templates) {
    Require-Leaf $template 'ULTRA installer template' | Out-Null
    if ($template.EndsWith('.ps1')) {
        Assert-PowerShellSyntax $template
    }
}

$packagePath = Require-Leaf (Join-Path $projectRoot 'package.json') 'package.json'
$package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
$version = [string]$package.version
if ([string]::IsNullOrWhiteSpace($version)) {
    $version = '0.0.0-dev'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $installerRoot "dist-ultra\JARVIS-NEXUS-ULTRA-Setup-$version.exe"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    Stop-Build "refusing to overwrite existing output: $OutputPath"
}
if ($OutputPath -match '\r|\n' -or $OutputPath -match '"') {
    Stop-Build 'OutputPath contains an unsupported character.'
}
Ensure-NewDirectory (Split-Path -Parent $OutputPath)

$IExpressWorkRoot = [System.IO.Path]::GetFullPath($IExpressWorkRoot)
Assert-IExpressSafeDirectory $IExpressWorkRoot 'IExpressWorkRoot'
Ensure-NewDirectory $IExpressWorkRoot

$buildId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path $IExpressWorkRoot "JNU-ULTRA-$buildId"
Assert-IExpressSafeDirectory $stageRoot 'IExpress staging directory'
if (Test-Path -LiteralPath $stageRoot) {
    Stop-Build "refusing to reuse staging directory: $stageRoot"
}

$nodePath = Get-LocalNode -RequestedPath $NodeRuntime -ProjectRoot $projectRoot
$nodeVersion = Test-NodeVersion $nodePath
$iexpressPath = Get-IExpress

New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null
$payloadRoot = Join-Path $stageRoot 'payload-root'
$appPayload = Join-Path $payloadRoot 'app'
$runtimePayload = Join-Path $payloadRoot 'runtime'
$launcherPayload = Join-Path $payloadRoot 'launcher'
New-Item -ItemType Directory -Path $appPayload, $runtimePayload, $launcherPayload -ErrorAction Stop | Out-Null

# Explicit allow-list: ULTRA only. No server.mjs, OMEGA mode, cloud-screen mode,
# data/, .env, .git, or node_modules are copied into the distribution.
Copy-Leaf (Join-Path $projectRoot 'ultra-server.mjs') $appPayload 'ULTRA server entrypoint'
Copy-Leaf (Join-Path $projectRoot 'package.json') $appPayload 'package.json'
Copy-Directory (Join-Path $projectRoot 'public-ultra') $appPayload 'public-ultra directory'
Copy-Directory (Join-Path $projectRoot 'assets') $appPayload 'assets directory'
Copy-Directory (Join-Path $projectRoot 'windows-control') $appPayload 'windows-control directory'
Copy-Directory (Join-Path $projectRoot 'windows-theme') $appPayload 'windows-theme directory'

$envExample = Join-Path $projectRoot '.env.example'
if (Test-Path -LiteralPath $envExample -PathType Leaf) {
    Copy-Leaf $envExample $appPayload '.env.example'
}

Copy-Item -LiteralPath $nodePath -Destination (Join-Path $runtimePayload 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-ULTRA.cmd') -Destination $launcherPayload -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-ULTRA.ps1') -Destination $launcherPayload -Force

# The wildcard packages app/, runtime/, and launcher/ at the ZIP root. IExpress
# only transports this flat archive plus the installer scripts.
$payloadZip = Join-Path $stageRoot 'payload.zip'
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal -ErrorAction Stop
$payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()

$manifest = [ordered]@{
    product = 'JARVIS NEXUS ULTRA'
    version = $version
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    entrypoint = 'ultra-server.mjs'
    port = 3791
    mode = 'ULTRA-local'
    payloadFile = 'payload.zip'
    payloadSha256 = $payloadHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    dataPolicy = 'User data and .env are excluded from the package and preserved during updates.'
}
$manifestPath = Join-Path $stageRoot 'installer-manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Set-Content -LiteralPath (Join-Path $stageRoot 'payload.sha256') -Value "$payloadHash  payload.zip" -Encoding ascii

Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-ULTRA.cmd') -Destination $stageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-ULTRA.ps1') -Destination $stageRoot -Force

$packageFiles = @(
    'Install-Jarvis-ULTRA.cmd',
    'Install-Jarvis-ULTRA.ps1',
    'installer-manifest.json',
    'payload.sha256',
    'payload.zip'
)
$sedName = 'JARVIS-NEXUS-ULTRA.sed'
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
$sedLines.Add('FriendlyName=JARVIS NEXUS ULTRA Installer')
$sedLines.Add('AppLaunched=Install-Jarvis-ULTRA.cmd')
$sedLines.Add('PostInstallCmd=<None>')
$sedLines.Add('AdminQuietInstCmd=Install-Jarvis-ULTRA.cmd /quiet')
$sedLines.Add('UserQuietInstCmd=Install-Jarvis-ULTRA.cmd /quiet')
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

# IExpress syntax must be exactly: iexpress.exe /N /Q <SED filename>.
# Use a no-space staging directory and pass the leaf name, not a quoted path.
Push-Location -LiteralPath $stageRoot
try {
    & $iexpressPath /N /Q $sedPath
    if ($LASTEXITCODE -ne 0) {
        Stop-Build "IExpress exited with code $LASTEXITCODE. Inspect the preserved SED: $sedPath"
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    Stop-Build "IExpress did not create the expected setup file: $OutputPath"
}

$outputHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$hashPath = "$OutputPath.sha256.txt"
if (Test-Path -LiteralPath $hashPath) {
    Stop-Build "refusing to overwrite existing checksum: $hashPath"
}
Set-Content -LiteralPath $hashPath -Value "$outputHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii

Write-Host ''
Write-Host 'JARVIS NEXUS ULTRA installer created.' -ForegroundColor Cyan
Write-Host "EXE:    $OutputPath"
Write-Host "SHA256: $hashPath"
Write-Host "Audit staging (preserved): $stageRoot"
