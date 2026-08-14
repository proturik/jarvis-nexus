[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$IExpressWorkRoot = (Join-Path $PSScriptRoot 'build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message)
    throw "JARVIS NEXUS ULTRA installer: $Message"
}

function Require-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "missing $Label: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Require-Directory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "missing $Label: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Copy-FileToPayload {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $sourcePath = Require-File $Source $Label
    Copy-Item -LiteralPath $sourcePath -Destination $DestinationDirectory -Force
}

function Copy-DirectoryToPayload {
    param([string]$Source, [string]$DestinationDirectory, [string]$Label)
    $sourcePath = Require-Directory $Source $Label
    Copy-Item -LiteralPath $sourcePath -Destination $DestinationDirectory -Recurse -Force
}

function Get-PortableNode {
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

    Fail 'Node.js 20+ was not found. Supply -NodeRuntime with a local node.exe; this build script never downloads a runtime.'
}

function Assert-NodeVersion {
    param([string]$NodePath)
    $reportedVersion = (& $NodePath --version 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -notmatch '^v(?<major>\d+)\.') {
        Fail "cannot execute Node runtime: $NodePath"
    }
    if ([int]$Matches.major -lt 20) {
        Fail "Node.js 20+ is required; found $reportedVersion."
    }
    return $reportedVersion
}

function Get-SafeIExpressPath {
    $candidates = @(
        (Join-Path $env:WINDIR 'System32\iexpress.exe'),
        (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Fail 'IExpress was not found in this Windows installation.'
}

function Assert-IExpressSafePath {
    param([string]$Path, [string]$Name)
    if ($Path -match '\s' -or $Path -match '[^\x20-\x7E]') {
        Fail "$Name must contain only ASCII characters and no spaces because IExpress cannot reliably parse a .sed path otherwise: $Path"
    }
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot
$templateFiles = @(
    (Join-Path $installerRoot 'Install-Jarvis.cmd'),
    (Join-Path $installerRoot 'Install-Jarvis.ps1'),
    (Join-Path $installerRoot 'Start-Jarvis.cmd'),
    (Join-Path $installerRoot 'Start-Jarvis.ps1')
)

foreach ($template in $templateFiles) {
    Require-File $template 'installer template' | Out-Null
}

$packagePath = Require-File (Join-Path $projectRoot 'package.json') 'package.json'
$package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
$version = [string]$package.version
if ([string]::IsNullOrWhiteSpace($version)) {
    $version = '0.0.0-dev'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $installerRoot "dist\JARVIS-NEXUS-ULTRA-Setup-$version.exe"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    Fail "refusing to overwrite existing output: $OutputPath"
}
if ($OutputPath -match '\r|\n' -or $OutputPath -match '"') {
    Fail 'OutputPath contains an unsupported character.'
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -ErrorAction Stop | Out-Null
}

$IExpressWorkRoot = [System.IO.Path]::GetFullPath($IExpressWorkRoot)
Assert-IExpressSafePath $IExpressWorkRoot 'IExpressWorkRoot'
if (-not (Test-Path -LiteralPath $IExpressWorkRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $IExpressWorkRoot -ErrorAction Stop | Out-Null
}

$buildId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path $IExpressWorkRoot "JNU-$buildId"
Assert-IExpressSafePath $stageRoot 'IExpress staging directory'
if (Test-Path -LiteralPath $stageRoot) {
    Fail "refusing to reuse staging directory: $stageRoot"
}

$nodePath = Get-PortableNode -RequestedPath $NodeRuntime -ProjectRoot $projectRoot
$nodeVersion = Assert-NodeVersion -NodePath $nodePath
$iexpressPath = Get-SafeIExpressPath

New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null
$payloadRoot = Join-Path $stageRoot 'payload-root'
$appPayload = Join-Path $payloadRoot 'app'
$runtimePayload = Join-Path $payloadRoot 'runtime'
$launcherPayload = Join-Path $payloadRoot 'launcher'
New-Item -ItemType Directory -Path $appPayload, $runtimePayload, $launcherPayload -ErrorAction Stop | Out-Null

# Package only executable app assets. data/ and .env are intentionally never copied:
# the installed app keeps them under the current user's LocalAppData folder.
Copy-FileToPayload (Join-Path $projectRoot 'ultra-server.mjs') $appPayload 'ultra server entrypoint'
Copy-FileToPayload (Join-Path $projectRoot 'package.json') $appPayload 'package.json'
Copy-DirectoryToPayload (Join-Path $projectRoot 'public-ultra') $appPayload 'public-ultra directory'
Copy-DirectoryToPayload (Join-Path $projectRoot 'assets') $appPayload 'assets directory'
Copy-DirectoryToPayload (Join-Path $projectRoot 'windows-control') $appPayload 'windows-control directory'
Copy-DirectoryToPayload (Join-Path $projectRoot 'windows-theme') $appPayload 'windows-theme directory'

$envExample = Join-Path $projectRoot '.env.example'
if (Test-Path -LiteralPath $envExample -PathType Leaf) {
    Copy-FileToPayload $envExample $appPayload '.env.example'
}

Copy-Item -LiteralPath $nodePath -Destination (Join-Path $runtimePayload 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis.cmd') -Destination $launcherPayload -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis.ps1') -Destination $launcherPayload -Force

$payloadZip = Join-Path $stageRoot 'payload.zip'
Compress-Archive -LiteralPath $payloadRoot -DestinationPath $payloadZip -CompressionLevel Optimal -ErrorAction Stop
$payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()

$manifest = [ordered]@{
    product = 'JARVIS NEXUS ULTRA'
    version = $version
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'
    payloadSha256 = $payloadHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    dataPolicy = 'User data and .env are excluded from the package and preserved during updates.'
}
$manifestPath = Join-Path $stageRoot 'installer-manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Set-Content -LiteralPath (Join-Path $stageRoot 'payload.sha256') -Value "$payloadHash  payload.zip" -Encoding ascii

Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis.cmd') -Destination $stageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis.ps1') -Destination $stageRoot -Force

# IExpress does not preserve directories in its CAB payload. The app hierarchy lives
# inside payload.zip, so IExpress only needs to carry these flat, audited files.
$packageFiles = @(
    'Install-Jarvis.cmd',
    'Install-Jarvis.ps1',
    'installer-manifest.json',
    'payload.sha256',
    'payload.zip'
)

$sedPath = Join-Path $stageRoot 'JARVIS-NEXUS-ULTRA.sed'
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
$sedLines.Add('AppLaunched=Install-Jarvis.cmd')
$sedLines.Add('PostInstallCmd=<None>')
$sedLines.Add('AdminQuietInstCmd=Install-Jarvis.cmd /quiet')
$sedLines.Add('UserQuietInstCmd=Install-Jarvis.cmd /quiet')
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

# Never pass an absolute .sed path to IExpress: its parser is brittle around spaces.
# Running from the generated ASCII/no-space staging directory makes this exact call
# stable and makes the required SED argument unambiguous.
Push-Location -LiteralPath $stageRoot
try {
    & $iexpressPath /N /Q 'JARVIS-NEXUS-ULTRA.sed'
    if ($LASTEXITCODE -ne 0) {
        Fail "IExpress exited with code $LASTEXITCODE. The SED was kept for inspection: $sedPath"
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    Fail "IExpress reported success but did not create: $OutputPath"
}

$outputHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$hashPath = "$OutputPath.sha256.txt"
if (Test-Path -LiteralPath $hashPath) {
    Fail "refusing to overwrite existing checksum: $hashPath"
}
Set-Content -LiteralPath $hashPath -Value "$outputHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii

Write-Host ''
Write-Host 'JARVIS NEXUS ULTRA installer created.' -ForegroundColor Cyan
Write-Host "EXE:    $OutputPath"
Write-Host "SHA256: $hashPath"
Write-Host "Audit staging (preserved): $stageRoot"
