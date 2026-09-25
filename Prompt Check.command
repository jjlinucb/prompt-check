#!/bin/bash
# Mac launcher: double-click in Finder. Starts the server if it isn't running, then opens a
# narrow app window to keep beside the Claude app.
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" # Finder skips shell profiles
URL="http://127.0.0.1:${PORT:-4747}"

if ! curl -s -o /dev/null "$URL/api/status"; then
  nohup node server.mjs > "${TMPDIR:-/tmp}/prompt-check.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$URL/api/status" && break; sleep 0.3; done
fi

if [ -d "/Applications/Google Chrome.app" ]; then
  open -na "Google Chrome" --args --app="$URL" --window-size=460,900
else
  open "$URL"
fi
