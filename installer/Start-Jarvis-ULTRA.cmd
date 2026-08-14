@echo off
setlocal EnableExtensions
set "JARVIS_HOME=%~dp0"

if not exist "%JARVIS_HOME%Start-Jarvis-ULTRA.ps1" (
  echo JARVIS NEXUS ULTRA: launcher script is missing.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%JARVIS_HOME%Start-Jarvis-ULTRA.ps1"
exit /b %ERRORLEVEL%
