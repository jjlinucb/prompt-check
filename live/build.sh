#!/bin/bash
# Builds "Prompt Check Live.app" next to this script: a menu-bar-only app (no Dock icon).
# macOS ties the Accessibility permission to the signature. With the default ad-hoc signature every
# rebuild looks like a new app and loses it. Create a code-signing certificate named
# "Prompt Check Local" once (Keychain Access > Certificate Assistant > Create a Certificate,
# Certificate Type: Code Signing) and every build is signed with it, so the permission sticks.
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
# Otherwise any code-signing certificate already on the Mac will do; PCL_SIGN_IDENTITY picks one.
IDENTITY="${PCL_SIGN_IDENTITY:-Prompt Check Local}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
  echo "signed ad-hoc: approve Accessibility again after this build (no code-signing certificate found)"
fi
echo "built $PWD/$APP"
