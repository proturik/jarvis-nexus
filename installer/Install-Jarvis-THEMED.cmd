@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Jarvis-THEMED.ps1" %*
exit /b %ERRORLEVEL%
