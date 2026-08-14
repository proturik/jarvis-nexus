[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "JARVIS package build: $Message" }
function NeedFile([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "Missing file $Path" }; (Resolve-Path -LiteralPath $Path).Path }
function NeedFolder([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "Missing folder $Path" }; (Resolve-Path -LiteralPath $Path).Path }
function EnsureFolder([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null } }
function AssertPs([string]$Path) {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { Fail "Syntax error in $Path line $($parseErrors[0].Extent.StartLineNumber)" }
}
function NodePath([string]$Requested) {
    $choices = @()
    if ($Requested) { $choices += $Requested }
    $found = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $found) { $found = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $found) { $choices += $found.Source }
    foreach ($choice in $choices) { if (Test-Path -LiteralPath $choice -PathType Leaf) { return (Resolve-Path -LiteralPath $choice).Path } }
    Fail 'Node.js 20+ was not found.'
}
function IExpressPath {
    foreach ($candidate in @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Fail 'IExpress was not found.'
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $projectRoot 'release\JARVIS-NEXUS-ULTRA-Setup.exe' }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "EXE already exists: $OutputPath" }
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Fail 'WorkRoot must use ASCII without spaces.' }
EnsureFolder $WorkRoot; EnsureFolder (Split-Path -Parent $OutputPath)

foreach ($file in @('Install-Jarvis-RELEASE.ps1', 'Start-Jarvis-RELEASE.ps1')) { AssertPs (NeedFile (Join-Path $installerRoot $file)) }
foreach ($file in @('Install-Jarvis-RELEASE.cmd', 'Start-Jarvis-RELEASE.cmd')) { NeedFile (Join-Path $installerRoot $file) | Out-Null }
$node = NodePath $NodeRuntime
$nodeVersion = (& $node --version 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(?<major>\d+)\.' -or [int]$Matches.major -lt 20) { Fail "Node runtime is invalid: $node" }

$stage = Join-Path $WorkRoot ('JARVIS-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$app = Join-Path $payload 'app'; $runtime = Join-Path $payload 'runtime'; $launcher = Join-Path $payload 'launcher'
New-Item -ItemType Directory -Path $app, $runtime, $launcher -ErrorAction Stop | Out-Null

# Explicit clean allow-list. No path ever points at data/, .env, history or cloud screen files.
Copy-Item -LiteralPath (NeedFile (Join-Path $projectRoot 'ultra-server.mjs')) -Destination $app -Force
Copy-Item -LiteralPath (NeedFile (Join-Path $projectRoot 'package.json')) -Destination $app -Force
foreach ($name in @('public-ultra', 'assets', 'windows-control')) { Copy-Item -LiteralPath (NeedFolder (Join-Path $projectRoot $name)) -Destination $app -Recurse -Force }
$themeTarget = Join-Path $app 'windows-theme'; New-Item -ItemType Directory -Path $themeTarget -ErrorAction Stop | Out-Null
foreach ($name in @('Sync-Nexus-Theme.ps1', 'Sync-Nexus-Theme-PRIME.ps1')) { Copy-Item -LiteralPath (NeedFile (Join-Path $projectRoot "windows-theme\$name")) -Destination $themeTarget -Force }
if (Test-Path -LiteralPath (Join-Path $projectRoot '.env.example') -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $projectRoot '.env.example') -Destination $app -Force }
Copy-Item -LiteralPath $node -Destination (Join-Path $runtime 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.ps1') -Destination $launcher -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.cmd') -Destination $launcher -Force

$private = Get-ChildItem -LiteralPath $payload -Force -Recurse | Where-Object {
    $leaf = $_.Name.ToLowerInvariant()
    ($leaf -in @('.env', 'data', 'server.mjs', 'omega-server.mjs', 'public-omega', '.git')) -or ($leaf -like '*conversation*') -or ($leaf -like '*memory*') -or ($leaf -like '*profile*')
} | Select-Object -First 1
if ($null -ne $private) { Fail "Private content found in staging: $($private.FullName)" }

$zip = Join-Path $stage 'payload.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$package = Get-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Raw | ConvertFrom-Json
[ordered]@{
    product = 'JARVIS NEXUS ULTRA'; version = [string]$package.version; builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'; payloadSha256 = $zipHash; nodeVersion = $nodeVersion; installScope = 'CurrentUser'
    privacy = 'No .env, data, chats, profile, memory, logs, backups, files, or cloud screen components are included.'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'installer-manifest.json') -Encoding utf8
Set-Content -LiteralPath (Join-Path $stage 'payload.sha256') -Value "$zipHash  payload.zip" -Encoding ascii
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.ps1') -Destination $stage -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.cmd') -Destination $stage -Force

$files = @('Install-Jarvis-RELEASE.cmd', 'Install-Jarvis-RELEASE.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
$sed = [System.Collections.Generic.List[string]]::new()
@('[Version]', 'Class=IEXPRESS', 'SEDVersion=3', '', '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=0', 'HideExtractAnimation=1', 'UseLongFileName=1', 'InsideCompressed=1', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=') | ForEach-Object { $sed.Add($_) }
$sed.Add("TargetName=$OutputPath"); $sed.Add('FriendlyName=JARVIS NEXUS ULTRA'); $sed.Add('AppLaunched=Install-Jarvis-RELEASE.cmd'); $sed.Add('PostInstallCmd=<None>'); $sed.Add('AdminQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet'); $sed.Add('UserQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet'); $sed.Add('SourceFiles=SourceFiles'); $sed.Add(''); $sed.Add('[Strings]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('FILE{0}="{1}"' -f $i, $files[$i])) }
$sed.Add(''); $sed.Add('[SourceFiles]'); $sed.Add("SourceFiles0=$stage\"); $sed.Add(''); $sed.Add('[SourceFiles0]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('%FILE{0}%=' -f $i)) }
$sedPath = Join-Path $stage 'JARVIS-NEXUS-ULTRA.sed'
$sed | Set-Content -LiteralPath $sedPath -Encoding ascii

# Correct compiler syntax: iexpress.exe /N /Q <SED path>.
& (IExpressPath) /N /Q $sedPath
if ($LASTEXITCODE -ne 0) { Fail "IExpress failed with code $LASTEXITCODE. SED is retained at $sedPath" }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Fail 'IExpress did not create the EXE.' }
$exeHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$checksum = "$OutputPath.sha256.txt"; Set-Content -LiteralPath $checksum -Value "$exeHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksum" -ForegroundColor Cyan
Write-Host "Audit stage: $stage" -ForegroundColor DarkCyan
