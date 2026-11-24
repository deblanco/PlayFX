# PlayFX

PlayFX: a PS5/PS4 Remote Play client for macOS (repo folder: `ps-remote-play`). Bun monorepo:

- `apps/desktop` — Tauri v2 app (macOS first). React UI in a transparent webview over a native Metal view.
- `packages/streamcore` — shared Swift package (macOS + iOS): the stream session (`PlayFXEngine`, on
  PlayFXProtocol), VideoToolbox decode, Metal + MetalFX upscaling, audio, controller input. `psrp` CLI for
  headless debugging.
- `packages/playfxprotocol` — PlayFX's own Remote Play protocol implementation in Swift (proprietary), written
  clean-room from the facts-only spec in `docs/protocol`.
- Scope: macOS only. No iOS/Expo, Windows/Linux or browser builds are planned.

## Rules

### TypeScript: Effect everywhere
- All TypeScript uses [Effect](https://effect.website) (`effect` v4). No raw Promises, `try/catch`,
  `JSON.parse` or untyped `any` in app code — model work as `Effect`, errors as tagged errors
  (`Schema.TaggedError` / `Data.TaggedError`), dependencies as services provided through Layers.
- Every value crossing a boundary (Tauri `invoke` replies, events, `localStorage`, network) is decoded
  with `Schema`. Types are derived from schemas, not declared twice.
- React components stay thin: they run effects through the app's `ManagedRuntime` and render state.
- Static analysis is strict and must pass with zero warnings: `tsc` (strict +
  `exactOptionalPropertyTypes` + `noUncheckedIndexedAccess`), ESLint with `typescript-eslint`
  strict-type-checked, and the Effect language service.

### PLAN.md stays current
- Every feature or fix commit updates `PLAN.md` in the same commit: its entry (✅/🔶, what was verified and
  how, what's left), section 4 "Suggested order of work", and the "Last updated" line and test counts
  when they change. One commit per feature, pushed after each.

### UI
- Tailwind CSS v4 for styling; no hand-written CSS beyond Tailwind's theme layer.
- Components come from shadcn/ui (MIT) before writing custom ones.

### Licences
- PlayFX is proprietary (LICENSE). Only permissively licensed code goes in (MIT, BSD, ISC, Apache-2.0,
  zlib…): no copyleft (GPL/LGPL/AGPL/MPL) and no source-available licences (e.g. shadcn/studio blocks, MIT
  with a Commons Clause). Anything new that ships gets an entry in `THIRD_PARTY_LICENSES` (re-run
  `scripts/third-party-licenses.py`).

### Tests: ≥ 80% coverage, everywhere
- Every package keeps line, branch and function coverage at or above **80%**; the coverage commands
  fail below that. New code ships with tests.
  - TypeScript: `vitest` + `@effect/vitest`, `bun run test:coverage` (thresholds in `vitest.config.ts`).
  - Swift: `swift test --enable-code-coverage` via `packages/streamcore/scripts/coverage.sh`. CI runs in a
    VM, where VideoToolbox frame interpolation and ML upscaling are off; `STREAMCORE_SIMULATE_VM=1` before
    the script shows locally what CI's coverage sees. Hardware engines are injected so the logic around
    them is tested in both.
  - Rust: `cargo llvm-cov` via `bun run --cwd apps/desktop coverage:rust`.
- Code that can only run against real hardware (a console, a GPU display link, a gamepad) is kept in
  thin adapters; the logic around it is extracted and unit-tested.

## Build notes
- Rust isn't on the default PATH on this machine: `export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"`.
- StreamCore links Homebrew's static libopus: `brew install opus` once (`OPUS_PREFIX` overrides where it's found).
- Run the desktop app: `bun run desktop`.
- Drive a running dev build from scripts (settings, play, button presses, renderer stats) with the dev
  control port: `PLAYFX_DEV_CONTROL=7780 bun run desktop`; see `docs/dev-control.md`. Never in release builds.
- Headless debugging against a real console (psrp runs on PlayFXProtocol through StreamCore):
  `packages/streamcore/.build/debug/psrp --help`-style
  commands (`discover`, `register`, `stream` with a control API on `127.0.0.1:7777`). Pairing keys live in
  `~/.config/psrp/config.json`; never commit or print them.
