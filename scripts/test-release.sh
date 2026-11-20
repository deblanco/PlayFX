#!/usr/bin/env bash
# Tests release.sh's notarization wait and its DMG app swap without Apple's notary service or a signing
# identity: a fake `xcrun` on PATH plays notarytool, and the DMG is a small one made here.
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

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All release script checks passed."
