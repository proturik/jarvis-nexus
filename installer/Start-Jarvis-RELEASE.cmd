@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Jarvis-RELEASE.ps1"
exit /b %ERRORLEVEL%
