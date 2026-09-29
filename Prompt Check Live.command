#!/bin/bash
# Mac: double-click. Starts the Prompt Check server if needed, builds the overlay app on first
# run, and starts it. Then type or dictate into Claude's message box. Quit from the "Jev" menu-bar item.
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" # Finder skips shell profiles
URL="http://127.0.0.1:${PORT:-4747}"

# Started at login (live/login.sh): refresh that copy if the server here is newer.
COPY="$HOME/Library/Application Support/Prompt Check"
if [ -f "$HOME/Library/LaunchAgents/com.johnlin.prompt-check.plist" ] && [ server.mjs -nt "$COPY/server.mjs" -o index.html -nt "$COPY/index.html" ]; then
  bash live/login.sh on
fi

if ! curl -s -o /dev/null "$URL/api/status"; then
  nohup node server.mjs > "${TMPDIR:-/tmp}/prompt-check.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$URL/api/status" && break; sleep 0.3; done
fi

APP="live/Prompt Check Live.app"
if [ ! -x "$APP/Contents/MacOS/prompt-check-live" ] || [ live/PromptCheckLive.swift -nt "$APP/Contents/MacOS/prompt-check-live" ]; then
  live/build.sh || exit 1
fi
pkill -x prompt-check-live 2>/dev/null
open "$APP"
