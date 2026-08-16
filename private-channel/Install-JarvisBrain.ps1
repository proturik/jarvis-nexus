<#
.SYNOPSIS
  Ensures the full JARVIS local brain is installed and running: Ollama, the
  chat model (qwen3:8b) AND the vision models (qwen3-vl:4b-instruct for
  watching, qwen3-vl:8b-instruct for actions). Runs automatically at first
  launch; the user does not configure anything.

.DESCRIPTION
  Fast path: Ollama present, all models pulled and the local server answering on
  http://127.0.0.1:11434 -> exits 0 immediately. Slow path: download and silently
  install Ollama, pull each missing model with live progress, then start the
  server. Progress is printed to the console. Never deletes anything and never
  touches the JARVIS program dir.
#>
[CmdletBinding()]
param(
    [string[]]$Models = @('qwen3:8b', 'qwen3-vl:4b-instruct', 'qwen3-vl:8b-instruct'),
    [int]$InstallTimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OllamaUrl = 'https://ollama.com/download/OllamaSetup.exe'
$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
$OllamaExeCandidates = @(
    (Join-Path $LocalAppData 'Programs\Ollama\ollama.exe'),
    (Join-Path $env:ProgramFiles 'Ollama\ollama.exe')
)

function Find-OllamaExe {
    foreach ($candidate in $OllamaExeCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Test-OllamaApi {
    try {
        $response = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -UseBasicParsing -TimeoutSec 3
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Test-ModelPulled {
    param([string]$OllamaExe, [string]$ModelName)
    try {
        $raw = & $OllamaExe list 2>$null | Out-String
        return ($raw -match ([regex]::Escape($ModelName)))
    } catch {
        return $false
    }
}

Write-Output 'JARVIS: проверяю локальный мозг...'

$ollamaExe = Find-OllamaExe
if ($null -eq $ollamaExe) {
    Write-Output 'JARVIS: Ollama не найден. Скачиваю установщик (~700 МБ) — это один раз.'
    $setupPath = Join-Path $env:TEMP 'OllamaSetup.exe'
    try {
        Invoke-WebRequest -Uri $OllamaUrl -OutFile $setupPath -UseBasicParsing
    } catch {
        throw "Не удалось скачать Ollama: $($_.Exception.Message)"
    }
    Write-Output 'JARVIS: устанавливаю Ollama (тихо)...'
    Start-Process -FilePath $setupPath -ArgumentList '/S' -Wait | Out-Null
    Remove-Item -LiteralPath $setupPath -Force -ErrorAction SilentlyContinue

    $deadline = [DateTime]::UtcNow.AddSeconds($InstallTimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $ollamaExe = Find-OllamaExe
    } while ($null -eq $ollamaExe -and [DateTime]::UtcNow -lt $deadline)
    if ($null -eq $ollamaExe) {
        throw 'Ollama установился, но исполняемый файл не найден. Перезапустите JARVIS.'
    }
}

foreach ($model in $Models) {
    if (-not (Test-ModelPulled -OllamaExe $ollamaExe -ModelName $model)) {
        Write-Output "JARVIS: скачиваю модель $model. Это один раз, подождите (виден прогресс)."
        & $ollamaExe pull $model
        if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать модель $model." }
    } else {
        Write-Output "JARVIS: модель $model уже на месте."
    }
}

if (-not (Test-OllamaApi)) {
    Write-Output 'JARVIS: запускаю локальный мозг...'
    Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-OllamaApi) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    if (-not (Test-OllamaApi)) { throw 'Локальный мозг не ответил на 127.0.0.1:11434.' }
}

Write-Output ('JARVIS: мозг готов (Ollama + ' + ($Models -join ', ') + ').')
