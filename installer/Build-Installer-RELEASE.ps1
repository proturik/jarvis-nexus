[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release\JARVIS-NEXUS-ULTRA-Setup.exe'),
    [string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Build([string]$Message) { throw "JARVIS NEXUS RELEASE: $Message" }

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Build "Missing $Label: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Require-Directory([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Stop-Build "Missing $Label: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-DirectoryIfNeeded([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
}

function Assert-PowerShellSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { Stop-Build "PowerShell syntax error in $Path at line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
}

function Assert-CleanPayloadTree([string]$Path) {
    $root = Require-Directory $Path 'payload tree'
    $blockedNames = @('.env', 'data', 'omega-server.mjs', 'server.mjs', 'public-omega', '.git')
    $blockedExtensions = @('.log', '.bak', '.backup', '.sqlite', '.db')
    $forbidden = Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {
        $name = $_.Name.ToLowerInvariant()
        ($name -in $blockedNames) -or ($name -like '*omega*') -or ([System.IO.Path]::GetExtension($name) -in $blockedExtensions)
    } | Select-Object -First 1
    if ($null -ne $forbidden) { Stop-Build "Private or unsupported content found in payload: $($forbidden.FullName)" }
}

function Get-NodeRuntime([string]$RequestedPath, [string]$ProjectRoot) {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($RequestedPath) { $candidates.Add($RequestedPath) }
    $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $systemNode) { $systemNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $systemNode -and $systemNode.Source) { $candidates.Add($systemNode.Source) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Stop-Build 'Node.js 20+ was not found. Supply a local node.exe with -NodeRuntime.'
}

function Test-NodeRuntime([string]$NodePath) {
    $version = (& $NodePath --version 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(?<major>\d+)\.') { Stop-Build "Cannot start Node runtime: $NodePath" }
    if ([int]$Matches.major -lt 20) { Stop-Build "Node.js 20+ is required; found $version." }
    return $version
}

function Get-IExpressPath {
    foreach ($candidate in @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Stop-Build 'IExpress was not found in this Windows installation.'
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot
$requiredScripts = @(
    (Join-Path $installerRoot 'Install-Jarvis-RELEASE.ps1'),
    (Join-Path $installerRoot 'Install-Jarvis-RELEASE.cmd'),
    (Join-Path $installerRoot 'Start-Jarvis-RELEASE.ps1'),
    (Join-Path $installerRoot 'Start-Jarvis-RELEASE.cmd')
)
foreach ($scriptPath in $requiredScripts) {
    Require-File $scriptPath 'installer support file' | Out-Null
    if ($scriptPath.EndsWith('.ps1')) { Assert-PowerShellSyntax $scriptPath }
}

$nodePath = Get-NodeRuntime $NodeRuntime $projectRoot
$nodeVersion = Test-NodeRuntime $nodePath
$iexpressPath = Get-IExpressPath
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Stop-Build "Refusing to overwrite existing EXE: $OutputPath" }
New-DirectoryIfNeeded (Split-Path -Parent $OutputPath)

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s' -or $WorkRoot -match '[^\x20-\x7E]') { Stop-Build 'WorkRoot must be ASCII and contain no spaces for IExpress.' }
New-DirectoryIfNeeded $WorkRoot
$stageRoot = Join-Path $WorkRoot ('JARVIS-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null

$payloadRoot = Join-Path $stageRoot 'payload-root'
$appRoot = Join-Path $payloadRoot 'app'
$runtimeRoot = Join-Path $payloadRoot 'runtime'
$launcherRoot = Join-Path $payloadRoot 'launcher'
New-Item -ItemType Directory -Path $appRoot, $runtimeRoot, $launcherRoot -ErrorAction Stop | Out-Null

# Explicit allow-list: user history, memories, .env and cloud screen mode never enter this package.
Copy-Item -LiteralPath (Require-File (Join-Path $projectRoot 'ultra-server.mjs') 'ULTRA server') -Destination $appRoot -Force
Copy-Item -LiteralPath (Require-File (Join-Path $projectRoot 'package.json') 'package manifest') -Destination $appRoot -Force
foreach ($directory in @('public-ultra', 'assets', 'windows-control', 'windows-theme')) {
    Copy-Item -LiteralPath (Require-Directory (Join-Path $projectRoot $directory) $directory) -Destination $appRoot -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $projectRoot '.env.example') -PathType Leaf) {
    Copy-Item -LiteralPath (Join-Path $projectRoot '.env.example') -Destination $appRoot -Force
}
Copy-Item -LiteralPath $nodePath -Destination (Join-Path $runtimeRoot 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.ps1') -Destination $launcherRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.cmd') -Destination $launcherRoot -Force
Assert-CleanPayloadTree $payloadRoot

$payloadZip = Join-Path $stageRoot 'payload.zip'
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal -ErrorAction Stop
$payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash.ToUpperInvariant()

$package = Get-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Raw | ConvertFrom-Json
$manifest = [ordered]@{
    product = 'JARVIS NEXUS ULTRA'
    version = [string]$package.version
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'
    payloadSha256 = $payloadHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    privacy = 'No .env, data, memory, profile, conversation, log, backup, or OMEGA files are included.'
}
$manifestPath = Join-Path $stageRoot 'installer-manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Set-Content -LiteralPath (Join-Path $stageRoot 'payload.sha256') -Value "$payloadHash  payload.zip" -Encoding ascii
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.ps1') -Destination $stageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.cmd') -Destination $stageRoot -Force

$payloadFiles = @('Install-Jarvis-RELEASE.cmd', 'Install-Jarvis-RELEASE.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
$sedPath = Join-Path $stageRoot 'JARVIS-NEXUS-RELEASE.sed'
$sed = [System.Collections.Generic.List[string]]::new()
$sed.Add('[Version]'); $sed.Add('Class=IEXPRESS'); $sed.Add('SEDVersion=3'); $sed.Add('')
$sed.Add('[Options]'); $sed.Add('PackagePurpose=InstallApp'); $sed.Add('ShowInstallProgramWindow=0'); $sed.Add('HideExtractAnimation=1')
$sed.Add('UseLongFileName=1'); $sed.Add('InsideCompressed=1'); $sed.Add('CAB_FixedSize=0'); $sed.Add('CAB_ResvCodeSigning=0'); $sed.Add('RebootMode=N')
$sed.Add('InstallPrompt='); $sed.Add('DisplayLicense='); $sed.Add('FinishMessage=')
$sed.Add("TargetName=$OutputPath"); $sed.Add('FriendlyName=JARVIS NEXUS ULTRA'); $sed.Add('AppLaunched=Install-Jarvis-RELEASE.cmd')
$sed.Add('PostInstallCmd=<None>'); $sed.Add('AdminQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet'); $sed.Add('UserQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet')
$sed.Add('SourceFiles=SourceFiles'); $sed.Add(''); $sed.Add('[Strings]')
for ($index = 0; $index -lt $payloadFiles.Count; $index++) { $sed.Add(('FILE{0}="{1}"' -f $index, $payloadFiles[$index])) }
$sed.Add(''); $sed.Add('[SourceFiles]'); $sed.Add("SourceFiles0=$stageRoot\"); $sed.Add(''); $sed.Add('[SourceFiles0]')
for ($index = 0; $index -lt $payloadFiles.Count; $index++) { $sed.Add(('%FILE{0}%=' -f $index)) }
$sed | Set-Content -LiteralPath $sedPath -Encoding ascii

# Correct IExpress compiler syntax: /N /Q followed by the SED file.
& $iexpressPath /N /Q $sedPath
if ($LASTEXITCODE -ne 0) { Stop-Build "IExpress exited with code $LASTEXITCODE. SED retained at: $sedPath" }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Stop-Build 'IExpress did not create the expected EXE.' }

$outputHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$checksumPath = "$OutputPath.sha256.txt"
Set-Content -LiteralPath $checksumPath -Value "$outputHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksumPath" -ForegroundColor Cyan
Write-Host "Audit stage retained: $stageRoot" -ForegroundColor DarkCyan
