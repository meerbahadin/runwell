#!/bin/bash
# Section 9.3: the shipping build is Developer ID-signed, hardened-runtime and
# notarized. Ad-hoc signing (Scripts/build-app.sh) is for local runs only — Gatekeeper
# rejects it on any other Mac, and the user sees "Runwell is damaged", which they
# cannot work around.
#
# Prerequisites:
#   1. Apple Developer Program membership ($99/yr)
#   2. A "Developer ID Application" certificate in your login keychain
#   3. A notarytool keychain profile, created once with:
#        xcrun notarytool store-credentials runwell-notary \
#          --apple-id you@example.com --team-id 728Q4KSP8P --password APP-SPECIFIC-PASSWORD
#
# Usage: Scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

IDENTITY="${1:-}"
PROFILE="${2:-runwell-notary}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Runwell.app"
DMG="$ROOT/build/Runwell.dmg"

if [ -z "$IDENTITY" ]; then
  echo "usage: Scripts/release.sh \"Developer ID Application: Name (TEAMID)\" [notary-profile]" >&2
  echo >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" >&2 || \
    echo "  (none found — you need an Apple Developer Program membership)" >&2
  exit 1
fi

echo "==> Building release binary"
# The shipping identifier, pinned here so a local build's development identifier
# can never reach a notarized artifact.
BUNDLE_ID="com.runwell.Runwell" "$ROOT/Scripts/build-app.sh" release

# The hardened runtime is required for notarization. Runwell asks for no
# exceptions: it reads public counters, so it needs no entitlement relaxations.
echo "==> Signing with hardened runtime"
codesign --force --deep --timestamp --options runtime \
         --sign "$IDENTITY" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building disk image"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Runwell" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Signing the disk image too means the download itself is verifiable, not just the
# app inside it.
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Submitting for notarization (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling attaches the notarization ticket to the file, so Gatekeeper can verify it
# offline. Without this a first launch with no network still warns.
echo "==> Stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo
echo "Ready to ship: $DMG"
