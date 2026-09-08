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

# macOS 15 (LSMinimumSystemVersion, below) supports Intel Macs as well as Apple
# silicon, but `swift build` alone only ever produces the host machine's
# architecture. A single-arch release built on Apple silicon simply will not launch
# on an Intel Mac — Gatekeeper never gets the chance to reject it; the OS reports
# it as damaged/incompatible. UNIVERSAL=1 builds and merges both slices, which
# release.sh always sets; local dev builds default to the fast single-arch path.
UNIVERSAL="${UNIVERSAL:-0}"

# One source of truth for the marketing version; release.sh requires this to have
# been bumped since the last tag before it will ship. The build number is the git
# commit count, which is monotonic by construction — no separate counter to forget
# to increment, and every build has a distinct, orderable identity for support.
MARKETING_VERSION="$(cat "$ROOT/VERSION" | tr -d '[:space:]')"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

echo "Building ($CONFIG, version $MARKETING_VERSION build $BUILD_NUMBER)…"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$UNIVERSAL" = "1" ]; then
  echo "  -> arm64"
  swift build -c "$CONFIG" --package-path "$ROOT" --triple arm64-apple-macosx15.0
  ARM_BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --triple arm64-apple-macosx15.0 --show-bin-path)/Runwell"
  echo "  -> x86_64"
  swift build -c "$CONFIG" --package-path "$ROOT" --triple x86_64-apple-macosx15.0
  X86_BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --triple x86_64-apple-macosx15.0 --show-bin-path)/Runwell"
  lipo -create -output "$APP/Contents/MacOS/Runwell" "$ARM_BIN" "$X86_BIN"
  echo "  -> $(lipo -info "$APP/Contents/MacOS/Runwell")"
else
  swift build -c "$CONFIG" --package-path "$ROOT"
  BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Runwell"
  cp "$BIN" "$APP/Contents/MacOS/Runwell"
fi

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
    <key>CFBundleVersion</key>           <string>__BUILD_NUMBER__</string>
    <key>CFBundleShortVersionString</key><string>__MARKETING_VERSION__</string>
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
/usr/bin/sed -i '' \
  -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
  -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|" \
  -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|" \
  "$APP/Contents/Info.plist"

# Ad-hoc signature for local runs; a Developer ID identity replaces this at release.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
  echo "warning: ad-hoc signing failed; the app will still run locally"

echo "Built $APP ($BUNDLE_ID, v$MARKETING_VERSION build $BUILD_NUMBER)"
