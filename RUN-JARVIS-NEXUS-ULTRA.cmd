@echo off
setlocal
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is not available. Install Node.js 20+ and run this file again.
  pause
  exit /b 1
)
rem User data stays in a stable directory that the updater never replaces.
if not defined JARVIS_DATA_DIR set "JARVIS_DATA_DIR=%LOCALAPPDATA%\JARVIS NEXUS ULTRA\data"
if not exist "%JARVIS_DATA_DIR%" mkdir "%JARVIS_DATA_DIR%"
rem Optional update check (opt-in via JARVIS_INDEX_URL; no-op unless the program
rem directory is a marked versioned program directory).
if defined JARVIS_INDEX_URL (
  if exist "%~dp0private-channel\Invoke-JarvisUpdate.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0private-channel\Invoke-JarvisUpdate.ps1" -ProgramRoot "%~dp0" -IndexUrl "%JARVIS_INDEX_URL%" -DataRoot "%JARVIS_DATA_DIR%" -AutoConfirm
  )
)
start "JARVIS NEXUS ULTRA" /b node ultra-server.mjs
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:3791"
echo JARVIS NEXUS ULTRA is running at http://127.0.0.1:3791
echo Keep this window open while JARVIS is working.
pause
