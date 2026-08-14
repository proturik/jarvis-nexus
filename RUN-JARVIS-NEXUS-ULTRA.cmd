@echo off
setlocal
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is not available. Install Node.js 20+ and run this file again.
  pause
  exit /b 1
)
start "JARVIS NEXUS ULTRA" /b node ultra-server.mjs
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:3791"
echo JARVIS NEXUS ULTRA is running at http://127.0.0.1:3791
echo Keep this window open while JARVIS is working.
pause
