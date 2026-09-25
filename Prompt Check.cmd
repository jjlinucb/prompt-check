@echo off
rem Windows launcher: double-click in Explorer. Starts the server if it isn't running, then opens
rem a narrow app window to keep beside the Claude app. Needs Node 20+ on PATH.
cd /d "%~dp0"
set "URL=http://127.0.0.1:4747"

curl -s -o nul "%URL%/api/status"
if errorlevel 1 (
  start "Prompt Check server" /min node server.mjs
  timeout /t 2 /nobreak >nul
)

set "BROWSER=msedge"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" >nul 2>&1 && set "BROWSER=chrome"
reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" >nul 2>&1 && set "BROWSER=chrome"
start "" %BROWSER% --app=%URL% --window-size=460,900
