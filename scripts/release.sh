#!/usr/bin/env bash
# Builds PlayFX for release: a Developer ID-signed app (hardened runtime) in a DMG, notarized by Apple
# and stapled, so it opens on any Mac without warnings.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for your team in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notary credentials kept in the keychain: an App Store Connect API key with Developer access
#      (App Store Connect → Users and Access → Integrations → Team Keys; the .p8 downloads once):
#        xcrun notarytool store-credentials playfx --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER>
#      then delete the .p8; the profile keeps the key in the keychain.
#
# Nothing ships below the coverage floor: every package's tests and coverage gates (≥ 80% lines and
# functions everywhere, branches too in TypeScript) run first, and any failure stops the release.
#
# Usage: scripts/release.sh            (SIGNING_IDENTITY / NOTARY_PROFILE override the defaults)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"

NOTARY_PROFILE="${NOTARY_PROFILE:-playfx}"
# Default: PlayFX's team, BLANK HEXADECIMAL SL (this Mac also holds other teams' certificates).
TEAM_ID=K579SJ8947
# `|| true`: with pipefail, grep finding nothing would end the script here, before the message below.
IDENTITY="${SIGNING_IDENTITY:-$( (security find-identity -v -p codesigning \
  | grep -o "\"Developer ID Application: [^\"]*($TEAM_ID)\"" | tr -d '"' | head -1) || true)}"
[[ -n "$IDENTITY" ]] || { echo "release: no Developer ID Application certificate found (see setup above)" >&2; exit 1; }
echo "Signing as: $IDENTITY"

echo "Tests and coverage (a release needs >= 80% in every package)…"
packages/streamcore/scripts/coverage.sh --no-parallel   # Swift: lines, functions
bun run --cwd apps/desktop check                        # TypeScript: tsc, ESLint, lines/branches/functions
bun run --cwd apps/desktop coverage:rust                # Rust: lines, functions
echo "Coverage gates passed."

VERSION="$(python3 -c 'import json; print(json.load(open("apps/desktop/src-tauri/tauri.conf.json"))["version"])')"
APPLE_SIGNING_IDENTITY="$IDENTITY" bun run desktop:build

BUNDLE=apps/desktop/src-tauri/target/release/bundle
APP="$BUNDLE/macos/PlayFX.app"
DMG="$(ls "$BUNDLE"/dmg/PlayFX_"$VERSION"_*.dmg)"

codesign --verify --deep --strict "$APP"
# Read whole first: `grep -q` stopping early could SIGPIPE codesign and fail the pipeline even with it present.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
[[ "$ENTITLEMENTS" == *audio-input* ]] || { echo "release: the microphone entitlement is missing" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "Release ready: $DMG"
