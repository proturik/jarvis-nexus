[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "JARVIS v6 installer: $Message" }
function Need([string]$Path, [bool]$Folder = $false) {
    $kind = if ($Folder) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $Path -PathType $kind)) { Fail "Missing path $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}
function Ensure([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
}
function Assert-Parse([string]$Path) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { Fail "PowerShell syntax error in $Path at line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
}
function Assert-NodeSyntax([string]$Node, [string]$Path) {
    & $Node --check $Path
    $exitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -eq $exitCode -or [int]$exitCode.Value -ne 0) { Fail "Node syntax check failed: $Path" }
}
function Replace-Required([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $matches = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($matches -ne 1) { Fail "Expected exactly one old $Label fragment, found $matches." }
    return $Text.Replace($Old, $New)
}
function Get-RelativeZipPath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}
function Test-AllowedPayloadFile([string]$RelativePath) {
    return (
        $RelativePath -in @(
            'app/ultra-server.mjs',
            'app/package.json',
            'app/public-ultra/index.html',
            'app/public-ultra/ultra.css',
            'app/public-ultra/ultra.js',
            'app/public-ultra/ultra-wake-patch.js',
            'app/windows-theme/Enable-Nexus-Desktop.ps1',
            'app/windows-theme/Sync-Nexus-Theme.ps1',
            'runtime/node.exe',
            'launcher/Start-Jarvis-RELEASE.ps1',
            'launcher/Start-Jarvis-RELEASE.cmd'
        ) -or
        $RelativePath -like 'app/assets/*' -or
        $RelativePath -like 'app/windows-control/*'
    )
}
function Assert-CleanPayload([string]$PayloadRoot) {
    $allItems = Get-ChildItem -LiteralPath $PayloadRoot -Force -Recurse
    $privateItem = $allItems | Where-Object {
        $leaf = $_.Name.ToLowerInvariant()
        ($leaf -in @('.env', '.git', 'data', 'logs', 'log', 'backups', 'backup', 'server.mjs', 'omega-server.mjs', 'public-omega')) -or
        ($leaf -like '*conversation*') -or ($leaf -like '*memory*') -or
        ($leaf -like '*profile*') -or ($leaf -like '*task*') -or
        ($leaf -like '*event*') -or ($leaf -like '*.log') -or
        ($leaf -like '*.bak') -or ($leaf -like '*.sqlite') -or ($leaf -like '*.db')
    } | Select-Object -First 1
    if ($null -ne $privateItem) { Fail "Private, backup, log, or forbidden mode content entered payload: $($privateItem.FullName)" }

    foreach ($file in Get-ChildItem -LiteralPath $PayloadRoot -Force -File -Recurse) {
        $relative = Get-RelativeZipPath $PayloadRoot $file.FullName
        if (-not (Test-AllowedPayloadFile $relative)) { Fail "Payload file violates the exact allow-list: $relative" }
        if ($file.Extension -in @('.js', '.mjs', '.json', '.ps1', '.cmd', '.html', '.css', '.txt')) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -match '(?i)\bsk-[A-Za-z0-9_-]{16,}\b|\bghp_[A-Za-z0-9]{20,}\b|\bAIza[0-9A-Za-z_-]{20,}\b') {
                Fail "Credential-like token entered payload: $relative"
            }
        }
    }
}
function Assert-ArchiveMatchesPayload([string]$PayloadRoot, [string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected = @(Get-ChildItem -LiteralPath $PayloadRoot -Force -File -Recurse | ForEach-Object { Get-RelativeZipPath $PayloadRoot $_.FullName } | Sort-Object)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $actual = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
    }
    finally { $archive.Dispose() }
    $difference = Compare-Object -ReferenceObject $expected -DifferenceObject $actual
    if ($null -ne $difference) { Fail "Archive entries differ from staged payload: $($difference | Out-String)" }
    foreach ($entry in $actual) {
        if (-not (Test-AllowedPayloadFile $entry)) { Fail "Archive entry violates the exact allow-list: $entry" }
    }
}

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $project 'release\JARVIS-NEXUS-ULTRA-Setup-THEMED-AUTOSTART-TESTED-v4.exe'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "Refusing to overwrite $OutputPath" }
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Fail 'WorkRoot must be ASCII and contain no spaces.' }
Ensure $WorkRoot
Ensure (Split-Path -Parent $OutputPath)

$outerPs1 = Need (Join-Path $installer 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1')
$outerCmd = Need (Join-Path $installer 'Install-Jarvis-THEMED-AUTOSTART-v3.cmd')
$coreV3 = Need (Join-Path $installer 'Install-Jarvis-CORE-v3.ps1')
$launcherPs1 = Need (Join-Path $installer 'Start-Jarvis-RELEASE-v2.ps1')
$launcherCmd = Need (Join-Path $installer 'Start-Jarvis-RELEASE-v2.cmd')
$desktopV3 = Need (Join-Path $project 'windows-theme\Enable-Nexus-Desktop-v3.ps1')
$syncV2 = Need (Join-Path $project 'windows-theme\Sync-Nexus-Theme-v2.ps1')
$server = Need (Join-Path $project 'ultra-server.mjs')
$packageJson = Need (Join-Path $project 'package.json')
$indexSource = Need (Join-Path $project 'public-ultra\index.html')
$styleSource = Need (Join-Path $project 'public-ultra\ultra.css')
$ultraV2 = Need (Join-Path $project 'public-ultra\ultra-v2.js')
$wakeV3 = Need (Join-Path $project 'public-ultra\ultra-wake-patch-v3.js')
$assets = Need (Join-Path $project 'assets') $true
$controls = Need (Join-Path $project 'windows-control') $true
foreach ($path in @($outerPs1, $coreV3, $launcherPs1, $desktopV3, $syncV2)) { Assert-Parse $path }

$nodeCandidates = @()
if ($NodeRuntime) { $nodeCandidates += $NodeRuntime }
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($null -ne $nodeCommand) { $nodeCandidates += $nodeCommand.Source }
$node = $nodeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $node) { Fail 'Node.js 20+ was not found.' }
$node = (Resolve-Path -LiteralPath $node).Path
$nodeVersion = (& $node --version 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(?<major>\d+)\.' -or [int]$Matches.major -lt 20) { Fail "Invalid Node runtime $node" }
foreach ($path in @($server, $ultraV2, $wakeV3)) { Assert-NodeSyntax $node $path }

$iexpress = @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) { Fail 'IExpress was not found.' }

$stage = Join-Path $WorkRoot ('THEMED-AUTOSTART-TESTED-v4-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$app = Join-Path $payload 'app'
$runtime = Join-Path $payload 'runtime'
$launcher = Join-Path $payload 'launcher'
$publicUltra = Join-Path $app 'public-ultra'
$themes = Join-Path $app 'windows-theme'
New-Item -ItemType Directory -Path $app, $runtime, $launcher, $publicUltra, $themes -ErrorAction Stop | Out-Null

Copy-Item -LiteralPath $server -Destination $app -Force
Copy-Item -LiteralPath $packageJson -Destination $app -Force
Copy-Item -LiteralPath $indexSource -Destination $publicUltra -Force
Copy-Item -LiteralPath $styleSource -Destination $publicUltra -Force
Copy-Item -LiteralPath $ultraV2 -Destination (Join-Path $publicUltra 'ultra.js') -Force
Copy-Item -LiteralPath $wakeV3 -Destination (Join-Path $publicUltra 'ultra-wake-patch.js') -Force
Copy-Item -LiteralPath $assets -Destination $app -Recurse -Force
Copy-Item -LiteralPath $controls -Destination $app -Recurse -Force
Copy-Item -LiteralPath $desktopV3 -Destination (Join-Path $themes 'Enable-Nexus-Desktop.ps1') -Force
Copy-Item -LiteralPath $syncV2 -Destination (Join-Path $themes 'Sync-Nexus-Theme.ps1') -Force

$ultraScriptTag = '<script src="ultra.js"></script>'
$wakeScriptTag = '<script src="ultra-wake-patch.js"></script>'
$stagedIndex = Join-Path $publicUltra 'index.html'
$index = Get-Content -LiteralPath $stagedIndex -Raw
if ([regex]::Matches($index, [regex]::Escape($ultraScriptTag)).Count -ne 1) { Fail 'Expected exactly one ultra.js script tag in staged index.html.' }
if ($index.Contains($wakeScriptTag)) { Fail 'Staged index.html unexpectedly already contains the wake patch tag.' }
Set-Content -LiteralPath $stagedIndex -Value $index.Replace($ultraScriptTag, $ultraScriptTag + [Environment]::NewLine + '  ' + $wakeScriptTag) -Encoding utf8
$verifiedIndex = Get-Content -LiteralPath $stagedIndex -Raw
if ($verifiedIndex.IndexOf($wakeScriptTag) -le $verifiedIndex.IndexOf($ultraScriptTag)) { Fail 'Wake patch script was not injected immediately after ultra.js.' }

# Patch only the staged server copy. Every replacement is guarded so a source
# change cannot silently produce a partially patched installer.
$stagedServer = Join-Path $app 'ultra-server.mjs'
$stagedText = Get-Content -LiteralPath $stagedServer -Raw
$stagedText = Replace-Required $stagedText '/\b(?:статус|состояние|диагностик|пульс системы)\b/iu' '/(?:^|\s)(?:статус|состояние|диагностик|пульс системы)(?=$|\s|[,.!?])/iu' 'status-regex'
$stagedText = Replace-Required $stagedText '/^(?:открой|запусти|включи)\b/iu' '/^(?:открой|запусти|включи)(?=$|\s)/iu' 'open-regex'
$stagedText = Replace-Required $stagedText '/\bпогода\b/iu' '/(?:^|\s)погода(?=$|\s|[,.!?])/iu' 'weather-regex'
$stagedText = Replace-Required $stagedText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'cloud-history'
Set-Content -LiteralPath $stagedServer -Value $stagedText -Encoding utf8
Assert-NodeSyntax $node $stagedServer
if ($stagedText -notlike '*/^(?:открой|запусти|включи)(?=$|\s)/*') { Fail 'Staged open-regex patch is missing.' }
& $node --input-type=module --eval "const re=/^(?:открой|запусти|включи)(?=$|\s)/iu; if(!re.test('открой блокнот')) process.exit(1);"
$regexExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -eq $regexExit -or [int]$regexExit.Value -ne 0) { Fail 'Cyrillic open-command regex assertion failed.' }

Copy-Item -LiteralPath $node -Destination (Join-Path $runtime 'node.exe') -Force
Copy-Item -LiteralPath $launcherPs1 -Destination (Join-Path $launcher 'Start-Jarvis-RELEASE.ps1') -Force
Copy-Item -LiteralPath $launcherCmd -Destination (Join-Path $launcher 'Start-Jarvis-RELEASE.cmd') -Force

Assert-CleanPayload $payload
$zip = Join-Path $stage 'payload.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
Assert-ArchiveMatchesPayload $payload $zip
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
[ordered]@{
    product = 'JARVIS NEXUS ULTRA'
    version = [string]$package.version
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'
    payloadSha256 = $zipHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    privacy = 'Exact archive allow-list; no .env, data, chats, profile, memory, tasks, events, logs, backups, API credentials, OMEGA or cloud screen components.'
    client = 'ultra-v2.js with JARVIS wake-word patch v3'
    serverPatch = 'Unicode-safe Russian action regexes and cloud-history deduplication'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'installer-manifest.json') -Encoding utf8
Set-Content -LiteralPath (Join-Path $stage 'payload.sha256') -Value "$zipHash  payload.zip" -Encoding ascii

Copy-Item -LiteralPath $outerCmd -Destination (Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.cmd') -Force
Copy-Item -LiteralPath $outerPs1 -Destination (Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1') -Force
Copy-Item -LiteralPath $coreV3 -Destination (Join-Path $stage 'Install-Jarvis-CORE-v2.ps1') -Force

$files = @('Install-Jarvis-THEMED-AUTOSTART-v3.cmd', 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1', 'Install-Jarvis-CORE-v2.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
$sed = [System.Collections.Generic.List[string]]::new()
@('[Version]', 'Class=IEXPRESS', 'SEDVersion=3', '', '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=0', 'HideExtractAnimation=1', 'UseLongFileName=1', 'InsideCompressed=1', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=') | ForEach-Object { $sed.Add($_) }
$sed.Add("TargetName=$OutputPath")
$sed.Add('FriendlyName=JARVIS NEXUS ULTRA')
$sed.Add('AppLaunched=Install-Jarvis-THEMED-AUTOSTART-v3.cmd')
$sed.Add('PostInstallCmd=<None>')
$sed.Add('AdminQuietInstCmd=Install-Jarvis-THEMED-AUTOSTART-v3.cmd -Quiet')
$sed.Add('UserQuietInstCmd=Install-Jarvis-THEMED-AUTOSTART-v3.cmd -Quiet')
$sed.Add('SourceFiles=SourceFiles')
$sed.Add('')
$sed.Add('[Strings]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('FILE{0}="{1}"' -f $i, $files[$i])) }
$sed.Add('')
$sed.Add('[SourceFiles]')
$sed.Add("SourceFiles0=$stage\")
$sed.Add('')
$sed.Add('[SourceFiles0]')
for ($i = 0; $i -lt $files.Count; $i++) { $sed.Add(('%FILE{0}%=' -f $i)) }
$sedPath = Join-Path $stage 'JARVIS-NEXUS-THEMED-AUTOSTART-TESTED-v4.sed'
$sed | Set-Content -LiteralPath $sedPath -Encoding ascii

& $iexpress /N /Q $sedPath
$iexpressExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -eq $iexpressExit) { Fail 'IExpress did not provide an exit code.' }
if ([int]$iexpressExit.Value -ne 0) { Fail "IExpress exited with code $($iexpressExit.Value). SED retained at $sedPath" }

$deadline = [DateTime]::UtcNow.AddSeconds(90)
while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Fail "IExpress did not create an EXE. SED retained at $sedPath" }

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToUpperInvariant()
$checksum = "$OutputPath.sha256.txt"
if (Test-Path -LiteralPath $checksum) { Fail "Refusing to overwrite $checksum" }
Set-Content -LiteralPath $checksum -Value "$hash  $(Split-Path -Leaf $OutputPath)" -Encoding ascii
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksum" -ForegroundColor Cyan
Write-Host "Audit stage: $stage" -ForegroundColor DarkCyan
exit 0
