@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Jarvis-RELEASE.ps1" %*
exit /b %ERRORLEVEL%
