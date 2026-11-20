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
# Notarization runs twice: the .app is notarized and stapled before it goes into the DMG (so its first launch
# works offline, without Gatekeeper's online check), then the DMG. Each submission is waited on by its id, and
# a wait that errors or times out is retried, never resubmitted. scripts/test-release.sh tests that wait and
# the DMG's app swap with a fake notarytool (no Apple service, no signing).
#
# Usage: scripts/release.sh            (SIGNING_IDENTITY / NOTARY_PROFILE override the defaults;
#                                       NOTARY_WAIT_ATTEMPTS / NOTARY_WAIT_TIMEOUT tune the waits)

NOTARY_PROFILE="${NOTARY_PROFILE:-playfx}"
NOTARY_WAIT_ATTEMPTS="${NOTARY_WAIT_ATTEMPTS:-6}"   # waits on one submission before giving up
NOTARY_WAIT_TIMEOUT="${NOTARY_WAIT_TIMEOUT:-1h}"    # how long each wait polls
NOTARY_RETRY_DELAY="${NOTARY_RETRY_DELAY:-30}"      # seconds between waits

# Prints one field of the JSON object on stdin; nothing when it isn't JSON or lacks the field.
json_field() {
  python3 -c 'import json, sys
try: print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception: pass' "$1"
}

# Submits a file to Apple's notary service and waits for its verdict by submission id. notarytool's status polls
# can time out while Apple is still "In Progress" (it once took hours), so a wait that errors or runs out of
# time is retried on the same id, up to NOTARY_WAIT_ATTEMPTS times. Fails, printing the notary log, on
# Invalid or Rejected.
notarize() {
  local file="$1" name reply id status attempt
  name="$(basename "$file")"
  echo "Notarizing ${name}…"
  reply="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --no-wait --output-format json)" \
    || { echo "release: notarytool couldn't submit $name" >&2; return 1; }
  id="$(json_field id <<<"$reply")"
  [[ -n "$id" ]] || { echo "release: notarytool gave no submission id for $name: $reply" >&2; return 1; }
  echo "Submission id: $id"
  for ((attempt = 1; attempt <= NOTARY_WAIT_ATTEMPTS; attempt++)); do
    xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --timeout "$NOTARY_WAIT_TIMEOUT" || true
    # The verdict comes from `info`, not from wait's exit status.
    status="$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json \
      | json_field status)" || status=""
    case "$status" in
      Accepted)
        echo "Notarized: $name"
        return 0 ;;
      Invalid | Rejected)
        echo "release: Apple's notary service marked $name $status ($id). Its log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        return 1 ;;
    esac
    echo "release: $name is ${status:-of unknown status} after wait $attempt of $NOTARY_WAIT_ATTEMPTS ($id)" >&2
    if ((attempt < NOTARY_WAIT_ATTEMPTS)); then sleep "$NOTARY_RETRY_DELAY"; fi
  done
  echo "release: no verdict for $name; check it with" >&2
  echo "  xcrun notarytool info $id --keychain-profile $NOTARY_PROFILE" >&2
  echo "and once it's Accepted, finish the steps after it in scripts/release.sh by hand." >&2
  return 1
}

# Replaces the app inside a DMG with another copy of it (the stapled one), keeping everything else tauri
# laid out (window, icon positions, Applications link, volume icon) and the DMG's name and format.
replace_app_in_dmg() {
  local dmg="$1" app="$2" work ok=0
  work="$(mktemp -d)"
  mkdir "$work/mnt"
  if hdiutil convert -quiet "$dmg" -format UDRW -o "$work/rw.dmg" \
    && hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$work/mnt" "$work/rw.dmg"; then
    rm -rf "$work/mnt/$(basename "$app")" && ditto "$app" "$work/mnt/$(basename "$app")" || ok=1
    hdiutil detach -quiet "$work/mnt" || hdiutil detach -quiet -force "$work/mnt" || ok=1
    ((ok == 0)) && hdiutil convert -quiet "$work/rw.dmg" -format UDZO -ov -o "$dmg" || ok=1
  else
    ok=1
  fi
  rm -rf "$work"
  ((ok == 0)) || { echo "release: couldn't put $(basename "$app") into $(basename "$dmg")" >&2; return 1; }
}

# Sourced by scripts/test-release.sh for the functions above: stop here.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"

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

# The app first, so the copy in the DMG carries its own ticket.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/PlayFX.zip"
notarize "$WORK/PlayFX.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute -v "$APP"
replace_app_in_dmg "$DMG" "$APP"

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "Release ready: $DMG"
