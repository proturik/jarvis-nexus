<#
.SYNOPSIS
  Post-install health check for JARVIS NEXUS ULTRA. Verifies that every
  component and library is present and working: program files, bundled Node,
  core syntax, module imports, public key pin, running server, local brain
  (Ollama + qwen3:8b), Sense bridge, data directories and the update channel.

.DESCRIPTION
  Returns a result object and exits non-zero when a required check fails.
  With -ShowResult it opens a small window: green «JARVIS готов» when
  everything passes, or red with the list of problems. The launcher runs this
  after install/startup so the user immediately sees what is broken.

  Checks are fast (short timeouts) and never modify anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$DataRoot = '',
    [string]$Port = '3791',
    [string]$SensePort = '3793',
    [string]$PinnedPublicKeyFingerprint = '',
    [string]$IndexUrl = 'https://proturik.github.io/jarvis-nexus/release-index.json',
    [switch]$ShowResult,
    [switch]$ShowIfFail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path (Split-Path -Parent $installFull) 'data' }
if ([string]::IsNullOrWhiteSpace($PinnedPublicKeyFingerprint)) {
    $PinnedPublicKeyFingerprint = 'A935F9AC016C656C695A53A988C5EAD5CE30D42F6D57550A35311D7D8C0B455D'
}

function New-Check([string]$Name, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Name, $Ok, [string]$Detail)
    $okBool = [bool]$Ok
    $status = if ($okBool) { 'OK' } else { 'FAIL' }
    [void]$checks.Add((New-Check -Name $Name -Status $status -Detail $Detail))
}

function Test-HttpPort([int]$LocalPort) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $LocalPort)
        if (-not $task.Wait(2000)) { return $false }
        return $client.Connected
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

# --- Program files ---
$serverPath = Join-Path $installFull 'ultra-server.mjs'
$markerPath = Join-Path $installFull '.jarvis-program-marker'
$versionPath = Join-Path $installFull 'version.txt'
$packageJson = Join-Path $installFull 'package.json'
$knowledgeFile = Join-Path $installFull 'knowledge\jarvis-core.json'
$publicKeyPath = Join-Path $installFull 'private-channel\public-key.xml'

Add-Check 'Ядро ultra-server.mjs' (Test-Path -LiteralPath $serverPath -PathType Leaf) $serverPath
Add-Check 'Маркер каталога' (Test-Path -LiteralPath $markerPath -PathType Leaf) $markerPath
Add-Check 'version.txt' (Test-Path -LiteralPath $versionPath -PathType Leaf) $versionPath
Add-Check 'package.json' (Test-Path -LiteralPath $packageJson -PathType Leaf) $packageJson
Add-Check 'Ядро знаний jarvis-core.json' (Test-Path -LiteralPath $knowledgeFile -PathType Leaf) $knowledgeFile

$version = ''
if (Test-Path -LiteralPath $versionPath -PathType Leaf) { $version = ([string](Get-Content -LiteralPath $versionPath -Raw)).Trim() }
Add-Check 'Формат версии' ($version -match '^[0-9]+\.[0-9]+\.[0-9]+$') $version

# --- Bundled Node ---
$nodePath = Join-Path (Split-Path -Parent $installFull) 'runtime\node.exe'
if (Test-Path -LiteralPath $nodePath -PathType Leaf) {
    $nodeVersion = (& $nodePath --version 2>$null | Out-String).Trim()
    Add-Check 'Node.js (bundled)' ($nodeVersion -match '^v(2[0-9]|[3-9][0-9])\.') $nodeVersion
} else {
    Add-Check 'Node.js (bundled)' $false 'runtime\node.exe не найден'
    $nodePath = $null
}

# --- Core syntax + module imports ---
if (Test-Path -LiteralPath $serverPath -PathType Leaf) {
    $checkOut = & $nodePath --check $serverPath 2>&1
    Add-Check 'Синтаксис ядра' ($LASTEXITCODE -eq 0) ([string]($checkOut -join ' ')).Trim()
}

$moduleNames = @('jarvis-tools.mjs', 'knowledge-graph.mjs', 'mcp-client.mjs', 'conversation-intelligence.mjs', 'poe2-build-coach.mjs')
foreach ($moduleName in $moduleNames) {
    $modulePath = Join-Path $installFull $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        Add-Check "Модуль $moduleName" $false 'файл отсутствует'
        continue
    }
    $checkOut = & $nodePath --check $modulePath 2>&1
    Add-Check "Модуль $moduleName" ($LASTEXITCODE -eq 0) ([string]($checkOut -join ' ')).Trim()
}

# --- Public key pin ---
if (Test-Path -LiteralPath $publicKeyPath -PathType Leaf) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $pubBytes = [IO.File]::ReadAllBytes($publicKeyPath)
        $actualFp = ([BitConverter]::ToString($sha.ComputeHash($pubBytes))).Replace('-', '')
        Add-Check 'Публичный ключ (пин)' ($actualFp -eq $PinnedPublicKeyFingerprint) $actualFp
    } finally { $sha.Dispose() }
} else {
    Add-Check 'Публичный ключ (пин)' $false 'public-key.xml отсутствует'
}

# --- Data directories ---
foreach ($dir in @('data', 'sense-state', 'update-state')) {
    $full = Join-Path (Split-Path -Parent $installFull) $dir
    Add-Check "Каталог $dir" (Test-Path -LiteralPath $full -PathType Container) $full
}

# --- Running server ---
$coreUp = Test-HttpPort ([int]$Port)
if ($coreUp) {
    try {
        $boot = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/api/bootstrap") -TimeoutSec 3
        Add-Check 'Сервер /api/bootstrap' ($null -ne $boot.settings) ("version=" + [string]$boot.version)
    } catch {
        Add-Check 'Сервер /api/bootstrap' $false $_.Exception.Message
    }
} else {
    Add-Check 'Сервер (порт ' + $Port + ')' $false 'не отвечает'
}

# --- Local brain (Ollama) ---
$ollamaUp = Test-HttpPort 11434
if ($ollamaUp) {
    try {
        $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
        $modelNames = @($tags.models | ForEach-Object { [string]$_.name })
        $hasQwen = @($modelNames | Where-Object { $_ -match 'qwen3:8b' }).Count -gt 0
        Add-Check 'Мозг (Ollama)' $true ('моделей: ' + $modelNames.Count)
        Add-Check 'Модель qwen3:8b' $hasQwen ($modelNames -join ', ')
    } catch {
        Add-Check 'Мозг (Ollama)' $false $_.Exception.Message
    }
} else {
    Add-Check 'Мозг (Ollama)' $false 'не отвечает на 11434'
}

# --- Sense bridge ---
$senseUp = Test-HttpPort ([int]$SensePort)
Add-Check 'Sense (порт ' + $SensePort + ')' $senseUp $(if ($senseUp) { 'отвечает' } else { 'не отвечает' })

# --- Update channel (network, informational) ---
try {
    $indexResp = Invoke-WebRequest -Uri $IndexUrl -Method Head -UseBasicParsing -TimeoutSec 8
    Add-Check 'Канал обновлений' ($indexResp.StatusCode -eq 200) ('HTTP ' + $indexResp.StatusCode)
} catch {
    Add-Check 'Канал обновлений' $false 'нет сети или канал недоступен'
}

# --- Native companions (Pet window / Sense) ---
$installParent = Split-Path -Parent $installFull
$petExe = Join-Path $installParent 'desktop-shell\JarvisPet.exe'
$senseExe = Join-Path $installParent 'desktop-shell\sense\JarvisSense.exe'
Add-Check 'Окно JARVIS (JarvisPet.exe)' (Test-Path -LiteralPath $petExe -PathType Leaf) $petExe
Add-Check 'Голос (JarvisSense.exe)' (Test-Path -LiteralPath $senseExe -PathType Leaf) $senseExe
$senseInternal = Join-Path (Split-Path -Parent $senseExe) '_internal'
Add-Check 'Библиотеки Sense (_internal)' (Test-Path -LiteralPath $senseInternal -PathType Container) $senseInternal

# --- Install ID ---
$installIdPath = Join-Path $DataRoot 'install-id.txt'
if (Test-Path -LiteralPath $installIdPath -PathType Leaf) {
    $installId = ([string](Get-Content -LiteralPath $installIdPath -Raw)).Trim()
    Add-Check 'Код установки (install-id)' ($installId -match '^install-[A-Za-z0-9_-]{12,80}$') $installId
} else {
    Add-Check 'Код установки (install-id)' $false 'файл не создан (запустите лаунчер)'
}

# --- Subscription license (validated by signature, not just presence) ---
$licensePath = Join-Path $DataRoot 'license\license.json'
if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
    $licenseValid = $false
    $licenseDetail = 'лицензия найдена'
    try {
        $subscriptionModule = Join-Path $installFull 'private-channel\Jarvis.Subscription.psm1'
        if (Test-Path -LiteralPath $subscriptionModule -PathType Leaf) {
            Import-Module $subscriptionModule -Force -ErrorAction SilentlyContinue
            if ($null -ne $installId -and $installId -match '^install-[A-Za-z0-9_-]{12,80}$') {
                $sub = Test-JarvisSubscription -LicensePath $licensePath -InstallId $installId -PublicKeyPath $publicKeyPath
                $licenseValid = ($null -ne $sub -and $sub.Licensed)
                if ($licenseValid) { $licenseDetail = "tier=$($sub.Tier) licenseId=$($sub.LicenseId) до=$($sub.ExpiresAt.ToString('yyyy-MM-dd'))" }
                else { $licenseDetail = 'лицензия недействительна для этого кода установки' }
            }
        }
    } catch {
        $licenseDetail = $_.Exception.Message
    }
    Add-Check 'Подписка (лицензия)' $licenseValid $licenseDetail
} else {
    Add-Check 'Подписка (лицензия)' $false 'лицензия не найдена (требуется подписка)'
}

$failed = @($checks | Where-Object { $_.Status -eq 'FAIL' })
$allOk = ($failed.Count -eq 0)

$result = [pscustomobject]@{
    AllOk = $allOk
    Version = $version
    Passed = (@($checks).Count - $failed.Count)
    Failed = $failed.Count
    Checks = @($checks)
}

# --- Human-readable report (text): the user can copy it and send it to the owner ---
$reportLines = New-Object System.Collections.ArrayList
[void]$reportLines.Add('=== JARVIS NEXUS ULTRA — диагностика ===')
[void]$reportLines.Add(('Дата: ' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')))
[void]$reportLines.Add(('Версия: ' + $version))
[void]$reportLines.Add(('Итог: ' + $(if ($allOk) { 'ВСЁ РАБОТАЕТ' } else { 'НАЙДЕНЫ ПРОБЛЕМЫ' })))
[void]$reportLines.Add('')
foreach ($check in @($checks)) {
    [void]$reportLines.Add(('[' + $check.Status + '] ' + $check.Name + ' — ' + $check.Detail))
}
$reportText = ($reportLines -join "`r`n")

$reportPath = Join-Path $DataRoot 'diagnostic-report.txt'
try {
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    [IO.File]::WriteAllText($reportPath, $reportText, (New-Object Text.UTF8Encoding($true)))
} catch { }

$showWindow = $ShowResult -or ($ShowIfFail -and -not $allOk)
if ($showWindow) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Диагностика JARVIS'
    $form.Size = New-Object System.Drawing.Size(580, 470)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $header = New-Object System.Windows.Forms.Label
    $header.Location = New-Object System.Drawing.Point(16, 12)
    $header.Size = New-Object System.Drawing.Size(540, 30)
    $header.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $header.Text = if ($allOk) { 'JARVIS готов к работе' } else { 'JARVIS нашёл проблемы' }
    $header.ForeColor = if ($allOk) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(16, 48)
    $list.Size = New-Object System.Drawing.Size(540, 300)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    [void]$list.Columns.Add('Компонент', 230)
    [void]$list.Columns.Add('Статус', 60)
    [void]$list.Columns.Add('Детали', 220)

    foreach ($check in @($checks)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$check.Name)
        [void]$item.SubItems.Add([string]$check.Status)
        [void]$item.SubItems.Add([string]$check.Detail)
        if ($check.Status -eq 'FAIL') { $item.ForeColor = [System.Drawing.Color]::DarkRed }
        [void]$list.Items.Add($item)
    }

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Скопировать отчёт'
    $copyButton.Size = New-Object System.Drawing.Size(150, 30)
    $copyButton.Location = New-Object System.Drawing.Point(16, 360)
    $copyButton.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($reportText)
            $copyButton.Text = 'Скопировано! Отправьте владельцу.'
        } catch {
            $copyButton.Text = 'Отчёт: ' + $reportPath
        }
    })

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Size = New-Object System.Drawing.Size(104, 30)
    $okButton.Location = New-Object System.Drawing.Point(452, 360)
    $okButton.DialogResult = 'OK'

    $form.AcceptButton = $okButton
    $form.CancelButton = $okButton
    $form.Controls.Add($header)
    $form.Controls.Add($list)
    $form.Controls.Add($copyButton)
    $form.Controls.Add($okButton)

    try { $null = $form.ShowDialog() } finally { $form.Dispose() }
}

$result
if (-not $allOk) { exit 1 }
exit 0
