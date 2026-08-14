[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'release\JARVIS-NEXUS-ULTRA-Setup.exe'),
    [string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Build([string]$Message) { throw "JARVIS NEXUS RELEASE: $Message" }
function Need-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Build "Missing $($Label): $Path" }
    (Resolve-Path -LiteralPath $Path).Path
}
function Need-Directory([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Stop-Build "Missing $($Label): $Path" }
    (Resolve-Path -LiteralPath $Path).Path
}
function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null }
}
function Assert-Syntax([string]$Path) {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { Stop-Build "Syntax error in $Path line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)" }
}
function Assert-CleanPayload([string]$Path) {
    $blocked = @('.env', 'data', 'omega-server.mjs', 'server.mjs', 'public-omega', '.git')
    $found = Get-ChildItem -LiteralPath $Path -Force -Recurse | Where-Object {
        $leaf = $_.Name.ToLowerInvariant()
        ($leaf -in $blocked) -or ($leaf -like '*omega*') -or ([System.IO.Path]::GetExtension($leaf) -in @('.log', '.bak', '.backup', '.sqlite', '.db'))
    } | Select-Object -First 1
    if ($null -ne $found) { Stop-Build "Private content detected in staged payload: $($found.FullName)" }
}
function Get-NodePath([string]$RequestedPath) {
    $candidates = @()
    if ($RequestedPath) { $candidates += $RequestedPath }
    $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $node) { $candidates += $node.Source }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path } }
    Stop-Build 'Node.js 20+ was not found. Pass a local node.exe with -NodeRuntime.'
}
function Get-IExpressPath {
    foreach ($candidate in @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    Stop-Build 'IExpress was not found.'
}

$installerRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $installerRoot
foreach ($file in @('Install-Jarvis-RELEASE.ps1', 'Install-Jarvis-RELEASE.cmd', 'Start-Jarvis-RELEASE.ps1', 'Start-Jarvis-RELEASE.cmd')) {
    $path = Need-File (Join-Path $installerRoot $file) 'installer support file'
    if ($path.EndsWith('.ps1')) { Assert-Syntax $path }
}
$nodePath = Get-NodePath $NodeRuntime
$nodeVersion = (& $nodePath --version 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(?<major>\d+)\.') { Stop-Build "Cannot run Node: $nodePath" }
if ([int]$Matches.major -lt 20) { Stop-Build "Node.js 20+ required; found $nodeVersion" }
$iexpress = Get-IExpressPath
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Stop-Build "Output already exists: $OutputPath" }
Ensure-Directory (Split-Path -Parent $OutputPath)
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Stop-Build 'WorkRoot must be ASCII with no spaces for IExpress.' }
Ensure-Directory $WorkRoot
$stageRoot = Join-Path $WorkRoot ('NEXUS-' + [guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $stageRoot 'payload-root'
$appRoot = Join-Path $payloadRoot 'app'
$runtimeRoot = Join-Path $payloadRoot 'runtime'
$launcherRoot = Join-Path $payloadRoot 'launcher'
New-Item -ItemType Directory -Path $appRoot, $runtimeRoot, $launcherRoot -ErrorAction Stop | Out-Null

# Only an explicit allow-list is copied. There is no source path for .env or data.
Copy-Item -LiteralPath (Need-File (Join-Path $projectRoot 'ultra-server.mjs') 'ULTRA server') -Destination $appRoot -Force
Copy-Item -LiteralPath (Need-File (Join-Path $projectRoot 'package.json') 'package manifest') -Destination $appRoot -Force
foreach ($directory in @('public-ultra', 'assets', 'windows-control', 'windows-theme')) {
    Copy-Item -LiteralPath (Need-Directory (Join-Path $projectRoot $directory) $directory) -Destination $appRoot -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $projectRoot '.env.example') -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $projectRoot '.env.example') -Destination $appRoot -Force }
Copy-Item -LiteralPath $nodePath -Destination (Join-Path $runtimeRoot 'node.exe') -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.ps1') -Destination $launcherRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Start-Jarvis-RELEASE.cmd') -Destination $launcherRoot -Force
Assert-CleanPayload $payloadRoot

$zipPath = Join-Path $stageRoot 'payload.zip'
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
$package = Get-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Raw | ConvertFrom-Json
$manifest = [ordered]@{
    product = 'JARVIS NEXUS ULTRA'; version = [string]$package.version; builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'; payloadSha256 = $zipHash; nodeVersion = $nodeVersion; installScope = 'CurrentUser'
    privacy = 'No .env, data, conversations, profile, memory, tasks, logs, backups, or OMEGA files are packaged.'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stageRoot 'installer-manifest.json') -Encoding utf8
Set-Content -LiteralPath (Join-Path $stageRoot 'payload.sha256') -Value "$zipHash  payload.zip" -Encoding ascii
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.ps1') -Destination $stageRoot -Force
Copy-Item -LiteralPath (Join-Path $installerRoot 'Install-Jarvis-RELEASE.cmd') -Destination $stageRoot -Force

$files = @('Install-Jarvis-RELEASE.cmd', 'Install-Jarvis-RELEASE.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
$sedPath = Join-Path $stageRoot 'JARVIS-NEXUS-RELEASE.sed'
$lines = [System.Collections.Generic.List[string]]::new()
@('[Version]', 'Class=IEXPRESS', 'SEDVersion=3', '', '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=0', 'HideExtractAnimation=1', 'UseLongFileName=1', 'InsideCompressed=1', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=') | ForEach-Object { $lines.Add($_) }
$lines.Add("TargetName=$OutputPath"); $lines.Add('FriendlyName=JARVIS NEXUS ULTRA'); $lines.Add('AppLaunched=Install-Jarvis-RELEASE.cmd'); $lines.Add('PostInstallCmd=<None>')
$lines.Add('AdminQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet'); $lines.Add('UserQuietInstCmd=Install-Jarvis-RELEASE.cmd /quiet'); $lines.Add('SourceFiles=SourceFiles'); $lines.Add(''); $lines.Add('[Strings]')
for ($i = 0; $i -lt $files.Count; $i++) { $lines.Add(('FILE{0}="{1}"' -f $i, $files[$i])) }
$lines.Add(''); $lines.Add('[SourceFiles]'); $lines.Add("SourceFiles0=$stageRoot\"); $lines.Add(''); $lines.Add('[SourceFiles0]')
for ($i = 0; $i -lt $files.Count; $i++) { $lines.Add(('%FILE{0}%=' -f $i)) }
$lines | Set-Content -LiteralPath $sedPath -Encoding ascii

# This is the correct IExpress command form shown by its own usage dialog.
& $iexpress /N /Q $sedPath
if ($LASTEXITCODE -ne 0) { Stop-Build "IExpress exited with code $LASTEXITCODE. Audit SED: $sedPath" }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Stop-Build 'IExpress did not create an EXE.' }
$exeHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$checksum = "$OutputPath.sha256.txt"
Set-Content -LiteralPath $checksum -Value "$exeHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksum" -ForegroundColor Cyan
Write-Host "Audit stage: $stageRoot" -ForegroundColor DarkCyan
