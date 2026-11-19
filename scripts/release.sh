#!/usr/bin/env bash
# Builds PlayFX for release: a Developer ID-signed app (hardened runtime) in a DMG, notarized by Apple
# and stapled, so it opens on any Mac without warnings.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for your team in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notary credentials kept in the keychain (an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials playfx --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Usage: scripts/release.sh            (SIGNING_IDENTITY / NOTARY_PROFILE override the defaults)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"

NOTARY_PROFILE="${NOTARY_PROFILE:-playfx}"
# Default: the personal team's Developer ID (this Mac also holds other teams' certificates).
IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: Daniel B. ([^"]*"' | tr -d '"' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "release: no Developer ID Application certificate found (see setup above)" >&2; exit 1; }
echo "Signing as: $IDENTITY"

VERSION="$(python3 -c 'import json; print(json.load(open("apps/desktop/src-tauri/tauri.conf.json"))["version"])')"
APPLE_SIGNING_IDENTITY="$IDENTITY" bun run desktop:build

BUNDLE=apps/desktop/src-tauri/target/release/bundle
APP="$BUNDLE/macos/PlayFX.app"
DMG="$(ls "$BUNDLE"/dmg/PlayFX_"$VERSION"_*.dmg)"

codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input \
  || { echo "release: the microphone entitlement is missing" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "Release ready: $DMG"
