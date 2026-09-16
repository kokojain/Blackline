#!/bin/bash
# Assembles Blackline.app around the SwiftPM executable.
#
# SwiftPM cannot produce an app bundle, and a menu bar app needs one: LSUIElement keeps it
# out of the Dock, and UserNotifications refuses to register for an unbundled binary.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Blackline.app"

swift build -c "$CONFIG" --product Blackline
BIN="$(swift build -c "$CONFIG" --product Blackline --show-bin-path)/Blackline"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Blackline"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Blackline</string>
  <key>CFBundleDisplayName</key><string>Blackline</string>
  <key>CFBundleIdentifier</key><string>com.knob.blackline</string>
  <key>CFBundleExecutable</key><string>Blackline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Runs entirely on this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough for local running and is what lets notifications register.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
