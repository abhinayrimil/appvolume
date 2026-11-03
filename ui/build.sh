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

# ad-hoc sign so TCC can attribute the audio-capture consent to a stable identity
codesign --force --sign - --identifier com.local.appvolume "$APP" >/dev/null 2>&1 || true

echo "built $PWD/$APP"
