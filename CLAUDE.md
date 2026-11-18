# ps-remote-play

PS5/PS4 Remote Play client. Bun monorepo:

- `apps/desktop` — Tauri v2 app (macOS first). React UI in a transparent webview over a native Metal view.
- `packages/streamcore` — shared Swift package (macOS + iOS): libchiaki session, VideoToolbox decode,
  Metal + MetalFX upscaling, audio, controller input. `psrp` CLI for headless debugging.
- `third_party/chiaki-ng` — git submodule (AGPL-3.0); the Remote Play protocol implementation.
- Future: `apps/mobile` (Expo) reusing StreamCore on iOS.

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

### UI
- Tailwind CSS v4 for styling; no hand-written CSS beyond Tailwind's theme layer.
- Components come from shadcn/ui, preferring blocks/components from the shadcn studio registry
  (https://shadcnstudio.com, `@shadcn-studio` in `components.json`) before writing custom ones.

### Tests: ≥ 80% coverage, everywhere
- Every package keeps line, branch and function coverage at or above **80%**; the coverage commands
  fail below that. New code ships with tests.
  - TypeScript: `vitest` + `@effect/vitest`, `bun run test:coverage` (thresholds in `vitest.config.ts`).
  - Swift: `swift test --enable-code-coverage` via `packages/streamcore/scripts/coverage.sh`.
  - Rust: `cargo llvm-cov` via `bun run --cwd apps/desktop coverage:rust`.
- Code that can only run against real hardware (a console, a GPU display link, a gamepad) is kept in
  thin adapters; the logic around it is extracted and unit-tested.

## Build notes
- Rust isn't on the default PATH on this machine: `export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"`.
- Build libchiaki once (and after bumping the submodule): `packages/streamcore/scripts/build-chiaki.sh`.
- Run the desktop app: `bun run desktop`.
- Headless debugging against a real console: `packages/streamcore/.build/debug/psrp --help`-style
  commands (`discover`, `register`, `stream` with a control API on `127.0.0.1:7777`). Pairing keys live in
  `~/.config/psrp/config.json`; never commit or print them.
