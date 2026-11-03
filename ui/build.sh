#!/bin/bash
# Build AppVolume.app (menu-bar, no Dock icon). Needs macOS 14.3+ SDK.
set -e
cd "$(dirname "$0")"
APP="AppVolume.app"
MACOS="$APP/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$MACOS"

swiftc -O Mixer.swift main.swift -o "$MACOS/AppVolume" \
    -framework CoreAudio -framework AudioToolbox -framework Accelerate \
    -framework AppKit -framework Foundation

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AppVolume</string>
  <key>CFBundleDisplayName</key><string>AppVolume</string>
  <key>CFBundleIdentifier</key><string>com.local.appvolume</string>
  <key>CFBundleExecutable</key><string>AppVolume</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.3</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>AppVolume taps app audio to re-render it at your chosen volume.</string>
</dict></plist>
PLIST

# Sign with the hardened runtime so a dylib can't be injected (DYLD_INSERT_LIBRARIES)
# to inherit the app's audio-capture TCC grant. Ad-hoc ("-") because no Developer ID
# is set up: note its cdhash changes every rebuild, so macOS re-asks for permission
# after each build. Set IDENTITY to a Developer ID cert for a persistent identity.
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --sign "$IDENTITY" --identifier com.local.appvolume "$APP"

echo "built $PWD/$APP"
