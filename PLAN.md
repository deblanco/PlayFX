# PLAN

Roadmap and gap list for **PlayFX** — a macOS PS5 (and PS4) Remote Play client.
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
  - ✅ 4. UI: paired PS5s PSN can reach but that aren't on this network show as "internet" (checked every
    minute when signed in for internet play); Play connects through PSN with a connecting screen (route
    map, steps, elapsed time, Cancel); a Connect choice on the home screen (Automatic / Home network /
    Internet); Automatic falls back to PSN when the home network can't reach or wake the console;
    reconnects through PSN stop the old session and wait 10 s for the console to release it. Verified in
    the desktop app on the real PS5 (connects in ~27 s; settings reconnect in 39 s). Still to do: a run
    from another network (phone hotspot) — needs the user.
  - ✅ Verified on the real account and PS5 (via `psrp stream --psn`, routed through PSN from the home
    network): PSN lists PS5-454; connected in 28 s (UPnP mapping, PSN-side registration, data hole);
    1280×720 with 0 lost frames; controller input reaches the console; cancelling mid-setup exits in
    0.5 s with a clean "Stopped". Still to do: the desktop UI flow and a run from another network (phone
    hotspot) — the "internet" row only appears when the console isn't found locally.
  - ⚠️ Correction: the "PSN revoked the sign-in" seen after the first real run was our own bug — a
    bridge test signed in (with a stubbed Sony reply) through `PSNAccount.shared` and overwrote the real
    stored tokens on every test run; the first logs showed Sony's reply ("invalid_grant — 4159 — Invalid
    refresh token" for our fake token). Fixed: tests swap in an in-memory store. The refresh-and-retry on
    a rejected token stays as a safety net.
  - ⚠️ Dev builds are unsigned, so macOS ties the Keychain item to each build: after a rebuild, reading
    the PSN tokens shows a Keychain prompt (and blocks while the screen is locked). Signed release builds
    don't have this; for the CLI, consider a 0600 file store like the pairing keys.
- ✅ **Auto-wake on Play.** *(done: Play is enabled for consoles in rest mode — it sends the wake-up,
  shows "Waking…" with Cancel, polls discovery every second (re-sending the wake-up every 5 checks), and
  plays once the console is ready; after 45 s it explains the "Stay connected to the internet" rest-mode
  setting. A stream that gets "busy" before it connected (just woken, or right after another session)
  waits it out instead of failing. Verified on the PS5: rest mode → one click → streaming in 11 s.)*
- ✅ **Reconnect & resilience.** *(done: StreamCore classifies quits as final / busy / dropped; a connected
  stream that drops (stream/control connection lost) reconnects on its own — HUD "Connection lost.
  Reconnecting…", last frame held — up to 3 times per session, retrying while the console is busy; final
  quits (console asleep, version mismatch…) go home with the reason in plain words and a **Try again**
  button (same console, same route). **Network changes**: an `NWPathMonitor` runs while a session does;
  when the Mac comes back online or moves to another interface (Wi-Fi ↔ Ethernet, another Wi-Fi) the app
  reconnects at once ("Your network changed. Reconnecting…") instead of waiting for the stream to time
  out; going offline alone does nothing. Not verified on hardware: switching networks mid-stream would cut
  the remote session used to develop this, so it's unit-tested only.)*


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
  - ✅ **View** (requested): the split-screen switch became a three-way choice in Settings → Picture —
    **Original** (the stream as it arrives: no clean-up, upscaling, sharpening, ML or smooth motion; colors
    kept), **Split** (both halves) and **Enhanced** (the picture settings, the default). Saved; the pipeline
    strip shows every stage off in Original.
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

- 🔶 **Rumble.** *(plays on a DualSense over Bluetooth — `psrp pad` /rumble; feel in a game unverified):
  the console's two motor levels play through GameController haptics, the heavy motor on the left handle
  and the light one on the right (or the stronger one on single-actuator pads); stopped when the session
  ends. **It never played before**: on macOS 27 gamecontrollerd rejects patterns sent for an *advanced*
  (looping) player — `AVHapticEvent` isn't in its allowed XPC classes, so it drops the connection (error
  4097). Now a plain player runs one 30 s continuous event, its intensity follows the console through
  dynamic parameters, and it is replaced every 25 s while rumbling. Engine failures are logged.)*
- 🔶 **Adaptive triggers** (DualSense). *(**felt on a DualSense over Bluetooth** with `psrp pad`: feedback,
  weapon, and raw console effects through the decoder (0x25 weapon, 0x26 vibration) all play; in a game
  unverified. The console's vibration frequency (Hz) is mapped to GameController's 0–1 as Hz/255, a guess
  to tune in a game. The shim forwards
  libchiaki's trigger-effect events (the DualSense's raw format: mode byte + 10 parameters per trigger);
  `TriggerEffect` decodes feedback (per-zone resistance), weapon, vibration (per-zone amplitude +
  frequency), bow/galloping/machine (as the nearest weapon/vibration) and the older simple modes; the
  adapter applies them with `GCDualSenseAdaptiveTrigger`, and releases the triggers when the session
  ends. To verify in a game: Astro's Playroom.)*
- 🔶 **DualSense haptics channel** (built; the stream arrives — feel on a pad unverified): PS5 games drive
  the DualSense's voice-coil motors with a haptics audio stream instead of rumble events, so pads got
  nothing in those games. The shim now takes libchiaki's haptics sink and, as chiaki-ng does for pads
  that can't play it (GameController can't take raw haptic audio), turns each 10 ms frame into rumble
  strengths (mean |sample| per channel, noise floor), reported only when they change, through the
  existing rumble path. Seen live in Silent Hill 2: 44 rumble updates in ~10 s of play (`psrp /status`
  now counts them). A pad in hand is needed to judge the feel.
- 🔶 **Touchpad + motion.** *(touchpad built, **unverified on hardware**: the shim takes a struct-based
  controller state (`psrp_session_set_controller_state`) with up to 2 touches on the 1920×1079 pad; the
  DualSense/DS4 touchpad is read through GameController with a stable id per finger while it's down (new
  id per touch, 7 bits). Limitation: GameController reports a lifted finger as (0, 0), so a finger exactly
  at the center reads as lifted. Motion built, **unverified on hardware**: the pad's gyro (rad/s) and
  accelerometer (g, gravity included) go to the shim, which derives the orientation with libchiaki's
  Madgwick tracker per session, as chiaki-ng does. To verify on a DualSense: the axis conventions between
  GameController and the console (may need sign flips), and motion aiming in a game. **Mac pointer as
  the touchpad** (done): hold ⌥ Option over the video and the pointer is a finger (the video's area maps
  to the pad), ⌥-click presses the touchpad; the video is outlined as a glowing pad with the finger dot
  (ripple on press). StreamCore merges this finger and press into whatever the pad or keyboard sends
  (`sc_session_set_pointer_touch`), one update per animation frame. **Verified on the PS5**: in
  Silent Hill 2 an ⌥-click on the video opened the map, as the pad's touchpad button does.)*
- 🔶 **Pad buttons on the Mac** (`psrp pad`, DualSense over Bluetooth, 2026-11-19): every face/shoulder/
  D-pad/stick button, Create, Options, the touchpad click and both analog triggers (0–255) map correctly;
  touchpad ids are stable per finger and two fingers track. All elements opt out of macOS system
  gestures. **PS button**: macOS never delivers it to the app; with a game-category app in front
  (`LSApplicationCategoryType` games, now in the desktop `Info.plist`) it at least stops opening the
  Games app. Keyboard H still sends PS. **Mute** isn't exposed by GameController.
- ✅ **Microphone** (verified on the Mac with the user allowing the prompt: capture starts — 48 kHz mono
  input converted to stereo — the stream stays clean at 60 fps / 0 lost, the amber button and the tag
  after the HUD fades both show, and turning it off stops capture; hearing it on the console needs a
  party chat, not checked): a **Mic** button in the stream HUD (off by default) captures the default
  input with AVAudioEngine, converts it to 48 kHz stereo 16-bit, cuts it into 10 ms frames and sends them
  through libchiaki's Opus encoder (`psrp_session_set_mic` connects the console's mic channel on first
  use, then toggles mute). While it's live the button turns amber ("Mic on") and an amber "Mic on" tag
  stays in the corner after the HUD fades. Permission denied / no input explain what to do. The app's
  `Info.plist` carries the usage description (macOS kills apps that touch the mic without one; StreamCore
  refuses instead when it's missing). No echo cancellation yet (chiaki-ng's speex path) — use headphones.
- ✅ **Keyboard-as-controller** for testing (done — see §1). Possible follow-ups: on-screen touch
  pad overlay, remappable keys.
- ⛔ **Keyboard text passthrough** (built, but switched off — blocked by the console): the UI and plumbing
  exist (console `KEYBOARD_*` events → a bar at the bottom of the video, every change mirrored into the
  field, Return sends, Esc cancels; `psrp /type`). But enabling it (`enable_keyboard`) makes the PS5 shut
  the stream down right after "Enabling Keyboard" — A/B tested back to back: flag off streams, flag on is
  closed with "Server shutting down". chiaki-ng ships it off too. Left off; revisit if libchiaki learns
  the right handshake.
- ✅ **HDR** (verified on the PS5 with Silent Hill 2 on the MacBook Pro's XDR display: the console sends
  10-bit `x420` frames tagged BT.2020 + PQ, the renderer switches to EDR, the stats line reads "HDR", 61 fps,
  0 lost frames; earlier connection failures were PSN flakiness, an SDR control run in between): an **HDR**
  switch in Settings → Stream (HEVC only) asks the PS5 for HEVC HDR10 (`CHIAKI_CODEC_H265_HDR`). VideoToolbox
  then decodes to 10-bit (`x420`); frames tagged with the PQ curve switch the renderer to HDR: float
  (rgba16F) textures through clean-up / MetalFX (HDR processing mode) / sharpen, the PQ curve turned into
  light (203 nits = SDR white = 1.0) in BT.2020, and an EDR layer (`extendedLinearITUR_2020`) so highlights
  go brighter than white on XDR / HDR displays (macOS clips beyond the display's headroom). It switches
  back to SDR for SDR frames or the backdrop. ML upscaling and Smooth motion only take 8-bit frames, so they
  sit out in HDR. The stats line says "HDR" while it's on. Unit test: a 1000-nit HDR10 frame renders at
  ~4.9× SDR white. `psrp stream --hdr` for CLI checks (`/frameinfo` shows the curve).
- 🔶 **Login PIN (console passcode) flow.** Plumbed end to end but not verified on a console that
  requires it; confirm and polish the dialog.

### P2 — quality, settings, UX

- ✅ **Bitrate / FPS / resolution validation**: bitrate is in Settings → Stream; the stats line shows what
  the console actually sends, and flags a lower resolution than asked for in amber ("1280×720 (asked
  1080p)" — auto-downgrade at work).
- ✅ **Latency & frame pacing** (Mac side): the stats line shows **latency** = VideoToolbox decode time
  (measured per frame) + display time (decoded frame → on screen, from Metal's presented-time handler),
  amber at ≥ 33 ms; the network's part is the ping. Present path: two drawables instead of three, so a
  frame waits at most one refresh; this also stopped draws from running ahead of the screen, which had
  made Smooth motion think a 60 Hz screen was faster and turn itself on for 60 fps streams (holding real
  frames back for nothing). Measured on the PS5: 44 ms (3 drawables, Smooth motion wrongly on) → 33 ms
  (2 drawables; not a strict A/B). Not done: audio jitter-buffer tuning (no audio/video sync complaints
  so far).
- ✅ **Audio controls**: Volume (0–100 %) and Output (System default or any of the Mac's outputs, by
  CoreAudio UID) under Sound in Settings → Stream, applied at once to the playing stream and saved for
  later ones (`sc_audio_devices`, `sc_set_audio_output`). A chosen device that's unplugged plays through
  the system default and the setting says so. Not checked by ear (nobody at the Mac).
- ✅ **Window UX.** *(done: the Mac and its display stay awake exactly while a session runs (a
  `ProcessInfo` user activity — `pmset -g assertions` shows "Streaming from a PlayStation"); a Fullscreen
  HUD button and double-click on the video toggle native fullscreen (Rust `toggle_fullscreen`, reading
  the window's real state); the cursor auto-hides after 5 s without mouse movement while streaming and
  comes back on any movement, never while the settings are open. Verified live on the PS5.)*
- ✅ **Credential storage hardening**: pairing keys and the PSN account ID live in a native secret store —
  the Keychain in release builds, a 0600 file in development (`~/.config/psrp/playfx-secrets.json`, or
  `$PSRP_SECRET_FILE`; an unsigned build would get a Keychain prompt after every rebuild) — through
  `sc_secret_get/set/remove` and Tauri commands. Existing pairings move out of the webview's localStorage
  on first read and are deleted there; settings stay in localStorage. Verified on the user's real data:
  the file is created 0600 with the pairing and account ID, both gone from localStorage, the console still
  listed as paired.
- ✅ **First-run / onboarding**: until a console is paired, the home card opens with a "Get started"
  guide — 1 Sign in with PlayStation, 2 Pair your PS5 (where the code is: Settings › System › Remote
  Play › Pair Device), 3 Play — marking each step done / current / waiting as the user goes; it never
  shows (or flashes) once a console is paired. Clearer copy: "No consoles found. Check that your PS5 is
  on or in rest mode, on this Mac's network."; the account note now says the ID and sign-in stay in the
  Mac's Keychain. Checked by unit tests (the dev seed refills the webview's storage, so a clean first run
  couldn't be shown live).

### Out of scope: other platforms

The project focuses on **macOS only** (decided 2026-11-18). Not planned: an iOS app (Expo), Windows /
Linux (would need a non-Apple decode/render/input layer, e.g. FSR), or a browser build (no raw UDP/TCP
in a normal tab). StreamCore keeps its iOS target in `Package.swift`, but nothing depends on it.

### P4 — build, distribution, compliance

- ✅ **AGPL compliance.** PlayFX is AGPL-3.0-only (chiaki-ng is AGPL-3.0-only with an OpenSSL
  exception): `LICENSE`, `NOTICE` (third-party code linked in), both copied into the app's Resources,
  license fields in every manifest, and Settings → Diagnostics → **Source code** opens the repo. Make the
  repo public (or publish the source) with the first public build.
- ✅ **Sony ToS note.** README: unofficial client, own consoles and account, PSN sign-in only through
  Sony's page, no credentials shipped. NOTICE and the app's About text: not affiliated with Sony.
- 🔶 **Packaging** *(built and launched unsigned; signing needs the personal Developer ID)*: bundle ID
  `dev.deblanco.playfx`, macOS 13+, hardened runtime with only the microphone entitlement,
  `NSLocalNetworkUsageDescription` (a shipped app gets its own local-network prompt, unlike dev runs from
  Terminal), `.app` + `.dmg` (7.3 MB). The binary links only system libraries (`/usr/lib/swift` is part of
  macOS 13+). `scripts/release.sh` signs with the personal "Developer ID Application" identity, notarizes
  the DMG with the `playfx` notarytool keychain profile, staples and checks it with Gatekeeper.
- ✅ **CI**: `.github/workflows/ci.yml` on every push and PR, macOS runner (a VM): libchiaki built once
  per submodule commit + script (cached right after building), Swift tests one at a time + coverage,
  tsc/ESLint/vitest + coverage, clippy `-D warnings`, Rust tests + `cargo llvm-cov --lib` (≥ 80% lines and
  functions). Getting it green found real bugs: `protobuf` missing from the documented dependencies; the
  dev seed import broke every clean checkout; in a VM, VideoToolbox reports frame interpolation and ML
  super-resolution as supported, then crashes or never runs (both now off in VMs). Rust coverage was
  first measured here (72% lines): the app's entry point moved to `main.rs` (a thin adapter), every
  command is now exercised through IPC with the UI's argument names and with missing arguments, and the
  safe StreamCore calls are smoke-tested for real.
- ✅ **Reproducibility**: README lists the Homebrew dependencies and `build-chiaki.sh`; CI regenerates
  `vendor/` from scratch whenever the submodule or the script changes.

---

### Logging & diagnostics (done, requested)

For users and us to debug: one scrubbed log across native, Rust and the web UI, and a diagnostics export.
- ✅ L1. Native logger (`Log`): levels (debug/info/warning/error) and areas (session, psn, console,
  renderer, input, chiaki); every entry to the system log (Console.app, subsystem `playfx`) and
  a sink (psrp: stderr; desktop: the host via `sc_set_log_callback`, `sc_set_log_detailed`). libchiaki's
  messages routed through it. Secrets scrubbed before anything leaves (Bearer/Basic headers, token
  fields, sign-in codes, the token in Sony's account-lookup URL, pairing keys, account IDs). Log points
  for PSN (HTTP outcomes, Sony's error replies on sign-in/refresh failures, forced refreshes, console
  list), sessions, discovery/wake/pairing, renderer capabilities and ML fallbacks, controllers.
- ✅ L2. One log file: `~/Library/Logs/dev.deblanco.playfx/playfx.log` (tauri-plugin-log;
  5 MB, the last 3 kept, local time) and the terminal. Native entries arrive through
  `sc_set_log_callback` as `streamcore::<area>`; Rust logs stream starts (local/internet), the PSN
  sign-in window, every StreamCore error reply. Ours at every level, other crates from info up.
  libchiaki's expected discovery failures (unreachable broadcast addresses — VM/container bridges) are
  debug, not error: they were 106 of the first 114 lines.
- ✅ L3. Web UI logging: the app runtime's Effect logger writes to the same file (tauri-plugin-log,
  target `webview`): play (route, video settings), stop, pairing, wake / wake-until-ready, reconnect
  attempts (busy retries, outcome), every stream event (quits with reason and kind, as warnings when
  they're errors), settings changes (debug), and every failure shown as a toast. Unit-tested incl. the
  plugin call; live check pending (the console wouldn't wake and the screen was locked).
- ✅ Wake from deeper rest (found via the logs: the unicast wake packet failed with "No route to host"
  while discovery still saw the PS5 in standby). The wake packet now also goes to every interface's
  broadcast address; and when the PS5 is on the PSN account, Play falls back to connecting through
  PSN (which wakes it — verified with `psrp stream --psn`) if the local wake-up can't be sent or the
  console isn't ready within 20 s. Unit-tested; live deep-rest check skipped for now (user's call).
- ✅ Play falls back to PSN when the local network can't reach a console that's awake (seen live: the Mac
  reached the router but every unicast to the PS5 failed with "No route to host" while broadcast
  discovery still listed it as ready). If the local session request fails that way before connecting
  and the console is on the PSN account, the app says so and connects over the internet instead.
- ✅ L4. Settings → Diagnostics: "Detailed logs" (saved; switches native/libchiaki and web UI debug
  entries on, applied at startup and when it changes), "Copy diagnostics" (app and macOS versions,
  renderer capabilities, settings, the last 200 log lines — already scrubbed) and "Open logs folder".
  Live click-through pending (the screen was locked).
- Development builds keep the PSN sign-in in a 0600 JSON file (`~/.config/psrp/psn-tokens.json`, or
  `$PSRP_TOKEN_FILE`) instead of the Keychain, which would prompt after every rebuild of an unsigned
  build — unanswerable when developing remotely. Release builds use the Keychain.

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
