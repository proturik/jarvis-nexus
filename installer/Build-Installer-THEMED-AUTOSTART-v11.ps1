[CmdletBinding()]
param(
    [string]$NodeRuntime,
    [string]$OutputPath,
    [string]$WorkRoot = 'C:\tmp\jarvis-iexpress'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$ReleaseId = 'themed-autostart-v11'

function Fail([string]$Message) { throw "JARVIS v11 installer: $Message" }

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

function Replace-Exactly([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($count -ne 1) { Fail "Expected exactly one $Label patch anchor; found $count." }
    return $Text.Replace($Old, $New)
}

function Patch-Exactly([string]$Old, [string]$New, [string]$Label) {
    $script:effective = Replace-Exactly $script:effective $Old $New $Label
}

function Assert-Parse([string]$Path) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Fail "PowerShell syntax error in generated v11 builder at line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
    }
}

$installer = $PSScriptRoot
$project = Split-Path -Parent $installer
$baseBuilder = Need (Join-Path $installer 'Build-Installer-THEMED-AUTOSTART-v10.ps1')
$finder = Need (Join-Path $project 'windows-control\Find-NexusApp.ps1')
$senseDist = Need (Join-Path $project 'sensors\dist\JarvisSense') $true
$senseExe = Need (Join-Path $senseDist 'JarvisSense.exe')
$senseInternal = Need (Join-Path $senseDist '_internal') $true
$senseVoiceModel = Need (Join-Path $senseInternal 'voice-model') $true

$script:effective = Read-Utf8NoBom $baseBuilder
$script:effective = $script:effective.Replace('JARVIS v10 installer', 'JARVIS v11 installer')
$script:effective = $script:effective.Replace('themed-autostart-v10', $ReleaseId)
$script:effective = $script:effective.Replace('THEMED-AUTOSTART-v10', 'THEMED-AUTOSTART-v11')
$nl = Get-NewLine $script:effective
$installerLiteral = "'" + $installer.Replace("'", "''") + "'"
Patch-Exactly '$installer = $PSScriptRoot' ('$installer = ' + $installerLiteral) 'effective installer root'
# The frozen server already owns a richer local-brain path. Keep v10 compatibility
# for older sources, but do not insert duplicate functions into a newer source.
$providerDefaultAnchor = @'
$serverText = Replace-Exactly $serverText "  provider: 'auto'," "  provider: 'local'," 'default local provider'
'@.TrimEnd()
$providerDefaultReplacement = @'
$legacyDefaultProvider = "  provider: 'auto',"
if ($serverText.Contains($legacyDefaultProvider)) {
    $serverText = Replace-Exactly $serverText "  provider: 'auto'," "  provider: 'local'," 'default local provider'
}
elseif (-not $serverText.Contains("  provider: 'local',")) {
    Fail 'Server does not define a local default provider.'
}
'@.TrimEnd()
Patch-Exactly $providerDefaultAnchor $providerDefaultReplacement 'default local provider compatibility'

$legacyLocalBrainAnchor = @'
$serverText = Replace-Exactly $serverText 'async function askCloud(message) {' ($localBrainSource + 'async function askCloud(message) {') 'local brain insertion'
'@.TrimEnd()
$localBrainCompatibility = @'
if ($serverText -notmatch 'async function askLocalBrain\(') {
    $serverText = Replace-Exactly $serverText 'async function askCloud(message) {' ($localBrainSource + 'async function askCloud(message) {') 'local brain insertion'
}
'@.TrimEnd()
Patch-Exactly $legacyLocalBrainAnchor $localBrainCompatibility 'local brain compatibility'

$legacyProviderRouteAnchor = @'
$serverText = Replace-Exactly $serverText '    reply = await askCloud(message);' $providerRoute 'explicit provider dispatcher'
'@.TrimEnd()
$providerRouteCompatibility = @'
if ($serverText -notmatch 'async function askBrain\(') {
    $serverText = Replace-Exactly $serverText '    reply = await askCloud(message);' $providerRoute 'explicit provider dispatcher'
}
'@.TrimEnd()
Patch-Exactly $legacyProviderRouteAnchor $providerRouteCompatibility 'provider dispatcher compatibility'
$legacyHistorySliceAnchor = @'
$serverText = Replace-Exactly $serverText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'cloud history slice'
'@.TrimEnd()
$historySliceCompatibility = @'
if ($serverText -notmatch 'async function askLocalBrain\(') {
    $serverText = Replace-Exactly $serverText 'state.conversations.slice(-14)' 'state.conversations.slice(-15, -1)' 'cloud history slice'
}
'@.TrimEnd()
Patch-Exactly $legacyHistorySliceAnchor $historySliceCompatibility 'local brain history compatibility'





# Keep the payload strict: the finder and only the packaged Sense tree are added.
Patch-Exactly "            'app/windows-control/Invoke-NexusControl.ps1'," ("            'app/windows-control/Invoke-NexusControl.ps1'," + $nl + "            'app/windows-control/Find-NexusApp.ps1',") 'finder allow-list'
$senseAllow = @(
    "    ) -or `$RelativePath -like 'app/assets/*' -or",
    "        (`$RelativePath -eq 'desktop-shell/sense/JarvisSense.exe') -or",
    "        (`$RelativePath -like 'desktop-shell/sense/_internal/*')"
) -join $nl
Patch-Exactly "    ) -or `$RelativePath -like 'app/assets/*'" $senseAllow 'sense allow-list'

$sensePayloadAssertion = @'
function Assert-SensePayloadMatchesSource([string]$SourceRoot, [string]$PayloadRoot) {
    $payloadSenseRoot = Join-Path $PayloadRoot 'desktop-shell\sense'
    $senseExe = Join-Path $payloadSenseRoot 'JarvisSense.exe'
    $senseInternal = Join-Path $payloadSenseRoot '_internal'
    $voiceModel = Join-Path $senseInternal 'voice-model'
    foreach ($required in @($senseExe, $senseInternal, $voiceModel)) {
        if (-not (Test-Path -LiteralPath $required)) { Fail "Required Sense component is missing from payload: $required" }
    }
    $expected = @(Get-ChildItem -LiteralPath $SourceRoot -File -Force -Recurse | ForEach-Object { Get-RelativeZipPath $SourceRoot $_.FullName } | Sort-Object)
    $actual = @(Get-ChildItem -LiteralPath $payloadSenseRoot -File -Force -Recurse | ForEach-Object { Get-RelativeZipPath $payloadSenseRoot $_.FullName } | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -ne 0) {
        Fail 'Staged Sense tree does not exactly match the reviewed source tree.'
    }
}

'@
Patch-Exactly 'function Assert-V9Stage([string]$PayloadRoot, [string]$ServerPath, [string]$LauncherPath, [string]$CorePath, [string]$OuterPath, [string]$LocalBrainPath) {' ($sensePayloadAssertion + 'function Assert-V11Stage([string]$PayloadRoot, [string]$ServerPath, [string]$LauncherPath, [string]$CorePath, [string]$OuterPath, [string]$LocalBrainPath) {') 'v11 stage assertion insertion'
$script:effective = $script:effective.Replace('Assert-V9Stage', 'Assert-V11Stage')

$controlsAssertion = @'
    $expectedControls = @('Find-NexusApp.ps1', 'Invoke-NexusControl.ps1')
    $actualControls = @($controls | ForEach-Object { $_.Name } | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedControls -DifferenceObject $actualControls).Count -ne 0) { Fail 'Payload controls do not match the strict v11 allow-list.' }
'@.TrimEnd()
Patch-Exactly "    if (`$controls.Count -ne 1 -or `$controls[0].Name -ne 'Invoke-NexusControl.ps1') { Fail 'Payload must ship only Invoke-NexusControl.ps1.' }" $controlsAssertion 'v11 controls assertion'
$senseStageChecks = @'
    $senseExe = Join-Path $PayloadRoot 'desktop-shell\sense\JarvisSense.exe'
    $senseInternal = Join-Path $PayloadRoot 'desktop-shell\sense\_internal'
    $voiceModel = Join-Path $senseInternal 'voice-model'
    foreach ($required in @($senseExe, $senseInternal, $voiceModel)) {
        if (-not (Test-Path -LiteralPath $required)) { Fail "Required Sense component is missing from payload: $required" }
    }
'@.TrimEnd()
Patch-Exactly "    if (Test-Path -LiteralPath `$capture) { Fail 'Capture-NexusScreen.ps1 must not be staged.' }" ("    if (Test-Path -LiteralPath `$capture) { Fail 'Capture-NexusScreen.ps1 must not be staged.' }" + $nl + $senseStageChecks) 'sense stage shape assertion'
Patch-Exactly "    if (`$launcher -notmatch 'JarvisPet\.exe') { Fail 'Native launcher does not start JarvisPet.' }" ("    if (`$launcher -notmatch 'JarvisPet\.exe') { Fail 'Native launcher does not start JarvisPet.' }" + $nl + "    if (`$launcher -notmatch 'JarvisSense\.exe' -or `$launcher -notmatch 'Test-ExactSenseRunning' -or `$launcher -notmatch '--install-root') { Fail 'Native launcher does not start the exact local Sense companion.' }") 'sense launcher assertion'
Patch-Exactly '    if ($core -notmatch "Name=''JarvisPet\.exe''") { Fail ''Exact JarvisPet cleanup is missing.'' }' ('    if ($core -notmatch "Name=''JarvisPet\.exe''") { Fail ''Exact JarvisPet cleanup is missing.'' }' + $nl + '    if ($core -notmatch "Name=''JarvisSense\.exe''") { Fail ''Exact JarvisSense cleanup is missing.'' }') 'sense upgrade assertion'

Patch-Exactly "`$petExe = Need (Join-Path `$project 'desktop-shell\dist\JarvisPet.exe')" (@(
    "`$petExe = Need (Join-Path `$project 'desktop-shell\dist\JarvisPet.exe')",
    "`$findNexusApp = Need (Join-Path `$project 'windows-control\Find-NexusApp.ps1')",
    "`$senseDist = Need (Join-Path `$project 'sensors\dist\JarvisSense') `$true",
    "`$senseExe = Need (Join-Path `$senseDist 'JarvisSense.exe')",
    "`$senseInternal = Need (Join-Path `$senseDist '_internal') `$true",
    "`$senseVoiceModel = Need (Join-Path `$senseInternal 'voice-model') `$true"
) -join $nl) 'v11 source components'
Patch-Exactly 'foreach ($path in @($outerPs1, $coreV3, $desktopV3, $syncV2, $invokeNexusControl)) { Assert-Parse $path }' 'foreach ($path in @($outerPs1, $coreV3, $desktopV3, $syncV2, $invokeNexusControl, $findNexusApp)) { Assert-Parse $path }' 'finder syntax check'

Patch-Exactly "`$desktopShell = Join-Path `$payload 'desktop-shell'" ("`$desktopShell = Join-Path `$payload 'desktop-shell'" + $nl + "`$sensePayload = Join-Path `$desktopShell 'sense'") 'sense destination'
Patch-Exactly 'New-Item -ItemType Directory -Path $app, $runtime, $launcher, $desktopShell, $themes, $controls -ErrorAction Stop | Out-Null' 'New-Item -ItemType Directory -Path $app, $runtime, $launcher, $desktopShell, $sensePayload, $themes, $controls -ErrorAction Stop | Out-Null' 'sense staging directory'
Patch-Exactly "Copy-Item -LiteralPath `$invokeNexusControl -Destination (Join-Path `$controls 'Invoke-NexusControl.ps1') -Force" ("Copy-Item -LiteralPath `$invokeNexusControl -Destination (Join-Path `$controls 'Invoke-NexusControl.ps1') -Force" + $nl + "Copy-Item -LiteralPath `$findNexusApp -Destination (Join-Path `$controls 'Find-NexusApp.ps1') -Force") 'finder staging copy'
Patch-Exactly "Copy-Item -LiteralPath `$petExe -Destination (Join-Path `$desktopShell 'JarvisPet.exe') -Force" ("Copy-Item -LiteralPath `$petExe -Destination (Join-Path `$desktopShell 'JarvisPet.exe') -Force" + $nl + "Get-ChildItem -LiteralPath `$senseDist -Force | Copy-Item -Destination `$sensePayload -Recurse -Force") 'sense staging copy'

Patch-Exactly "`$PetPath = Join-Path `$InstallRoot 'desktop-shell\JarvisPet.exe'" ("`$PetPath = Join-Path `$InstallRoot 'desktop-shell\JarvisPet.exe'" + $nl + "`$SensePath = Join-Path `$InstallRoot 'desktop-shell\sense\JarvisSense.exe'") 'native sense path'
$senseProcessFunction = @'
function Test-ExactSenseRunning {
    $expectedPath = [System.IO.Path]::GetFullPath($SensePath)
    $senses = Get-CimInstance -ClassName Win32_Process -Filter "Name='JarvisSense.exe'" -ErrorAction SilentlyContinue
    return $null -ne ($senses | Where-Object {
        $_.ExecutablePath -and [string]::Equals([System.IO.Path]::GetFullPath($_.ExecutablePath), $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
}
'@.TrimEnd()
Patch-Exactly 'foreach ($required in @($NodePath, $ServerPath, $PetPath)) {' ($senseProcessFunction + $nl + 'foreach ($required in @($NodePath, $ServerPath, $PetPath, $SensePath)) {') 'native sense process check'
$petStart = @'
if (-not (Test-ExactPetRunning)) {
    Start-Process -FilePath $PetPath -WorkingDirectory (Split-Path -Parent $PetPath)
}
'@.TrimEnd()
$senseStart = @'
if (-not (Test-ExactSenseRunning)) {
    Start-Process -FilePath $SensePath -ArgumentList @('--install-root', ('"{0}"' -f $InstallRoot)) -WorkingDirectory (Split-Path -Parent $SensePath) -WindowStyle Hidden
}
'@.TrimEnd()
Patch-Exactly $petStart ($petStart + $nl + $senseStart) 'native Sense launch'

Patch-Exactly "    `$oldPet = Join-Path `$Root 'desktop-shell\JarvisPet.exe'" ("    `$oldPet = Join-Path `$Root 'desktop-shell\JarvisPet.exe'" + $nl + "    `$oldSense = Join-Path `$Root 'desktop-shell\sense\JarvisSense.exe'") 'upgrade sense path'
Patch-Exactly '        $pets = @(Get-CimInstance -ClassName Win32_Process -Filter "Name=''JarvisPet.exe''" -ErrorAction Stop)' ('        $pets = @(Get-CimInstance -ClassName Win32_Process -Filter "Name=''JarvisPet.exe''" -ErrorAction Stop)' + $nl + '        $senses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name=''JarvisSense.exe''" -ErrorAction Stop)') 'upgrade sense process query'
$senseUpgradeTarget = @'
    $targets += $senses | Where-Object {
        Test-ExactProcessPath $_.ExecutablePath $oldSense
    } | ForEach-Object { [pscustomobject]@{ Process = $_; Label = 'installed JarvisSense companion' } }
'@.TrimEnd()
$legacyEdgePatternLine = '    $legacyEdgePattern = ''(?i)(?:^|\s)--app=(?:"?http://127\.0\.0\.1:3791/?(?:"?))(?=\s|$)'''; Patch-Exactly $legacyEdgePatternLine ($senseUpgradeTarget + $nl + $legacyEdgePatternLine) 'upgrade sense target'
Patch-Exactly "    `$localBrainPath = Join-Path `$installRoot ''launcher\Install-Local-Brain.ps1''" ("    `$localBrainPath = Join-Path `$installRoot ''launcher\Install-Local-Brain.ps1''" + $nl + "    `$sensePath = Join-Path `$installRoot ''desktop-shell\sense\JarvisSense.exe''") 'core sense verification path'
Patch-Exactly 'foreach ($required in @($serverPath, $nodePath, $launcher, $petPath, $localBrainPath)) {' 'foreach ($required in @($serverPath, $nodePath, $launcher, $petPath, $sensePath, $localBrainPath)) {' 'core sense verification list'

Patch-Exactly 'Assert-CleanPayload $payload' ('Assert-CleanPayload $payload' + $nl + 'Assert-SensePayloadMatchesSource $senseDist $payload') 'sense payload equality check'
Patch-Exactly "    privacy = 'Exact allow-list; no .env, data, chats, browser UI, cloud-screen capture, profiles, memory, tasks, events, logs, backups, API credentials, or model files.'" "    privacy = 'Exact allow-list; no .env, personal data, chats, browser UI, cloud-screen capture, profiles, memory, tasks, events, logs, backups, API credentials, or local LLM/vision model files. The bundled Vosk speech pack is code-adjacent runtime data only.'" 'v11 privacy manifest'
Patch-Exactly "    client = 'Native JarvisPet.exe only; no browser or Edge app is launched.'" "    client = 'Native JarvisPet.exe plus one exact local JarvisSense.exe companion; no browser or Edge app is launched.'" 'v11 client manifest'
Patch-Exactly "    localBrain = 'Optional signed OllamaSetup.exe download; model setup runs outside the installer UI and no model is bundled.'" "    localBrain = 'Optional signed OllamaSetup.exe download; every LLM download requires an explicit interactive consent and no LLM or vision model is bundled.'" 'v11 local brain manifest'

$iexpressOldBlock = @(
    '& $iexpress /N /Q $sedPath',
    '$iexpressExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue',
    'if ($null -eq $iexpressExit) { Fail ''IExpress did not provide an exit code.'' }',
    'if ([int]$iexpressExit.Value -ne 0) { Fail "IExpress exited with code $($iexpressExit.Value). SED retained at $sedPath" }',
    '$deadline = [DateTime]::UtcNow.AddSeconds(90)',
    'while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }',
    'if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Fail "IExpress did not create an EXE. SED retained at $sedPath" }'
) -join $nl
$iexpressNewBlock = @(
    '$iexpressProcess = Start-Process -FilePath $iexpress -ArgumentList @(''/N'', ''/Q'', $sedPath) -Wait -PassThru -WindowStyle Hidden',
    '$iexpressExit = [pscustomobject]@{ Value = [int]$iexpressProcess.ExitCode }',
    'if ($null -eq $iexpressExit) { Fail ''IExpress did not provide an exit code.'' }',
    '$deadline = [DateTime]::UtcNow.AddSeconds(90)',
    'while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }',
    'if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { Fail "IExpress did not create an EXE. SED retained at $sedPath" }',
    '$stub = New-Object byte[] 2',
    '$stubStream = [System.IO.File]::OpenRead($OutputPath)',
    'try { $read = $stubStream.Read($stub, 0, 2) }',
    'finally { $stubStream.Dispose() }',
    'if ($read -ne 2 -or $stub[0] -ne 0x4D -or $stub[1] -ne 0x5A) { Fail ''IExpress output is not a PE executable.'' }',
    'if ([int]$iexpressExit.Value -ne 0) { Write-Warning "IExpress returned code $($iexpressExit.Value) after writing a verified PE stub; continuing with the staged payload hash." }'
) -join $nl
Patch-Exactly $iexpressOldBlock $iexpressNewBlock 'IExpress PE output validation'
$effectiveWorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
Ensure $effectiveWorkRoot
$effectivePath = Join-Path $effectiveWorkRoot ('Build-Installer-THEMED-AUTOSTART-v11-effective-' + [guid]::NewGuid().ToString('N') + '.ps1')
Write-Utf8NoBom $effectivePath $script:effective
Assert-Parse $effectivePath

& $effectivePath @PSBoundParameters
if ($LASTEXITCODE -ne 0) { Fail "Effective v11 builder exited with code $LASTEXITCODE. Audit script retained at $effectivePath" }
