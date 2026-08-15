<#
.SYNOPSIS
  Reproducible rebuild of JarvisSense.exe (one-dir PyInstaller build) with the
  offline dictation mode. Uses uv-managed Python 3.12 and bundles the Vosk
  Russian model + Silero TTS model.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\sensors\Rebuild-Sense.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Venv = Join-Path $RepoRoot '.venv-sense-build'
$VoskModel = Join-Path $PSScriptRoot 'models\vosk-model-small-ru-0.22'
$TtsModel = Join-Path $PSScriptRoot 'models\tts\v5_5_ru.pt'

# 1. Extract the models from the live install if they are not in the repo.
$liveInternal = Join-Path $env:LOCALAPPDATA 'JARVIS NEXUS ULTRA\desktop-shell\sense\_internal'
if (-not (Test-Path -LiteralPath $VoskModel)) {
    if (-not (Test-Path -LiteralPath (Join-Path $liveInternal 'voice-model'))) { throw 'Vosk model missing from repo and live install.' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $VoskModel) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $liveInternal 'voice-model') -Destination $VoskModel -Recurse -Force
}
if (-not (Test-Path -LiteralPath $TtsModel)) {
    if (-not (Test-Path -LiteralPath (Join-Path $liveInternal 'tts-model\v5_5_ru.pt'))) { throw 'Silero TTS model missing from repo and live install.' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $TtsModel) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $liveInternal 'tts-model\v5_5_ru.pt') -Destination $TtsModel -Force
}

# 2. Build venv + deps.
& uv venv --python 3.12 $Venv | Out-Null
$python = Join-Path $Venv 'Scripts\python.exe'
& uv pip install --python $python pyinstaller vosk pynput pyperclip mss sounddevice numpy pillow torch --index https://download.pytorch.org/whl/cpu | Out-Null

# 3. Bundle vosk DLLs and models, build.
$voskPkg = Join-Path $Venv 'Lib\site-packages\vosk'
Push-Location $PSScriptRoot
try {
    Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'build'), (Join-Path $PSScriptRoot 'dist') -Recurse -Force -ErrorAction SilentlyContinue
    & $python -m PyInstaller --noconfirm --onedir --name JarvisSense `
        --add-data "models/vosk-model-small-ru-0.22;voice-model" `
        --add-data "models/tts/v5_5_ru.pt;tts-model" `
        --add-binary (Join-Path $voskPkg 'libvosk.dll;vosk') `
        --add-binary (Join-Path $voskPkg 'libgcc_s_seh-1.dll;vosk') `
        --add-binary (Join-Path $voskPkg 'libstdc++-6.dll;vosk') `
        --add-binary (Join-Path $voskPkg 'libwinpthread-1.dll;vosk') `
        --hidden-import pynput --hidden-import pyperclip jarvis_sense.py
    if ($LASTEXITCODE -ne 0) { throw 'PyInstaller build failed.' }
    Write-Output ("Built: " + (Join-Path $PSScriptRoot 'dist\JarvisSense\JarvisSense.exe'))
} finally {
    Pop-Location
}
