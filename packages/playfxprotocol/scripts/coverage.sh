#!/usr/bin/env bash
# Runs the tests with coverage for Sources/PlayFXProtocol; line and function coverage must be at least
# $MIN_COVERAGE (default 80). SwiftPM records no branch coverage for Swift.
set -euo pipefail
cd "$(dirname "$0")/.."
MIN_COVERAGE="${MIN_COVERAGE:-80}"

./scripts/test.sh --enable-code-coverage "$@"

BIN_DIR="$(swift build --show-bin-path)"
PROFDATA="$BIN_DIR/codecov/default.profdata"
BINARY="$BIN_DIR/PlayFXProtocolPackageTests.xctest/Contents/MacOS/PlayFXProtocolPackageTests"
# Newer toolchains build tests with the Xcode build system, under .build/out/Products/Debug.
if [[ ! -f "$BINARY" && -d .build/out/Products/Debug/PlayFXProtocolTests.xctest ]]; then
  PROFDATA=.build/out/Products/Debug/codecov/default.profdata
  BINARY=.build/out/Products/Debug/PlayFXProtocolTests.xctest/Contents/MacOS/PlayFXProtocolTests
fi
[[ -f "$PROFDATA" ]] || { echo "coverage: no profile data at $PROFDATA" >&2; exit 1; }
[[ -f "$BINARY" ]] || { echo "coverage: no test binary at $BINARY" >&2; exit 1; }

report() { xcrun llvm-cov report "$BINARY" -instr-profile "$PROFDATA" "$@"; }

echo
echo "== PlayFXProtocol =="
report Sources/PlayFXProtocol

# TOTAL row: Filename Regions Missed Cover Functions Missed Executed Lines Missed Cover
TOTAL="$(report Sources/PlayFXProtocol | awk '/^TOTAL/')"
LINES="$(echo "$TOTAL" | awk '{ print $10 }' | tr -d '%')"
FUNCTIONS="$(echo "$TOTAL" | awk '{ print $7 }' | tr -d '%')"
echo
status=0
for metric in "line:$LINES" "function:$FUNCTIONS"; do
  name="${metric%%:*}"; value="${metric#*:}"
  if awk -v c="$value" -v m="$MIN_COVERAGE" 'BEGIN { exit !(c + 0 >= m + 0) }'; then
    echo "PlayFXProtocol $name coverage ${value}% (>= ${MIN_COVERAGE}%)"
  else
    echo "PlayFXProtocol $name coverage ${value}% is below ${MIN_COVERAGE}%" >&2
    status=1
  fi
done
exit $status
