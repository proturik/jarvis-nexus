@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Jarvis-THEMED-AUTOSTART-v2.ps1" %*
exit /b %ERRORLEVEL%
