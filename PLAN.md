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

- 🔶 **Remote Play over the internet (PSN hole-punching).** In progress — PS5 only (libchiaki only lists
  PS5s), console must be paired on the LAN first. libchiaki does PSN sessions, STUN/UPnP, hole punching and
  a fresh PSN-side registration per connection inside `chiaki_session_start`; the app supplies tokens, the
  console's PSN device ID, and runs the blocking setup (≤30 s per step) off the main thread.
  - ✅ 1. PSN tokens: sign-in carries a fresh `duid`; access + refresh tokens kept in the Keychain (never
    the web UI), refreshed a minute before expiry, cleared on a rejected refresh or sign-out.
  - ✅ 2. Find the console via PSN: `psrp_psn_list_consoles` (libchiaki's device list, PS5) → name, PSN
    device ID, Remote Play on; matched to paired consoles by name or the console's nickname, as chiaki-ng
    does; `psrp psn-consoles` for checking from the CLI. (Real account check pending the user's sign-in.)
  - ✅ 3. Connect over the internet: with a PSN token + the console's device ID, `psrp_session_start`
    returns at once and a worker runs PSN session → UPnP → session create → offer → start → control
    hole, then hands the holepunch session to chiaki (which re-registers over PSN and opens the data
    hole); progress events (linking → data → connected); stop cancels the blocking steps and joins;
    controller/PIN/IDR calls are dropped until the session exists; clear errors for "PSN can't reach
    the PS5" and "this network blocks it". The token is fetched natively (Rust, off the main thread) and
    never passes through the web UI. `psrp stream --psn` for CLI testing.
  - ❌ 4. UI + verification from another network (e.g. phone hotspot).
- ✅ **Auto-wake on Play.** *(done: Play is enabled for consoles in rest mode — it sends the wake-up,
  shows "Waking…" with Cancel, polls discovery every second (re-sending the wake-up every 5 checks), and
  plays once the console is ready; after 45 s it explains the "Stay connected to the internet" rest-mode
  setting. A stream that gets "busy" before it connected (just woken, or right after another session)
  waits it out instead of failing. Verified on the PS5: rest mode → one click → streaming in 11 s.)*
- 🔶 **Reconnect & resilience.** *(done: StreamCore classifies quits as final / busy / dropped; a connected
  stream that drops (stream/control connection lost) reconnects on its own — HUD "Connection lost.
  Reconnecting…", last frame held — up to 3 times per session, retrying while the console is busy; final
  quits (console asleep, version mismatch…) go home with the reason. Not yet: Wi-Fi/network-change
  detection, a manual "Try again" on the error, and verifying a real drop on hardware — it needs pulling
  the network for a few seconds, which this session couldn't do without root.)*


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
- ✅ **Q5. Settings UI.** *(done: a non-modal glass sheet over the live video with Picture (live) and
  Stream (next connection) tabs; a "picture pipeline" strip — Clean up → Upscale → Sharpen → Color, in
  render order, lit amber where a stage changes the picture — jumps to each stage's controls; sliders,
  segmented choices and switches replace the selects; Split screen labels sit at the divider. Changing
  stream settings mid-stream offers **Reconnect**, which retries while the PS5 says it's busy (measured:
  it refuses new sessions for ~9 s after one ends; StreamCore now flags that quit as `busy`). Verified
  on the real console: reconnect 1080p→720p after 5 busy answers, no stray errors.)*
  - ✅ Follow-up done: the last frame stays on screen while reconnecting (start replaces the session; a
    quit's own cleanup no longer brings back the idle pattern, and is ignored if a newer session started).
  - ℹ️ The dev autoplay harness re-plays when Home remounts (dev-only, harmless).
  - Note: the split screen now compares *baseline vs. all current picture settings* (upscaler included)
    rather than only bilinear vs MetalFX. A Settings sheet with *Stream* and *Picture* sections (shadcn studio
  components), sliders for the 0–1 params, live preview while streaming, "Reset to defaults",
  and a compare mode that splits **current params vs. baseline** (not just bilinear vs MetalFX).
- ✅ **Q6. Measure.** *(done: smoothed GPU time per frame in the HUD — measured 2.9 ms for 720p →
  window with MetalFX + sharpen + split, well inside a 60 fps frame; `psrp /grid.png?vary=…&values=…&crop=…`
  renders one frame per value, so A/B grids are same-frame and reproducible. Scope cut: per-pass timings
  (would need Metal counter sample buffers) — toggle a stage in the HUD to see its cost instead.)* Per-pass GPU time (`MTLCommandBuffer` GPU start/end) in the stats overlay;
  a `psrp` capture script that renders a fixed frame with N param sets → labeled grid, so
  quality claims are reproducible.
- ✅ **Q7. ML super-resolution.** *(done, opt-in: Apple's `VTLowLatencySuperResolutionScaler` runs on
  the decoded NV12 frame inside the Metal command buffer, before conversion/cleanup/MetalFX — "ML upscaling
  first". Limits measured on this Mac: inputs ≤ 1280 px per side, 720p → 1.5× only, 540p → 1.5×/2×, so
  **1080p streams can't use it**. On PS5 frames at 720p it's the biggest visible gain of the whole series
  (much crisper hair/edge detail, same frame A/B via `/grid.png?vary=ml`), but it costs ~5.5 ms wall time
  per frame (6.1 → 11.4 ms median; GPU time barely moves — the model runs off the GPU), so it's **off by
  default** and the UI states the latency. The full (non-low-latency) VT scaler was ruled out: model
  download, cross-frame optical flow, offline-oriented. The compare baseline stays the raw stream.)*
- Not planned: MetalFX temporal / frame interpolation (need engine motion vectors + depth).

### P1 — making a stream feel complete

- 🔶 **Rumble.** *(built, **unverified on hardware** — no pad was connected: the console's two motor
  levels play through GameController haptics, the heavy motor on the left handle and the light one on the
  right (or the stronger one on single-actuator pads), as looping continuous haptics whose intensity
  follows the console; stopped when the session ends. To verify: connect a DualSense, play a game that
  rumbles.)*
- 🔶 **Adaptive triggers** (DualSense). *(built, **unverified on hardware**: the shim forwards
  libchiaki's trigger-effect events (the DualSense's raw format: mode byte + 10 parameters per trigger);
  `TriggerEffect` decodes feedback (per-zone resistance), weapon, vibration (per-zone amplitude +
  frequency), bow/galloping/machine (as the nearest weapon/vibration) and the older simple modes; the
  adapter applies them with `GCDualSenseAdaptiveTrigger`, and releases the triggers when the session
  ends. To verify: a DualSense and a game that uses the triggers, e.g. Astro's Playroom.)*
- ❌ **DualSense haptics audio channel.** chiaki exposes a separate haptics sink; route it to the
  controller's haptic engine.
- 🔶 **Touchpad + motion.** *(touchpad built, **unverified on hardware**: the shim takes a struct-based
  controller state (`psrp_session_set_controller_state`) with up to 2 touches on the 1920×1079 pad; the
  DualSense/DS4 touchpad is read through GameController with a stable id per finger while it's down (new
  id per touch, 7 bits). Limitation: GameController reports a lifted finger as (0, 0), so a finger exactly
  at the center reads as lifted. Motion built, **unverified on hardware**: the pad's gyro (rad/s) and
  accelerometer (g, gravity included) go to the shim, which derives the orientation with libchiaki's
  Madgwick tracker per session, as chiaki-ng does. To verify on a DualSense: the axis conventions between
  GameController and the console (may need sign flips), and motion aiming in a game. Not yet: mouse/
  trackpad → touchpad from the Mac.)*
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
- ✅ **Window UX.** *(done: the Mac and its display stay awake exactly while a session runs (a
  `ProcessInfo` user activity — `pmset -g assertions` shows "Streaming from a PlayStation"); a Fullscreen
  HUD button and double-click on the video toggle native fullscreen (Rust `toggle_fullscreen`, reading
  the window's real state); the cursor auto-hides after 5 s without mouse movement while streaming and
  comes back on any movement, never while the settings are open. Verified live on the PS5.)*
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

0. ~~Picture quality & full stream configuration, Q1 → Q7~~ (done). *(P1, requested)*
1. ~~Auto-wake on Play~~ (done). *(P0)*
2. Reconnect/resilience + clear quit-reason UI. *(P0)*
3. Remote Play over the internet (hole-punching) — the headline feature. *(P0)*
4. Rumble + adaptive triggers + touchpad/motion. *(P1)*
5. Keychain credential storage. *(P2)* (sleep-prevention, fullscreen and cursor: done)
6. Packaging + AGPL/licensing + CI. *(P4, before any release)*
7. iOS (Expo) once Xcode is installed; then Windows/Linux via an FSR path. *(P3)*
