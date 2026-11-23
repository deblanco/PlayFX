#!/usr/bin/env bash
# Runs the PlayFXProtocol tests. With only the Command Line Tools installed, SwiftPM compiles its test
# runner without swift-testing's framework search path, so a bare `swift test` builds the tests but
# runs none of them; passing the path globally fixes that (harmless with a full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
FLAGS=()
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  FLAGS=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
