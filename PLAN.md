# PLAN

Roadmap and gap list for **PlayFX** — a macOS PS5 (and PS4) Remote Play client.
Status legend: ✅ done · 🔶 partial · ❌ not started.

Last updated 2026-11-20, after frame generation from the game's rate (the playhead), the hardware round on the
PS5 and the review of that work.

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
  controller state through `sc_session_set_controller`, which StreamCore merges with the pad's
  (`ControllerInput.setKeys`); mapping is a pure, tested function (`src/app/keyboard.ts`), with an in-HUD
  key legend. It's the only keyboard path: StreamCore's own GameController keyboard reading was removed
  (it ignored text fields and dialogs). The headless `psrp` CLI also drives input via its `/press`,
  `/hold`, `/stick` control API.
- React/Effect UI: account, console list, pairing, settings, streaming HUD.
- Credentials in a native secret store (the Keychain in release builds, a 0600 file in development); PSN
  login via Sony's own page.
- Tests + gates (2026-11-20): TS 311 tests (97% lines), Swift 274 tests (88% lines; 84% as CI's VM sees
  it), Rust 53 tests (88% lines), strict `tsc`/ESLint, `@effect/vitest`, clippy `-D warnings`, chiaki-ng's
  own unit tests 123/123. Each package's gate fails below 80%; CI runs them all on every push. No test
  reaches a real controller (`PadHardware` is closed in a test run).

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
  - ✅ **A stopped picture reconnects too** (2026-11-20, requested): seen live over the internet route, 95% of
    the video was lost while the sound went on, and chiaki waited forever for a keyframe that never arrived
    whole; the picture stayed frozen. The app now watches the decoded frame count while connected: no new
    frame for 5 s (the console sends frames all the time, even for a still scene, and a lost frame recovers
    within a second) reconnects with "The picture stopped. Reconnecting…", counted with the dropped-connection
    reconnects (3 in a row, then home with the reason). Unit-tested; not yet seen on a real stall.
    Before giving up it now asks the console for a keyframe at 1 s and 3 s without a new frame (2026-11-20;
    unit-tested).


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
    **Original** (the stream as it arrives: no clean-up, upscaling, sharpening, ML or frame interpolation; colors
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
- Not planned: MetalFX temporal upscaling (needs engine motion vectors + depth).
- ✅ **Frame interpolation** (was "Smooth motion"; requested): reworked after the benchmark showed it adding
  nothing (30 fps in, 31 shown).
  - Frames are shown by a stream clock built from libchiaki's frame index, with an eased, stated delay.
  - In-between images are made on their own lane (VideoToolbox, Neural Engine), sized to fit the time.
  - Still areas are blended back; scene cuts and empty outputs are skipped.
  - Presentations are counted from the presented callback.
  - Bench, live on Sidecar: 30 fps in → 57–59 shown/s with jitter, about 40–45 ms delay.
  - MetalFX frame interpolation was measured (zero motion, media-engine motion, optical flow) and isn't
    worth its GPU time. See [docs/FRAME_INTERPOLATION.md](docs/FRAME_INTERPOLATION.md).
  - **Blank images found and fixed:** VideoToolbox writes all-zero (green) images at sizes whose sides
    aren't multiples of 16 on its fast path (960×540, 854×480, 640×360), so 540p streams only ever got
    partly green in-between images. Small sizes are now rounded down (540p works at 960×528) and scaled
    back; the blank check looks at VideoToolbox's own output, before the still-area blend that hid it.
  - The lane takes its engine as a parameter (VideoToolbox in the app, stand-ins in tests), so its logic
    is tested in CI's VM too.
  - Review fixes: the size climbs back up after a spike; a late in-between image never shows after a
    newer one; the extra delay only while images are being made; 10-bit HDR frames aren't sent to the lane.
  - The clock slides through a late stretch instead of starting over (2026-11-20): its phase moves up to 8%
    of a frame per frame when frames come far from it, so the in-between images and the playhead's place are
    kept. It starts over only after a gap, and the playhead then goes on from the new frame, never back.
    A 7-minute trace had 51 start-overs, each a moment of plain stream and a held picture; replayed through
    the new pacing, only its 3 real gaps start over. Not yet seen live.
  - Not yet checked on the PS5.
- ✅ **Network** (requested): see [docs/NETWORK.md](docs/NETWORK.md).
  - **Cause found:** AirDrop and Handoff (AWDL) stall the Mac's Wi-Fi about 90 ms every second. Pings to
    the PS5 peaked at 105 ms; with AWDL off, 21 ms.
  - **Steady Wi-Fi** (Home and Settings → Stream) pauses AWDL while PlayFX is open: one password prompt,
    and a root helper that ends on quit or crash. The choice is remembered: after a relaunch, Play asks
    for the password again (once per launch if dismissed). While streaming, the HUD warns when AirDrop is
    stalling the Wi-Fi, with a button to turn Steady Wi-Fi on.
  - **libchiaki now comes from our fork** (deblanco/chiaki-ng, branch `playfx`), with four fixes: false
    packet loss on wrap, a 4 MB receive buffer, Wi-Fi priority marking, and gap-block acks.
  - **Threads:** libchiaki's receive and input threads run at user-interactive QoS.
  - **Result** (1080p60, AWDL on): lateness behind the stream clock went from 219–555 ms to 9.5 ms, and
    lost frames from 2–15 to 0.
  - The pacing clock now follows lateness that stays high (it used to grow without bound): first by starting
    over, since 2026-11-20 by sliding its phase (see FRAME_INTERPOLATION.md, "Stream clock").
  - From [neo773/chiaki-ng](https://github.com/neo773/chiaki-ng) (reviewed 2026-11-19): the fork retries the
    control request when the console resets the connection (3×, 35 ms apart), and both TCP sockets get
    `TCP_NODELAY`, the real-time marking and `SO_NOSIGPIPE`. Video now decodes asynchronously, off
    libchiaki's receive thread. Its Takion rewrite was left out (tuned for wired links). Not yet tried on the
    console. See docs/NETWORK.md.
  - **Open:**
    - the 33 ms reorder wait from PR #817 is untested;
    - the stream with Steady Wi-Fi on hasn't been measured (only pings were);
    - the HUD warns while AWDL is on, but not from the stall itself (the once-a-second ping pattern);
    - offer the packet-loss wrap fix upstream to chiaki-ng (not sent).

### P1 — making a stream feel complete

- ✅ **Rumble.** *(works in a game: GTA VI on the PS5, pad on USB, 2026-11-20, the user. Plays on a DualSense over Bluetooth — `psrp pad` /rumble; feel in a game unverified):
  the console's two motor levels play through GameController haptics, the heavy motor on the left handle
  and the light one on the right (or the stronger one on single-actuator pads); stopped when the session
  ends. **It never played before**: on macOS 27 gamecontrollerd rejects patterns sent for an *advanced*
  (looping) player — `AVHapticEvent` isn't in its allowed XPC classes, so it drops the connection (error
  4097). Now a plain player runs one 30 s continuous event, its intensity follows the console through
  dynamic parameters, and it is replaced every 25 s while rumbling. Engine failures are logged. Felt in a
  game on 2026-11-19, which found the non-stop rumble below.)*
- ✅ **Adaptive triggers** (DualSense). *(**felt in a game**: GTA VI on the PS5, 2026-11-20, the user: works. Earlier **felt on a DualSense over Bluetooth** with `psrp pad`: feedback,
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
  strengths (mean |sample| per channel, noise floor). Seen live in Silent Hill 2: 44 rumble updates in
  ~10 s of play (`psrp /status` now counts them). **Fixed 2026-11-19: the pad rumbled non-stop.** When
  an effect ends the console stops sending haptics packets instead of sending silence, so no zero level
  ever came. Haptics-made rumble is now its own event (`PSRP_EVENT_HAPTIC_RUMBLE`), repeated every 50 ms
  while packets keep coming, and stopped 150 ms after the last one; the console's own rumble messages
  still last until it ends them. The feel in a game still needs judging.
  **Real haptics over USB** (built 2026-11-19, unverified on a pad): on USB the DualSense is also a 4-channel
  sound device whose channels 3 and 4 are its motors. The shim hands the raw stream (stereo, 3 kHz) to
  StreamCore first; `DualSenseHaptics` finds the pad's device (name "DualSense", 4+ output channels), plays
  the stream there through an AUHAL output (upsampled to 48 kHz, at most 60 ms buffered so it never lags the
  game) and tells the shim not to make rumble from it. Devices are looked at every 2 s off the receive
  thread, so plugging or unplugging mid-stream switches between the two. A pad left at 2-channel sound gets
  a hint in the log (set it to Quadraphonic in Audio MIDI Setup) and stays on rumble, as chiaki-ng does.
  **Works in a game** (GTA VI, pad on a cable, 2026-11-20: the log shows the haptics stream playing on the pad,
  and the user reports rumble and triggers working). Astro's Playroom would show the fine textures best.
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
  Games app. The Mac keyboard's P sends PS (the web UI's keymap), and the stream HUD has a semi-transparent
  **PS button** at the bottom center (held while the pointer is down: short press = control center, long = home). **Mute** isn't exposed by GameController.
- ✅ **Settings profiles**: a profile holds the stream and picture settings (resolution, frame rate, codec,
  bitrate, HDR, view, upscaler, sharpening, cleanup, ML, frame interpolation, colors); app preferences stay put.
  Built-in **Recommended** (1080p60 · MetalFX · sharpness 0.3, also what a new install starts with); the
  user saves the current settings under a name, switches, deletes. Settings → Profile; stored in
  `psrp.profiles`. "Custom" when the settings match no profile. **Replacing a profile** (2026-11-20,
  requested): Save as… lists the saved profiles to pick; a matching name turns Save into **Replace** with a
  line saying so, and the profile keeps its place in the list.
- ✅ **Rest mode on Stop**: while streaming, Stop asks "Put <console> in rest mode?" (Rest mode / Leave
  it on / Keep playing). Rest mode sends libchiaki's goto-bed (`sleep_console`), waits 1.5 s for it to
  reach the console, then stops. Before the stream connects, Stop stops at once. Unverified on a console.
- ✅ **Console IP on the home network**: with Connect set to Home network, an optional IP field; each
  discovery round also asks that address directly (`discover` with `host`, IPs only) and merges what it
  finds, so a console broadcast discovery can't see still shows up and plays. Unverified on a console.
- ✅ **Microphone** (verified on the Mac with the user allowing the prompt: capture starts — 48 kHz mono
  input converted to stereo — the stream stays clean at 60 fps / 0 lost, the amber button and the tag
  after the HUD hides both show, and turning it off stops capture; hearing it on the console needs a
  party chat, not checked): a **Mic** button in the stream HUD (off by default) captures the default
  input with AVAudioEngine, converts it to 48 kHz stereo 16-bit, cuts it into 10 ms frames and sends them
  through libchiaki's Opus encoder (`psrp_session_set_mic` connects the console's mic channel on first
  use, then toggles mute). While it's live the button turns amber ("Mic on") and an amber "Mic on" tag
  stays in the corner after the HUD hides. Permission denied / no input explain what to do. The app's
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
  back to SDR for SDR frames or the backdrop. ML upscaling and frame interpolation only take 8-bit frames, so they
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
  - Before the first public release (2026-11-20): the app ships `THIRD_PARTY_LICENSES` (full texts and
    copyright lines for the 209 Rust crates plus the Rust standard library, the C libraries linked into
    libchiaki, the web UI's 58 packages and its two OFL fonts), generated by `scripts/third-party-licenses.py`
    from what's actually built (re-run it after dependency bumps). `LICENSE` is the plain AGPL-3.0 (the OpenSSL
    exception copied from chiaki-ng was worded as the FSF's and isn't needed: OpenSSL 3 is Apache-2.0).
    `NOTICE` names the fork libchiaki is built from. No shadcn/studio code: its blocks are MIT with a Commons
    Clause, which the AGPL can't carry, so the PIN input and the status badge are plain shadcn/ui.
- ✅ **Sony ToS note.** README: unofficial client, own consoles and account, PSN sign-in only through
  Sony's page, no credentials shipped. NOTICE and the app's About text: not affiliated with Sony.
- 🔶 **Packaging** *(built and launched; Developer ID certificate in the keychain; notarization profile `playfx` in the keychain: an App Store Connect API key, Developer access)*: bundle ID
  `dev.deblanco.playfx`, macOS 13+, hardened runtime with only the microphone entitlement,
  `NSLocalNetworkUsageDescription` (a shipped app gets its own local-network prompt, unlike dev runs from
  Terminal), `.app` + `.dmg` (7.3 MB). The binary links only system libraries (`/usr/lib/swift` is part of
  macOS 13+). `scripts/release.sh` first runs every package's tests and coverage gates (stops below 80%), then signs with the "Developer ID Application: BLANK HEXADECIMAL SL (K579SJ8947)" identity (in the login keychain), notarizes
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

### Stability, CI and the project-wide review (2026-11-19)

- ✅ **Crash about two minutes into a stream:** the session's event handler was kept in a lock's state and
  re-wrapped in two conversion thunks on every event, until a few thousand haptics events overflowed the
  receive thread's stack. Boxed in a class; a test checks the call depth stays constant.
- ✅ **CI was red** from the pacing work on: a test assumed a second frame shows at once (true before the
  stream clock), and Swift coverage in CI's VM was 76% (the interpolation lane never ran there).
  `STREAMCORE_SIMULATE_VM=1` shows locally what CI's coverage sees.
- ✅ **Project-wide review** (four reviewers, every file read in full), all findings fixed:
  - *Security:* the PSN sign-in window could call every app command, secrets included (an app manifest
    now grants them to the main window only, and the window stays on Sony's sign-in hosts); a
    Content-Security-Policy; both debug control ports want a custom header and a local Host (any web page
    could press buttons); pairing keys are written through an exclusive 0600 temp file.
  - *Data loss:* settings are read field by field and profiles one by one; pairings that don't decode are
    written back untouched; a temporary PSN error no longer signs you out; a secrets file that doesn't
    decode is never written over; pairing writes are serialized.
  - *Crashes and stalls:* the microphone's permission prompt answered after a stream ended no longer
    feeds a freed session; audio engine changes are serialized; slow PSN/Keychain/discovery calls run on
    the blocking pool, not the async workers.
  - *Input:* key presses and releases stay in order; ⌘ shortcuts release held keys; the keyboard
    controller is off in the rest-mode dialog and before the stream is up; double-click fullscreen only on
    the video; the Fullscreen button reads the window's real state.
  - *Picture:* HDR highlights are no longer clipped to SDR white by sharpening or clean-up; 10-bit range
    constants (white exactly 1.0).
- **Behaviour changes users will notice:** the keyboard's PS button is **P** (it was H in the removed
  StreamCore path); Sound → "System default" follows macOS when its output changes; the dev control port
  needs `-H 'X-PlayFX-Dev: 1'` and `psrp`'s control API `-H 'X-PSRP: 1'`.
- 🔶 Not covered by a test: the reconnect race fix, and the audio output following the system default.

## 3. Known issues / tech debt

- ℹ️ **Swift tests**: run them with `packages/streamcore/scripts/test.sh` or `coverage.sh`, which pass
  swift-testing's framework path (a bare `swift test` under the Command Line Tools runs none). Full
  Xcode is installed on this Mac now.
- ✅ **Rust coverage tooling**: `bun run coverage:rust` runs `src-tauri/scripts/coverage.sh` (tests and
  `main.rs` excluded), locally, in CI and in `release.sh`. Branch coverage needs nightly, so Rust gates
  lines and functions only.
- 🔶 `renderer_status` returns `stream: null` when stats JSON can't be parsed, which surfaces as a
  `CoreError`. Decide whether to soften this.
- ✅ **Notarization**: the first release DMG (0.1.0) was accepted by Apple on 2026-11-19, stapled, and passes
  Gatekeeper (DMG and app: "Notarized Developer ID"). `release.sh` stopped before stapling because one of
  `notarytool`'s status polls timed out after hours "In Progress"; it should survive that (retry the wait).
  The app inside the DMG has no ticket of its own: Gatekeeper checks it online on first launch. Stapling the
  `.app` before building the DMG would cover offline first launches.
- 🔶 **Linker warnings**: vendored static libs built for a newer macOS than the 13.0 deployment
  target. Harmless; silence by building the deps at the target version.
- 🔶 **FFI safety**: the Rust↔Swift boundary (CString lifetimes, `sc_free` once, main-thread
  rules) was reviewed and tested, but every new `@_cdecl` needs the same care.
- ℹ️ **Dev E2E harness** (`src/app/devSeed.ts` + autoplay) is env-gated and inert in production;
  the seed file holding keys is gitignored. Keep it dev-only.
- ℹ️ The `psrp` CLI is a debugging tool, not a shipped artifact.

---

### From PushFPS and Veyra (2026-11-20: built overnight, then a hardware round on the PS5 the same day)

Ideas from PushFPS (frame generation for console capture) and Veyra's Remote Play pull requests, plus two
requests and a bug report.

- ✅ **Frame generation from the game's frame rate** (verified on the PS5 with GTA VI, the user: "smoother",
  "latency wise seems better"): the game measured as 30 fps in the 60 fps stream; its repeats aren't
  exact copies (the encoder refines them: 2–4 KB, mean luma change 0.02–0.4 against 0.6–8 for new
  pictures), so they're told apart by their change relative to the last new picture. Images are made at
  VideoToolbox's ½ or ¼ ½ ¾ points and shown by a **playhead** that follows the clock with at most 8%
  speed change instead of holding and jumping; it never passes an image not made yet, but doesn't wait
  for one longer than the delay plus a picture (a model build at stream start no longer freezes the
  picture). The stream clock slides through a late stretch instead of starting over. See
  FRAME_INTERPOLATION.md. To check: 30-in-60 on the 75 Hz external screen.
- ✅ **Stats say why a step is idle, and count the generated frames** (requested; also the "MetalFX
  selected, stats say Bilinear" report, which is MetalFX only enlarging, with a 1080p stream on a 1080p
  screen): `Bilinear (no upscale needed)`, `ML idle (only for 720p and lower)`, `+30 generated (2 missed)`,
  `no interpolation: 60 fps on a 60 Hz screen`, `30 fps game · 60 fps stream · 60 shown`; the Picture
  tab's Upscale card says "not needed". Seen live on the PS5: game 30 · stream 60 · ~100 shown on 120 Hz.
- 🔶 **Light bar colour and player number** from the console (`PadLight`); `psrp pad` has `/light` and
  `/player`. Unit-tested; **check on the pad**, then in a game that sets the light bar.
- 🔶 **The pad is left quiet when PlayFX ends** (bug: after `pkill` mid-effect the pad kept rumbling and kept
  its trigger effect): `PadQuiet` stops the rumble (waiting up to 0.3 s for the haptic engines), the DualSense
  haptics output and the trigger effects on quit (Tauri's exit event → `sc_quiet_pads`), on SIGTERM, SIGINT
  and SIGHUP (handlers on a queue of their own), and in `psrp stream` / `psrp pad`; nothing drives a pad
  after that. A session ending already stopped them. SIGKILL and crashes can't be handled. Unit-tested with
  stand-ins; **to check on the pad**: `pkill` PlayFX mid-rumble and mid-trigger-effect, and ⌘Q.
- 🔶 **Real haptics over Bluetooth**: HID report 0x32 (`BluetoothHaptics.swift`), after USB, before rumble.
  Report and pacer unit-tested. **To check on the pad**: whether macOS takes the write while GameController
  holds the pad, and whether the pad plays at full level without the "effects" setup report Veyra sends
  first (not sent here: on macOS it would go around GameController).
- ✅ **Bitrate**: the console's target shown beside the received rate (`7.5 Mbps (target 19.4)`); a bitrate
  change alone reconnects on its own after 1.2 s. The protocol's debug bitrate option was tried on the PS5:
  it's ignored, so there's no live bitrate change.
- ✅ **Latency test** (dev tool): dev control `POST /latency-test`, `psrp stream` `/latency-test`. It times
  Right/Left in the control centre (PS itself only answers after ~0.5 s): about 120 ms press → decoded
  picture over the internet.
- ✅ **Frame generation from the game's rate** (2026-11-20): GTA VI measured as 30 fps in the 60 fps stream;
  repeats detected from their mean change; images placed by the playhead (see FRAME_INTERPOLATION.md).
  Smoother and less lag in play.
- ✅ **Logs keep a whole session**: chiaki's per-frame and per-packet lines (99% of a detailed log) and its
  protocol hexdumps (which can carry session material) no longer reach the log.
- 🔶 **Frames skipped without packet loss** on the 75 Hz screen (1,379 → 1,530 in one session): to trace with
  `STREAMCORE_PACING_TRACE` on that screen. On the built-in screen the cause of most hops was AirDrop's
  radio (AWDL) with Steady Wi-Fi off: a ~100 ms stall every half second (router pings 4 ms median, spikes
  to 120 ms). With Steady Wi-Fi on it went away.
- ✅ **The stream controls show and hide at once** (requested): no fade either way.
- ✅ **Review of the day's work** (six reviewers, three skeptics per finding; 14 raised, 6 refuted, 8 fixed,
  one commit each): keyframe requests were refused by the app's permission list (never worked); the cadence
  grid drifted for 40/45 fps games (pictures 1.5–48 ms apart instead of 25); the picture froze while
  VideoToolbox built a model; a race could leave a pair counted as in the lane forever; interpolation
  flipped on and off for games near the 1.2× threshold (now on at 1.2×, off below 1.1×); the latency test
  read the session off the main thread; `psrp`'s /quit waited a second on itself; a pad connecting during a
  test run could take a test's light bar. One fix (a wait on main without a limit) hung the Rust tests; the final run caught it,
  and the wait is now at most 2 s.
- **PushFPS, second page of commits** (reviewed 2026-11-20, 35 commits): little applies. Worth doing: a
  worst-frame and worst-tile (16×9) quality score in `psrp interpolate --truth`, which catches a fast object
  vanishing from a generated frame that the mean hides (~30 lines, no console). Their measured negative
  result supports leaving a HUD/ghost guard out without evidence; their stuck-buttons fix is already in our
  fork, and their concealed-frame fix is covered by VideoToolbox plus our keyframe retries.
- Left for evidence: a HUD lock that remembers over several frames (if generated frames flicker on HUDs),
  and the console's real frame number from chiaki (if pacing looks off after packet loss).

## 4. Suggested order of work

0. ~~Picture quality & full stream configuration, Q1 → Q7~~ (done). *(P1, requested)*
1. ~~Auto-wake on Play~~ (done). *(P0)*
2. ~~Reconnect/resilience + clear quit-reason UI~~ (done). *(P0)*
3. Remote Play over the internet: built, and used for every stream on 2026-11-20 (through PSN, from the home
   network); **a run from another network (phone hotspot) is left** (needs the user). *(P0)*
4. ~~Rumble + adaptive triggers in a game~~ (done 2026-11-20: GTA VI, pad on USB, the user: works);
   touchpad built; **the motion axes in a game are left**. *(P1)*
5. ~~Keychain credential storage~~ (done). *(P2)*
6. Packaging + AGPL/licensing + CI: done, and notarization accepted (2026-11-19). Left: **the public release**
   (make the repo public with it; the user's call), and `release.sh` surviving a notarytool status timeout and
   stapling the `.app` too. *(P4)*
7. On the PS5 and the pad: ~~frame generation on the built-in 120 Hz screen~~ (done 2026-11-20: GTA VI, 30 fps
   in 60, ~100 shown/s); left: the 75 Hz external screen; a stream measured with Steady Wi-Fi on (only pings
   were); the pad left quiet on `pkill` and ⌘Q mid-effect; the light bar in a game that sets it; Bluetooth
   haptics in Astro's Playroom.
8. Smaller follow-ups: ~~the Wi-Fi stall warning~~ (done 2026-11-20, from AirDrop's state; warning from the
   stall itself is open); the worst-tile quality score (from PushFPS); the 50 fps cadence (a picture up to
   13 ms ahead of the grid still re-anchors it); the PR #817 reorder-wait test (needs the console); the
   chiaki-ng upstream PR (needs the user's OK); echo cancellation for the microphone; audio jitter-buffer
   tuning.
