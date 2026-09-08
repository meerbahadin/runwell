#!/bin/bash
# Assembles Runwell.app from the SwiftPM executable.
#
# Section 2.3 / 9.3: the shipping build is Developer ID-signed, hardened-runtime and
# notarized. This script produces a locally-signed bundle for development; signing
# identity and notarization are added at release time.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Runwell.app"

# Local builds are ad-hoc signed, and the signature changes on every rebuild. macOS
# keys notification authorization to the bundle identity, so sharing the release
# identifier lets a stale local denial stick to the shipping app (and vice versa).
# Keep development under its own identifier; release.sh overrides this.
BUNDLE_ID="${BUNDLE_ID:-com.runwell.Runwell.dev}"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Runwell"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Runwell"

# The app icon. Resources/Runwell.icon is the Icon Composer source; the .icns is
# the rendered form macOS reads from the bundle.
if [ -f "$ROOT/Resources/Runwell.icns" ]; then
  cp "$ROOT/Resources/Runwell.icns" "$APP/Contents/Resources/Runwell.icns"
fi

# The menu-bar template image, at 1x and 2x. Loaded by name at runtime, so it lives
# loose in Resources rather than in an asset catalog SwiftPM would have to compile.
if [ -d "$ROOT/Resources/MenuBar" ]; then
  cp "$ROOT/Resources/MenuBar/"*.png "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Runwell</string>
    <key>CFBundleDisplayName</key>       <string>Runwell</string>
    <key>CFBundleIdentifier</key>        <string>__BUNDLE_ID__</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>        <string>Runwell</string>
    <key>CFBundleIconFile</key>          <string>Runwell</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <!-- A normal windowed app that also installs a menu-bar extra. It switches to
         accessory mode at runtime when the window closes and background recording is
         on, so the Dock tile disappears rather than implying an unclosed window. -->
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Section 9.1: no account, no analytics, no outbound network request. -->
    <key>NSHumanReadableCopyright</key>  <string>Local-only. No telemetry.</string>
</dict>
</plist>
PLIST

# Substituted after the heredoc so the plist stays a literal block.
/usr/bin/sed -i '' "s|__BUNDLE_ID__|$BUNDLE_ID|" "$APP/Contents/Info.plist"

# Ad-hoc signature for local runs; a Developer ID identity replaces this at release.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
  echo "warning: ad-hoc signing failed; the app will still run locally"

echo "Built $APP ($BUNDLE_ID)"
