@echo off
setlocal EnableExtensions
set "JARVIS_INSTALLER_DIR=%~dp0"

if not exist "%JARVIS_INSTALLER_DIR%Install-Jarvis.ps1" (
  echo JARVIS NEXUS ULTRA: installer script is missing.
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%JARVIS_INSTALLER_DIR%Install-Jarvis.ps1" %*
exit /b %ERRORLEVEL%
