#!/usr/bin/env bash
# Tests release.sh's notarization wait, its DMG app swap, the in-app update it makes and how it reads and tries the
# updater key, without Apple's notary service, a signing identity, the keychain or the real updater key: a fake
# `xcrun` on PATH plays notarytool, a fake `security` plays the keychain, the DMG is a small one made here, and the
# update is signed with a throwaway key generated here (`tauri signer generate`).
#
# Usage: scripts/test-release.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=release.sh
source scripts/release.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
check() { # description, then a command that must succeed
  local what="$1"
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what" >&2; failures=$((failures + 1)); fi
}

ID=2efe0f3a-0000-4000-8000-000000000001
mkdir "$TMP/bin"
cat >"$TMP/bin/xcrun" <<EOF
#!/usr/bin/env bash
# Fake \`xcrun notarytool\`: the first FAKE_TIMEOUTS waits fail like a timed-out status poll (the submission
# stays "In Progress"), then the submission ends as FAKE_VERDICT.
[[ "\$1" == notarytool ]] || exit 99
shift
echo "\$*" >>"\$FAKE_DIR/calls"
waits=\$(grep -c '^wait ' "\$FAKE_DIR/calls")
case "\$1" in
  submit) echo '{"id":"$ID","message":"Successfully uploaded file"}' ;;
  wait)
    if ((waits <= FAKE_TIMEOUTS)); then echo "Error: The request timed out." >&2; exit 1; fi
    echo "Current status: \$FAKE_VERDICT" ;;
  info)
    status="\$FAKE_VERDICT"
    if ((waits <= FAKE_TIMEOUTS)); then status="In Progress"; fi
    echo "{\"id\":\"$ID\",\"status\":\"\$status\"}" ;;
  log) echo '{"issues":[{"message":"The binary is not signed with a valid Developer ID certificate."}]}' ;;
  *) exit 98 ;;
esac
EOF
chmod +x "$TMP/bin/xcrun"
touch "$TMP/PlayFX.zip"

# Runs notarize against the fake: timeouts before the verdict, the verdict, how many waits it may make.
# Leaves its exit status in $rc, its output in $TMP/out and notarytool's calls in $TMP/calls. Runs under the
# release's own `set -euo pipefail`, so a failing command notarize doesn't guard ends it here as it would there.
run_notarize() {
  rm -f "$TMP/calls"
  (
    set -euo pipefail
    export FAKE_DIR="$TMP" FAKE_TIMEOUTS="$1" FAKE_VERDICT="$2" PATH="$TMP/bin:$PATH"
    NOTARY_WAIT_ATTEMPTS="$3" NOTARY_RETRY_DELAY=0
    notarize "$TMP/PlayFX.zip"
  ) >"$TMP/out" 2>&1
  rc=$?
}
calls() { grep -c "^$1 " "$TMP/calls"; }
output_has() { grep -qF "$1" "$TMP/out"; }

echo "Notarization wait"
run_notarize 2 Accepted 6
check "two timed-out waits, then Accepted: succeeds" test "$rc" -eq 0
check "  submitted once" test "$(calls submit)" -eq 1
check "  waited three times, on the submission's id" test "$(grep -c "^wait $ID " "$TMP/calls")" -eq 3

run_notarize 0 Invalid 6
check "Invalid: fails" test "$rc" -ne 0
check "  submitted once, waited once" test "$(calls submit)$(calls wait)" = 11
check "  prints the notary log for the id" test "$(grep -c "^log $ID " "$TMP/calls")" -eq 1
check "  the log reaches the output" output_has "not signed with a valid Developer ID"
check "  says it was Invalid" output_has "marked PlayFX.zip Invalid"

run_notarize 2 Rejected 6
check "Rejected after two timeouts: fails" test "$rc" -ne 0
check "  prints the notary log" test "$(calls log)" -eq 1

run_notarize 99 Accepted 3
check "never finishes: gives up" test "$rc" -ne 0
check "  after the allowed waits, without resubmitting" test "$(calls submit)$(calls wait)" = 13
check "  says how to check the submission" output_has "xcrun notarytool info $ID"

echo "DMG app swap"
mkdir -p "$TMP/src/PlayFX.app/Contents" "$TMP/new/PlayFX.app/Contents"
echo old >"$TMP/src/PlayFX.app/Contents/marker"
echo layout >"$TMP/src/.VolumeIcon.icns"
ln -s /Applications "$TMP/src/Applications"
echo new >"$TMP/new/PlayFX.app/Contents/marker"
echo ticket >"$TMP/new/PlayFX.app/Contents/CodeResources"
hdiutil create -quiet -srcfolder "$TMP/src" -volname PlayFX -fs HFS+ -size 8m -format UDZO "$TMP/PlayFX_0.0.0_aarch64.dmg"
replace_app_in_dmg "$TMP/PlayFX_0.0.0_aarch64.dmg" "$TMP/new/PlayFX.app"
check "replaces without error" test $? -eq 0
mkdir "$TMP/mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$TMP/mnt" "$TMP/PlayFX_0.0.0_aarch64.dmg"
check "the DMG holds the new app" grep -qx new "$TMP/mnt/PlayFX.app/Contents/marker"
check "  with its ticket" test -f "$TMP/mnt/PlayFX.app/Contents/CodeResources"
check "  and keeps the rest (the volume icon)" grep -qx layout "$TMP/mnt/.VolumeIcon.icns"
check "  and the Applications link" test "$(readlink "$TMP/mnt/Applications")" = /Applications
check "  under the same volume name" test "$(diskutil info "$TMP/mnt" | awk -F': *' '/Volume Name/ {print $2}')" = PlayFX
hdiutil detach -quiet "$TMP/mnt"
check "  still a compressed read-only image" \
  bash -c "hdiutil imageinfo '$TMP/PlayFX_0.0.0_aarch64.dmg' 2>/dev/null | grep -q 'Format: UDZO'"

echo "In-app update"
# Throwaway keys, made here and gone with $TMP: the release's own key never leaves the keychain.
mkdir "$TMP/keys" "$TMP/update"
for key in key other; do
  bun run --cwd apps/desktop tauri signer generate --ci -p throwaway -w "$TMP/keys/$key" >/dev/null 2>&1
done
xattr -w com.apple.quarantine "0081;00000000;test;" "$TMP/new/PlayFX.app/Contents/marker"
# Hands make_update the key the way release.sh does (assignments before the call, nothing exported).
run_make_update() { # public key file, then extra env assignments; output in $TMP/update.log, status in $rc
  local pub="$1"
  shift
  (
    set -euo pipefail
    (($# == 0)) || export "$@"
    TAURI_SIGNING_PRIVATE_KEY="$(cat "$TMP/keys/key")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD=throwaway \
      make_update "$TMP/new/PlayFX.app" 0.0.1 "$TMP/update" "$(cat "$pub")"
  ) >"$TMP/update.log" 2>&1
  rc=$?
}
manifest() { python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$TMP/update/latest.json" "$1"; }
TARBALL="$TMP/update/PlayFX_0.0.1_aarch64.app.tar.gz"

run_make_update "$TMP/keys/key.pub"
check "makes the update" test "$rc" -eq 0
check "  a tarball with the app at its root" \
  bash -c "! tar -tzf '$TARBALL' | grep -qv '^PlayFX\.app/' && tar -tzf '$TARBALL' | grep -qx 'PlayFX.app/Contents/marker'"
check "  no AppleDouble files in it" bash -c "! tar -tzf '$TARBALL' | grep -q '\._'"
mkdir "$TMP/unpacked"
tar -xzf "$TARBALL" -C "$TMP/unpacked"
check "  holding the stapled app as it is" diff -r "$TMP/new/PlayFX.app" "$TMP/unpacked/PlayFX.app"
check "  without its extended attributes (a quarantine flag)" \
  bash -c "! xattr '$TMP/unpacked/PlayFX.app/Contents/marker' | grep -q quarantine"
check "  signed, bound to the version" bash -c "base64 -d <'$TARBALL.sig' | grep -q 'trusted comment: .*version:0.0.1'"
check "latest.json names the version" test "$(manifest 'm["version"]')" = 0.0.1
check "  and where the release page is" test "$(manifest 'm["notes"]')" = "See https://github.com/deblanco/PlayFX/releases/tag/v0.0.1"
check "  carries the signature" test "$(manifest 'm["platforms"]["darwin-aarch64"]["signature"]')" = "$(cat "$TARBALL.sig" 2>/dev/null || echo missing)"
check "  and the download URL" test "$(manifest 'm["platforms"]["darwin-aarch64"]["url"]')" \
  = "https://github.com/deblanco/PlayFX/releases/download/v0.0.1/PlayFX_0.0.1_aarch64.app.tar.gz"
check "  with an RFC 3339 UTC date" bash -c "[[ '$(manifest 'm["pub_date"]')' =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]"
check "  and nothing secret" bash -c "test -s '$TMP/update/latest.json' && ! grep -qF \"\$(cat '$TMP/keys/key')\" '$TMP/update/latest.json' && ! grep -q throwaway '$TMP/update/latest.json' '$TMP/update.log'"

run_make_update "$TMP/keys/other.pub"
check "another key than tauri.conf.json's: fails" test "$rc" -ne 0
check "  saying installed copies would refuse it" grep -q "another key" "$TMP/update.log"
check "  without a latest.json to publish" test ! -e "$TMP/update/latest.json"

run_make_update "$TMP/keys/key.pub" SIGNER=false
check "the signer failing: fails" test "$rc" -ne 0
check "  pointing at the keychain setup" grep -q "is the updater key in the keychain" "$TMP/update.log"

cat >"$TMP/bin/unbound-signer" <<'EOF2'
#!/usr/bin/env bash
# Signs like `tauri signer sign` without --app-version (no version in the trusted comment).
file="${@: -1}"
bun run --cwd apps/desktop tauri signer sign "$file" >/dev/null
EOF2
chmod +x "$TMP/bin/unbound-signer"
run_make_update "$TMP/keys/key.pub" SIGNER="$TMP/bin/unbound-signer"
check "a signature not bound to the version: fails" test "$rc" -ne 0
check "  saying so" grep -q "isn't bound to version 0.0.1" "$TMP/update.log"

echo "Updater key"
mkdir -p "$TMP/keychain/items"
cat >"$TMP/keychain/security" <<'EOF3'
#!/usr/bin/env bash
# Fake `security find-generic-password -a <account> -s <service> -w`: an item is the file <account>.<service> in
# $FAKE_KEYCHAIN/items; a missing one fails with 44, as security does.
echo "$*" >>"$FAKE_KEYCHAIN/calls"
[[ "$1" == find-generic-password ]] || exit 99
shift
while (($#)); do
  case "$1" in
    -a) account="$2"; shift ;;
    -s) service="$2"; shift ;;
    -w) ;;
    *) exit 98 ;;
  esac
  shift
done
item="$FAKE_KEYCHAIN/items/$account.$service"
[[ -f "$item" ]] || { echo "security: The specified item could not be found in the keychain." >&2; exit 44; }
cat "$item"
EOF3
chmod +x "$TMP/keychain/security"
# Runs read_updater_key against the fake keychain: status in $rc, output in $TMP/key.log, what it read in $TMP/key.read.
run_read_key() {
  rm -f "$TMP/keychain/calls" "$TMP/key.read"
  (
    set -euo pipefail
    export FAKE_KEYCHAIN="$TMP/keychain" PATH="$TMP/keychain:$PATH"
    read_updater_key
    printf '%s\n%s\n' "$UPDATER_KEY" "$UPDATER_KEY_PASSWORD" >"$TMP/key.read"
  ) >"$TMP/key.log" 2>&1
  rc=$?
}

run_read_key
check "no key in the keychain: fails" test "$rc" -ne 0
check "  saying it isn't in the login keychain" grep -q "isn't in the login keychain" "$TMP/key.log"
check "  and pointing at step 3 of the setup" grep -q "step 3 of the setup" "$TMP/key.log"
check "  having asked for the key, account playfx" grep -qx -- "find-generic-password -a playfx -s playfx-updater-key -w" "$TMP/keychain/calls"
cp "$TMP/keys/key" "$TMP/keychain/items/playfx.playfx-updater-key"
run_read_key
check "the key without its password: fails" test "$rc" -ne 0
check "  having asked for the password" grep -qx -- "find-generic-password -a playfx -s playfx-updater-key-password -w" "$TMP/keychain/calls"
printf throwaway >"$TMP/keychain/items/playfx.playfx-updater-key-password"
run_read_key
check "both there: reads them" test "$rc" -eq 0
check "  whole" test "$(cat "$TMP/key.read" 2>/dev/null)" = "$(cat "$TMP/keys/key")"$'\n'throwaway
check "  printing nothing" test ! -s "$TMP/key.log"

# Runs check_updater_key with a key text, its password and a public key file: status in $rc, output in $TMP/check.log.
run_check_key() {
  (
    set -euo pipefail
    TAURI_SIGNING_PRIVATE_KEY="$1" TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$2" check_updater_key "$(cat "$3")"
  ) >"$TMP/check.log" 2>&1
  rc=$?
}
KEY_TEXT="$(cat "$TMP/keys/key")"
run_check_key "$KEY_TEXT" throwaway "$TMP/keys/key.pub"
check "trying the key: a good one passes" test "$rc" -eq 0
check "  printing neither the key nor its password" \
  bash -c "! grep -qF \"\$(cat '$TMP/keys/key')\" '$TMP/check.log' && ! grep -q throwaway '$TMP/check.log'"
run_check_key "$KEY_TEXT" wrong "$TMP/keys/key.pub"
check "a wrong password: fails" test "$rc" -ne 0
check "  saying what to check" grep -q "can't sign an update installed copies accept" "$TMP/check.log"
# What pasting it at security's -w prompt stores: its first 128 characters.
run_check_key "${KEY_TEXT:0:128}" throwaway "$TMP/keys/key.pub"
check "a cut-off key: fails" test "$rc" -ne 0
run_check_key "$KEY_TEXT" throwaway "$TMP/keys/other.pub"
check "a key that isn't tauri.conf.json's: fails" test "$rc" -ne 0
check "  saying installed copies would refuse it" grep -q "another key" "$TMP/check.log"
check "  without printing the key" bash -c "! grep -qF \"\$(cat '$TMP/keys/key')\" '$TMP/check.log'"

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All release script checks passed."
