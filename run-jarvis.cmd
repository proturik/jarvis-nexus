@echo off
cd /d "%~dp0"
start "JARVIS NEXUS" http://127.0.0.1:3788
node server.mjs
pause
