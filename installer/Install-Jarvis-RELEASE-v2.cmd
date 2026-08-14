@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Jarvis-RELEASE-v2.ps1" %*
exit /b %ERRORLEVEL%
