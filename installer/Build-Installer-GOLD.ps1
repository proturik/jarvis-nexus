[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-nexus-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "JARVIS GOLD builder: $Message" }
function Need([string]$Path, [bool]$Folder = $false) {
    $kind = if ($Folder) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $Path -PathType $kind)) { Fail "Missing path $Path" }
    (Resolve-Path -LiteralPath $Path).Path
}
function Ensure([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null } }
function Assert-Parse([string]$Path) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { Fail "PowerShell syntax error in $Path line $($errors[0].Extent.StartLineNumber)" }
}

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $project 'release\JARVIS-NEXUS-ULTRA-Setup-FINAL.exe' }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "Refusing to overwrite existing EXE $OutputPath" }
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Fail 'WorkRoot must be ASCII with no spaces.' }
Ensure $WorkRoot; Ensure (Split-Path -Parent $OutputPath)

foreach ($name in @('Install-Jarvis-RELEASE.ps1', 'Install-Jarvis-RELEASE-v2.ps1', 'Start-Jarvis-RELEASE.ps1')) { Assert-Parse (Need (Join-Path $installer $name)) }
foreach ($name in @('Install-Jarvis-RELEASE-v2.cmd', 'Start-Jarvis-RELEASE.cmd')) { Need (Join-Path $installer $name) | Out-Null }
$nodeChoices = @()
if ($NodeRuntime) { $nodeChoices += $NodeRuntime }
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($null -ne $nodeCommand) { $nodeChoices += $nodeCommand.Source }
$node = $nodeChoices | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $node) { Fail 'Node.js 20+ was not found.' }
$node = (Resolve-Path -LiteralPath $node).Path
$nodeVersion = (& $node --version 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(?<major>\d+)\.' -or [int]$Matches.major -lt 20) { Fail "Invalid Node runtime $node" }
$iexpress = @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) { Fail 'IExpress was not found.' }

$stage = Join-Path $WorkRoot ('GOLD-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$app = Join-Path $payload 'app'; $runtime = Join-Path $payload 'runtime'; $launcher = Join-Path $payload 'launcher'
New-Item -ItemType Directory -Path $app, $runtime, $launcher -ErrorAction Stop | Out-Null

# Strict allow-list means no source path exists for user data, .env or OMEGA/cloud components.
Copy-Item -LiteralPath (Need (Join-Path $project 'ultra-server.mjs')) -Destination $app -Force
Copy-Item -LiteralPath (Need (Join-Path $project 'package.json')) -Destination $app -Force
foreach ($name in @('public-ultra', 'assets', 'windows-control')) { Copy-Item -LiteralPath (Need (Join-Path $project $name) $true) -Destination $app -Recurse -Force }
$themes = Join-Path $app 'windows-theme'; New-Item -ItemType Directory -Path $themes -ErrorAction Stop | Out-Null
foreach ($name in @('Sync-Nexus-Theme.ps1', 'Sync-Nexus-Theme-PRIME.ps1')) { Copy-Item -LiteralPath (Need (Join-Path $project "windows-theme\$name")) -Destination $themes -Force }
if (Test-Path -LiteralPath (Join-Path $project '.env.example') -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $project '.env.example') -Destination $app -Force }
Copy-Item -LiteralPath $node -Destination (Join-Path $runtime 'node.exe') -Force
foreach ($name in @('Start-Jarvis-RELEASE.ps1', 'Start-Jarvis-RELEASE.cmd')) { Copy-Item -LiteralPath (Join-Path $installer $name) -Destination $launcher -Force }
$private = Get-ChildItem -LiteralPath $payload -Force -Recurse | Where-Object {
    $leaf = $_.Name.ToLowerInvariant()
    ($leaf -in @('.env', 'data', 'server.mjs', 'omega-server.mjs', 'public-omega', '.git')) -or ($leaf -like '*conversation*') -or ($leaf -like '*memory*') -or ($leaf -like '*profile*')
} | Select-Object -First 1
if ($null -ne $private) { Fail "Private file entered payload $($private.FullName)" }

$zip = Join-Path $stage 'payload.zip'; Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$package = Get-Content -LiteralPath (Join-Path $project 'package.json') -Raw | ConvertFrom-Json
[ordered]@{ product = 'JARVIS NEXUS ULTRA'; version = [string]$package.version; builtAtUtc = [DateTime]::UtcNow.ToString('o'); payloadFile = 'payload.zip'; payloadSha256 = $zipHash; nodeVersion = $nodeVersion; installScope = 'CurrentUser'; privacy = 'No .env, data, chats, profile, memory, logs, backups, files, or cloud screen components are included.' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'installer-manifest.json') -Encoding utf8
Set-Content -LiteralPath (Join-Path $stage 'payload.sha256') -Value "$zipHash  payload.zip" -Encoding ascii
foreach ($name in @('Install-Jarvis-RELEASE-v2.cmd', 'Install-Jarvis-RELEASE-v2.ps1', 'Install-Jarvis-RELEASE.ps1')) { Copy-Item -LiteralPath (Join-Path $installer $name) -Destination $stage -Force }

$files = @('Install-Jarvis-RELEASE-v2.cmd', 'Install-Jarvis-RELEASE-v2.ps1', 'Install-Jarvis-RELEASE.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
$sed = [System.Collections.Generic.List[string]]::new()
@('[Version]', 'Class=IEXPRESS', 'SEDVersion=3', '', '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=0', 'HideExtractAnimation=1', 'UseLongFileName=1', 'InsideCompressed=1', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=') | ForEach-Object { $sed.Add($_) }
$sed.Add("TargetName=$OutputPath"); $sed.Add('FriendlyName=JARVIS NEXUS ULTRA'); $sed.Add('AppLaunched=Install-Jarvis-RELEASE-v2.cmd'); $sed.Add('PostInstallCmd=<None>'); $sed.Add('AdminQuietInstCmd=Install-Jarvis-RELEASE-v2.cmd /quiet'); $sed.Add('UserQuietInstCmd=Install-Jarvis-RELEASE-v2.cmd /quiet'); $sed.Add('SourceFiles=SourceFiles'); $sed.Add(''); $sed.Add('[Strings]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('FILE{0}="{1}"' -f $i, $files[$i])) }
$sed.Add(''); $sed.Add('[SourceFiles]'); $sed.Add("SourceFiles0=$stage\"); $sed.Add(''); $sed.Add('[SourceFiles0]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('%FILE{0}%=' -f $i)) }
$sedPath = Join-Path $stage 'JARVIS-NEXUS-GOLD.sed'; $sed | Set-Content -LiteralPath $sedPath -Encoding ascii

& $iexpress /N /Q $sedPath
$iexpressExit = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Fail "IExpress did not create an EXE. Exit code $iexpressExit. SED retained at $sedPath" }
if ($iexpressExit -ne 0) { Write-Warning "IExpress returned $iexpressExit after producing the EXE; output existence and payload were verified." }
$exeHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant(); $checksum = "$OutputPath.sha256.txt"
Set-Content -LiteralPath $checksum -Value "$exeHash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksum" -ForegroundColor Cyan
Write-Host "Audit stage: $stage" -ForegroundColor DarkCyan
