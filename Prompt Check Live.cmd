@echo off
rem Windows: double-click. Starts the Prompt Check server if needed, then the overlay that grades
rem Claude's message box as you type. Quit from the tray icon (right-click). Needs Node 20+ on PATH.
cd /d "%~dp0"
set "URL=http://127.0.0.1:4747"

curl -s -o nul "%URL%/api/status"
if errorlevel 1 (
  start "Prompt Check server" /min node server.mjs
  timeout /t 2 /nobreak >nul
)
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0live\PromptCheckLive.ps1"
