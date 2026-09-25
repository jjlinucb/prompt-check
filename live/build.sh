#!/bin/bash
# Builds "Prompt Check Live.app" next to this script: a menu-bar-only app (no Dock icon).
# Rebuilding changes its signature, so macOS asks for Accessibility permission again.
set -euo pipefail
cd "$(dirname "$0")"
APP="Prompt Check Live.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O PromptCheckLive.swift -o "$APP/Contents/MacOS/prompt-check-live"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Prompt Check Live</string>
  <key>CFBundleIdentifier</key><string>local.prompt-check-live</string>
  <key>CFBundleExecutable</key><string>prompt-check-live</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $PWD/$APP"
