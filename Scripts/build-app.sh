#!/bin/bash
# Assembles PowerTask.app from the SwiftPM executable.
#
# Section 2.3 / 9.3: the shipping build is Developer ID-signed, hardened-runtime and
# notarized. This script produces a locally-signed bundle for development; signing
# identity and notarization are added at release time.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/PowerTask.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/PowerTask"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PowerTask"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>PowerTask</string>
    <key>CFBundleDisplayName</key>       <string>PowerTask</string>
    <key>CFBundleIdentifier</key>        <string>com.powertask.PowerTask</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>        <string>PowerTask</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <!-- A normal windowed app that also installs a menu-bar extra. -->
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Section 9.1: no account, no analytics, no outbound network request. -->
    <key>NSHumanReadableCopyright</key>  <string>Local-only. No telemetry.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature for local runs; a Developer ID identity replaces this at release.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
  echo "warning: ad-hoc signing failed; the app will still run locally"

echo "Built $APP"
