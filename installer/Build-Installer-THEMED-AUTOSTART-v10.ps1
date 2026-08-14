[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$ReleaseId = 'themed-autostart-v10'

function Fail([string]$Message) { throw "JARVIS v10 installer: $Message" }

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

function Get-NewLine([string]$Text) {
    $crlf = ([string][char]13) + ([string][char]10)
    if ($Text.Contains($crlf)) { return $crlf }
    return [string][char]10
}

function Read-Utf8NoBom([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))) {
        Fail "Expected UTF-8 without a BOM: $Path"
    }
    try { return $Utf8NoBom.GetString($bytes) }
    catch [System.Text.DecoderFallbackException] { Fail "Expected valid UTF-8 text: $Path" }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Assert-Utf8NoBom([string]$Path) { $null = Read-Utf8NoBom $Path }

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
    $exitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -eq $exitCode -or [int]$exitCode.Value -ne 0) { Fail "Node syntax check failed: $Path" }
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
            'app/windows-control/Invoke-NexusControl.ps1',
            'app/windows-theme/Enable-Nexus-Desktop.ps1',
            'app/windows-theme/Sync-Nexus-Theme.ps1',
            'desktop-shell/JarvisPet.exe',
            'runtime/node.exe',
            'launcher/Install-Local-Brain.ps1',
            'launcher/Start-Jarvis-RELEASE.ps1',
            'launcher/Start-Jarvis-RELEASE.cmd'
        )
    ) -or $RelativePath -like 'app/assets/*'
}

function Assert-CleanPayload([string]$PayloadRoot) {
    $allItems = Get-ChildItem -LiteralPath $PayloadRoot -Force -Recurse
    $forbidden = $allItems | Where-Object {
        $leaf = $_.Name.ToLowerInvariant()
        ($leaf -in @('.env', '.git', 'data', 'logs', 'log', 'backups', 'backup', 'server.mjs', 'omega-server.mjs', 'public-omega', 'public-ultra', 'capture-nexusscreen.ps1')) -or
        ($leaf -like '*conversation*') -or ($leaf -like '*memory*') -or ($leaf -like '*profile*') -or
        ($leaf -like '*task*') -or ($leaf -like '*event*') -or ($leaf -like '*.log') -or
        ($leaf -like '*.bak') -or ($leaf -like '*.sqlite') -or ($leaf -like '*.db')
    } | Select-Object -First 1
    if ($null -ne $forbidden) { Fail "Forbidden content entered payload: $($forbidden.FullName)" }

    foreach ($file in Get-ChildItem -LiteralPath $PayloadRoot -Force -File -Recurse) {
        $relative = Get-RelativeZipPath $PayloadRoot $file.FullName
        if (-not (Test-AllowedPayloadFile $relative)) { Fail "Payload file violates the exact allow-list: $relative" }
        if ($file.Extension -in @('.js', '.mjs', '.json', '.ps1', '.cmd', '.html', '.css', '.txt')) {
            $text = Read-Utf8NoBom $file.FullName
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
    if ($null -ne (Compare-Object -ReferenceObject $expected -DifferenceObject $actual)) { Fail 'Archive entries differ from the staged payload.' }
    foreach ($entry in $actual) {
        if (-not (Test-AllowedPayloadFile $entry)) { Fail "Archive entry violates the exact allow-list: $entry" }
    }
}

function Assert-V9Stage([string]$PayloadRoot, [string]$ServerPath, [string]$LauncherPath, [string]$CorePath, [string]$OuterPath, [string]$LocalBrainPath) {
    foreach ($path in @($ServerPath, $LauncherPath, $CorePath, $OuterPath, $LocalBrainPath)) { Assert-Utf8NoBom $path }
    $capture = Join-Path $PayloadRoot 'app\windows-control\Capture-NexusScreen.ps1'
    if (Test-Path -LiteralPath $capture) { Fail 'Capture-NexusScreen.ps1 must not be staged.' }
    $controls = @(Get-ChildItem -LiteralPath (Join-Path $PayloadRoot 'app\windows-control') -File -Force)
    if ($controls.Count -ne 1 -or $controls[0].Name -ne 'Invoke-NexusControl.ps1') { Fail 'Payload must ship only Invoke-NexusControl.ps1.' }

    $server = Read-Utf8NoBom $ServerPath
    if ($server -notmatch "provider: 'local'") { Fail 'Local provider is not the v10 default.' }
    if ($server -notmatch "provider: \['local', 'openai'\]\.includes\(value\.provider\) \? value\.provider : 'local'") { Fail 'Provider sanitizer does not default to local.' }
    if ($server -notmatch "state\.settings\.provider === 'local'\) return null;") { Fail 'Local provider cloud guard is missing.' }
    if ($server -match 'if \(reply === null\) reply = await askCloud') { Fail 'Cloud fallback remains in the local route.' }
    if ($server -notmatch "state\.settings\.provider === 'openai'") { Fail 'Explicit provider dispatcher is missing.' }
    if ($server -notmatch "const releaseId = '$ReleaseId';" -or $server -notmatch '    releaseId,') { Fail 'Release identity is missing from bootstrap.' }

    $launcher = Read-Utf8NoBom $LauncherPath
    if ($launcher -match '(?i)msedge|--app=|Start-Process\s+\$Uri') { Fail 'Native launcher still contains browser launch behavior.' }
    if ($launcher -notmatch 'JarvisPet\.exe') { Fail 'Native launcher does not start JarvisPet.' }
    if ($launcher -notmatch [regex]::Escape($ReleaseId)) { Fail 'Native launcher does not require the staged release identity.' }

    $core = Read-Utf8NoBom $CorePath
    if ($core -notmatch 'Stop-ExactJarvisUpgrade') { Fail 'Upgrade shutdown guard is missing.' }
    if ($core -notmatch "Name='msedge\.exe'") { Fail 'Legacy Edge cleanup is missing.' }
    if ($core -notmatch "Name='JarvisPet\.exe'") { Fail 'Exact JarvisPet cleanup is missing.' }

    $brain = Read-Utf8NoBom $LocalBrainPath
    if ($brain -match '(?i)Invoke-Expression|install\.ps1') { Fail 'Remote script execution remains in Local Brain setup.' }
    if ($brain -notmatch 'OllamaSetup\.exe|Get-AuthenticodeSignature') { Fail 'Signed OllamaSetup.exe flow is missing.' }
    $outer = Read-Utf8NoBom $OuterPath
    if ($outer -notmatch 'Start-LocalBrainSetup') { Fail 'Detached Local Brain setup is missing.' }
    if ($outer -match '& \$scriptPath -Interactive') { Fail 'Local Brain setup would block the installer UI.' }
}

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $project 'release\JARVIS-NEXUS-ULTRA-Setup-THEMED-AUTOSTART-v10.exe' }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { Fail "Refusing to overwrite $OutputPath" }
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if ($WorkRoot -match '\s|[^\x20-\x7E]') { Fail 'WorkRoot must be ASCII and contain no spaces.' }
Ensure $WorkRoot
Ensure (Split-Path -Parent $OutputPath)

$outerPs1 = Need (Join-Path $installer 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1')
$outerCmd = Need (Join-Path $installer 'Install-Jarvis-THEMED-AUTOSTART-v3.cmd')
$coreV3 = Need (Join-Path $installer 'Install-Jarvis-CORE-v3.ps1')
$launcherCmd = Need (Join-Path $installer 'Start-Jarvis-RELEASE-v2.cmd')
$desktopV3 = Need (Join-Path $project 'windows-theme\Enable-Nexus-Desktop-v3.ps1')
$syncV2 = Need (Join-Path $project 'windows-theme\Sync-Nexus-Theme-v2.ps1')
$server = Need (Join-Path $project 'ultra-server.mjs')
$packageJson = Need (Join-Path $project 'package.json')
$assets = Need (Join-Path $project 'assets') $true
$invokeNexusControl = Need (Join-Path $project 'windows-control\Invoke-NexusControl.ps1')
$petExe = Need (Join-Path $project 'desktop-shell\dist\JarvisPet.exe')
foreach ($path in @($outerPs1, $coreV3, $desktopV3, $syncV2, $invokeNexusControl)) { Assert-Parse $path }

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
Assert-NodeSyntax $node $server

$iexpress = @((Join-Path $env:WINDIR 'System32\iexpress.exe'), (Join-Path $env:WINDIR 'SysWOW64\iexpress.exe')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iexpress) { Fail 'IExpress was not found.' }

$stage = Join-Path $WorkRoot ('THEMED-AUTOSTART-v10-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$app = Join-Path $payload 'app'
$runtime = Join-Path $payload 'runtime'
$launcher = Join-Path $payload 'launcher'
$desktopShell = Join-Path $payload 'desktop-shell'
$themes = Join-Path $app 'windows-theme'
$controls = Join-Path $app 'windows-control'
New-Item -ItemType Directory -Path $app, $runtime, $launcher, $desktopShell, $themes, $controls -ErrorAction Stop | Out-Null

Copy-Item -LiteralPath $server -Destination $app -Force
Copy-Item -LiteralPath $packageJson -Destination $app -Force
Copy-Item -LiteralPath $assets -Destination $app -Recurse -Force
Copy-Item -LiteralPath $desktopV3 -Destination (Join-Path $themes 'Enable-Nexus-Desktop.ps1') -Force
Copy-Item -LiteralPath $syncV2 -Destination (Join-Path $themes 'Sync-Nexus-Theme.ps1') -Force
Copy-Item -LiteralPath $invokeNexusControl -Destination (Join-Path $controls 'Invoke-NexusControl.ps1') -Force
Copy-Item -LiteralPath $petExe -Destination (Join-Path $desktopShell 'JarvisPet.exe') -Force
Copy-Item -LiteralPath $node -Destination (Join-Path $runtime 'node.exe') -Force

$stagedServer = Join-Path $app 'ultra-server.mjs'
$serverText = Read-Utf8NoBom $stagedServer
$serverNl = Get-NewLine $serverText
$serverText = Replace-Exactly $serverText "  provider: 'auto'," "  provider: 'local'," 'default local provider'
$serverText = Replace-Exactly $serverText "provider: ['auto', 'local', 'openai'].includes(value.provider) ? value.provider : 'auto'," "provider: ['local', 'openai'].includes(value.provider) ? value.provider : 'local'," 'local provider sanitizer'
$serverText = Replace-Exactly $serverText "settings: { ...state.settings, cloudConnected: Boolean(process.env.OPENAI_API_KEY), themeBackupExists: false }," "settings: { ...state.settings, cloudConnected: state.settings.provider === 'openai' && Boolean(process.env.OPENAI_API_KEY), themeBackupExists: false }," 'cloud status privacy'
$serverText = Replace-Exactly $serverText 'function publicState() {' ("function publicState() {" + $serverNl + "  const releaseId = '$ReleaseId';") 'release identity declaration'
$serverText = Replace-Exactly $serverText '    settings: { ...state.settings, cloudConnected:' ("    releaseId," + $serverNl + '    settings: { ...state.settings, cloudConnected:') 'release identity response'
$serverText = Replace-Exactly $serverText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'cloud history slice'
$localBrainSource = @'
async function askLocalBrain(message) {
  if (process.env.JARVIS_DISABLE_LOCAL_BRAIN === '1') return null;
  const models = process.env.OLLAMA_MODEL ? [process.env.OLLAMA_MODEL] : ['llama3.1:8b', 'llama3.2'];
  const history = state.conversations.slice(-15, -1).map((turn) => ({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: turn.text }));
  for (const model of models) {
    try {
      const response = await fetch('http://127.0.0.1:11434/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model, messages: [{ role: 'system', content: systemPrompt() }, ...history, { role: 'user', content: message }], stream: false }),
        signal: AbortSignal.timeout(60000),
      });
      if (!response.ok) continue;
      const payload = await response.json();
      const reply = clean(payload && payload.message && payload.message.content, 1800);
      if (reply) return reply;
    } catch {
      continue;
    }
  }
  return null;
}

'@
$serverText = Replace-Exactly $serverText 'async function askCloud(message) {' ($localBrainSource + 'async function askCloud(message) {') 'local brain insertion'
$providerRoute = @'
    if (state.settings.provider === 'openai') {
      reply = await askCloud(message);
    } else {
      reply = await askLocalBrain(message);
    }
'@
$serverText = Replace-Exactly $serverText '    reply = await askCloud(message);' $providerRoute 'explicit provider dispatcher'
Write-Utf8NoBom $stagedServer $serverText
Assert-NodeSyntax $node $stagedServer

$stagedLauncher = Join-Path $launcher 'Start-Jarvis-RELEASE.ps1'
$nativeLauncher = @'
<#
.SYNOPSIS
  Starts the installed JARVIS server and native JarvisPet window only.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ReleaseId = 'themed-autostart-v10'
$InstallRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $InstallRoot 'app'
$NodePath = Join-Path $InstallRoot 'runtime\node.exe'
$ServerPath = Join-Path $AppRoot 'ultra-server.mjs'
$PetPath = Join-Path $InstallRoot 'desktop-shell\JarvisPet.exe'
$BootstrapUri = 'http://127.0.0.1:3791/api/bootstrap'

function Test-JarvisEndpoint {
    try {
        $boot = Invoke-RestMethod -Uri $BootstrapUri -TimeoutSec 1
        return $null -ne $boot.settings -and [string]$boot.settings.assistantName -eq 'JARVIS' -and [string]$boot.releaseId -eq $ReleaseId
    }
    catch { return $false }
}

function Test-ExactPetRunning {
    $expectedPath = [System.IO.Path]::GetFullPath($PetPath)
    $pets = Get-CimInstance -ClassName Win32_Process -Filter "Name='JarvisPet.exe'" -ErrorAction SilentlyContinue
    return $null -ne ($pets | Where-Object {
        $_.ExecutablePath -and [string]::Equals([System.IO.Path]::GetFullPath($_.ExecutablePath), $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
}

foreach ($required in @($NodePath, $ServerPath, $PetPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "JARVIS component missing: $required" }
}
New-Item -ItemType Directory -Path (Join-Path $AppRoot 'data') -Force | Out-Null
if (-not (Test-JarvisEndpoint)) {
    Start-Process -FilePath $NodePath -ArgumentList ('"{0}"' -f $ServerPath) -WorkingDirectory $AppRoot -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-JarvisEndpoint)) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-JarvisEndpoint)) { throw 'The staged JARVIS server did not become ready on its local endpoint.' }
}
if (-not (Test-ExactPetRunning)) {
    Start-Process -FilePath $PetPath -WorkingDirectory (Split-Path -Parent $PetPath)
}
'@
Write-Utf8NoBom $stagedLauncher $nativeLauncher
Assert-Parse $stagedLauncher

$stagedLauncherCmd = Join-Path $launcher 'Start-Jarvis-RELEASE.cmd'
$launcherCmdText = Read-Utf8NoBom $launcherCmd
$launcherCmdText = Replace-Exactly $launcherCmdText 'Start-Jarvis-RELEASE-v2.ps1' 'Start-Jarvis-RELEASE.ps1' 'stable launcher command target'
Write-Utf8NoBom $stagedLauncherCmd $launcherCmdText
Assert-Utf8NoBom $stagedLauncherCmd

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

function Install-SignedOllama {
    $downloadRoot = Join-Path $env:TEMP ('JARVIS-Ollama-' + [guid]::NewGuid().ToString('N'))
    $setupPath = Join-Path $downloadRoot 'OllamaSetup.exe'
    New-Item -ItemType Directory -Path $downloadRoot -ErrorAction Stop | Out-Null
    try {
        $oldProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setupPath -UseBasicParsing
        }
        finally { $ProgressPreference = $oldProgress }
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'OllamaSetup.exe was not downloaded.' }
        $signature = Get-AuthenticodeSignature -FilePath $setupPath
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)ollama') {
            throw "OllamaSetup.exe signature is not a valid Ollama signature: $($signature.Status)."
        }
        $process = Start-Process -FilePath $setupPath -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "OllamaSetup.exe exited with code $($process.ExitCode)." }
    }
    finally {
        if (Test-Path -LiteralPath $downloadRoot -PathType Container) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
    }
}

function Assert-OllamaExit([string]$Operation) {
    $exitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -ne $exitCode -and [int]$exitCode.Value -ne 0) { throw "$Operation exited with code $($exitCode.Value)." }
}

if (-not $Interactive) { throw 'Interactive consent is required for Local Brain setup.' }
$baselineModel = 'llama3.1:8b'
$fastFallbackModel = 'llama3.2'
$ollama = Find-Ollama
if ($null -eq $ollama) {
    if (-not (Confirm-LocalBrain 'Ollama is not installed. Download the signed official OllamaSetup.exe now?' 'JARVIS Local Brain')) {
        Write-Host 'Local Brain setup skipped.'
        exit 0
    }
    Install-SignedOllama
    $ollama = Find-Ollama
    if ($null -eq $ollama) { throw 'Ollama installation did not make ollama available.' }
}
if (-not (Confirm-LocalBrain 'Download the default smart local model llama3.1:8b now? It needs about 5 GB of disk space.' 'JARVIS Local Brain')) {
    Write-Host 'Local Brain model download skipped.'
    exit 0
}
& $ollama pull $baselineModel
Assert-OllamaExit 'Ollama baseline model download'
if (Confirm-LocalBrain 'Optionally download llama3.2 as a smaller, faster local fallback?' 'JARVIS Local Brain') {
    & $ollama pull $fastFallbackModel
    Assert-OllamaExit 'Ollama fast fallback model download'
}
Write-Host 'Local Brain baseline is ready.'
'@
$localBrainPath = Join-Path $launcher 'Install-Local-Brain.ps1'
Write-Utf8NoBom $localBrainPath $localBrainScript
Assert-Parse $localBrainPath

$stagedCore = Join-Path $stage 'Install-Jarvis-CORE-v2.ps1'
$coreText = Read-Utf8NoBom $coreV3
$coreNl = Get-NewLine $coreText
$upgradeFunctions = @'
function Test-ExactProcessPath([string]$ActualPath, [string]$ExpectedPath) {
    if ([string]::IsNullOrWhiteSpace($ActualPath)) { return $false }
    try {
        return [string]::Equals([System.IO.Path]::GetFullPath($ActualPath), [System.IO.Path]::GetFullPath($ExpectedPath), [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Stop-ExactJarvisUpgrade([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $oldNode = Join-Path $Root 'runtime\node.exe'
    $oldServer = Join-Path $Root 'app\ultra-server.mjs'
    $oldPet = Join-Path $Root 'desktop-shell\JarvisPet.exe'
    try {
        $nodes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)
        $pets = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='JarvisPet.exe'" -ErrorAction Stop)
        $edges = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop)
    }
    catch {
        throw "Cannot safely inspect existing JARVIS processes: $($_.Exception.Message)"
    }
    $targets = @()
    $targets += $nodes | Where-Object {
        (Test-ExactProcessPath $_.ExecutablePath $oldNode) -and $_.CommandLine -and $_.CommandLine -match [regex]::Escape($oldServer)
    } | ForEach-Object { [pscustomobject]@{ Process = $_; Label = 'installed JARVIS node server' } }
    $targets += $pets | Where-Object {
        Test-ExactProcessPath $_.ExecutablePath $oldPet
    } | ForEach-Object { [pscustomobject]@{ Process = $_; Label = 'installed JarvisPet' } }
    $legacyEdgePattern = '(?i)(?:^|\s)--app=(?:"?http://127\.0\.0\.1:3791/?(?:"?))(?=\s|$)'
    $targets += $edges | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $legacyEdgePattern
    } | ForEach-Object { [pscustomobject]@{ Process = $_; Label = 'legacy JARVIS Edge app window' } }
    $targets = @($targets | Group-Object { [int]$_.Process.ProcessId } | ForEach-Object { $_.Group[0] })
    foreach ($target in $targets) {
        try { Stop-Process -Id ([int]$target.Process.ProcessId) -Force -ErrorAction Stop }
        catch { throw "Could not stop $($target.Label) (PID $($target.Process.ProcessId)): $($_.Exception.Message)" }
    }
    foreach ($target in $targets) {
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id ([int]$target.Process.ProcessId) -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 150
        }
        if (Get-Process -Id ([int]$target.Process.ProcessId) -ErrorAction SilentlyContinue) {
            throw "$($target.Label) did not stop; upgrade was not overlaid."
        }
    }
}

'@
$coreText = Replace-Exactly $coreText '$manifest = Get-Manifest' ($upgradeFunctions + '$manifest = Get-Manifest') 'upgrade function insertion'
$coreText = Replace-Exactly $coreText 'foreach ($name in @(''app'', ''runtime'', ''launcher'')) {' 'foreach ($name in @(''app'', ''runtime'', ''launcher'', ''desktop-shell'')) {' 'core desktop shell copy list'
$coreTryAnchor = 'try {' + $coreNl + '    Add-Type -AssemblyName System.IO.Compression.FileSystem'
$coreTryReplacement = 'try {' + $coreNl + '    Stop-ExactJarvisUpgrade -Root $installRoot' + $coreNl + '    Add-Type -AssemblyName System.IO.Compression.FileSystem'
$coreText = Replace-Exactly $coreText $coreTryAnchor $coreTryReplacement 'upgrade shutdown before overlay'
$coreLauncherAnchor = '    $launcher = Join-Path $installRoot ''launcher\Start-Jarvis-RELEASE.cmd'''
$coreLauncherReplacement = $coreLauncherAnchor + $coreNl + '    $petPath = Join-Path $installRoot ''desktop-shell\JarvisPet.exe''' + $coreNl + '    $localBrainPath = Join-Path $installRoot ''launcher\Install-Local-Brain.ps1'''
$coreText = Replace-Exactly $coreText $coreLauncherAnchor $coreLauncherReplacement 'core native verification paths'
$coreText = Replace-Exactly $coreText 'foreach ($required in @($serverPath, $nodePath, $launcher)) {' 'foreach ($required in @($serverPath, $nodePath, $launcher, $petPath, $localBrainPath)) {' 'core native verification list'
Write-Utf8NoBom $stagedCore $coreText
Assert-Parse $stagedCore

$outerText = Read-Utf8NoBom $outerPs1
$outerNl = Get-NewLine $outerText
$outerParamAnchor = '    [switch]$EnableAutostart' + $outerNl + ')'
$outerParamReplacement = '    [switch]$EnableAutostart,' + $outerNl + '    [switch]$SetupLocalBrain' + $outerNl + ')'
$outerText = Replace-Exactly $outerText $outerParamAnchor $outerParamReplacement 'outer parameter list'
$setupFunction = @'
function Start-LocalBrainSetup {
    $scriptPath = Join-Path $InstallRoot 'launcher\Install-Local-Brain.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Installed Local Brain module missing: $scriptPath" }
    $systemPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $quote = [char]34
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $quote + $scriptPath + $quote + ' -Interactive'
    Start-Process -FilePath $systemPowerShell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

'@
$outerText = Replace-Exactly $outerText 'function Enable-NexusDesktop {' ($setupFunction + 'function Enable-NexusDesktop {') 'outer detached local brain function'
$autostartTag = '            <CheckBox x:Name="EnableAutostart" IsChecked="True" Content="Start JARVIS automatically when I sign in" Margin="2,4" Foreground="#DDFBFF"/>'
$localBrainTag = '            <CheckBox x:Name="SetupLocalBrain" IsChecked="True" Content="Optionally set up Local Brain (Ollama, about 5 GB)" Margin="2,4" Foreground="#DDFBFF"/>'
$outerText = Replace-Exactly $outerText $autostartTag ($autostartTag + $outerNl + $localBrainTag) 'outer local brain checkbox'
$lookupAnchor = '    $enableAutostart = $window.FindName(''EnableAutostart'')'
$lookupReplacement = $lookupAnchor + $outerNl + '    $setupLocalBrain = $window.FindName(''SetupLocalBrain'')'
$outerText = Replace-Exactly $outerText $lookupAnchor $lookupReplacement 'outer local brain lookup'
$autostartBlock = '            if ([bool]$enableAutostart.IsChecked) {' + $outerNl + '                $status.Text = ''ARMING LOCAL AUTOSTART...''' + $outerNl + '                Enable-JarvisAutostart' + $outerNl + '            }'
$brainBlock = $autostartBlock + $outerNl + '            if ([bool]$setupLocalBrain.IsChecked) {' + $outerNl + '                $status.Text = ''STARTING OPTIONAL LOCAL BRAIN...''' + $outerNl + '                Start-LocalBrainSetup' + $outerNl + '            }'
$outerText = Replace-Exactly $outerText $autostartBlock $brainBlock 'outer detached local brain click flow'
$quietBlock = '    if ($EnableAutostart) { Enable-JarvisAutostart }' + $outerNl + '}'
$quietReplacement = '    if ($EnableAutostart) { Enable-JarvisAutostart }' + $outerNl + '    if ($SetupLocalBrain) { Write-Warning ''Local Brain setup is skipped in quiet mode because it requires interactive consent.'' }' + $outerNl + '}'
$outerText = Replace-Exactly $outerText $quietBlock $quietReplacement 'quiet local brain guard'
$stagedOuter = Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.ps1'
Write-Utf8NoBom $stagedOuter $outerText
Assert-Parse $stagedOuter

$stagedOuterCmd = Join-Path $stage 'Install-Jarvis-THEMED-AUTOSTART-v3.cmd'
Write-Utf8NoBom $stagedOuterCmd (Read-Utf8NoBom $outerCmd)
Assert-Utf8NoBom $stagedOuterCmd
Assert-V9Stage $payload $stagedServer $stagedLauncher $stagedCore $stagedOuter $localBrainPath
Assert-CleanPayload $payload

$zip = Join-Path $stage 'payload.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
Assert-ArchiveMatchesPayload $payload $zip
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$package = Read-Utf8NoBom $packageJson | ConvertFrom-Json
$manifest = [ordered]@{
    product = 'JARVIS NEXUS ULTRA'
    version = [string]$package.version
    releaseId = $ReleaseId
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    payloadFile = 'payload.zip'
    payloadSha256 = $zipHash
    nodeVersion = $nodeVersion
    installScope = 'CurrentUser'
    privacy = 'Exact allow-list; no .env, data, chats, browser UI, cloud-screen capture, profiles, memory, tasks, events, logs, backups, API credentials, or model files.'
    client = 'Native JarvisPet.exe only; no browser or Edge app is launched.'
    localBrain = 'Optional signed OllamaSetup.exe download; model setup runs outside the installer UI and no model is bundled.'
}
$manifestPath = Join-Path $stage 'installer-manifest.json'
Write-Utf8NoBom $manifestPath (($manifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
$payloadHashPath = Join-Path $stage 'payload.sha256'
[System.IO.File]::WriteAllText($payloadHashPath, "$zipHash  payload.zip$([Environment]::NewLine)", [System.Text.Encoding]::ASCII)

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
$sedPath = Join-Path $stage 'JARVIS-NEXUS-THEMED-AUTOSTART-v10.sed'
[System.IO.File]::WriteAllLines($sedPath, [string[]]$sed, [System.Text.Encoding]::ASCII)

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
[System.IO.File]::WriteAllText($checksum, "$hash  $(Split-Path -Leaf $OutputPath)$([Environment]::NewLine)", [System.Text.Encoding]::ASCII)
Write-Host "EXE: $OutputPath" -ForegroundColor Cyan
Write-Host "SHA256: $checksum" -ForegroundColor Cyan
Write-Host "Audit stage: $stage" -ForegroundColor DarkCyan
exit 0
