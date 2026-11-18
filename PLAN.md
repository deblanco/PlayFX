# PLAN

Roadmap and gap list for **ps-remote-play** — a browser/desktop PS5 (and PS4) Remote Play client.
Status legend: ✅ done · 🔶 partial · ❌ not started.

Last updated by the build session that got end-to-end streaming working on real hardware.

---

## 1. What exists today

A Bun monorepo with a working macOS desktop client, proven end to end against a real PS5
(discovery → wake → pair → session → HEVC video → audio → controller input), both via the
headless `psrp` CLI and the Tauri app.

```
apps/desktop            Tauri v2 app: React 19 + Effect + Tailwind + shadcn UI over a
                        transparent webview, with native video drawn behind it.
  src/core              Effect services: Core (Tauri bridge), Preferences, schemas, runtime.
  src/app               React UI: Home, ConsoleList, Settings, StreamView, actions/format.
  src-tauri             Rust: Tauri commands → StreamCore C ABI (NativeCore trait, ffi/native).
packages/streamcore     Swift package (macOS + iOS target):
  Sources/CChiaki       psrp.h — thin C shim over libchiaki.
  Sources/StreamCore    Console (discover/register/wake), PSNAuth, StreamSession,
                        VideoDecoder (VideoToolbox), AudioPlayer, ControllerInput,
                        StreamRenderer (Metal + MetalFX), MacOSBridge (JSON C ABI).
  Sources/psrp          Headless debug CLI with a localhost control API.
third_party/chiaki-ng   Submodule (AGPL-3.0): the Remote Play protocol implementation.
```

**Working / ✅**
- Console discovery (UDP), wake-from-standby, PIN pairing, PSN OAuth → account ID.
- Session handshake (Senkusha/Takion/StreamConnection) over the LAN.
- Video: H.264 + HEVC hardware decode via VideoToolbox.
- Rendering: NV12 → RGB → MetalFX spatial upscale (with bilinear fallback), letterboxed.
- **Upscaler A/B**: `Compare (split)` upscaler mode (left bilinear, right MetalFX, divider +
  labels) in the desktop HUD/settings; `psrp` `/render.png?mode=…&w=…&h=…` renders the latest frame
  offscreen at any size (used for the 720p → 4K comparison screenshots).
- Audio: Opus decode → low-latency `AVAudioEngine` with a jitter buffer.
- Input: DualSense/DualShock/Xbox/MFi via the GameController framework.
- **Keyboard-as-controller** (testing without a pad): the web UI captures keys and forwards a
  controller state through `sc_session_set_controller`; mapping is a pure, tested function
  (`src/app/keyboard.ts`), with an in-HUD key legend. The headless `psrp` CLI also drives input
  via its `/press`, `/hold`, `/stick` control API.
- React/Effect UI: account, console list, pairing, settings, streaming HUD.
- Credentials kept client-side (webview `localStorage`); PSN login via Sony's own page.
- Tests + gates: TS 130 tests (100% lines), Swift 58 tests (95%), Rust 31 tests (86%),
  strict `tsc`/ESLint, `@effect/vitest`. Per-language `coverage.sh`.
- Ops: local rest-mode watchdog (`~/.config/psrp/rest-watchdog.sh`), auto-sleep after 2 h idle.

---

## 2. Missing — prioritized

### P0 — the features that most change what the product can do

- ❌ **Remote Play over the internet (PSN hole-punching).** Today everything is LAN-only; the
  app can't reach the console from another network. libchiaki already implements it
  (`lib/src/remote/holepunch.c`, `rudp.c`), but the shim wires `holepunch_session = NULL`.
  Work: extend `psrp.h`/`StreamSession` to accept a PSN token + DUID, implement the PSN session
  manager calls (device list, session create/message), surface a "connect from anywhere" path in
  the UI. This is the single highest-value feature (it's the reason LAN-only blocked real use).
- ❌ **Auto-wake on Play.** If the console is in standby when the user hits Play, wake it and poll
  until `ready` instead of failing. The console dropped to standby repeatedly in testing.
- ❌ **Reconnect & resilience.** Handle mid-stream drops, Wi-Fi/network changes, and the
  `RP_IN_USE` / version-mismatch quit reasons with clear UI and optional auto-retry/backoff.

### P1 — Picture quality & full stream configuration (next up)

Goal: the best possible image from a stream capped at 1080p, with **every stream and picture
parameter configurable from the desktop app**, and each change measurable with the compare view.

Findings that drive this (from the 720p → 4K screenshot session):
- The source, not the upscaler, is the main limit: chiaki's presets send **720p @ 10 Mbps** and
  **1080p @ 15 Mbps** (`chiaki_connect_video_profile_preset`), and 1080p is the max preset in this
  chiaki version. MetalFX sharpens compression artifacts along with detail.
- MetalFX spatial has no sharpness control and looks soft on video; it's best at ≤ 2× (1080p → 4K).
- Color is hardcoded: BT.709 limited range in `nv12ToRGB`, bilinear chroma, and the
  `CAMetalLayer` has no colorspace (P3 displays may oversaturate).

**Two kinds of settings** (the UI groups them this way):
- *Stream* (needs a reconnect; applied on next Play, with a "Reconnect to apply" action in the HUD):
  resolution, fps, codec, **bitrate**, auto-downgrade, audio on/off.
- *Picture* (live, per frame, no reconnect): upscaler, sharpness, deblock/deband strength,
  chroma filter, color matrix/range override, output colorspace. Sent to StreamCore as one
  JSON `RenderParams` via a single `sc_set_render_params` (replaces `sc_set_upscale_mode`).

Work items:
- ✅ **Q1. Stream parameters.** *(done: bitrate Auto/10–50 Mbps, auto-downgrade, audio; live Mbps in the
  HUD from received bytes. Measured on the PS5 while switching tiles at 1080p: 5.8 Mbps at the default
  cap vs 9.5 Mbps at 40 Mbps. Still frames converge at any cap: bitrate pays off in motion.)* Expose bitrate (presets 5–50 Mbps + "Auto" = chiaki default),
  auto-downgrade toggle, audio toggle; validate against the console's reply (actual resolution /
  bitrate from streaminfo) and show it in the HUD. Shim: pass `video_profile_auto_downgrade`
  through `PsrpSessionConfig`. Schema: extend `Settings` (Effect `Schema`) with migration of
  saved settings.
- ✅ **Q2. Sharpening pass (CAS/RCAS).** *(done: CAS in the present shader, neighbors one output pixel
  apart; picture settings now travel as one `RenderParams` JSON via `sc_set_render_params`; "compare"
  became a toggle: left = unprocessed baseline, right = current picture settings. On PS5 frames 0.3
  is subtle, 0.6 clearly crisper, 1.0 still halo-free.)* Compute pass after the upscaler (MetalFX *and* bilinear),
  `sharpness` 0–1 (0 = off). Port AMD FidelityFX CAS (MIT). Unit-test on synthetic edges
  (sharpness 0 = identity; >0 increases edge contrast without clipping).
- ✅ **Q3. Pre-upscale cleanup.** *(done: one `cleanup` compute pass at stream resolution feeding the
  upscaler; deblock on HEVC's 8×8 grid (small, flat-sided steps only), deband via rotated-cross averaging
  under a threshold + faint dither; both 0–1, default off; the compare baseline stays unfiltered. On PS5
  frames deband visibly removes fog contours in Silent Hill 2; deblock is for low-bitrate motion.)* Optional deblock + deband pass on the source-resolution
  texture before the upscaler (`deblock` 0–1, `deband` 0–1). Cheap at 1080p. Tests on synthetic
  8×8 block steps and gradients.
- ✅ **Q4. Color correctness.** *(done: matrix/range/chroma siting read from each frame — the PS5 signals
  BT.709 + left-sited chroma, so the old shader was a quarter chroma texel off — with overrides; bicubic
  (Catmull-Rom) or bilinear chroma; sRGB-tagged output ("Accurate") vs unmanaged ("Vivid"). On PS5
  frames the chroma changes are near-invisible (correctness, not a visible upgrade); the colorspace tag is
  the visible part and only shows on a wide-gamut display. `psrp /frameinfo` dumps a frame's colorimetry.)* Read matrix/range/transfer from the `CVPixelBuffer` attachments
  (BT.601/709/2020, limited/full) with a manual override; set the layer colorspace (Rec.709/sRGB)
  so macOS color-manages to the display; better chroma upsampling (bicubic or luma-guided).
  Groundwork for HDR (P1 below). Tests: known YCbCr triples per matrix/range.
- ❌ **Q5. Settings UI.** A Settings sheet with *Stream* and *Picture* sections (shadcn studio
  components), sliders for the 0–1 params, live preview while streaming, "Reset to defaults",
  and a compare mode that splits **current params vs. baseline** (not just bilinear vs MetalFX).
- ❌ **Q6. Measure.** Per-pass GPU time (`MTLCommandBuffer` GPU start/end) in the stats overlay;
  a `psrp` capture script that renders a fixed frame with N param sets → labeled grid, so
  quality claims are reproducible.
- ❌ **Q7. ML super-resolution (later, after Q1–Q6).** Apple's `VTLowLatencySuperResolutionScaler`
  (VideoToolbox, macOS 26+, in the SDK here) as a third upscaler, built for decoded compressed
  video. Check `supportedScaleFactors` for 720p/1080p, measure added latency vs MetalFX, keep
  MetalFX as the fallback. Ship only if the A/B and the latency numbers justify it.
- Not planned: MetalFX temporal / frame interpolation (need engine motion vectors + depth).

### P1 — making a stream feel complete

- 🔶 **Rumble.** Rumble events are received (`StreamSession.Event.rumble`) but not applied to the
  pad. Drive `GCDeviceHaptics` / `GCController` rumble from them.
- ❌ **Adaptive triggers** (DualSense). `trigger_effects` events aren't surfaced by the shim yet;
  forward them and apply via `GCDualSenseAdaptiveTrigger`.
- ❌ **DualSense haptics audio channel.** chiaki exposes a separate haptics sink; route it to the
  controller's haptic engine.
- ❌ **Touchpad + motion.** Map mouse/trackpad (and touch on mobile) to the PS touchpad; forward
  gyro/accel for motion-aware games.
- ❌ **Microphone.** chiaki supports mic capture/echo-cancel (speex, currently disabled); wire an
  opt-in mic path.
- ✅ **Keyboard-as-controller** for testing (done — see §1). Possible follow-ups: on-screen touch
  pad overlay, remappable keys.
- ❌ **Keyboard text passthrough** to the console (`enable_keyboard`) and the on-screen keyboard
  events (`KEYBOARD_*`) → let the user type into PS text fields (distinct from the above).
- ❌ **HDR.** `CHIAKI_CODEC_H265_HDR` isn't selectable; add HDR decode + display tone-mapping.
- 🔶 **Login PIN (console passcode) flow.** Plumbed end to end but not verified on a console that
  requires it; confirm and polish the dialog.

### P2 — quality, settings, UX

- ❌ **Bitrate / FPS / resolution validation** against what the console advertises; expose bitrate
  in settings (schema has it; UI doesn't).
- ❌ **Latency & frame pacing**: measure end-to-end latency, tune the audio/video jitter buffers,
  consider a low-latency present path; expose a stats overlay.
- ❌ **Audio controls**: output-device selection and volume.
- ❌ **Window UX**: fullscreen toggle, hide cursor during play, and **prevent the Mac from
  sleeping** while streaming (`IOPMAssertion`/`NSProcessInfo` activity).
- ❌ **Credential storage hardening**: move registration keys from `localStorage` to the macOS
  **Keychain** (and Keychain/Keystore on mobile).
- ❌ **First-run / onboarding** and clearer pairing guidance.

### P3 — reach: cross-platform and mobile

- ❌ **iOS app (Expo).** `apps/mobile` doesn't exist yet. Plan: an Expo native module wrapping
  `StreamCore` (the renderer/session are already platform-neutral; only `MacOSBridge.swift` is
  Mac-specific). Needs **full Xcode + an iOS SDK** (only Command Line Tools are installed now).
  Add an on-screen touch controller overlay and iOS lifecycle handling.
- ❌ **Windows / Linux.** Tauri is cross-platform, but `StreamCore` is Apple-only (VideoToolbox,
  Metal, MetalFX, GameController). A non-Apple target needs a different decode/render/input layer:
  - **FSR** (AMD FidelityFX Super Resolution 1, MIT) as the upscaler, e.g. as WGSL/WebGPU or a
    native shader — the cross-platform analogue of MetalFX spatial. (MetalFX *temporal* and frame
    interpolation need motion vectors a video stream lacks, so they don't apply here.)
  - Hardware decode via the platform API (D3D11VA/NVDEC, VAAPI) or a portable decoder.
- ❌ **Browser build** (the original ask). Not possible in a normal tab (no raw UDP/TCP). Revisit
  only if Chrome Direct Sockets / Isolated Web Apps become broadly available, or ship the
  "browser client + tiny local relay" design documented earlier. Keep the socket layer swappable.

### P4 — build, distribution, compliance

- ❌ **AGPL compliance.** `third_party/chiaki-ng` is **AGPL-3.0**; any distributed build must make
  complete source available and carry the license. Add `LICENSE`, NOTICE, and a build/source link.
  Decide the project's own license accordingly before any public release.
- ❌ **Sony ToS note.** Unofficial client; fine for personal use, but document the stance and
  don't ship anyone's credentials.
- ❌ **Packaging**: code-sign + notarize the macOS app, bundle the static libs/rpath correctly,
  produce a `.dmg`. (Currently relies on an `-rpath /usr/lib/swift` link arg for dev.)
- ❌ **CI**: build + test + coverage for all three languages; reproducible libchiaki build
  (`packages/streamcore/scripts/build-chiaki.sh`) with the OpenSSL-3 pinning and curl trimming.
- ❌ **Reproducibility**: `vendor/macos/lib/*.a` are generated and gitignored; document/automate
  regenerating them, and the Homebrew deps (`cmake ninja openssl@3 opus json-c miniupnpc libevent`).

---

## 3. Known issues / tech debt

- 🔶 **Swift tests under Command Line Tools**: `swift test` reports 0 tests on this machine
  (no full Xcode); `scripts/coverage.sh` runs the 58 tests correctly. Installing Xcode fixes
  `swift test` and unblocks the iOS target.
- 🔶 **Rust coverage tooling** had to be bootstrapped by hand (rustup not on PATH, llvm-tools);
  see `apps/desktop/src-tauri/scripts/coverage.sh`. Document it in CI.
- 🔶 `preferences.ts` has one unreachable branch (88.9% branch) — the `if (p)` guard in
  `refreshAddresses`. Harmless; left as-is.
- 🔶 `renderer_status` returns `stream: null` when stats JSON can't be parsed, which surfaces as a
  `CoreError`. Decide whether to soften this.
- 🔶 **Linker warnings**: vendored static libs built for a newer macOS than the 13.0 deployment
  target. Harmless; silence by building the deps at the target version.
- 🔶 **FFI safety**: the Rust↔Swift boundary (CString lifetimes, `sc_free` once, main-thread
  rules) was reviewed and tested, but every new `@_cdecl` needs the same care.
- ℹ️ **Dev E2E harness** (`src/app/devSeed.ts` + autoplay) is env-gated and inert in production;
  the seed file holding keys is gitignored. Keep it dev-only.
- ℹ️ The `psrp` CLI is a debugging tool, not a shipped artifact.

---

## 4. Suggested order of work

0. Picture quality & full stream configuration, Q1 → Q6, then evaluate Q7. *(P1, requested)*
1. Auto-wake on Play (small, removes a constant papercut). *(P0)*
2. Reconnect/resilience + clear quit-reason UI. *(P0)*
3. Remote Play over the internet (hole-punching) — the headline feature. *(P0)*
4. Rumble + adaptive triggers + touchpad/motion. *(P1)*
5. Keychain credential storage; sleep-prevention; fullscreen/cursor. *(P2)*
6. Packaging + AGPL/licensing + CI. *(P4, before any release)*
7. iOS (Expo) once Xcode is installed; then Windows/Linux via an FSR path. *(P3)*
