#!/usr/bin/env bash
# Runs the crate's tests under cargo-llvm-cov, prints the per-file summary and fails below 80%
# line or function coverage. Test-only code (src/tests/) and the bare binary entry (main.rs) are excluded from the report.
#
# One-time setup: rustup component add llvm-tools-preview && cargo install cargo-llvm-cov --locked
# Branch coverage needs nightly (-Z coverage-options=branch), so it isn't gated on stable.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PATH"

if ! cargo llvm-cov --version >/dev/null 2>&1; then
  echo "cargo-llvm-cov not found; run: rustup component add llvm-tools-preview && cargo install cargo-llvm-cov --locked" >&2
  exit 1
fi

cargo llvm-cov \
  --ignore-filename-regex 'src/(tests/|main\.rs)' \
  --show-missing-lines \
  --fail-under-lines 80 \
  --fail-under-functions 80 \
  "$@"
