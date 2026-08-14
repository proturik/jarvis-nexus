[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-native-build'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "JARVIS native installer: $Message" }
function Need([string]$Path, [bool]$Folder = $false) {
    $kind = if ($Folder) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $Path -PathType $kind)) { Fail "Missing path: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}
function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Assert-NoBom([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Fail "Unexpected UTF-8 BOM: $Path" }
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { Fail "Expected one $Label anchor, found $count." }
    return $Text.Replace($Old, $New)
}
function Decode-Utf8Base64([string]$Value) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }
function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { $sha = [Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') } finally { $sha.Dispose() } }
    finally { $stream.Dispose() }
}
function Assert-Parse([string]$Path) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { Fail "PowerShell parse failure in $Path line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
}
function Assert-Node([string]$Node, [string]$Path) { & $Node --check $Path; if ($LASTEXITCODE -ne 0) { Fail "Node syntax failed: $Path" } }
function Ensure-Directory([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Relative([string]$Root, [string]$Path) { return $Path.Substring($Root.Length).TrimStart('\','/').Replace('\','/') }

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $project 'release\JARVIS-NEXUS-NATIVE-Setup-v1.exe' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "Refusing to overwrite: $OutputPath" }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Fail 'WorkRoot must be an ASCII path without spaces.' }
Ensure-Directory $WorkRoot
Ensure-Directory (Split-Path -Parent $OutputPath)

$serverSource = Need (Join-Path $project 'ultra-server.mjs')
$packageSource = Need (Join-Path $project 'package.json')
$petSource = Need (Join-Path $project 'desktop-shell\dist\JarvisPet.exe')
$controlSource = Need (Join-Path $project 'windows-control\Invoke-NexusControl.ps1')
$themeSource = Need (Join-Path $project 'windows-theme\Enable-Nexus-Desktop-v3.ps1')
$syncSource = Need (Join-Path $project 'windows-theme\Sync-Nexus-Theme-v2.ps1')
$wallpaper = Need (Join-Path $project 'assets\nexus-command-deck-wallpaper.png')
$outerSource = Need (Join-Path $installer 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1')
$nodeCandidates = @()
if ($NodeRuntime) { $nodeCandidates += $NodeRuntime }
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($null -ne $nodeCommand) { $nodeCandidates += $nodeCommand.Source }
$node = $nodeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $node) { Fail 'Node.js 20+ is required to build the native package.' }
$node = (Resolve-Path -LiteralPath $node).Path
& $node --version | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'Node runtime cannot start.' }
$iexpress = @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) { Fail 'IExpress was not found.' }

$stage = Join-Path $WorkRoot ('native-v1-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$app = Join-Path $payload 'app'
$runtime = Join-Path $payload 'runtime'
$launcher = Join-Path $payload 'launcher'
$petFolder = Join-Path $payload 'desktop-shell'
New-Item -ItemType Directory -Path $app,$runtime,$launcher,$petFolder,(Join-Path $app 'assets'),(Join-Path $app 'windows-control'),(Join-Path $app 'windows-theme') -Force | Out-Null

Copy-Item -LiteralPath $packageSource -Destination $app -Force
Copy-Item -LiteralPath $petSource -Destination (Join-Path $petFolder 'JarvisPet.exe') -Force
Copy-Item -LiteralPath $controlSource -Destination (Join-Path $app 'windows-control\Invoke-NexusControl.ps1') -Force
Copy-Item -LiteralPath $themeSource -Destination (Join-Path $app 'windows-theme\Enable-Nexus-Desktop.ps1') -Force
Copy-Item -LiteralPath $syncSource -Destination (Join-Path $app 'windows-theme\Sync-Nexus-Theme.ps1') -Force
Copy-Item -LiteralPath $wallpaper -Destination (Join-Path $app 'assets\nexus-command-deck-wallpaper.png') -Force
Copy-Item -LiteralPath $node -Destination (Join-Path $runtime 'node.exe') -Force

$serverText = Read-Utf8 $serverSource
$patches = @(
    @{ O='L1xiKD860YHRgtCw0YLRg9GBfNGB0L7RgdGC0L7Rj9C90LjQtXzQtNC40LDQs9C90L7RgdGC0LjQunzQv9GD0LvRjNGBINGB0LjRgdGC0LXQvNGLKVxiL2l1'; N='Lyg/Ol58XHMpKD860YHRgtCw0YLRg9GBfNGB0L7RgdGC0L7Rj9C90LjQtXzQtNC40LDQs9C90L7RgdGC0LjQunzQv9GD0LvRjNGBINGB0LjRgdGC0LXQvNGLKSg/PSR8XHN8WywuIT9dKS9pdQ=='; L='status regex' },
    @{ O='L14oPzrQvtGC0LrRgNC+0Ll80LfQsNC/0YPRgdGC0Lh80LLQutC70Y7Rh9C4KVxiL2l1'; N='L14oPzrQvtGC0LrRgNC+0Ll80LfQsNC/0YPRgdGC0Lh80LLQutC70Y7Rh9C4KSg/PSR8XHMpL2l1'; L='open regex' },
    @{ O='L1xi0L/QvtCz0L7QtNCwXGIvaXU='; N='Lyg/Ol58XHMp0L/QvtCz0L7QtNCwKD89JHxcc3xbLC4hP10pL2l1'; L='weather regex' }
)
foreach ($p in $patches) { $serverText = Replace-Once $serverText (Decode-Utf8Base64 $p.O) (Decode-Utf8Base64 $p.N) $p.L }
$serverText = Replace-Once $serverText "  provider: 'auto'," "  provider: 'local'," 'local provider default'
$serverText = Replace-Once $serverText ": 'auto'," ": 'local'," 'local provider sanitizer'
$serverText = Replace-Once $serverText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'history slice'
$localBrain = @'
async function askLocalBrain(message) {
  if (process.env.JARVIS_DISABLE_LOCAL_BRAIN === '1') return null;
  const models = process.env.OLLAMA_MODEL ? [process.env.OLLAMA_MODEL] : ['llama3.1:8b', 'llama3.2'];
  const history = state.conversations.slice(-15, -1).map((turn) => ({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: turn.text }));
  for (const model of models) {
    try {
      const response = await fetch('http://127.0.0.1:11434/api/chat', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model, messages: [{ role: 'system', content: systemPrompt() }, ...history, { role: 'user', content: message }], stream: false }),
        signal: AbortSignal.timeout(60000),
      });
      if (!response.ok) continue;
      const payload = await response.json();
      const reply = clean(payload && payload.message && payload.message.content, 1800);
      if (reply) return reply;
    } catch { }
  }
  return null;
}

'@
$serverText = Replace-Once $serverText 'async function askCloud(message) {' ($localBrain + 'async function askCloud(message) {') 'local brain insertion'
$oldRoute = "  } else if (operation.kind === 'chat') {`n    reply = await askCloud(message);`n  }"
$newRoute = "  } else if (operation.kind === 'chat') {`n    if (state.settings.provider === 'openai') reply = await askCloud(message);`n    else {`n      reply = await askLocalBrain(message);`n      if (reply === null -and state.settings.provider === 'auto') reply = await askCloud(message);`n    }`n  }"
$serverText = Replace-Once $serverText $oldRoute $newRoute 'chat dispatcher'
$stagedServer = Join-Path $app 'ultra-server.mjs'
Write-Utf8 $stagedServer $serverText
Assert-NoBom $stagedServer
Assert-Node $node $stagedServer

$launcherText = @'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $InstallRoot 'app'
$NodePath = Join-Path $InstallRoot 'runtime\node.exe'
$ServerPath = Join-Path $AppRoot 'ultra-server.mjs'
$PetPath = Join-Path $InstallRoot 'desktop-shell\JarvisPet.exe'
$Uri = 'http://127.0.0.1:3791/api/bootstrap'
function Test-Endpoint {
    try { $boot = Invoke-RestMethod -Uri $Uri -TimeoutSec 1; return $boot.settings.assistantName -eq 'JARVIS' -and $null -ne $boot.system } catch { return $false }
}
foreach ($path in @($NodePath,$ServerPath,$PetPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "JARVIS component missing: $path" } }
New-Item -ItemType Directory -Path (Join-Path $AppRoot 'data') -Force | Out-Null
if (-not (Test-Endpoint)) {
    Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $ServerPath) -WorkingDirectory $AppRoot -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Endpoint)) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Endpoint)) { throw 'JARVIS local server did not become ready.' }
}
$me = (Resolve-Path -LiteralPath $PetPath).Path
$pet = Get-CimInstance Win32_Process -Filter "Name='JarvisPet.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath,$me,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
if ($null -eq $pet) { Start-Process -FilePath $PetPath -WorkingDirectory (Split-Path -Parent $PetPath) }
'@
$stagedLauncher = Join-Path $launcher 'Start-Jarvis-NATIVE.ps1'
Write-Utf8 $stagedLauncher $launcherText
Assert-NoBom $stagedLauncher
Assert-Parse $stagedLauncher
$launcherCmd = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Jarvis-NATIVE.ps1"' + "`r`n"
[IO.File]::WriteAllText((Join-Path $launcher 'Start-Jarvis-NATIVE.cmd'), $launcherCmd, [Text.Encoding]::ASCII)

$brainText = @'
[CmdletBinding()]
param([switch]$Interactive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Confirm([string]$Text) {
    if (-not $Interactive) { return $false }
    Add-Type -AssemblyName PresentationFramework
    return [Windows.MessageBox]::Show($Text,'JARVIS Local Brain','YesNo','Question') -eq 'Yes'
}
function Find-Ollama {
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command ollama.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return $null
}
$model = 'llama3.1:8b'
$ollama = Find-Ollama
if ($null -eq $ollama) {
    if (-not (Confirm 'Download and install the official local Ollama runtime now?')) { exit 0 }
    $setup = Join-Path $env:TEMP 'JARVIS-OllamaSetup.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup
    Import-Module Microsoft.PowerShell.Security -Force
    $sig = Get-AuthenticodeSignature -FilePath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Ollama Inc\\.') { throw 'Official Ollama installer signature verification failed.' }
    $proc = Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES') -PassThru
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "Ollama installer exited with code $($proc.ExitCode)." }
    $ollama = Find-Ollama
    if ($null -eq $ollama) { throw 'Ollama did not become available after installation.' }
}
if (-not (Confirm 'Download the smart local model (about 5 GB) now?')) { exit 0 }
& $ollama pull $model
if ($LASTEXITCODE -ne 0) { throw "Model download exited with code $LASTEXITCODE." }
$tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 20
if (-not (@($tags.models | ForEach-Object { $_.name }) -contains $model)) { throw 'Downloaded local model was not reported by Ollama.' }
[void][Windows.MessageBox]::Show('JARVIS Local Brain is ready.','JARVIS','OK','Information')
'@
$stagedBrain = Join-Path $launcher 'Install-Local-Brain.ps1'
Write-Utf8 $stagedBrain $brainText
Assert-NoBom $stagedBrain
Assert-Parse $stagedBrain

$coreText = @'
[CmdletBinding()]
param([switch]$Quiet)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-Sha256([string]$Path) { $s=[IO.File]::OpenRead($Path); try { $h=[Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','') } finally { $h.Dispose() } } finally { $s.Dispose() } }
function Stop-Exact([string]$InstallRoot) {
    $server = (Join-Path $InstallRoot 'app\ultra-server.mjs')
    $pet = (Join-Path $InstallRoot 'desktop-shell\JarvisPet.exe')
    $targets = @()
    $targets += Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($server,[StringComparison]::OrdinalIgnoreCase) -ge 0 }
    $targets += Get-CimInstance Win32_Process -Filter "Name='JarvisPet.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath,$pet,[StringComparison]::OrdinalIgnoreCase) }
    foreach ($target in @($targets | Sort-Object ProcessId -Unique)) { Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop }
    foreach ($target in @($targets | Sort-Object ProcessId -Unique)) { $deadline=[DateTime]::UtcNow.AddSeconds(8); while ((Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 150 }; if (Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue) { throw "Old JARVIS process did not stop: $($target.ProcessId)" } }
}
function Copy-Contents([string]$Source,[string]$Destination) { if(-not (Test-Path -LiteralPath $Source -PathType Container)){throw "Payload folder missing: $Source"}; New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Get-ChildItem -LiteralPath $Source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force } }
function New-Shortcut([string]$Path,[string]$Target,[string]$Description) { $shell=New-Object -ComObject WScript.Shell; $link=$shell.CreateShortcut($Path); $link.TargetPath=$Target; $link.WorkingDirectory=Split-Path -Parent $Target; $link.Description=$Description; $link.Save() }
$manifestPath=Join-Path $PSScriptRoot 'installer-manifest.json'; $manifest=ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath,[Text.UTF8Encoding]::new($false)))
$payload=Join-Path $PSScriptRoot $manifest.payloadFile; if((Get-Sha256 $payload) -ne $manifest.payloadSha256){throw 'Payload integrity check failed.'}
$installRoot=Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA'; $extract=Join-Path $env:TEMP ('JARVIS-NATIVE-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $extract -Force | Out-Null
try { Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::ExtractToDirectory($payload,$extract); Stop-Exact $installRoot; foreach($name in @('app','runtime','launcher','desktop-shell')) { Copy-Contents (Join-Path $extract $name) (Join-Path $installRoot $name) }; New-Item -ItemType Directory -Path (Join-Path $installRoot 'app\data') -Force | Out-Null; $launch=Join-Path $installRoot 'launcher\Start-Jarvis-NATIVE.cmd'; foreach($required in @((Join-Path $installRoot 'app\ultra-server.mjs'),(Join-Path $installRoot 'runtime\node.exe'),(Join-Path $installRoot 'desktop-shell\JarvisPet.exe'),$launch)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Post-install component missing: $required"}}; New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'JARVIS NEXUS ULTRA.lnk') $launch 'Launch native JARVIS NEXUS ULTRA'; [IO.File]::WriteAllText((Join-Path $installRoot 'release.json'),($manifest | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false)) }
finally { if(Test-Path -LiteralPath $extract -PathType Container){Remove-Item -LiteralPath $extract -Recurse -Force} }
Start-Process -FilePath $launch
'@
$stagedCore = Join-Path $stage 'Install-Jarvis-NATIVE-CORE.ps1'
Write-Utf8 $stagedCore $coreText
Assert-NoBom $stagedCore
Assert-Parse $stagedCore

$outerText = Read-Utf8 $outerSource
$outerText = Replace-Once $outerText "'Install-Jarvis-CORE-v2.ps1'" "'Install-Jarvis-NATIVE-CORE.ps1'" 'core name'
$brainFunction = @'
function Start-LocalBrainSetup {
    $scriptPath = Join-Path $InstallRoot 'launcher\Install-Local-Brain.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Local Brain module missing: $scriptPath" }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Interactive')
}

'@
$outerText = Replace-Once $outerText 'function Enable-NexusDesktop {' ($brainFunction + 'function Enable-NexusDesktop {') 'brain function'
$tag = '            <CheckBox x:Name="EnableAutostart" IsChecked="True" Content="Start JARVIS automatically when I sign in" Margin="2,4" Foreground="#DDFBFF"/>'
$brainTag = '            <CheckBox x:Name="SetupLocalBrain" IsChecked="True" Content="Set up Local Brain (downloads about 5 GB)" Margin="2,4" Foreground="#DDFBFF"/>'
$outerText = Replace-Once $outerText $tag ($tag + [Environment]::NewLine + $brainTag) 'brain checkbox'
$outerText = Replace-Once $outerText "    `$enableAutostart = `$window.FindName('EnableAutostart')" ("    `$enableAutostart = `$window.FindName('EnableAutostart')" + [Environment]::NewLine + "    `$setupLocalBrain = `$window.FindName('SetupLocalBrain')") 'brain lookup'
$autoBlock = "            if ([bool]`$enableAutostart.IsChecked) {`n                `$status.Text = 'ARMING LOCAL AUTOSTART...'`n                Enable-JarvisAutostart`n            }"
$combined = $autoBlock + "`n            if ([bool]`$setupLocalBrain.IsChecked) {`n                `$status.Text = 'OPENING LOCAL BRAIN SETUP...'`n                Start-LocalBrainSetup`n            }"
$outerText = Replace-Once $outerText $autoBlock $combined 'brain start block'
$stagedOuter = Join-Path $stage 'Install-Jarvis-NATIVE.ps1'
Write-Utf8 $stagedOuter $outerText
Assert-NoBom $stagedOuter
Assert-Parse $stagedOuter
$outerCmd = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Jarvis-NATIVE.ps1" %*' + "`r`n"
[IO.File]::WriteAllText((Join-Path $stage 'Install-Jarvis-NATIVE.cmd'), $outerCmd, [Text.Encoding]::ASCII)

$files = @('Install-Jarvis-NATIVE.cmd','Install-Jarvis-NATIVE.ps1','Install-Jarvis-NATIVE-CORE.ps1','installer-manifest.json','payload.sha256','payload.zip')
$payloadFiles = @(Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object { Relative $payload $_.FullName } | Sort-Object)
$allowed = @('app/ultra-server.mjs','app/package.json','app/assets/nexus-command-deck-wallpaper.png','app/windows-control/Invoke-NexusControl.ps1','app/windows-theme/Enable-Nexus-Desktop.ps1','app/windows-theme/Sync-Nexus-Theme.ps1','runtime/node.exe','launcher/Start-Jarvis-NATIVE.ps1','launcher/Start-Jarvis-NATIVE.cmd','launcher/Install-Local-Brain.ps1','desktop-shell/JarvisPet.exe')
if ((Compare-Object $allowed $payloadFiles)) { Fail 'Payload does not match the native exact allow-list.' }
foreach($item in Get-ChildItem -LiteralPath $payload -File -Recurse){if($item.Extension -in @('.mjs','.ps1','.json','.cmd')){if((Read-Utf8 $item.FullName) -match '(?i)\bsk-[A-Za-z0-9_-]{16,}\b|\bghp_[A-Za-z0-9]{20,}\b'){Fail "Credential-like content in $($item.FullName)"}}}
$zip = Join-Path $stage 'payload.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
$hash = Get-Sha256 $zip
$manifest = [ordered]@{product='JARVIS NEXUS ULTRA NATIVE'; version='native-v1'; builtAtUtc=[DateTime]::UtcNow.ToString('o'); payloadFile='payload.zip'; payloadSha256=$hash; installScope='CurrentUser'; localBrain='Optional local Llama 3.1 8B setup downloads after explicit consent; model is not bundled.'; privacy='No .env, chats, profile, memories, tasks, logs, API keys, model files, OMEGA, or screen-capture components.'} | ConvertTo-Json -Depth 4
Write-Utf8 (Join-Path $stage 'installer-manifest.json') $manifest
[IO.File]::WriteAllText((Join-Path $stage 'payload.sha256'), "$hash  payload.zip", [Text.Encoding]::ASCII)

$sed = [Collections.Generic.List[string]]::new()
@('[Version]','Class=IEXPRESS','SEDVersion=3','','[Options]','PackagePurpose=InstallApp','ShowInstallProgramWindow=0','HideExtractAnimation=1','UseLongFileName=1','InsideCompressed=1','CAB_FixedSize=0','CAB_ResvCodeSigning=0','RebootMode=N','InstallPrompt=','DisplayLicense=','FinishMessage=') | ForEach-Object { $sed.Add($_) }
$sed.Add("TargetName=$OutputPath"); $sed.Add('FriendlyName=JARVIS NEXUS ULTRA NATIVE'); $sed.Add('AppLaunched=Install-Jarvis-NATIVE.cmd'); $sed.Add('PostInstallCmd=<None>'); $sed.Add('AdminQuietInstCmd=Install-Jarvis-NATIVE.cmd -Quiet'); $sed.Add('UserQuietInstCmd=Install-Jarvis-NATIVE.cmd -Quiet'); $sed.Add('SourceFiles=SourceFiles'); $sed.Add(''); $sed.Add('[Strings]')
for($i=0;$i -lt $files.Count;$i++){ $sed.Add(('FILE{0}="{1}"' -f $i,$files[$i])) }
$sed.Add('');$sed.Add('[SourceFiles]');$sed.Add("SourceFiles0=$stage\");$sed.Add('');$sed.Add('[SourceFiles0]');for($i=0;$i -lt $files.Count;$i++){ $sed.Add(('%FILE{0}%=' -f $i)) }
$sedPath = Join-Path $stage 'JARVIS-NATIVE-v1.sed'; [IO.File]::WriteAllLines($sedPath,$sed,[Text.Encoding]::ASCII)
& $iexpress /N /Q $sedPath
if ($LASTEXITCODE -ne 0) { Fail "IExpress exited with $LASTEXITCODE" }
$deadline=[DateTime]::UtcNow.AddSeconds(90); while(-not(Test-Path -LiteralPath $OutputPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Seconds 1}; if(-not(Test-Path -LiteralPath $OutputPath -PathType Leaf)){Fail 'IExpress did not create the EXE.'}
$exeHash=Get-Sha256 $OutputPath; [IO.File]::WriteAllText("$OutputPath.sha256.txt","$exeHash  $(Split-Path -Leaf $OutputPath)",[Text.Encoding]::ASCII)
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "Audit stage: $stage" -ForegroundColor Cyan
