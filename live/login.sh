#!/bin/bash
# Mac: start Prompt Check at login.   bash live/login.sh on | off
#
# macOS keeps a login job out of ~/Documents, where this project lives ("Operation not permitted"),
# so `on` copies server.mjs and index.html to ~/Library/Application Support/Prompt Check and runs
# that copy, restarted if it ever stops. A second job opens the overlay app at login. Run `on`
# again after changing server.mjs or index.html; "Prompt Check Live.command" does it for you.
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT=$(pwd)
COPY="$HOME/Library/Application Support/Prompt Check"
AGENTS="$HOME/Library/LaunchAgents"
SERVER=com.johnlin.prompt-check
OVERLAY=com.johnlin.prompt-check-live
NODE=$(PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" command -v node) || { echo "node not found" >&2; exit 1; }
LOG="$HOME/Library/Logs/prompt-check.log"
x() { local s=${1//&/&amp;}; s=${s//</&lt;}; printf '%s' "${s//>/&gt;}"; }

agent() {  # label, then the program and its arguments; the server's job is kept alive
  local label=$1; shift
  local args="" a
  for a in "$@"; do args+="<string>$(x "$a")</string>"; done
  local keep=""
  [[ $label == "$SERVER" ]] && keep="<key>KeepAlive</key><true/><key>EnvironmentVariables</key><dict><key>PROMPT_CHECK_USAGE</key><string>$(x "$COPY/usage.jsonl")</string></dict>"
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>RunAtLoad</key><true/>$keep
  <key>StandardOutPath</key><string>$(x "$LOG")</string>
  <key>StandardErrorPath</key><string>$(x "$LOG")</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$label.plist"
}

case "${1:-}" in
  on)
    mkdir -p "$COPY" "$AGENTS"
    cp server.mjs index.html "$COPY/"
    # The spend so far comes along once; after that the copy's log is the one that grows.
    [[ -f "$COPY/usage.jsonl" || ! -f usage.jsonl ]] || cp usage.jsonl "$COPY/usage.jsonl"
    # A server started by hand from the project holds the port; the login copy takes over.
    pkill -f "node server.mjs" 2>/dev/null || true
    agent "$SERVER" "$NODE" "$COPY/server.mjs"
    agent "$OVERLAY" /usr/bin/open -g "$PROJECT/live/Prompt Check Live.app"
    echo "Prompt Check starts at login: the server from $COPY, then the overlay. Log: $LOG"
    echo "Spend is logged to $COPY/usage.jsonl." ;;
  off)
    for label in "$SERVER" "$OVERLAY"; do
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      rm -f "$AGENTS/$label.plist"
    done
    echo "Prompt Check no longer starts at login. The copy in $COPY is left in place." ;;
  *) echo "usage: bash live/login.sh on | off" >&2; exit 2 ;;
esac
