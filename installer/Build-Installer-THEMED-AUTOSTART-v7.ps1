[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "JARVIS final installer: $Message" }

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
    if ($errors.Count -gt 0) {
        Fail "PowerShell syntax error in $Path at line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
    }
}

function Assert-NodeSyntax([string]$Node, [string]$Path) {
    & $Node --check $Path
    $exitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -eq $exitCodeVariable -or [int]$exitCodeVariable.Value -ne 0) {
        Fail "Node syntax check failed: $Path"
    }
}

function Decode-Utf8Base64([string]$Base64) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function Replace-Exactly([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { Fail "Expected exactly one $Label patch anchor; found $count." }
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
    if ($null -ne $privateItem) { Fail "Private or forbidden content entered payload: $($privateItem.FullName)" }

    $files = Get-ChildItem -LiteralPath $PayloadRoot -Force -File -Recurse
    foreach ($file in $files) {
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
    try { $actual = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object) }
    finally { $archive.Dispose() }
    $difference = Compare-Object -ReferenceObject $expected -DifferenceObject $actual
    if ($null -ne $difference) { Fail "Archive entries differ from staged payload: $($difference | Out-String)" }
    foreach ($entry in $actual) { if (-not (Test-AllowedPayloadFile $entry)) { Fail "Archive entry violates the exact allow-list: $entry" } }
}

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $project 'release\JARVIS-NEXUS-ULTRA-Setup-THEMED-AUTOSTART-TESTED-v5.exe' }
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

$stage = Join-Path $WorkRoot ('THEMED-AUTOSTART-TESTED-v5-' + [guid]::NewGuid().ToString('N'))
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

$stagedServer = Join-Path $app 'ultra-server.mjs'
$serverText = Get-Content -LiteralPath $stagedServer -Raw
$unicodePatches = @(
    @{ Old = 'L1xiKD860YHRgtCw0YLRg9GBfNGB0L7RgdGC0L7Rj9C90LjQtXzQtNC40LDQs9C90L7RgdGC0LjQunzQv9GD0LvRjNGBINGB0LjRgdGC0LXQvNGLKVxiL2l1'; New = 'Lyg/Ol58XHMpKD860YHRgtCw0YLRg9GBfNGB0L7RgdGC0L7Rj9C90LjQtXzQtNC40LDQs9C90L7RgdGC0LjQunzQv9GD0LvRjNGBINGB0LjRgdGC0LXQvNGLKSg/PSR8XHN8WywuIT9dKS9pdQ=='; Label = 'status regex' },
    @{ Old = 'L14oPzrQvtGC0LrRgNC+0Ll80LfQsNC/0YPRgdGC0Lh80LLQutC70Y7Rh9C4KVxiL2l1'; New = 'L14oPzrQvtGC0LrRgNC+0Ll80LfQsNC/0YPRgdGC0Lh80LLQutC70Y7Rh9C4KSg/PSR8XHMpL2l1'; Label = 'open regex' },
    @{ Old = 'L1xi0L/QvtCz0L7QtNCwXGIvaXU='; New = 'Lyg/Ol58XHMp0L/QvtCz0L7QtNCwKD89JHxcc3xbLC4hP10pL2l1'; Label = 'weather regex' }
)
foreach ($patch in $unicodePatches) {
    $serverText = Replace-Exactly $serverText (Decode-Utf8Base64 $patch.Old) (Decode-Utf8Base64 $patch.New) $patch.Label
}
$serverText = Replace-Exactly $serverText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'cloud history slice'
$serverText = Replace-Exactly $serverText 'if (!process.env.OPENAI_API_KEY || state.settings.provider === 'local') return null;' 'if (!process.env.OPENAI_API_KEY) return null;' 'cloud fallback guard'
$localBrainSource = @'
async function askLocalBrain(message) {
  if (process.env.JARVIS_DISABLE_LOCAL_BRAIN === '1') return null;
  try {
    const history = state.conversations.slice(-15, -1).map((turn) => ({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: turn.text }));
    const response = await fetch('http://127.0.0.1:11434/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: process.env.OLLAMA_MODEL || 'llama3.2',
        messages: [...history, { role: 'user', content: message }],
        stream: false,
      }),
      signal: AbortSignal.timeout(18000),
    });
    if (!response.ok) return null;
    const payload = await response.json();
    return clean(payload && payload.message && payload.message.content, 1800) || null;
  } catch {
    return null;
  }
}

'@
$serverText = Replace-Exactly $serverText 'async function askCloud(message) {' ($localBrainSource + 'async function askCloud(message) {') 'local brain insertion'
$serverText = Replace-Exactly $serverText '    reply = await askCloud(message);' ("    reply = await askLocalBrain(message);" + [Environment]::NewLine + '    reply ||= await askCloud(message);') 'local-first chat route'
Set-Content -LiteralPath $stagedServer -Value $serverText -Encoding utf8
Assert-NodeSyntax $node $stagedServer

$ultraScriptTag = '<script src="ultra.js"></script>'
$wakeScriptTag = '<script src="ultra-wake-patch.js"></script>'
$stagedIndex = Join-Path $publicUltra 'index.html'
$index = Get-Content -LiteralPath $stagedIndex -Raw
if ([regex]::Matches($index, [regex]::Escape($ultraScriptTag)).Count -ne 1) { Fail 'Expected exactly one ultra.js script tag in staged index.html.' }
if ($index.Contains($wakeScriptTag)) { Fail 'Staged index.html unexpectedly already contains the wake patch tag.' }
$injected = $ultraScriptTag + [Environment]::NewLine + '  ' + $wakeScriptTag
Set-Content -LiteralPath $stagedIndex -Value $index.Replace($ultraScriptTag, $injected) -Encoding utf8
$verifiedIndex = Get-Content -LiteralPath $stagedIndex -Raw
if ($verifiedIndex.IndexOf($wakeScriptTag) -le $verifiedIndex.IndexOf($ultraScriptTag)) { Fail 'Wake patch script was not injected immediately after ultra.js.' }

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
    privacy = 'Exact archive allow-list; no .env, data, chats, profile, memory, tasks, events, logs, backups, API credentials, OMEGA, model files, or cloud screen components.'
    client = 'ultra-v2.js with wake patch v3 and optional local Ollama runtime'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'installer-manifest.json') -Encoding utf8
Set-Content -LiteralPath (Join-Path $stage 'payload.sha256') -Value "$zipHash  payload.zip" -Encoding ascii

$localBrainScript = @'
[CmdletBinding()]
param([switch]$Interactive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-LocalBrain([string]$Text, [string]$Title) {
    if (-not $Interactive) { return $false }
    Add-Type -AssemblyName PresentationFramework
    return [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes'
}

function Find-Ollama {
    $command = Get-Command ollama.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { $command = Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -ne $command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

if (-not $Interactive) { throw 'Interactive consent is required for Local Brain setup.' }
$ollama = Find-Ollama
if ($null -eq $ollama) {
    $message = 'Ollama is not installed. Run the official installer from https://ollama.com/install.ps1 now?'
    if (-not (Confirm-LocalBrain $message 'JARVIS Local Brain')) { Write-Host 'Local Brain setup skipped.'; exit 0 }
    $officialUrl = 'https://ollama.com/install.ps1'
    $installer = Invoke-RestMethod -Uri $officialUrl
    if ([string]::IsNullOrWhiteSpace($installer)) { throw 'Official Ollama installer download returned no content.' }
    Invoke-Expression $installer
    $ollama = Find-Ollama
    if ($null -eq $ollama) { throw 'Ollama installation did not make ollama available.' }
}

if (-not (Confirm-LocalBrain 'Download the optional llama3.2 model now? This can use several GB of disk space.' 'JARVIS Local Brain')) {
    Write-Host 'Local Brain model download skipped.'
    exit 0
}
& $ollama pull llama3.2
$exitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -ne $exitCodeVariable -and [int]$exitCodeVariable.Value -ne 0) { throw "Ollama model download exited with code $($exitCodeVariable.Value)." }
Write-Host 'Local Brain is ready.'
'@
$localBrainPath = Join-Path $stage 'Install-Local-Brain.ps1'
Set-Content -LiteralPath $localBrainPath -Value $localBrainScript -Encoding utf8
Assert-Parse $localBrainPath

$outerText = Get-Content -LiteralPath $outerPs1 -Raw
$nl = if ($outerText.Contains("`r`n")) { "`r`n" } else { "`n" }
$outerText = Replace-Exactly $outerText ("    [switch]`$EnableAutostart" + $nl + ')') ("    [switch]`$EnableAutostart," + $nl + "    [switch]`$SetupLocalBrain" + $nl + ')') 'outer parameter list'
$setupFunction = @'
function Setup-LocalBrain {
    $scriptPath = Join-Path $PSScriptRoot 'Install-Local-Brain.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Local Brain setup module missing: $scriptPath" }
    & $scriptPath -Interactive
    Assert-OptionalNativeExitCode 'Local Brain setup'
}

'@
$outerText = Replace-Exactly $outerText 'function Enable-NexusDesktop {' ($setupFunction + 'function Enable-NexusDesktop {') 'outer local brain function'
$autostartTag = '            <CheckBox x:Name="EnableAutostart" IsChecked="True" Content="Start JARVIS automatically when I sign in" Margin="2,4" Foreground="#DDFBFF"/>'
$localBrainTag = '            <CheckBox x:Name="SetupLocalBrain" IsChecked="False" Content="Set up Local Brain (Ollama, optional)" Margin="2,4" Foreground="#DDFBFF"/>'
$outerText = Replace-Exactly $outerText $autostartTag ($autostartTag + $nl + $localBrainTag) 'outer local brain checkbox'
$outerText = Replace-Exactly $outerText "    `$enableAutostart = `$window.FindName('EnableAutostart')" ("    `$enableAutostart = `$window.FindName('EnableAutostart')" + $nl + "    `$setupLocalBrain = `$window.FindName('SetupLocalBrain')") 'outer local brain lookup'
$autostartBlock = "            if ([bool]`$enableAutostart.IsChecked) {" + $nl + "                `$status.Text = 'ARMING LOCAL AUTOSTART...'" + $nl + '                Enable-JarvisAutostart' + $nl + '            }'
$brainBlock = $autostartBlock + $nl + "            if ([bool]`$setupLocalBrain.IsChecked) {" + $nl + "                `$status.Text = 'SETTING UP OPTIONAL LOCAL BRAIN...'" + $nl + '                Setup-LocalBrain' + $nl + '            }'
$outerText = Replace-Exactly $outerText $autostartBlock $brainBlock 'outer local brain click flow'
$quietBlock = "    if (`$EnableAutostart) { Enable-JarvisAutostart }" + $nl + '}'
$outerText = Replace-Exactly $outerText $quietBlock ("    if (`$EnableAutostart) { Enable-JarvisAutostart }" + $nl + "    if (`$SetupLocalBrain) { Setup-LocalBrain }" + $nl + '}') 'outer local brain quiet flow'
$stagedOuter = Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1'
Set-Content -LiteralPath $stagedOuter -Value $outerText -Encoding utf8
Assert-Parse $stagedOuter

Copy-Item -LiteralPath $outerCmd -Destination (Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.cmd') -Force
Copy-Item -LiteralPath $coreV3 -Destination (Join-Path $stage 'Install-Jarvis-CORE-v2.ps1') -Force
$files = @('Install-Jarvis-THEMED-AUTOSTART-v3.cmd', 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1', 'Install-Jarvis-CORE-v2.ps1', 'Install-Local-Brain.ps1', 'installer-manifest.json', 'payload.sha256', 'payload.zip')
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
$sedPath = Join-Path $stage 'JARVIS-NEXUS-THEMED-AUTOSTART-TESTED-v5.sed'
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
