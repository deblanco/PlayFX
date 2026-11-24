# PLAN

Roadmap and gap list for **PlayFX** — a macOS PS5 (and PS4) Remote Play client.
Status legend: ✅ done · 🔶 partial · ❌ not started.

Last updated 2026-11-24, after **the input lane (PR #6) merged into this branch**: pad readings reach the console off the
main thread, read by a loop of their own (`streamcore.input`, user-interactive) paced by `InputPacer` (500 Hz while
readings change, 125 Hz after a second of quiet), motion readings identical to the last one dropped, states handed
on under the lock they're merged in; with `PlayFXEngine` behind `StreamSession` unchanged. Unit tests only; the
latency test before and after on the console is left. Before that, **USB haptics felt**: on macOS a DualSense on USB ignores the haptics audio on its
sound device's channels 3 and 4 until it gets one all-zero HID output report 0x02 (found on the user's pad with a test
tone); StreamCore now sends it when haptics start on a USB pad, about once a second while they play and shortly after
the app's own rumble, trigger or light bar output, and logs what it found when no pad plays them (StreamCore 509
tests, 91.6% lines / 89.9% functions; 90.2% / 88.7% in VM mode). Before that, **libopus built from source**: libopus 1.6.1 is vendored unmodified in StreamCore
(`Sources/CLibopus`, float build, generic C) and compiled for the package's deployment targets, so the build needs
no Homebrew and the "built for newer macOS version" linker warnings are gone (StreamCore 501 tests, 91.5% lines / 90.1%
in VM mode; Rust 74, 91.4% lines; TS 424). Before that, **the final check of the libchiaki removal**: every gate green with no libchiaki
anywhere (StreamCore 501 tests, 91.5% lines / 90.1% in VM mode; PlayFXProtocol 851 tests, 97.9% lines in the
parallel, VM and serial runs, and its release allocation test; TS 424, 97.9% lines; Rust 74, 91.4% lines; clippy
clean); a debug `cargo build` links with libopus inside and no Homebrew dylib; `git grep -i chiaki` finds only
history (PLAN.md, docs/NETWORK.md's "History: libchiaki", FRAME_INTERPOLATION's note on Veyra) and the clean-room
provenance (docs/protocol, PlayFXProtocol's README, DESIGN and LICENSE). Before that, **PlayFX became proprietary**: `LICENSE` is "All rights reserved", `NOTICE` and
the Settings › Diagnostics **Source code** button are gone, every manifest says so (`UNLICENSED`,
`LicenseRef-Proprietary`), `THIRD_PARTY_LICENSES` is regenerated for what ships now (libsecp256k1 and libopus as
the C libraries), and CLAUDE.md allows only permissive licences (TS 427 tests, Rust 74). Before that, **chiaki-ng's submodule removed**: `third_party/` and `.gitmodules` are gone;
docs name chiaki-ng only as history (docs/NETWORK.md's "History: libchiaki") and as the clean-room spec's
provenance (docs/protocol, now naming commit d8efd673bc93bbc16e9f646c5b24e0dee013abcc, the one the submodule
recorded). Before that, **the app and CI without libchiaki**: the desktop app's Rust side builds and links
with only StreamCore, Homebrew's static libopus and system frameworks (no curl, OpenSSL, json-c, miniupnpc,
libevent, nanopb, Jerasure or GF-Complete); the UI shows the new engine's quit reasons in its own words (adding
"or play over the internet" for a PS5 that didn't answer) and tries PSN on its "didn't answer"/"couldn't reach"
texts; CI installs only `opus` and builds no libchiaki (TS 427 tests, Rust 74). Before that, **StreamCore on PlayFXProtocol only**: `ChiakiEngine`, the C shim (`Sources/CChiaki`)
and `build-chiaki.sh` are gone; every stream, local or through PSN, runs on `PlayFXEngine`, with libopus linked
statically from Homebrew's opus keg (StreamCore 501 tests, 91.5% lines; 90.1% in VM mode). Before that, **`PlayFXEngine`**: StreamCore can stream on PlayFXProtocol (`Options.engine = "playfx"`,
`psrp stream --engine playfx`), clean-room against the engine contract; not yet on a console. Before that, **the internet-play spec** (`docs/protocol/psn.md`, `holepunch.md`, `rudp.md`, PIN-less
pairing through PSN; facts only, vectors checked against the reference's byte layouts). Before that, **the StreamCore engine seam**: `StreamSession` now drives the protocol through a
small Swift interface (`StreamEngine` / `StreamEngineSink`), with libchiaki as its only engine and behaviour
unchanged, so `PlayFXEngine` can be written against that contract alone (Swift 428 tests, 90.4% lines; 88.8% as CI's
VM sees it). Before that, **the first stream on our own protocol code, with no libchiaki**: on the user's
PS5, `pfxp stream` ran 720p60 H.264, 1080p60 HEVC and HEVC HDR with nothing lost, on both receive transports,
and the saved video decoded cleanly in ffmpeg. Before that, **our own whole stream session in Swift**
(`PlayFXProtocol` milestone 3: `StreamSession` and `pfxp stream`, end to end over loopback against the real
console's recording; 544 tests, 97.9% lines). Before that, **our own session start and control channel in Swift** (`PlayFXProtocol`
milestone 2): on the user's PS5 a session opened, kept its heartbeats for 20 s and stopped cleanly, and go to
bed put the console in rest; 172 tests, 96.4% lines. Before that, **our own discovery, wake and pairing in Swift** (`PlayFXProtocol`, branch
`deblanco/rewrite-ps-remote-core`, see "Our own Remote Play protocol" under P4), written from the spec alone:
then **its first hardware round**: on the user's PS5 it discovered, woke and paired (the pairing returned
the same keys libchiaki holds), after a fix for the PS5's padded `Content-Length`; 92 tests, 96.7% lines. Before
that, the first step: a facts-only protocol spec in
`docs/protocol` (discovery, wake, registration, RP crypt, session init, ctrl) with known-answer vectors, and the
empty proprietary Swift package `packages/playfxprotocol` with its design notes and a CI step. Before that (on main), **the GTA VI profile without ML upscaling** (requested): the built-in **GTA VI**
profile is Recommended at 30 fps with ML upscaling and Touchpad touches off ("1080p30 · MetalFX · sharpness 0.3 ·
Frame interpolation · touchpad click only"); Recommended is unchanged, and Help's "sharpest picture" setup now says
to turn ML upscaling on. Unit tests only. Before that, **a CI fix**: the ML upscaler's defence tests failed on GitHub's macOS 26 runner
(8 tests, 17 issues), because `MLSuperResolution` asked VideoToolbox about the model even with stand-in
processors. Measured on the runner (a temporary diagnostic test on a branch): in its virtual machine VideoToolbox
names no scale factor for 1280×720 or the 1088×1088 tiles (2× only at 960×544) and an empty output format, so no
buffer pool could be made and every frame was refused before the stand-ins ran (`STREAMCORE_SIMULATE_VM=1` can't
show it: a real Mac still answers). Both answers now come from an injected `MLScalerModel` (VideoToolbox in the
app); the tests give what a Mac answers (1.5×, NV12 output). A first fix that injected only the factors still failed. Before that, **the project's site on GitHub Pages** (`apps/site`, https://deblanco.github.io/PlayFX/):
one screen that looks like the app — the idle backdrop's ribbons (StreamCore's shader ported to WebGL), the stream
HUD's stats line and buttons, a Download card that links the latest DMG (from GitHub's API, the release page
without it), and the Settings sheet's glass with feature tabs (Picture with the amber step strip, Stream, Pad,
Setup); it scrolls on a phone. Deployed by `.github/workflows/pages.yml` when it changes on main. Before that,
**in-app updates through GitHub Releases**: a banner on Home offers a newer release
(checked 5 s after launch and every 6 hours, or by hand in Diagnostics), and Update downloads, verifies, installs
and restarts, never during a stream; `release.sh` makes the signed update and `latest.json`. Built and tested
(Rust against a local server with a throwaway key, the release script with one), not yet end to end: that needs a
release after the first one with the updater. Its review fixes: the UI tells the native side it's playing (from
Play until back home, StreamCore's session or not), an update installed while a stream starts waits for
**Restart**, a refusal during a stream is no failure, an install uses the release its download was of, and
`release.sh` stores the key without `security`'s 128-character prompt and tries it before the build. Before that, saying why an HDR stream gets no frame interpolation: `sdrInHdr` (an SDR game with
HDR on), `hdrUnsupported` (no MetalFX frame interpolator here) and "MetalFX kept failing (HDR)", in the stats line
and on the Frame interpolation switch while streaming; unit tests only. Before that, a **Misc** tab in Settings (Picture · Stream · Misc · Diagnostics, each with an
icon and a line saying what it's for; the controller's Touchpad touches moved there from Stream). Before that, the measured reorder wait: libchiaki's Takion waits for a missing video packet as
long as the link shows packets come late (3–20 ms, learned from holes that fill and packets that come after a skip;
it was a fixed 16 ms), its video reorder queue has 256 slots instead of 64, and a full queue skips the missing
packets instead of dropping ones that arrived; Settings › Diagnostics shows the wait. Then its review fixes: loss
trims the wait only down to what late packets showed, a packet of a hole skipped 100 ms before is lost not late (and
a sample is at most 20 ms), and a packet half the sequence space old no longer empties and rebases the queue.
Unit-tested, not yet on the console. Before that, the built-in profiles (requested): **Recommended**, which is also the new
defaults, now streams 1080p60 HEVC at 20 Mbps with frame interpolation on (ML upscaling, MetalFX, sharpness
0.3 as before), and a second built-in **GTA VI** profile is the same at 30 fps with touchpad touches off; a
profile saved as "GTA VI" before shows as "GTA VI (saved)". Unit tests only. Before that, **Steady Wi-Fi
suggested at Play**: Play no longer opens macOS's password prompt by itself when Steady Wi-Fi was left on;
while AirDrop and Handoff are on, a toast suggests it ("Turn on" asks for the password, "Not now" closes it),
once per run of the app; unit tests only. Before that, the **Touchpad
touches** switch: off, a pad's touchpad sends only its click, not
where a finger rests (in GTA VI a resting thumb opened the map; chiaki-ng PR #896 asks for the same), applied
live and kept in profiles; unit tests only, not yet on the console. Its review fixes: a pad that disconnects
lets go of what it held (buttons, sticks, a touch, motion), and a finger resting when touches come back on is a
new touch. Before that, frame generation on HDR
streams: MetalFX's frame interpolator makes the in-between
images where VideoToolbox's can't (10-bit frames), built and tested offscreen on synthetic HDR frames, not yet on
the console, then its review fixes (exception quarantine, honest `failed` / `unsupported` states, engines let go,
a rerunnable quality table). Before that, a repeated picture is no longer run through ML super-resolution (a 30 fps
game in a 60 fps stream was upscaling every frame, then throwing the repeat away). Previously, after release v0.2.1:
VideoToolbox no longer leaks a Metal shared event per frame
(the crash 10–40 minutes into a session with frame interpolation or ML upscaling on), and a video processor that
fails is restarted, or its feature turned off, instead of ending the app. Release v0.2.1: the Wi-Fi stall warning from the stream
itself; Cancel during a PSN pairing's registration ends it at once, and a PS5 that PSN reached but that never
answers the registration gets its own message (PSN_REGIST_UNANSWERED); a profile switch during a bitrate
reconnect asks first; a 50 fps game's pictures stay evenly spaced while frames are generated; `psrp
interpolate --truth` scores the worst frame and the worst tile; the release script staples the app inside the
DMG and survives a notarization status timeout; tests for the reconnect race and the sound following the system
default. For release v0.2.0: the v0.1.0 crash fix, pairing through PSN without a code and the pairing help,
profiles from Home and in game, the Help page, stats as rates, and ML upscaling at every stream resolution, on
by default and on its own lane.

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
apps/site               The project's GitHub Pages site (Vite + Tailwind, plain JS).
packages/streamcore     Swift package (macOS + iOS target):
  Sources/CLibopus      libopus 1.6.1, vendored unmodified (float build, generic C), compiled in.
  Sources/COpus         the few libopus calls the engine makes.
  Sources/StreamCore    Console (discover/register/wake), PSNAuth, StreamSession on PlayFXEngine,
                        VideoDecoder (VideoToolbox), AudioPlayer, ControllerInput,
                        StreamRenderer (Metal + MetalFX), MacOSBridge (JSON C ABI).
  Sources/psrp          Headless debug CLI with a localhost control API.
packages/playfxprotocol Swift package: PlayFX's own Remote Play protocol (proprietary, clean-room from
                        docs/protocol): discovery, pairing, the stream, internet play through PSN.
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
- Input: DualSense/DualShock/Xbox/MFi via the GameController framework — its callbacks on the main thread,
  plus an **input loop** of its own (user-interactive) that reads the pads off it, paced adaptively by
  `InputPacer` (fast while readings change, a heartbeat when they don't), so a reading doesn't wait behind
  rendering and UI.
- **Keyboard-as-controller** (testing without a pad): the web UI captures keys and forwards a
  controller state through `sc_session_set_controller`, which StreamCore merges with the pad's
  (`ControllerInput.setKeys`); mapping is a pure, tested function (`src/app/keyboard.ts`), with an in-HUD
  key legend. It's the only keyboard path: StreamCore's own GameController keyboard reading was removed
  (it ignored text fields and dialogs). The headless `psrp` CLI also drives input via its `/press`,
  `/hold`, `/stick` control API.
- React/Effect UI: account, console list, pairing, settings, streaming HUD.
- Credentials in a native secret store (the Keychain in release builds, a 0600 file in development); PSN
  login via Sony's own page.
- Tests + gates (2026-11-24): TS 427 tests (97.9% lines), Swift 501 tests (91.5% lines; 90.1% as CI's VM sees
  it), PlayFXProtocol 851 tests (97.9% lines, the same in VM mode and serially; no test leaves loopback), Rust 74
  tests (91.4% lines), strict
  `tsc`/ESLint, `@effect/vitest`, clippy `-D warnings` (chiaki-ng's own unit tests went with the submodule on
  2026-11-24). Each package's gate fails below 80%; CI runs them all on every push. No test
  reaches a real controller (`PadHardware` is closed in a test run), for output or for input: a pad in someone's
  hands used to feed its buttons into a controller test and make it fail now and then.

---

## 2. Missing — prioritized

### P0 — the features that most change what the product can do

- 🔶 **Remote Play over the internet (PSN hole-punching).** In progress — PS5 only (libchiaki only lists
  PS5s); the console is paired on the home network with its PIN, or through PSN with no code (step 5: built,
  needs a hardware check). libchiaki does PSN sessions, STUN/UPnP, hole punching and
  a fresh PSN-side registration per connection inside `chiaki_session_start`; the app supplies tokens, the
  console's PSN device ID, and runs the blocking setup (≤30 s per step) off the main thread. Since 2026-11-24
  all of it runs on PlayFXProtocol instead (see "Our own Remote Play protocol" under P4); the steps below record
  the libchiaki build, and the new code needs its own run over the internet.
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
  - 🔶 5. Pair without a PIN through PSN: see "Pair without a PIN through PSN" below. Built; needs a hardware
    check before a console paired this way is known to play on the home network.
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
  *Follow-up: on by default, and every resolution now takes it. The model fails on sides that aren't multiples
  of 16 even where it reports them supported (1080, 540), so 540p is padded to 544 rows and 1080p goes through
  in two overlapping 1088×1088 tiles cut and joined with blits in the same command buffer: ~6 ms per frame at
  720p, ~11 ms at 1080p measured in the renderer. Verified in tests (1080p tiles, 540p padding, the cut on
  plain Metal for CI's VM). On a live 1080p PS5 stream (GTA VI, 120 Hz screen) ML in the draw dragged the
  screen from 115 to 42–54 Hz and lost up to 17 frames/s, with or without frame interpolation, so ML now runs
  on its own lane (`UpscaleLane`) ahead of the stream clock: the draw never waits for it, the pacing delay
  covers its time (up to 15 ms at 1080p), it upscales stream frames only (in-between images come from
  upscaled frames), and when it falls behind it drops the waiting frame (counted as lost). Tested with a
  stand-in engine, in CI's VM too. **Left: the same live stream with the lane.** Details:
  `docs/ML_UPSCALING.md`.*
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
    newer one; the extra delay only while images are being made; 10-bit HDR frames aren't sent to the lane
    (until HDR frame generation, below).
  - **Crash fixed** (2026-11-20, v0.1.0, seen once 39 minutes into a session): VideoToolbox's frame processor
    threw an Objective-C exception ("insertObject: object cannot be nil") from inside its own call, right after
    a burst of model rebuilds, and Swift can't catch those, so the app ended. The call now runs inside a small
    Objective-C catch (`CObjCCatch`): that pair gets no images and the session starts over; a size that keeps
    failing is dropped. The scaled-down copies of the frames now keep their colorimetry, which VideoToolbox may
    look up (a likely trigger). The rebuild churn behind it is fixed below. *Not the cause, and the catch made
    it worse in v0.2.1: see "Long sessions crashed" under Stability.*
  - Halves and quarters each keep their own VideoToolbox session (2026-11-20): the release on a ProMotion screen
    rebuilt the model every 20–60 s as the screen's rate moved and the choice flipped (seen in the log: "at halves"
    then "at quarters" in the same second), each rebuild a second or two with no images, which made most of a
    session's "missed" count. Both are prepared up front now and switching costs nothing.
  - The clock slides through a late stretch instead of starting over (2026-11-20): its phase moves up to 8%
    of a frame per frame when frames come far from it, so the in-between images and the playhead's place are
    kept. It starts over only after a gap, and the playhead then goes on from the new frame, never back.
    A 7-minute trace had 51 start-overs, each a moment of plain stream and a held picture; replayed through
    the new pacing, only its 3 real gaps start over. Not yet seen live.
  - Not yet checked on the PS5.
  - 🔶 **HDR streams** (2026-11-20): VideoToolbox's interpolation takes `420v` only, so HDR pairs (10-bit `x420`,
    PQ) go to MetalFX's frame interpolator instead (`HDRFrameInterpolator`): each frame's YCbCr → PQ-encoded R'G'B'
    (the present pass's own conversion, PQ → light step off; a spike showed linear light worse than a cross-fade),
    MetalFX with a zero motion field and flat depth (history kept across following pairs), then back to 10-bit
    YCbCr with the frame's matrix, range, siting and attachments, so the still-area blend (now on 16-bit planes),
    the HDR present path and EDR take it as a frame. Halves only (MetalFX has no phase), the stream's own size
    (one rung), its own failure budget and `failed` state; a pair across an SDR ↔ HDR switch gets nothing and
    resets the history. The stats follow the stream: `on`, or `unsupported` where MetalFX's interpolator can't run
    (CI's VMs). Repeats are now told apart in HDR too (10-bit luma read by its high byte). Verified offscreen on
    this M2 Pro (no console): codes round-trip within ±1 (limited and full range); on the spike's synthetic scene
    at 1080p, 8 pairs (`STREAMCORE_HDR_QUALITY=1 … --filter hdrQualityTable` reruns it), the midpoint is level
    with a cross-fade over the frame (43.4 dB both), 27.2 vs 25.1 dB around the fast square, worst 32 px tile
    15.9 vs 19.3; the 2600-nit core survives (2248 nits at 540p), no NaN; 4.9 ms a 1080p pair, wall clock; 200
    pairs make no Metal shared event. Below 1080p it scores under a cross-fade over the whole frame (still better
    on the square). Unit tests with stand-ins for MetalFX cover the round trip, history, failures, routing and the
    stats in CI's VM. Review fixes (2026-11-20, same tests and gates): an Objective-C exception from MetalFX
    quarantines that interpolator (never called again) and the next pair gets a fresh one; a command buffer that
    doesn't complete is tested; the engine's output buffers follow the frame size; HDR engines are let go when the
    stream turns SDR or a new one starts; the empty-image check skips HDR images (full-range black is 0); once the
    stream's only size (HDR) or every size (SDR) is dropped, the state says `failed`, not `on` with nothing made;
    10-bit SDR frames (HDR on, SDR game), which neither engine takes, report `unsupported` (now `sdrInHdr`, below) and keep their repeats;
    the stats row says "Off: kept failing", and the setting says 60 on ProMotion in HDR. Tests added for each,
    and the still-area blend test now uses an engine image unlike either frame, with the 10-bit thresholds.
    **Saying why** (2026-11-21, unit tests only): each HDR case now has its own reason instead of a vague
    "interpolation unavailable". New states `sdrInHdr` (10-bit SDR frames: the HDR setting on, an SDR game; was
    `unsupported`) and `hdrUnsupported` (an HDR stream where MetalFX's interpolator can't run; was `unsupported`,
    which now means SDR only), decided by `StreamRenderer.interpolationState(enabled:hdr:supported:taken:tenBitSDR:
    failed:…)`, a pure function (the renderer notes whether the newest frame is 10-bit SDR). `failed` keeps its
    meaning; with `hdrActive` the app says which engine. Stats line: "no interpolation: SDR game with HDR on", "no
    interpolation in HDR on this Mac", "interpolation off: MetalFX kept failing (HDR)" (amber). While streaming, the
    Frame interpolation switch's description says the live reason ("This game is SDR, but HDR is on, … Turn HDR off
    in Stream for this game.", "HDR needs MetalFX's frame interpolator …", "MetalFX failed several times, …", "In
    HDR it makes one image between two frames …", and "No images in between: 60 fps on a 60 Hz screen." for a screen
    too slow in HDR), the usual one otherwise and for every SDR stream (`interpolationReason`, passed to the sheet
    like `upscaleIdle`).
    Older hosts' replies still decode (the field defaults to `off`; the old literals stay). Verified by unit tests:
    Swift (the state's truth table, the wire names, a renderer fed 10-bit SDR frames reading `sdrInHdr` and one
    without the HDR engine reading `hdrUnsupported`), TS (each stats row, the reason per case and only while
    streaming, decoding with and without the new values, the switch's description following the renderer).
    Review fixes (2026-11-21, unit tests): a slow screen replaces the switch's description only in HDR (an SDR
    stream keeps the usual text, as before; test added), and FRAME_INTERPOLATION's 10-bit SDR and tests notes name
    `sdrInHdr` / `hdrUnsupported`.
    **Left: an HDR game with frame interpolation on, on the console** (see section 4). See
    [docs/FRAME_INTERPOLATION.md](docs/FRAME_INTERPOLATION.md), "HDR".
- ✅ **Network** (requested): see [docs/NETWORK.md](docs/NETWORK.md).
  - **Cause found:** AirDrop and Handoff (AWDL) stall the Mac's Wi-Fi about 90 ms every second. Pings to
    the PS5 peaked at 105 ms; with AWDL off, 21 ms.
  - **Steady Wi-Fi** (Home and Settings → Stream) pauses AWDL while PlayFX is open: one password prompt,
    and a root helper that ends on quit or crash. The choice is remembered. While streaming, the HUD warns
    when AirDrop is stalling the Wi-Fi, with a button to turn Steady Wi-Fi on.
  - **Suggested at Play, never forced** (2026-11-21, requested): Play used to open the password prompt by
    itself when Steady Wi-Fi was left on last time. Now, pressing Play while AWDL reads `active` (and no change
    is pending) shows a 10 s toast with the switch's wave as its icon: "Smoother play on Wi-Fi", why it helps
    (or "Steady Wi-Fi was on last time. Turn it on again?" when it was left on), **Turn on** (the switch's
    path: macOS asks then) and **Not now**. Once per run of the app: shown, or a dismissed/failed prompt, means
    no more suggestions until relaunch. The toast closes if Steady Wi-Fi is turned on some other way (the
    HUD's button) meanwhile. Verified by unit tests (`SteadyWifi.test.tsx`): no prompt until Turn on, then
    exactly one; the remembered copy; Not now then a second Play → no toast; `paused`/`off`/`absent`, no
    reading yet, a pending change, a dismissed prompt → no toast; closed by the HUD's button. Left: seeing it
    in the app.
  - **The stall seen in the stream** (2026-11-20): `StallPattern` (`FramePacing.swift`) watches decoded frames'
    arrival: nine or more 70–400 ms gaps in 12 s, none with frames lost across it, at a steady 0.3–1.2 s period.
    It's `wifiStalls` in the pacing stats, and logged when it starts (with its period) and ends. With AWDL
    reading `off` (macOS flips it by itself), the HUD now says "The Wi-Fi keeps stalling" with the same
    "Turn on Steady Wi-Fi" button; with Steady Wi-Fi on, or no AWDL, it stays quiet (nothing more to offer)
    and only the log has it. Verified by unit tests: the detector's truth table (a stall every second or half
    second → yes, each up to 30 ms early or late or one missed now and then still yes; a single hiccup,
    0–40 ms jitter, gaps with frames lost, half-second gaps → no; the same stalls at random times, 200 seeded
    minute-long runs 0.2–2.5 s apart and 200 0.5–1.5 s apart → none flagged, at most 1% allowed, where the
    first limits (six gaps in 8 s) flagged 131 and 195 of them; it ends about 4 s after the stalls stop),
    the renderer reporting it, the pacing JSON (Swift and Rust), the schema with and without the field, the
    stats poll, and the HUD for each AWDL state. Not yet seen on a live stream.
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
    libchiaki's receive thread. Its Takion rewrite was left out (tuned for wired links), except its 256-slot
    queue (below). Not yet tried on the console. See docs/NETWORK.md.
  - 🔶 **The reorder wait, measured** (2026-11-21, two fork commits). The logs showed why a fixed wait can't fit:
    at 1080p30 20 Mbps HDR a frame is ~70 packets, more than the queue's 64 slots (at 1080p60, 37 frames of 4444
    were), and a full queue dropped packets that had arrived; on the LAN holes are rare (5 in 50 min), while in a
    3-minute collapse ~25 timeouts a second each missed 10–30+ packets (real loss, FEC failed). Now:
    - the video reorder queue has 256 slots, and when a packet wouldn't fit, Takion delivers what is buffered and
      skips the holes in front of it, as the timeout does: an arrived packet is never dropped for room;
    - the wait comes from the link (`reorderwait.c`): a hole that fills while waiting is a lateness sample; a
      packet that comes after its hole was skipped raises the wait to 1.25× its lateness at once (and is a sample);
      a skipped hole nothing comes for in 100 ms (real loss) shrinks it by 5%, but once there are samples not below
      srtt + 4 rttvar (review fix: per lost hole, a collapse's ~25 a second took it to 3 ms in a second and skipped
      59 of 60 packets 5 ms late in a simulation). Samples go through a TCP RTO smoother (srtt + 4 rttvar), up at
      once and down by at most 5% a sample, within 3–20 ms, from 16 ms; a sample is at most 20 ms, and the late
      check first expires holes skipped 100 ms ago (review fix: after a stall with no video, such a packet counted
      as late and held the wait at 20 ms). A packet half the sequence space old is dropped as older before the full
      queue makes room (review fix: it emptied the queue and rebased it on itself, dropping ~32k real packets);
    - Settings › Diagnostics shows "Reorder wait 4 ms · N holes filled while waiting · N late packets · N holes
      lost · N holes skipped for a full queue" (singular for 1) while a stream runs, the copied report has the same line, and the log says when the
      wait moves by 2 ms (at most every 5 s). The status JSON's `stream` carries `reorderWaitMs` and the counts.
    - Verified by unit tests: chiaki's (estimator traces: late by 7 ms settles at 7–10 ms, pure loss drifts to
      3 ms, a burst then calm, one outlier bumps then decays, the clamps, duplicates, the wrap; and a fake console
      on localhost: a full queue delivers every packet that came in order, a hole filled in time lowers the wait,
      a packet 10 ms after its skip raises it to 20 ms, duplicates aren't late; and from the review: loss mixed
      with reordering keeps the late packets covered, a packet after the 100 ms window isn't late, a 90 ms one is a
      20 ms sample, a stale packet leaves the queue alone), and Swift, TS for the stats and the Diagnostics line
      (each reorder field checked with distinct values in `Stats.setReorder`; psrp.c's copy is checked at compile
      time against libchiaki's struct). **Left: a session on the console** (section 4).
  - **Open:**
    - the reorder wait on the console (section 4); PR #817's 33 ms isn't taken: the wait is measured instead;
    - the stream with Steady Wi-Fi on hasn't been measured (only pings were);
    - the warning from the stall itself hasn't been seen on a live stream (its thresholds come from the
      measured ~90 ms every 0.5–1 s);
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
  **Not felt until 2026-11-24** (GTA VI, pad on a cable, 2026-11-20: the log showed the haptics stream playing on
  the pad and rumble and triggers worked, but nothing came from the haptics themselves: on macOS the pad ignores
  that audio until it's switched into audio-haptics mode; fixed below). Astro's Playroom would show the fine
  textures best.
- ✅ **USB haptics felt: the pad switched into audio-haptics mode** (2026-11-24; **felt in GTA VI with the app**, pad
  on USB after a replug, the user: "now works perfect"). What was wrong: out of the box on
  macOS a DualSense on USB plays nothing from channels 3 and 4 of its sound device, so the USB path above played
  into nothing. How it was found: a scratch tool played 150 Hz pulses on those channels of the user's pad
  (macOS 27.2) and sent different HID output reports first; nothing was felt until one report 0x02 of 48 bytes
  (the pad's `kIOHIDMaxOutputReportSizeKey`) with every byte after the ID zero (all "valid" flags clear, so
  rumble, light bar, triggers and volumes don't change); a report with only the "haptics select" flag (0x02) did
  nothing. The pad forgets it when replugged, and GameController's own reports (rumble, triggers, light bar) may
  switch it back. The fix (`USBHapticsMode.swift`): when haptics start on a USB pad, `DualSenseHaptics` sends
  that report to the first DualSense (054C:0CE6) or DualSense Edge (054C:0DF2) HID device on USB (opened
  non-exclusively, kept open while they play), again about once a second while haptics frames keep coming, and
  0.1 s after the app's own rumble, trigger or light bar output (a counter `Rumble`, `AdaptiveTriggers` and
  `PadLight` bump); it lets the device go when they stop. All of it on the haptics queue, never the audio thread,
  and not per frame (the receive thread only compares times under the lock it already takes). Never on Bluetooth.
  A failed report (no HID device, or an IOReturn) is logged once and the haptics audio plays on. New log lines:
  "DualSense haptics: audio haptics enabled on <name> (USB)" once a session, and, when haptics arrive but no
  DualSense is found on USB or Bluetooth, the Mac's sound outputs with their channel counts (once a session).
  Unit-tested with a stand-in HID device: the bytes, sent at start and each second, sooner after pad output, not on
  Bluetooth or with no pad, failures logged once with playback going on (StreamCore 509 tests, +8). Docs: HELP
  and README. **Left**: feeling it in a game with the app (Astro's Playroom), including right after a rumble or
  trigger effect.
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
  Silent Hill 2 an ⌥-click on the video opened the map, as the pad's touchpad button does.) **Touchpad
  touches** switch (built 2026-11-21, **unit tests only, not yet on the console**): some games act on a touch
  alone (in GTA VI a thumb resting on the DualSense's touchpad opens the map, reported by the user and in
  chiaki-ng PR #896). Settings › Misc › Controller (Stream until the Misc tab came), on by default; off, `ControllerInput` leaves the pad's
  fingers (DualSense and DS4) out of the state it sends, and the touchpad click (`PSRP_BTN_TOUCHPAD`) still
  goes. It applies at once (`set_touchpad_touches` → `sc_set_touchpad_touches`, kept for later sessions), never
  asks for a reconnect, and belongs to profiles (summary "touchpad click only"; settings and profiles saved
  before it read as on). The Mac's pointer as the touchpad, the keyboard and the on-screen controls aren't
  affected. Verified by unit tests: Swift (fingers dropped off and kept on, the click kept, a finger down when
  it's turned off lifted on the console at once, the pointer's touch still merged, the bridge applying it to the
  playing session and the next one; turned back on with a finger resting, that finger is a new touch with a new
  id, not the one the console just saw lift), TS (decoding without the field, profile matching and summary, no reconnect
  from the switch or a profile mid-stream, the switch calling the bridge at startup and on change), Rust (the
  command, its IPC arguments and ACL). The switch is logged (StreamCore, `input`) only when it changes, not on
  every settings change. Review fix, older than the switch: a pad that disconnects mid-press or mid-touch (asleep,
  battery, Bluetooth) left its last reading held on the console, since GameController sends no last reading and
  nothing watched `GCControllerDidDisconnect`; now `ControllerInput` releases the buttons, sticks and touch of the
  pad that sent them (and the motion of the pad that sent it) and the keyboard keeps working, unit-tested through
  the notification and with two stand-in pads. Left: the hand-on check in GTA VI (section 4, item 4).*
- 🔶 **Pad buttons on the Mac** (`psrp pad`, DualSense over Bluetooth, 2026-11-19): every face/shoulder/
  D-pad/stick button, Create, Options, the touchpad click and both analog triggers (0–255) map correctly;
  touchpad ids are stable per finger and two fingers track. All elements opt out of macOS system
  gestures. **PS button**: macOS never delivers it to the app; with a game-category app in front
  (`LSApplicationCategoryType` games, now in the desktop `Info.plist`) it at least stops opening the
  Games app. The Mac keyboard's P sends PS (the web UI's keymap), and the stream HUD has a semi-transparent
  **PS button** at the bottom center (held while the pointer is down: short press = control center, long = home). **Mute** isn't exposed by GameController.
- ✅ **Settings profiles**: a profile holds the stream and picture settings (resolution, frame rate, codec,
  bitrate, HDR, view, upscaler, sharpening, cleanup, ML, frame interpolation, colors); app preferences stay put.
  Built-in **Recommended** (also what a new install starts with, and what Reset stream / Reset picture go
  back to): since 2026-11-21 (requested) 1080p60 · HEVC · 20 Mbps · MetalFX · sharpness 0.3 · ML upscaling ·
  Frame interpolation (it was Auto bitrate and interpolation off; stored settings aren't migrated, and settings
  saved before those fields existed still decode as Auto / off). A second built-in **GTA VI** (2026-11-21,
  requested): Recommended at 30 fps with Touchpad touches off, and since 2026-11-24 (requested) ML upscaling off
  too, "1080p30 · MetalFX · sharpness 0.3 · Frame interpolation · touchpad click only"; built-ins list first (Recommended, GTA VI), can't be
  deleted, replaced or saved over (`"GTA VI" is built in. Choose another name.`), and the Replace chips
  offer only saved ones. A profile the user saved as "GTA VI" (or "Recommended") before is loaded as "GTA VI
  (saved)" (the next free "(saved 2)"… if taken), so no two options share a name; the stored list keeps the
  old name until the next save or delete writes it back under the new one, by which it is picked, replaced
  and deleted. When a saved profile and a built-in one hold the same settings, the saved one shows as
  selected (and so can be deleted); before, the built-in always won, and a saved "GTA VI" identical to the
  built-in could be picked but not deleted. Verified by unit tests (profiles: both built-ins, order, summaries, the rename; actions:
  built-in names refused, replace and delete by the new name; App: GTA VI mid-stream asks to reconnect,
  ML upscaling off and touchpad click only at once, reconnects at 30 fps, and a saved "GTA VI" kept and deleted as "GTA VI
  (saved)", also when its settings equal the built-in's). Left: GTA VI on the console with that profile. The user saves the current settings under a name,
  switches, deletes. Settings → Profile; stored in
  `psrp.profiles`. "Custom" when the settings match no profile. **Replacing a profile** (2026-11-20,
  requested): Save as… lists the saved profiles to pick; a matching name turns Save into **Replace** with a
  line saying so, and the profile keeps its place in the list. **Switching from Home and while playing**
  (2026-11-20, requested): Home's footer reads "Profile [Recommended ▾] 1080p · 60 fps · … [Settings]", the
  same select as the Settings Profile bar (one shared component; the saved profiles are one list for the
  app, so a profile saved in Settings shows on Home at once). In game the Settings Profile bar is the
  switcher (no new HUD button): each other profile's option says what switching costs, "· applies now"
  (picture only) or "· needs a reconnect" (resolution, frame rate, codec, bitrate or HDR differ from what
  the stream started with). A switch toasts "Switched to <name>" (" · reconnect to apply" when it needs
  one), and the Reconnect notice now sits above the tabs so it shows from any tab. A profile switch asks
  first: the stream keeps going until Reconnect, even when only the bitrate differs (measured against the
  running stream, so a bitrate still settling on the slider waits too); the bitrate slider still reconnects
  on its own. **During a reconnect** (fixed 2026-11-20, from the v0.2.0 review) a switch is measured against
  the options that reconnect starts with, not the ones the old stream had: a profile with the old bitrate,
  picked while the slider's 20 → 30 Mbps reconnect was under way, used to read "applies now" and then
  reconnect on its own back to 20 Mbps once the stream was back; it now asks first, and a profile matching
  the bitrate coming applies at once. Verified with UI tests (Home switch and Custom, costs only while
  streaming, no auto-reconnect after a bitrate-only profile or a switch while the slider settles, the slider
  releasing a held switch, the slider after it, and both switches during a bitrate reconnect: no second
  reconnect, the labels and toasts). Left: a console session to see a
  mid-stream switch reconnect into the new profile, and the option labels in macOS's native select popup.
- ✅ **Rest mode on Stop**: while streaming, Stop asks "Put <console> in rest mode?" (Rest mode / Leave
  it on / Keep playing). Rest mode sends libchiaki's goto-bed (`sleep_console`), waits 1.5 s for it to
  reach the console, then stops. Before the stream connects, Stop stops at once. Unverified on a console.
- ✅ **Console IP on the home network**: an optional IP field (since 2026-11-20 in the console list, whatever
  the Connect mode; it used to show for Home network only); each discovery round also asks that address
  directly (`discover` with `host`, IPs only) and merges what it finds, so a console broadcast discovery can't
  see still shows up and plays, in Automatic too. Unverified on a console.
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
  back to SDR for SDR frames or the backdrop. ML upscaling only takes 8-bit frames, so it sits out in HDR; frame
  interpolation runs on HDR streams with MetalFX's frame interpolator (2026-11-20, offscreen only so far: see
  "Frame interpolation", HDR streams). The stats line says "HDR" while it's on. Unit test: a 1000-nit HDR10 frame renders at
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
- ✅ **Input lane off the main thread** (2026-11-21): an input loop (user-interactive) reads every connected pad
  between GameController's main-queue callbacks — `InputPacer` paces it, 500 Hz while readings change (learning
  half the pad's reporting interval from the gaps between distinct readings) and 125 Hz after a second of quiet —
  so a press or a stick move doesn't queue behind a frame's render or a UI update. Motion readings whose sensors
  read exactly as the last are dropped (a timestamp alone would re-integrate the same stillness). Unit tests only
  (pacer policy, the loop's read through `pollPads`, the motion dedupe): not yet on the pad — the off-main reads
  of GameController's elements want a look with one, then the dev latency test before and after. Review fixes
  (unit-tested): states reach `onChange` one at a time and in the order merged (the test fails against the old
  hand-off); each pad's unchanged reading and motion are dropped, so two connected pads don't take turns on every
  pass, and an idle pad's first reading doesn't take over; reads of a disconnected pad are dropped; the loop
  starts when `onChange` is set; `StreamSession` sends the pad's and pointer's states under its lock.
- ✅ **Settings tabs** (2026-11-21, asked for: Picture vs Stream read alike): Picture · Stream · **Misc** ·
  Diagnostics, each with an icon (lucide Image, Radio, SlidersHorizontal, Activity) and a plain line at the
  top saying what it controls ("How this Mac cleans up, sharpens and smooths the picture.", "What the console
  sends: …"). Misc holds the Controller group (Touchpad touches), which applies at once and so never belonged
  with the stream settings; it has no reset button (one setting). The sheet keeps its tab while open and
  reopened, Misc included. The four labels with their icons fit the 23rem sheet by sizing each column to its
  label (`grid-cols-[repeat(4,auto)]`, the leftover shared out); measured in headless Chrome with the app's
  CSS and font (300 px needed of 328), not yet looked at in the app's webview. Verified by unit tests (App: the
  four tab names, each line, the switch under Misc and not Stream, Misc kept on reopening).
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
- ✅ **Pairing guide and copy** (2026-11-20, from the pairing review): the guide starts with "Get your PS5
  ready" — Settings › System › Remote Play › Enable Remote Play, and for waking from rest mode Stay Connected
  to the Internet and Enable Turning On PS5 from Network under Settings › System › Power Saving › Features
  Available in Rest Mode — then Sign in, Pair, Play. The app can't see those settings, so that step stays
  open (not ticked off by signing in) until a pairing works. The guide now stays after pairing, with Play as the step to
  take, until the first Play leaves Home. The pair form names Pair Device (Link Device on some versions), the
  PS4 path (Settings › Remote Play Connection Settings › Add Device) for a PS4, says it's the 8-digit pairing
  code, not the console passcode, and that the code is valid for about 5 minutes. The login PIN dialog is now
  "Console passcode": the PS5 user's 4-digit passcode (PS4 user's when streaming a PS4), not the pairing
  code. Badges say "rest mode" instead of "standby" (the internal value is unchanged); one arrow style (›) in
  the UI. A failed PSN sign-in says
  "PSN sign-in failed" once (StreamCore now gives only the reason: Sony's, "PlayStation Network didn't answer
  in time", or "The Keychain couldn't save the PSN tokens (error N)"; `psrp account-id` prints that reason
  alone) and tells the user to sign in again and check the Mac is online. Checked by unit tests (App,
  actions, PSNAuth, bridge). **Needs a PS5 and a PS4 to confirm** the menu names as the current firmware
  shows them, and how long the code really lasts.
- ✅ **"No consoles found" help** (2026-11-20, from the pairing review): while the first scan runs, the empty
  console list says "Looking for consoles on this network…" (the header's status line now only shows discovery
  errors, so one state has one message); once a scan found nothing on the network (also
  when paired consoles are listed but none is here: "No consoles on this network yet") it shows what to check
  (the PS5 on, or in rest mode with Stay Connected to the Internet; the same network as the Mac, not a guest
  Wi-Fi; no VPN; PlayFX allowed on the local network, with **Open Local Network settings**, a new
  `open_local_network_settings` command that opens System Settings › Privacy & Security › Local Network at a
  fixed URL) and "On a different subnet here, or behind a second router at home? Enter its IP." with the
  console IP field, whatever the Connect mode, and "Away from home? Play a paired PS5 over the internet with
  Connect › Internet." With a console found here, the field sits folded under the list ("Console missing? Add
  it by IP"), open when an IP is saved. Every scan now asks a saved IP directly, not only in
  Home network mode, so a console paired through the IP field plays in Automatic too. Checked by unit tests
  (App: calm then help, the button, the field saving, the help hiding, playing in Automatic; actions: the IP
  asked in every mode; Rust: the command through the real ACL, with `open` recorded instead of run in
  tests). **Needs a Mac to confirm** that the button lands on the Local Network pane on the macOS versions we
  support (the URL is Apple's, not documented), and a console on another subnet to confirm the IP path in
  Automatic.
  In Internet mode (Connect › Internet) the help is left out under consoles listed through PSN (2026-11-20,
  owner's decision): it's about this network, which doesn't matter there. With none listed through PSN it
  still shows. Checked by unit tests (App: left out, and kept with nothing listed through PSN).
  There, its last line no longer says to choose Connect › Internet, the mode already chosen (2026-11-20, from
  the release review): without a PSN sign-in for internet play it says "Playing over the internet? Sign in with
  PlayStation above, and your PS5s show up here."; signed in (or before PSN has answered), that PSN lists the
  PS5 when Remote Play is on and it's on or in rest mode with Stay Connected to the Internet. The PSN poll now
  reports whether the sign-in is kept. The local-network checks and the IP field stay: pairing with a code
  still needs the console found here. Checked by unit tests (App: both lines, and no Connect › Internet in
  Internet mode; actions: the poll's sign-in).
- 🔶 **Say why pairing failed.** A failed pairing showed one sentence whatever went wrong. The fork's
  registration now reports the cause on its failed event (libchiaki's error, the console's HTTP status and
  RP-Application-Reason, and whether the console had answered the search; fork commits "Regist: say why a
  registration failed" and "Regist: say whether the console had answered when a registration failed", unit
  tests in `test/regist.c`, the second against a loopback stand-in console), and the C shim
  (`psrp_regist_error_message`) turns it into a message with the next step: wrong or expired code
  (`0x80108b09`) → get a new one from Pair Device; another PSN account (`0x80108b02`, signed in or a pasted
  account ID) → open Pair Device as that account's user, or sign in as that user (or paste their account
  ID); before the console answered: no answer (timeout, or the search refused because Pair Device is closed)
  → keep Pair Device open, same network; can't reach it (network errors) → Local Network permission, VPN;
  after it answered, a lost or refused connection → it stopped answering, keep Pair Device open and pair
  again with its code; Remote Play version mismatch (`0x80108b11`) → update; anything else (an unusable
  reply too) → the old sentence without "the account ID". A PS4 gets "Add Device". Swift, Rust and the UI
  pass the message through unchanged. Verified by unit tests (the mapping; a pairing against loopback ends
  in "didn't answer"), not on a console. Pairing through PSN tells the same two apart (2026-11-20): a PS5 that
  never answered the registration gets "didn't answer pairing through PSN" rather than "didn't accept" (see
  "Pair without a PIN through PSN"; fork unit tests against a loopback stand-in console for both cases).
  **Needs a console session:** trigger each case once (mistyped code, expired code, another PSN account, Pair
  Device closed, Local Network denied) and record the real codes from the log ("Reported Application Reason"):
  it isn't sure `0x80108b09` is the only wrong-code reason, nor which error a denied Local Network permission
  gives.
- 🔶 **Pair without a PIN through PSN.** PIN-less pairing built; **needs a hardware check: does a PSN
  registration's key work for streams on the home network** (chiaki-ng relies on it). Every internet session
  already registers the Mac with the PS5 over PSN with no PIN; with `auto_regist` libchiaki stops right after
  and hands over the same keys a PIN pairing gives. The shim gets a `register_only` start mode (PSN token, the
  console's PSN device ID and the account ID; no keys) that sets `auto_regist` and forwards the result through
  a new `registered` callback (keys, nickname, MAC, PS5), with a "registering" progress stage; StreamCore's
  `PSNPairing` runs it, treats a quit without the keys as a failure with a next step (a refused registration
  apart from no answer: fork commit "Session: keep a failed PSN registration's quit reason", as libchiaki
  turned every failed PSN registration into a clean stop; and since 2026-11-20 a PS5 that PSN reached but that
  never answered the registration apart from one that refused it: it used to get "didn't accept pairing", and
  now gets "didn't answer pairing through PSN" with what to check, on, Remote Play on, online and signed in to
  PSN with the same account; fork commit "Regist: end a PSN registration at once on a stop, and say when the
  console never answered" gives it its own quit reason, `PSN_REGIST_UNANSWERED`, from the registration's
  `console_answered`, which the PSN path sets once the console answers the RUDP init; internet play's toast
  says the same), and cancels it (while the PSN token is fetched too;
  a Cancel during the registration used to hang the pairing for good, as did a PS5 slower than libchiaki's 10 s
  wait and, by a race, a success: libchiaki joined its registration thread while holding the state mutex that
  thread's last callback takes. Fork commit "Session: don't hold the state mutex while waiting for the PSN
  registration to end", with a loopback test that deadlocked before it; internet sessions stopped while
  registering hung the same way. A Cancel there now ends at once (2026-11-20): the registration's RUDP steps
  waited on a stop pipe nothing stopped, so a Cancel took up to 3 s, and up to 12 s with a console answering
  slowly; they wait on the registration's own now, in the fork commit above, whose loopback test ends a
  stopped registration in ~2 ms and failed before it at 3 s. Verified by the fork's unit tests and StreamCore's
  mapping tests, not on a console);
  `sc_psn_pair` / `sc_psn_pair_cancel`, the Tauri commands `pair_psn` / `cancel_psn_pair` (the PSN token stays
  native), and `Core.pairPsn` (progress from "psnPairProgress" stream events; interrupting it cancels). In the
  UI, after the PSN sign-in, the account's unpaired PS5s get "Pair (no code needed)": on the row of the console
  found here with the same name (next to "Pair with a code"), or on a row of their own ("PS5 · on your PSN
  account"); a PS5 with Remote Play off says so and how to turn it on. A PS5 paired with a code and renamed since
  (the pairing keeps the old name) isn't offered again when it's found here under the new name (2026-11-20, from
  the release review: it showed twice, paired and "Pair (no code needed)"); away from home it still can be, as
  only its old name is known there. Pairing shows its step ("Finding … through
  PSN", "Pairing this Mac with …"), the seconds so far and Cancel. On failure the PIN form opens with the reason,
  or, for a console not on this network, a note says to connect it to pair with a code. Both follow the console
  by its PSN device ID, so they stay on it when discovery finds it mid-pairing (its row's host ID changes), and
  the seconds count from the pairing's start, not from the row's (it remounts then). The pairing is saved
  through the usual pairing store, with the console's PSN device ID (internet play then matches it by ID, not
  name), under discovery's host ID: the console's when it was found here, else its MAC as uppercase hex, which
  discovery's host ID is, so the console merges with it (and its address is filled in) once it's found at home;
  until then it plays over the internet. The first-run guide mentions it. Verified by unit tests at every layer
  (stand-ins for the session; the shim refuses bad input before any network), not on a console. **Needs a
  console session:** pair PS5-454 this way, then (1) play it on the home network (the main question), (2) play
  it over the internet, (3) check it merges with the discovered console (host ID = MAC) rather than showing
  twice, and (4) a failure case (Remote Play off, another PSN account) for the real messages. PS5 only (PSN lists
  PS5s); networks that block hole punching still need the PIN.
- ✅ **Help page** (2026-11-20, requested): [docs/HELP.md](docs/HELP.md), for players: requirements, first-time setup
  (with and without a code, over the internet), an FAQ (no consoles found, each pairing failure message and what to
  do, pairing code vs console passcode, waking, Steady Wi-Fi and its password prompt, stutter, every item of the
  stats line, frame interpolation, upscaling, HDR, bitrate and profiles, DualSense, microphone, other controllers),
  the keyboard map, what PlayFX stores and where, logs and bug reports, uninstalling. A **Help** button next to
  Settings on Home and in Settings › Diagnostics opens it on GitHub (a new `open_help` command with a fixed URL, like
  Source code). The README links it under Install. Checked by unit tests (App: both buttons; Rust: the command
  through the real ACL; a test fails when the page's keyboard table drifts from `keyboard.ts`). Keep the page in
  step with the UI's wording when that changes.

### Out of scope: other platforms

The project focuses on **macOS only** (decided 2026-11-18). Not planned: an iOS app (Expo), Windows /
Linux (would need a non-Apple decode/render/input layer, e.g. FSR), or a browser build (no raw UDP/TCP
in a normal tab). StreamCore keeps its iOS target in `Package.swift`, but nothing depends on it.

### P4 — build, distribution, compliance

- 🔶 **Our own Remote Play protocol (`PlayFXProtocol`), to replace libchiaki.** libchiaki is AGPL, which keeps
  PlayFX off the Mac App Store (a native shell replacing Tauri's private API is the other half, later). Decided
  2026-11-23: a Swift package of our own (`packages/playfxprotocol`, proprietary, no GPL/AGPL dependencies),
  native frameworks first (`packages/playfxprotocol/DESIGN.md`: Network.framework, Wi-Fi video service class,
  kernel receive timestamps, `NWPathMonitor`, CryptoKit/CommonCrypto), built clean-room: spec writers read
  chiaki-ng and write facts only into `docs/protocol`; implementers get only the spec and never open chiaki. A best-effort
  clean room (AI models have seen chiaki); a lawyer reviews before an App Store submission.
  - ✅ Spec, milestone 1 (2026-11-23): `docs/protocol` README (process, conventions), discovery + wake,
    registration, RP crypt (14 constant tables as hex with SHA-256s), session init, ctrl channel, test vectors.
    Verified: an independent Python script written from the spec text reproduced 82 values that a C harness
    computed with chiaki-ng's code (40 for session/ctrl, 42 for discovery/registration), and chiaki-ng's
    registration paired with a fake console built from the spec on loopback, for every target version. Open
    questions (console refusal codes, heartbeat rate, some `RP-*` fields) are listed in each doc, for the console.
  - ✅ Swift discovery, wake, RP crypt and registration from the spec (2026-11-23), by an implementer that never
    saw chiaki: `Discovery.discover/discoverThrowing/discoverAsync/wake`, `Registration.register/registerAsync`
    (cancellable), `RPCryptContext` (session, LAN and PSN registration, all targets; one reusable AES cryptor, no
    per-call allocation). Discovery/wake on a BSD socket (broadcast) with `NET_SERVICE_TYPE_RD`; registration's
    HTTP over `NWConnection`. Pairing errors give PlayFX's messages plus new ones for "in use" (80108b10),
    "crashed" (80108b15), other reason codes, a bad account ID or address, and a denied Local Network permission.
    87 tests (all spec vectors, the 14 tables' SHA-256s, extra vectors from an independent script, a loopback
    fake console for every target and failure), 96.6% lines / 94.3% functions (96.5% with
    `STREAMCORE_SIMULATE_VM=1`); a guard fails any test that sends to a non-loopback address. Reviewed against the
    spec by a separate agent: no interop divergence found; its fixes are in. From the automated security
    review: wake broadcasts only on the Mac's interface on the console's subnet (the credential never goes to
    other networks), a unicast search only accepts answers from that address, and a known console can't be
    moved to another address by a later answer. 91 tests, 96.8% lines. `pfxp discover | wake | pair` drives
    it on a real console (pairings saved apart from psrp's, 0600). Not yet on a console.
  - ✅ Hardware round (2026-11-23, the user's PS5, system 14230000, LAN), with `pfxp`: discovery (unicast and
    broadcast) found PS5-454 in standby with the same name, state, host ID and system version as `psrp
    discover`; `pfxp wake` brought it from rest to ready in under 10 s; `pfxp pair` paired in 0.1 s and got the
    same registration key, RP key, MAC and nickname that libchiaki stored for that account (so the decryption
    is right and the old pairing stays valid). The first three pairing attempts failed: a PS5 pads
    `Content-Length:        195`, and the parser took only one space after the colon. Fixed (values trimmed,
    the fake console answers with the PS5's exact header), and recorded in the spec ("Observed on a real
    console"). 92 tests, 96.7% lines.
  - ✅ Milestone 2, session init + ctrl channel in Swift from the spec (2026-11-23): `ControlSession.start`
    (session init with the version retry, the session crypt, the ctrl request with its encrypted headers, the
    `NWProtocolFramer` framing, every ctrl message both ways), events with the session to a handler on a private
    queue, throwing commands (login PIN only when asked, keyboard, go to bed/home, mic, stop), typed
    `SessionError`s with user messages (busy, crashed, version mismatch, resets, network), and the
    `StreamHandoff` for the stream stage (secrets redacted in descriptions and `dump`). 172 tests (spec vectors,
    an independent fake console, the PS5's observed start and go-to-bed sequences, every error, stop/cancel in
    each phase), 96.4% lines / 95.6% functions (96.5% with `STREAMCORE_SIMULATE_VM=1`). Reviewed against the
    spec: no divergence; its fixes are in (an early login-PIN request can be answered, a cancel after connecting
    no longer kills the session). **On the PS5** (`pfxp session`, 2026-11-23): session init 200 / 1.0 in 20 ms,
    ctrl up 20 ms later, login accepted unprompted, session ID at 0.5 s, heartbeats every 5.0 s all answered, a
    clean stop after 20 s; go to bed put it in rest in about 6 s; session init in rest mode is refused (wake
    first); woken, ready in 9 s. The spec records these ("Observed on a real console").
  - ✅ Milestone 3 spec (2026-11-23): `takion.md` (the UDP transport: packets, handshake, chunks and acks,
    GKCrypt with AES-GCM and key positions, the AV header, congestion and feedback packets, sequence numbers,
    and PlayFX's own reorder wait and 256-slot queue described as our design), `stream.md` (protobuf messages,
    the network probe, the Hello handshake with secp256k1 ECDH, the launch spec from PlayFX's settings, stream
    info, IDR and corrupt-frame reports, quit reasons, rumble, triggers, haptics, LED, motion, touch, mic) and
    `av.md` (frame assembly, the Cauchy Reed-Solomon FEC over GF(2^8) as maths so we can drop jerasure, the
    Annex-B unit, H.264/HEVC facts, Opus audio, haptics, the mic). Verified: independent scripts from the spec
    text matched chiaki's code on 16 Takion vector sets (client packets captured off loopback, console
    packets built from the spec accepted by its parser and GMAC check), 43 stream values (ECDH, launch spec,
    Hello and its split, console messages) and the FEC (300 random cases against jerasure, and the parity in a
    real console capture). Open questions for the console are listed in each doc.
  - ✅ secp256k1 for the stream handshake (2026-11-23): libsecp256k1 v0.8.0 (bitcoin-core, MIT, August 2026)
    vendored unmodified as the C target `CSecp256k1` (core, precomputed tables and the ECDH module only; see
    `Sources/CSecp256k1/README.PlayFX`). CryptoKit has no secp256k1. It goes into `THIRD_PARTY_LICENSES` when
    PlayFXProtocol first ships in the app.
  - ✅ The stream messages and the audio/video layer in Swift from the spec (2026-11-23), built in parallel by
    implementers that never saw chiaki, each reviewed against the spec (no wire divergence found) and fixed.
    **Stream** (`Sources/PlayFXProtocol/Stream`): a hand-written proto2 codec and every stream.md message, the
    Hello and its split, a stateful handshake that keeps an early StreamInfo and wipes the key pair only at the
    end, secp256k1 ECDH through `CSecp256k1`, the launch spec byte for byte, quit reasons with user messages,
    rumble, triggers, pad info, the feedback-state body and history events, the orientation estimator; secrets
    redacted in descriptions and `dump`. **Audio/video** (`Sources/PlayFXProtocol/AV`): frame assembly with
    the spec's completion and loss rules, our own Cauchy Reed-Solomon FEC (NEON split-nibble: 6 of 60 units of
    1400 bytes recovered in 17 µs, asserted under 100 µs in release; jerasure no longer needed), Annex-B into
    one reused buffer, H.264/HEVC slice parsing and the HEVC reference rewrite, IDR-wait and corrupt-frame
    rules (no IDR storm on decoder rejection), Opus packets with loss marking, haptics, the mic packetiser;
    no allocation per unit. The av.md writer answered the implementer's ten questions (a spec vector was
    wrong) and added a real console capture, which the decoder reproduces. 469 tests with Takion (below),
    97.7% lines; four cancel-timing tests got wider margins (they failed only when the whole, heavier suite
    ran in parallel).
  - ✅ Takion in Swift from the spec (2026-11-23, `Sources/PlayFXProtocol/Takion`): every packet type, the
    handshake, DATA/DATA_ACK, retransmission, fragmentation and reassembly, GKCrypt (counter blocks over
    AES-ECB, the keyPos rules, epoch keys pre-derived on a helper thread and cached only after the tag verifies,
    the GMAC as our own table GHASH, checked against CryptoKit in a randomised test), the AV header for every
    version, the congestion report (its numbers from the AV layer, which knows duplicates and frame completion),
    feedback framing, wrap arithmetic and PlayFX's reorder wait and 256-slot queue. Reviewed against the spec (no
    divergence) and fixed: haptics no longer counted as audio loss, no socket use after close, forged packets
    can't fill the key cache, hard send errors end the connection. **Two receive transports, measured on
    loopback** (`pfxp bench-transport`, release, 20,000 packets/s of 1400 bytes, alternating runs after a
    warm-up): a BSD socket thread (poll + `recvmsg` into a preallocated ring, `NET_SERVICE_TYPE_VI`,
    `SO_TIMESTAMP_MONOTONIC`) at 8.2 ms CPU per 1000 packets, p50/p99 8/13 µs, 0 allocations per packet;
    `NWConnection` (interactive video, kernel receive times) at 27 ms, 18/25 µs, 28 allocations. The BSD path
    is the default (decided 2026-11-24, `.nw` kept as a tested fallback, e.g. for iOS). A release test asserts 0 allocations on
    the receive path. 481 tests, 97.7% lines (same with `STREAMCORE_SIMULATE_VM=1` and serially).
  - ✅ The whole stream session from the spec (2026-11-24, `Sources/PlayFXProtocol/Session`): `StreamSession.start`
    runs ctrl, the network probe (best effort: RTT and MTU by bisection, fallbacks on failure), Takion, the
    Hello/HelloReply handshake with ECDH, StreamInfo into the AV layer, heartbeats, controller feedback (state and
    history), congestion reports, IDR and corrupt-frame reports, and ends exactly once (`stop()`, a console
    Disconnect, a lost connection or a ctrl end; the Disconnect is sent whenever the Hello was). `start` throws
    until the stream is up, then every ending is one `ended` event. AV events come straight from the receive
    thread with 0 allocations per packet (asserted in a release test, congestion path included); the rest from a
    private queue, and nothing reaches the app after `ended`. `pfxp stream` saves the video (Annex-B) and Opus
    packets to new files only (never overwrites), prints stats every second, takes `--transport bsd|nw` and
    `--mic-info`, and stops cleanly on Ctrl-C. Tested end to end: a fake console streams the real PS5 capture,
    encrypted over loopback, and the session reproduces its access units (SHA-256). Reviewed against the spec and
    fixed: a leak that kept every connection and the ECDH private key alive, a start that could fail after
    `connected`, no Disconnect when the session was dropped, EMSGSIZE ending the probe instead of shrinking the
    MTU, a lock held across sends, answers sent after `connected` instead of before, and `pfxp` output files
    that could overwrite anything. One deliberate deviation: the microphone StreamInfo is only sent with the mic
    enabled (`--mic-info` compares both on the console). 544 tests, 97.9% lines (same with
    `STREAMCORE_SIMULATE_VM=1` and serially).
  - ✅ First console round for the stream (2026-11-24, the user's PS5 on the LAN, woken from rest and put back
    to rest by our own code): `psrp stream` (libchiaki) as the baseline, then four `pfxp stream` runs, 720p60
    H.264 on the BSD socket thread and on Network.framework (30 s each), 1080p60 HEVC and 1080p60 HEVC HDR with
    `--mic-info` (15 s each). Every run connected in 0.5–1.1 s, kept 60 fps with no frame or audio packet lost, no
    GMAC failure or retransmission in about 20,900 packets, and ended cleanly; the saved video decoded in ffmpeg
    with no errors (H.264 Main; HEVC Main BT.709; HEVC Main 10 PQ/BT.2020). Answered in the spec ("Observed"
    sections of stream.md, av.md, takion.md): the console signs its HelloReply with the handshake key as
    expected, ConnectionQuality's target bitrate is in bit/s, the audio header is 2/16/48000/480, the probe's
    Takion v9 works on a PS5, and the console streams with or without the microphone StreamInfo. Probe RTT
    0.9 ms (bsd) vs 1.1 ms (nw). Then in a game (GTA VI unpaused through psrp's control API: PS, then circle
    three times), 1080p60 HEVC asking 30 Mbit/s: psrp 60 fps at about 4 Mbit/s, nothing lost; `pfxp` on the BSD
    thread 60 fps at 3.7–4.5 Mbit/s (about 660 packets/s, character standing still), nothing lost, 2,801 haptics
    frames received. Then, with nobody playing but a busier spot in the game (foliage, traffic), both at the same
    load: Network.framework 59–60 fps at 11–13 Mbit/s (40,764 packets in 30 s), BSD thread 59–60 fps at
    11–14 Mbit/s (41,915 packets); each lost nothing, had no GMAC failure or retransmission, ended cleanly and its
    video decodes in ffmpeg. On this wired-quality LAN the two transports are indistinguishable. Decided with the
    user: the BSD thread stays the default (cheaper per packet, which matters more on a phone, and fine on iOS),
    and Network.framework stays built and tested as a fallback (DESIGN.md "Stream transport"). One earlier nw run was ended by
    the console after 6.9 s ("Server shutting down", reported as `streamRemoteShutdown`) when the user picked up
    the console's own controller. **Not yet checked on hardware:** FEC recovery and reorder (the LAN lost
    nothing), CPU per packet on the console's traffic, controller input, the HEVC codec byte, the pad-info form.
  - ✅ Input and loss on the console (2026-11-24): `pfxp stream --press SCRIPT` (timed buttons and sticks,
    `ControllerScript` in the library; every boundary is sent even after a late wake-up, a repeated button gets a
    release), `--trace-input` (each state sent), and `--drop PERCENT [--drop-burst N]` (testing only, off by
    default: drops received stream datagrams once the stream is up, allocation-free, asserted in the release
    test). It also prints the video codec byte and the pad-info form. On the PS5 in GTA VI: our input closed the
    PS overlay, walked the character and turned the camera (the first time our own pad drove the console); with
    5% of datagrams dropped in pairs at about 11 Mbit/s, FEC rebuilt 490–612 frames per 30 s, 26–32 frames per
    30 s were beyond repair and each cost about 6 frames (≈100 ms) until the key frame the console always sent,
    audio lost nothing, BSD and Network.framework alike. Answered: HEVC's codec byte is 0x06, the PS5 sends the
    17-byte pad info. Unexplained: once, 4.5 s after the script's last input, the PS5 showed its "Adjust Display
    Area" screen (the state sent after a script is byte-identical to idle; `--trace-input` is for the next round).
    Reviewed against the spec and fixed (short presses announced but not sent, merged presses, wall clock, a
    wrapper left after a failed start, a flaky test). An implementer test accidentally made four refused
    session-init attempts to the console (in rest, nothing exchanged); it now runs pfxp only against 127.0.0.1.
    574 tests, 98% lines.
  - ✅ Heavy load (2026-11-24, the camera spun at full right-stick deflection in GTA VI, 1080p60 HEVC asking
    30 Mbit/s, the user's tip): libchiaki 21.6 Mbit/s, 58.8 fps, nothing lost; `pfxp` 21.9 (BSD) and 21.5 Mbit/s
    (Network.framework), about 2,170 packets/s, at least 56 fps, nothing lost, video clean in ffmpeg; half
    deflection 18.5 Mbit/s. With 5% loss in pairs the console's congestion control cut the bitrate to 10–12 Mbit/s
    (49–53 fps average, 26–31 unrepairable frames, FEC rebuilt 698–735); with 1% single drops 20.6 Mbit/s, 58 fps,
    4 unrepairable frames. `--trace-input` showed exactly the three intended states. After a lossy session the console
    answered "busy" for 6–9 s (vs under 6 s): the app must retry a busy console with a backoff.
  - ✅ StreamCore engine seam (2026-11-24, milestone 4's first step): `StreamSession` no longer calls the C shim.
    `Sources/StreamCore/StreamEngine.swift` (pure Swift) declares `StreamEngine` (controller state, login PIN,
    microphone on/off and 10 ms frames, keyboard text/done, key frame, go to bed, stats, `stop()` with its "no sink
    call after it returns" guarantee), `StreamEngineSink` (video access units → accepted or not, audio format and
    PCM, haptics PCM → played on a USB pad or left for the engine to turn into `.hapticRumble`, trigger effects,
    events), `StreamEngineConfig`/`StreamEngineStats` and the `StreamEngineFactory` StreamSession's internal
    initialiser takes; its doc comments are the whole contract (formats, units, threads, lifetimes, which ending
    is which `QuitKind`, when `.connected` comes). Every `psrp_session_*` call, the callbacks, the shim's event
    codes and its controller/stats structs moved to `ChiakiEngine.swift`; StreamSession keeps the decoder, audio,
    USB haptics, the pointer merge, microphone capture, stats and event buffering, and its public API is
    unchanged (the app and `psrp` build as before). Tests: the existing ones unchanged in meaning, plus
    StreamSession on `FakeStreamEngine` (a reusable test stand-in): the config it builds and the codec it asks
    for, an engine that can't start, events in order (buffered before a handler), video and the engine's stats in
    `stats`, haptics played on a stand-in USB pad or handed back, the pointer merged into what reaches the
    engine, every command, stop once with nothing crossing after it, release stopping the engine; libchiaki's
    engine stopping twice and ignoring commands after stop; the contract's numbers (key sizes, button bits, mic
    and haptics formats) checked against the shim. 428 tests (+15), 90.4% lines / 88.3% functions (88.8% / 86.9%
    with `STREAMCORE_SIMULATE_VM=1`). Not run against a console (no behaviour change intended). Fixed on the way:
    four PSNPairing tests timed out (5 s) in busy parallel runs, before this change too. Their stand-in session
    reported from `DispatchQueue.global()` while `run` blocked a cooperative thread, and the CPU-bound suites kept
    GCD's default-QoS workers busy (seen in a `sample`), so the reports waited past the timeout. It now reports
    from its own thread, as libchiaki does; 4 runs under 12 CPU burners didn't fail them (2 of 3 did before).
    BridgeTests' `discover()` fails while the user's PS5 rests on the LAN: it answers the broadcast and the
    unicast discovery to TEST-NET reports it (left as it is, same on main).
  - ✅ Internet play specified (2026-11-24, facts only, by a spec writer reading chiaki-ng read-only; nothing sent
    to PSN, STUN servers or the console): `docs/protocol/psn.md` (the PSN web APIs: console list, push WebSocket,
    remote-play session, OFFER/RESULT/ACCEPT/TERMINATE messages and candidates, errors, timeouts),
    `holepunch.md` (UPnP IGD, STUN, candidate lists with NAT port prediction, the 88-byte probes, the selected
    pair, the end-to-end sequence), `rudp.md` (the reliable UDP carrying registration, session init and ctrl over
    the punched path), PIN-less pairing through PSN (registration.md §8), and "Internet play" sections in
    session, ctrl, takion, stream and rpcrypt. Vectors computed by an independent script from the text and, for
    the byte layouts, confirmed by C harnesses over copies of the reference with every network call stubbed.
    Riskiest without a real internet test: RUDP reliability for ctrl, the probes across real NATs, PSN's error
    and notification behaviour.
  - Scope decided by the user (2026-11-24): this PR ends with third_party/ and chiaki-ng gone, PSN play rebuilt
    clean-room (not dropped), and PlayFX proprietary.
  - ✅ `PlayFXEngine` (2026-11-24, clean-room against StreamEngine.swift alone): StreamCore's second engine, on
    PlayFXProtocol. Video units with parameter sets in front of key frames (and after a refusal or a profile
    switch), game audio decoded with libopus (packet-loss concealment for lost frames, a reset after a long gap),
    the microphone encoded as av.md §8.2 says (CELT 10 ms, 40-byte packets), haptics to a USB pad or turned into
    rumble (its own curve: 255·√RMS, 64 levels, repeated every 50 ms), trigger effects, light bar, player index,
    login PIN, keyboard, go to bed, key-frame requests, stats, and the contract's stop guarantees. Chosen with
    `StreamSession.Options.engine = "playfx"` (default "chiaki"; internet play always libchiaki until PSN lands);
    `psrp stream --engine playfx`. `COpus` declares the few libopus calls it needs (linked through the static
    libopus already in the binary). PlayFXProtocol's fake console moved to a `PlayFXProtocolTestSupport` product
    so StreamCore's tests stream end to end over loopback. Reviewed against the contract and fixed: the sink kept
    alive past `stop()`, a deadlock when the app's handler calls back during `stop()` (StreamSession now stops the
    engine outside its lock), per-gate nesting, a nested stop's quit, microphone ordering. Not honoured: a PS5 may
    always lower the resolution (the spec has no "don't resize"). StreamCore 483 tests, 91% lines (89.5% in VM
    mode). Not yet run against a console.
  - ✅ Discovery, wake and PIN pairing in the app on PlayFXProtocol (2026-11-24): `Console.swift` no longer uses
    libchiaki; same public API, pairing failures now say which (wrong PIN, wrong account, busy, no answer).
    `BridgeTests.discover` no longer broadcasts on the LAN (loopback responder). `PLAYFX_ENGINE=playfx` picks the
    stream engine when the options don't (dev only, temporary). StreamCore 490 tests, 91% lines. Not yet on a
    console through the app.
  - ✅ PSN web client from the spec (2026-11-24, clean-room, `Sources/PlayFXProtocol/PSN`): the console list, the
    push WebSocket (URLSessionWebSocketTask, pings with a pong deadline), the remote-play session (create, inspect,
    PS5 start, PS4 wake, customData1), the OFFER/RESULT/ACCEPT/TERMINATE exchange per hole (with a background
    responder for the console's retransmitted OFFERs), and leaving the session even from a cancelled task. Byte-exact
    against psn.md's vectors; the token is redacted from descriptions and only sent over HTTPS; values from PSN are
    validated. Reviewed against the spec and fixed (a pong deadline that couldn't fire on a real socket, a leave that
    skipped the DELETE when cancelled, leaks, unbounded buffers). 113 tests against a fake PSN and a loopback
    WebSocket server; nothing reached Sony. Not yet against real PSN.
  - ✅ NAT traversal and reliable UDP from the spec (2026-11-24, clean-room, `Sources/PlayFXProtocol/Internet`): UPnP
    IGD (SSDP and SOAP, mapping and cleanup), STUN with NAT port prediction, the candidate lists and port guesses,
    the 88-byte hole-punch probes and selection (with up to 250 low-TTL extra sockets, stopping cleanly at the file
    limit), and RUDP (handshake, one HTTP exchange, ctrl with retransmission, the switch to the stream, the end).
    Byte-exact against holepunch.md's and rudp.md's vectors. Reviewed against the spec and fixed, mostly for a
    hostile LAN: malformed HTTP/XML/ports could trap, a rogue device could redirect the UPnP requests, responses
    were unbounded; also close() during an exchange, cancellation, an 8 KiB receive buffer. Deliberate deviations:
    signed port increments for a decreasing NAT, a per-exchange duplicate window for console ctrl data. 106 tests on
    loopback only (a fake console, gateway and lossy sockets). PlayFXProtocol 793 tests, 98% lines. Not yet over a
    real NAT.
  - ✅ Internet play integrated in PlayFXProtocol (2026-11-24, clean-room): `StreamSession.start(remote: PSNRemote…)`
    runs holepunch.md §8 end to end — UPnP and the push channel, the PSN session, the ctrl hole, a PIN-less PSN
    registration over RUDP (every session; its keys are used), session init and ctrl over RUDP (a `CtrlLink` seam,
    the LAN path unchanged), the data hole, the probe, the switch to the stream, Takion on the punched socket
    (allocation-free, asserted) — with progress stages, typed errors, and the PSN session left and UPnP mappings
    removed on every path (`stopAndWait()` waits for it). `Registration.registerThroughPSN` pairs without a PIN.
    Probes are checked against the console's and our identities (`.strict`, or `.logOnly` for the first hardware
    round). Reviewed against the spec and fixed (cancel during the switch wait, a stale descriptor after shutdown,
    slow cancel, home addresses in the system log, the console's sid width). End to end on loopback against a fake
    PSN and a fake console that punches, speaks RUDP and streams. PlayFXProtocol 843 tests, 98% lines. Not yet over
    the internet.
  - ✅ No ctrl counter is ever used twice (2026-11-24, from a security review): over the internet a PS5's first PIN
    reply takes the counter skipped after the request (ctrl.md §10); a second PIN reply, and a PS4's, take a fresh one,
    and a guard refuses any repeat (a reused keystream could reveal the PIN to an observer).
  - ✅ StreamCore's internet play, PSN console list and PIN-less pairing on PlayFXProtocol (2026-11-24, clean-room):
    `PlayFXEngine` starts internet sessions (progress linking → data → connected, start failures as final or busy,
    stop leaves PSN with an 8 s bound; `PLAYFX_PROBE_IDENTITY=logOnly` for the first round), `PSNAccount` lists the
    consoles with our PSN client (one token refresh on 401/403), `PSNPairing` pairs through `registerThroughPSN`.
    PSN sign-in already meets psn.md §2 (scopes, a fresh device ID per sign-in; now tested). The PSN and internet
    fakes moved to `PlayFXProtocolTestSupport`. StreamCore 519 tests, 91.4% lines (90.0% in VM mode). What still
    imports the C shim: `ChiakiEngine`, and constants in Log, ControllerInput, Microphone, LatencyTest.
  - ✅ StreamCore on PlayFXProtocol only (2026-11-24): `ChiakiEngine`, the C shim (`Sources/CChiaki`, its staged
    headers, `psrp.c`) and its tests, `scripts/build-chiaki.sh` and `vendor/` are gone. `StreamSession` always starts
    `PlayFXEngine` (the factory stays as the tests' seam); `Options.engine` and `PLAYFX_ENGINE` are gone, and an
    `engine` key in an older host's JSON is ignored (tested). The shim's constants are Swift's now with the same
    values (`ControllerButton`, `MicFramer.sampleRate`/`frameSamples`); `Log` no longer captures libchiaki's
    messages (its `chiaki` area and filters went with them). `COpus` compiles against libopus's own headers and
    links Homebrew's static `libopus.a` by its path (`OPUS_PREFIX`, else `/opt/homebrew/opt/opus` or
    `/usr/local/opt/opus`; never `-lopus`): `nm` shows libopus inside `psrp`, `otool -L` no libopus dylib. The
    desktop `build.rs` links the same archive (from `brew --prefix opus`) and nothing of libchiaki's. `psrp stream`
    lost `--engine` (`--psn` is our internet play). StreamCore 501 tests (the shim's and ChiakiEngine's went),
    91.5% lines / 89.8% functions; 90.1% with `STREAMCORE_SIMULATE_VM=1` (both skipping
    `opensAnOutputUnitOnARealDevice`, an environment failure on this Mac that predates this change). Not yet run against a console.
  - ✅ The app and CI without libchiaki (2026-11-24): `build.rs` links StreamCore, `libopus.a` from
    `brew --prefix opus` (by path) and system frameworks only (CoreServices and SystemConfiguration went: only
    curl used them); `cargo build` links, `otool -L` lists no Homebrew dylib, `nm` shows libopus inside. The UI's
    quit texts: libchiaki's reason strings are gone from `format.ts`; the engine's own messages (PlayFXProtocol's
    `userMessage`) are shown as they are (no "Disconnected:" prefix), except a PS5 that didn't answer, which adds
    "or play over the internet"; PSN is tried after the engine's "didn't answer" or "couldn't reach" texts (PS5
    and PS4), as it was after libchiaki's "Unknown Session Request Error". Comments in `native.rs`, `keyboard.ts`,
    `schema.ts` and the Settings text no longer name chiaki. CI: no submodule checkout, no libchiaki build or
    cache, `brew install opus` only; every gate kept. `release.sh` had no libchiaki step. TS 427 tests (97.9%
    lines), Rust 74 (91.4% lines), clippy clean. Not yet on a console.
  - ✅ chiaki-ng's submodule removed (2026-11-24): `git rm third_party/chiaki-ng`, `.gitmodules` deleted,
    `third_party/` gone (this worktree never checked it out; the main checkout's `.git/modules` copy was left
    alone). Every `chiaki`/`libchiaki`/`third_party`/`psrp_` hit outside `.m3` handled: code and config have
    none (only `PSRP_*` variables, psrp's own); README's "libchiaki: our fork" became "The protocol"
    (PlayFXProtocol's facts) and its layout lists `packages/playfxprotocol`; docs/NETWORK.md keeps the fork's
    fixes and measurements as "History: libchiaki (until 2026-11-24)" and drops its update steps; the protocol
    docs' provenance names commit d8efd673bc93bbc16e9f646c5b24e0dee013abcc; CLAUDE.md describes PlayFXProtocol
    and the libopus build note. Left for the licence change: LICENSE, NOTICE, THIRD_PARTY_LICENSES and its
    script (which still read chiaki-ng's tree), README's licence section.
  - ✅ PlayFX proprietary (2026-11-24): see "Licence: proprietary" below.
  - ✅ libopus built from source (2026-11-24): Homebrew's `libopus.a` was built for macOS 26 (a linker warning per
    object against our 13.0 target) and made Homebrew a build dependency. Now `Sources/CLibopus` vendors the
    official 1.6.1 release, unmodified: the tarball from downloads.xiph.org, checked against Xiph's SHA256SUMS.txt
    (6ffcb593…a411a1; tag v1.6.1, commit 22244de5a79b; both in its `README.PlayFX`), only the float build's sources
    from upstream's own lists (celt_sources.mk, silk_sources.mk with SILK_SOURCES_FLOAT, opus_sources.mk with
    OPUS_SOURCES_FLOAT: 137 files) and the 59 headers they include (found with `clang -MM` on both architectures),
    plus COPYING (BSD-3-Clause and the pointers to Opus's royalty-free patent licences). No config.h: the defines
    are CMake's defaults (`OPUS_BUILD`, `VAR_ARRAYS`, `HAVE_LRINT`, `HAVE_LRINTF`, `ENABLE_HARDENING`; no
    `FLOAT_APPROX`) plus `PACKAGE_VERSION` "1.6.1" (as autotools and Meson set it), `-w`. The NEON intrinsics files
    were left out: they include `<arm_neon.h>` unconditionally, so they can't build for x86_64, and SwiftPM can't
    set defines per architecture; both architectures run upstream's generic C path (the SSE files likewise). `COpus`
    depends on `CLibopus`; `OPUS_PREFIX` and the Homebrew lookups are gone from Package.swift, `build.rs`, CI
    (`brew install opus`), CLAUDE.md, the READMEs and `scripts/third-party-licenses.py` (which now reads the
    vendored COPYING and README.PlayFX; `THIRD_PARTY_LICENSES` regenerated, only the Opus entry changed). Verified:
    `swift build` and `swift build --arch x86_64` build and link `psrp` (the objects say minos 13.0, Homebrew's
    26.0); `otool -L` on `psrp` and the debug `psrp-desktop` shows no libopus or Homebrew dylib, `nm` shows the
    `opus_*` symbols inside, `strings` "libopus 1.6.1"; no "built for newer macOS" warnings in the Swift or cargo
    builds. StreamCore 501 tests (the engine's audio and microphone tests on the vendored libopus included),
    91.5% lines / 89.8% functions, 90.1% / 88.6% with `STREAMCORE_SIMULATE_VM=1` (both skipping
    `opensAnOutputUnitOnARealDevice`); Rust 74 tests, 91.4% lines, clippy clean; TS 424, 97.9% lines. The C
    is compiled without optimisation in debug builds (release builds optimise it); not yet heard on a console.
  - ✅ Provenance and risk record (2026-11-24, `docs/PROVENANCE.md`): how the protocol code was written (roles, what
    each read, the clean-room rules, verification, the one known slip), the limits of the clean room (AI training
    data above all), and the remaining risks with Sony's crypto constants as the largest. Not legal advice; the owner
    chose not to involve a lawyer. The scratch copies of chiaki-ng sources and the test programs built from them
    (outside the repository) were deleted.
  - ✅ Licence rule settled (2026-11-24, the owner): MPL-2.0 is allowed only as an unmodified dependency (the five
    crates Tauri brings in: cssparser, cssparser-macros, dtoa-short, selectors, option-ext); GPL/LGPL/AGPL and
    source-available licences stay out (CLAUDE.md).
  - 🔶 First CI run without libchiaki (PR #7, 2026-11-24): failed to compile one test helper (`$0` inside a `defer` in a
    closure, accepted by the local Swift, rejected by the runner's); fixed. The next run's test process died with
    SIGBUS in the loopback transport benchmark, which installs a libmalloc `malloc_logger` hook to count
    allocations; the hook is now opt-in (`pfxp bench-transport` only), so tests and the library never write it.
  - ✅ First session in the real app without libchiaki (2026-11-24, the user's PS5 on the LAN, the user: "works
    perfect"): PSN token refresh and console list on our PSN client, wake from rest (ready in 9 s), a 1080p60 HEVC
    stream at 20 Mbit/s connected in about 2 s (2,527 frames, 0 lost, 0 decode errors, RTT 1.25 ms), DualSense
    haptics over Bluetooth, the GTA VI profile, a clean quit. Left: haptics on USB, mic, PIN, pairing from the app,
    go to bed from the app; internet play; PS4.
  - ✅ "Lower resolution when the network is slow" only where it acts (2026-11-24, requested): it only ever affected a
    PS4 (a PS5 always may resize, with libchiaki too: the launch spec has no "don't resize"), so Settings → Stream
    shows it only when a PS4 is paired, or while streaming a PS4, labelled "PS4 only". TS 427 tests.
  - ✅ The microphone heard on the PS5 (2026-11-24, the user, Settings → Sound → Microphone → Adjust Microphone
    Level): the spec had the ctrl `0x0036` state byte backwards (`00` = unmuted, `01` = muted; the reference's
    argument is named "muted"), so turning the mic on connected it and then muted it, and the console wouldn't let
    the user unmute. Corrected in ctrl.md/stream.md (with what the reference sends at start-up, on, mute and unmute,
    and new vectors) and in `ControlSession.setMicrophone`; tests now check the byte, not only the message type.
    It had never been confirmed on a console before, with libchiaki either.
  - 🔶 First internet round (2026-11-24, Mac on an iPhone hotspot, PS5 at home): PSN sign-in, the console list, the
    PSN session, STUN, the start command and the console joining all worked on our code, three times; the ctrl hole
    failed each time after the probing window. The old libchiaki `psrp stream --psn` from the same hotspot failed at
    the same step (250 extra probe sockets, no answer from any candidate): the carrier's NAT blocks it. Added for the
    next run: a full hole-punch diagnosis in the log (each STUN answer, the NAT prediction, both sides' candidates
    with masked addresses, probes sent and received by source, the exact failure), a check that our prediction
    matches holepunch.md §3.3 (20,000 random cases agree), and `PLAYFX_FORCE_PORT_GUESSING=1` (dev). Second round,
    same hotspot: with forced port guessing the ctrl hole opened reproducibly (the console answered one of the 250 extra
    sockets in 1.6 s), the PIN-less PSN registration and session init worked, and ctrl ended after ~11 s. Likely cause
    (fixed per holepunch.md §8): we waited for the session ID before starting the data hole; the spec starts it after at
    most 10 s and waits 5 s more for the ID. Added `PLAYFX_RUDP_TRACE=1` (every RUDP datagram and decoded ctrl frame,
    no secrets) and always-on logs of the ctrl-stage events and the exact failure case. Left: the next hotspot run;
    detecting a per-destination NAT (different STUN ports, increment 0) so port guessing starts without the switch.
  - ✅ **First internet stream on our own code** (2026-11-24, Mac on an iPhone hotspot with no VPN, PS5 at home, from a
    network where libchiaki couldn't connect): with `PLAYFX_FORCE_PORT_GUESSING=1`, ctrl hole in 0.1 s, PIN-less
    registration, session init, ctrl over RUDP (no retransmissions, nothing malformed), the session ID 6.2 s after ctrl
    came up (after the data hole had started: the earlier failures were the deadlock now fixed), data hole in 0.6 s,
    switch acknowledged, stream connected: 1080p30 HEVC, 0 frames lost, RTT 45 ms; the user played ~3.5 min and found the
    mobile latency too high to enjoy. Then: a per-destination NAT (STUN ports that differ, no step) now starts port
    guessing by itself for both holes (a client choice beyond holepunch.md §3.3, in DESIGN.md); the doubled heartbeat
    reply is gone (the unrequested reply is timed from the last reply); retransmissions are labelled in the trace (66
    in that session, cause not yet known); messages the frame check drops are always logged with their data (the
    console sent a 4-byte `0x20` and a 20-byte `0x36` the spec can't place: spec requests). Left: a confirmation run
    without the dev switch from a non-home network.
  - ✅ App round on our engine finished (2026-11-24, the user): PIN pairing, PIN-less pairing through PSN, go to bed,
    streaming, wake, USB haptics, mic all work in the app; the console keyboard stays off on a PS5, as it was with
    libchiaki (the user: fine); no login passcode to test. PIN-less pairing took ~45 s: STUN asked its servers one at
    a time (dead ones cost 5 s each, ~21 s) before the start command, and the console then took ~15 s to boot from
    rest. Now (client choices, in DESIGN.md): STUN asks all servers at once, staggered 0.1 s, answers kept in the spec's
    server order (at most ~6 s); the start command goes out as soon as the PSN session exists, so the console boots
    while candidates are gathered (the OFFER order on the wire is unchanged). Expected: ~15 s from rest, 1-6 s awake.
    PlayFXProtocol 895 tests, StreamCore 525.
  - ❌ Next: the parity round in the app on the console (LAN and internet play on `PlayFXEngine`, then a
    release), and the provenance and risk page owed at the end of this PR.

- ✅ **Licence: proprietary (2026-11-24).** With libchiaki gone, PlayFX is proprietary: `LICENSE` reads
  "Copyright (C) 2026 Daniel B. All rights reserved." (worded like `packages/playfxprotocol/LICENSE`, which no
  longer says the rest of the repo is AGPL), with the unaffiliated-with-Sony and trademark note that `NOTICE`
  carried; `NOTICE` is deleted (nothing in it was still required: the licences' own notices are in
  `THIRD_PARTY_LICENSES`) and no longer bundled (`tauri.conf.json` copies `LICENSE` and `THIRD_PARTY_LICENSES`
  into Resources; its copyright line is "© 2026 Daniel B. All rights reserved."). Manifests: `"UNLICENSED"` in
  the four package.json files, `license = "LicenseRef-Proprietary"` in Cargo.toml (no cargo warning).
  Settings → Diagnostics → **Source code** is gone (the button, `open_source_code` and its permission, the
  `Core`/action, their tests); its paragraph now says "PlayFX © 2026 Daniel B. All rights reserved." and where
  the third-party licences are. The site drops "Free and open source", its AGPL footer and its "Source" link.
  `scripts/third-party-licenses.py` no longer reads chiaki-ng's tree or `vendor/`: the C libraries are
  libsecp256k1 0.8.0 (MIT, vendored in PlayFXProtocol, from its COPYING and README.PlayFX) and Opus 1.6.1
  (BSD-3-Clause, the Homebrew keg the build links, from its COPYING); `THIRD_PARTY_LICENSES` regenerated
  (262 Rust crates, the Rust standard library's 12, 58 npm packages with the two OFL fonts, CAS and shadcn/ui;
  libchiaki, curl, nanopb, Jerasure, GF-Complete, Mesa's vl_rbsp.h, OpenSSL, json-c, miniupnpc and libevent
  gone). CLAUDE.md allows only permissive licences (no GPL/LGPL/AGPL/MPL, no source-available). README's
  licence section says the same. Left for the user: five MPL-2.0 Rust crates come with Tauri itself
  (cssparser, cssparser-macros, dtoa-short and selectors through tauri-utils' dom_query; option-ext through
  dirs), unmodified, file-level copyleft whose sources the list links; and the old AGPL releases and history
  stay what they were. Not legal advice; a lawyer's review is still planned before an App Store submission.
  - History (2026-11-20 to 2026-11-24): PlayFX was AGPL-3.0-only because it linked libchiaki; `LICENSE`,
    `NOTICE` and the Source code button were its compliance, and the first public release shipped
    `THIRD_PARTY_LICENSES`. No shadcn/studio code was ever taken (MIT with a Commons Clause).
- ✅ **Project site on GitHub Pages** (2026-11-23, asked for: one screen, looking like the app, responsive):
  `apps/site` (Vite, Tailwind v4 with the app's fonts and dark tokens, plain JS, no framework) at
  https://deblanco.github.io/PlayFX/. The backdrop is StreamCore's ribbon shader in WebGL (still for reduced
  motion, paused in a hidden tab, the page's deep blue without WebGL); the Download button goes to the latest
  release's DMG once GitHub's API names it. Checked in Chrome at 1440×900, 1280×720 and a 390×844 phone (one screen
  on desktop, scrolling on the phone). `.github/workflows/pages.yml` builds and deploys it on a push to main that
  touches it (Pages set to deploy from Actions); it holds no keys. An in-game comparison (asked for the same day):
  the 720p before/after from `docs/images/ml-upscaling.jpg` as the app's Split view — a line to drag (or arrow
  keys on it), "Original"/"Enhanced" labels, and the Picture tab's View control (Original · Split · Enhanced)
  moving it. The two halves of that image weren't framed alike (the enhanced one 2% wider, shifted 10×22 px), so
  the original is resampled onto the enhanced one's frame (edge correlation 0.85) and both cropped to what they
  share; the enhanced side is untouched. Two columns from 1280 px wide; one screen down to 1024×768.
- 🔶 **In-app updates through GitHub Releases** (built 2026-11-21; **not yet verified end to end**, which needs a
  release after the first one that has the updater). Tauri's updater plugin (`tauri-plugin-updater` 2.14, Rust
  only: the webview gets none of its commands) reads
  `https://github.com/deblanco/PlayFX/releases/latest/download/latest.json` and accepts only an update signed with
  the updater key (its public half in `tauri.conf.json`, `requireSignedVersion` on, so a manifest can't pass an
  older signed build off as a newer version). The app's commands (`update_check`, `update_install`,
  `update_restart`, `open_release_page`; `src-tauri/src/updates.rs`) have the plugin behind a small `Updates`
  trait. The UI (`src/app/Updates.tsx`, the `Updater` service in `src/core/updater.ts`) checks 5 s after launch
  and every 6 hours (release builds only; by hand in every build: Settings › Diagnostics › **Check for
  updates**, with "PlayFX is up to date (0.2.4)", the version found or the error). A newer release shows a
  banner on Home (never over the stream): **Update** shows "Downloading… 42%", installs, then "Restarting…"
  (`AppHandle::request_restart`, so the exit steps, quiet pads included, run first); **Later** remembers that
  version (`psrp.dismissedUpdate`, Schema-decoded) and a newer one shows again; **What's new** opens the release
  page; a failure says why and offers **Download from GitHub**. Nothing installs or restarts while a stream runs
  or starts: the UI tells the native side it's playing from Play until it's back home (`update_set_playing`),
  which covers the stretches without a StreamCore session (a PSN token refresh before the start, a retry, a
  reconnect), and the native side also checks StreamCore's session; checked before the download, again before
  installing and before restarting, and the Update button is off with "Finish playing to update". A refusal
  during a stream is no failure: before the install the banner goes back to Update; after it ("PlayFX 0.2.5 is
  installed: restart to use it.") **Restart** waits for the stream to end. The install uses the release its
  download was of, whatever a check meanwhile found. Log lines for the check, the download, the install and failures.
  `PLAYFX_UPDATE_ENDPOINT` (any build; https, or http on this Mac only) points the check at a local server; the
  signature check still applies. `release.sh` packs the notarized, stapled app as
  `PlayFX_<version>_aarch64.app.tar.gz` (the app at its root, no AppleDouble files or extended attributes), signs
  it with `tauri signer sign --app-version` from the keychain items `playfx-updater-key` /
  `playfx-updater-key-password` (setup step 3; never printed, handed to the signer alone; stored with
  `security -i` fed by the shell's printf, since `security`'s `-w` prompt keeps only 128 of the key's ~350
  characters; tried at the start by signing a scratch update, so a wrong password or a cut-off or other key
  stops the release before the tests, the build and the notarization), refuses a signature by
  any other key than `tauri.conf.json`'s, writes `latest.json` next to the DMG and prints the `gh release create`
  for the three assets. Verified by: Rust unit tests with a fake updater (check → up to date / available / error,
  the automatic check off in debug builds, the endpoint override, install refused during a stream, while the UI
  plays between sessions or when Play comes mid-download, progress sent once per percent, restart, release pages
  for versions only) and the real
  plugin against a 127.0.0.1 server serving a `latest.json` and an update signed with a throwaway key (found,
  downloaded and verified, and still the one installed after a later check finds another; a tampered update and
  one relabelled as another version rejected; up to date; the shipped configuration accepted); TS tests (the
  service's decoding and errors, a refusal during a stream told from a failure, the schedule on `TestClock`,
  every banner state, Play during the download then Restart after it, Later and a newer version, Diagnostics'
  lines); `scripts/test-release.sh` (56 checks now) makes the update with a throwaway key (layout, no extended attributes,
  signature bound to the version, `latest.json`'s fields, another key or an unbound signature refused) and, with a
  fake `security`, reads the key (missing key or password refused with the setup steps) and tries it (a wrong
  password, a key cut to 128 characters and another key refused); a release-profile build accepts the plugin
  configuration.
  `THIRD_PARTY_LICENSES` regenerated (262 Rust crates now: the plugin, reqwest, rustls, ring…). Left: release
  0.2.4 with the updater, then publish 0.2.5 and update a 0.2.4 copy in place from the banner (in
  `/Applications`, and once in `~/Applications`), see it restart into 0.2.5, and check Later and the error path
  with the network off. Versions up to 0.2.3 have no updater: their users install 0.2.4 by hand once.
- ✅ **Sony ToS note.** README: unofficial client, own consoles and account, PSN sign-in only through
  Sony's page, no credentials shipped. NOTICE and the app's About text: not affiliated with Sony.
- ✅ **First public release** (2026-11-20): the repo is public and
  [v0.1.0](https://github.com/deblanco/PlayFX/releases/tag/v0.1.0) has the notarized, stapled DMG (built from the
  tagged commit). Before going public the history was audited and rewritten (a real PSN account ID in a test
  fixture, and the owner's full name, removed from every commit), and the GitHub repo was re-created with the
  clean history. **Releases are made on demand**: `scripts/release.sh` on the owner's Mac (the signing
  certificate and the notary profile stay in its keychain, never in CI), then a GitHub release from the DMG;
  bump the version in `tauri.conf.json`, `package.json` and `Cargo.toml` first.
  [v0.2.0](https://github.com/deblanco/PlayFX/releases/tag/v0.2.0) (2026-11-20) followed the same way: the
  v0.1.0 crash fix, pairing without a code, the pairing help, profiles in game, the Help page and ML upscaling
  for every stream; all suites passed on the tagged commit (TS 357, Swift 310 in both modes, Rust 55).
  [v0.2.1](https://github.com/deblanco/PlayFX/releases/tag/v0.2.1) (2026-11-20): Cancel in a PSN pairing ends at
  once and a PS5 that never answers gets its own message, the Wi-Fi stall warning from the stream itself, a
  profile switch during a reconnect asks first, 50 fps pacing, and the first release built by the new
  `release.sh` (the app inside the DMG stapled too); all suites passed (TS 365, Swift 331 in both modes, Rust 55,
  chiaki-ng 129).
  [v0.2.2](https://github.com/deblanco/PlayFX/releases/tag/v0.2.2) (2026-11-20): the crash after 10–40 minutes with
  frame interpolation or ML upscaling on (VideoToolbox's Metal call leaked a shared event per frame); every suite
  passed and 20,000 calls per path leaked nothing on the owner's Mac.
  [v0.2.3](https://github.com/deblanco/PlayFX/releases/tag/v0.2.3) (2026-11-20): frame generation on HDR streams
  (MetalFX, one image per pair; tested offscreen only) and ML upscaling no longer runs on a repeated picture;
  every suite passed (TS 365, Swift 402 in both modes, Rust 55).
  [v0.2.4](https://github.com/deblanco/PlayFX/releases/tag/v0.2.4) (2026-11-21): in-app updates through GitHub
  Releases (the first release that carries the signed update and `latest.json`), the measured reorder wait and
  256-slot video queue, the Touchpad touches switch, the built-in GTA VI profile and new Recommended defaults,
  Steady Wi-Fi suggested at Play, the Misc tab and why HDR gets no frame generation; every suite passed (TS 425,
  Swift 413 in both modes, Rust 74, chiaki-ng 150).
- 🔶 **Packaging** *(built and launched; Developer ID certificate in the keychain; notarization profile `playfx` in the keychain: an App Store Connect API key, Developer access)*: bundle ID
  `dev.deblanco.playfx`, macOS 13+, hardened runtime with only the microphone entitlement,
  `NSLocalNetworkUsageDescription` (a shipped app gets its own local-network prompt, unlike dev runs from
  Terminal), `.app` + `.dmg` (7.3 MB). The binary links only system libraries (`/usr/lib/swift` is part of
  macOS 13+). `scripts/release.sh` first runs every package's tests and coverage gates (stops below 80%), then signs with the "Developer ID Application: BLANK HEXADECIMAL SL (K579SJ8947)" identity (in the login keychain),
  notarizes the `.app` (zipped with `ditto`) with the `playfx` notarytool keychain profile and staples it, puts
  the stapled app into tauri's DMG in place of the unstapled one (same name, window and icon layout), then
  signs, notarizes, staples and checks the DMG with Gatekeeper. Each submission is waited on by its id, with
  retries (see Notarization in section 3); `scripts/test-release.sh` tests the wait and the DMG app swap.
- ✅ **CI**: `.github/workflows/ci.yml` on every push and PR, macOS runner (a VM): PlayFXProtocol tests +
  coverage, no Homebrew dependencies (until 2026-11-24: `brew install opus`, and before that libchiaki built once
  per submodule commit + script, cached),
  Swift tests one at a time + coverage,
  tsc/ESLint/vitest + coverage, clippy `-D warnings`, Rust tests + `cargo llvm-cov --lib` (≥ 80% lines and
  functions). Getting it green found real bugs: `protobuf` missing from the documented dependencies; the
  dev seed import broke every clean checkout; in a VM, VideoToolbox reports frame interpolation and ML
  super-resolution as supported, then crashes or never runs (both now off in VMs). Rust coverage was
  first measured here (72% lines): the app's entry point moved to `main.rs` (a thin adapter), every
  command is now exercised through IPC with the UI's argument names and with missing arguments, and the
  safe StreamCore calls are smoke-tested for real.
- ✅ **Reproducibility**: no Homebrew dependencies: libopus is vendored in StreamCore (`Sources/CLibopus`, with
  the release tarball's checksum) and compiled with the package (2026-11-24); libchiaki, `build-chiaki.sh` and
  `vendor/` are gone (2026-11-24).

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
  - The version and build (2026-11-20, requested): the Diagnostics panel opens with "PlayFX 0.1.0 (e038cd8) on
    macOS 27.2", the log's first line at each start says the same, and so does a copied report. The commit is
    embedded at build time (`build.rs`, `PLAYFX_COMMIT`; "+changes" when built from a tree that differs from it).
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
- ✅ Covered by tests now (2026-11-20): the reconnect race fix (App: a network change on top of a drop starts a
  second reconnect, which keeps its new session, stops nothing, and leaves only its own attempt listening: the
  first is interrupted, not left waiting) and the audio output following the system default (the decisions
  moved from `AudioPlayer` into `OutputRoute`; macOS's default-output notices and the switch of the output unit
  go through an injected `OutputDevices`, so a playing player is checked to move to the new default, and to
  stay once stopped, without switching a real output). Each test was checked to fail with its fix reverted
  (and the reconnect one with the interrupt dropped, the player one with the switch dropped).

- ✅ **Long sessions crashed** (v0.1.0 after 39 minutes; v0.2.1 after 10, with interpolation and ML upscaling,
  which v0.2.0 turned on by default): VideoToolbox's Metal call `process(with: commandBuffer, …)` makes a Metal
  shared event per call and never frees it (not on `endSession`, not when the processor goes; only when the
  process exits). Shared events are limited for the whole system (about 52,000 for a fresh process on this
  Mac), and once they ran out, VideoToolbox raised "insertObject:atIndex: object cannot be nil" with its own
  lock held. v0.1.0 didn't catch it; v0.2.1 caught it and then called `endSession` on the same processor,
  which took the held lock again, and libplatform killed the app. Fixed (2026-11-20):
  - Interpolation and ML upscaling call VideoToolbox's synchronous `processWithParameters:error:` (through
    `playfx_vt_process`: Swift doesn't see it, and its `process(parameters:)` without `await` returns before
    the work is done) on their lanes' queues. The lanes' Metal work is split around it: scaling down (or
    cutting tiles) is committed and finished first, the blend (or the join) goes in a second command buffer.
  - Every call into a processor (start, process, end) is caught for Objective-C exceptions as well as Swift
    errors (`GuardedProcessor`). One that raised an exception is never called again, not even ended, and is
    kept for the rest of the run; a fresh one starts with the next pair or frame. An error restarts the
    processor; whether it counts is decided per configuration (size with steps or factor) for the run, not
    per processor (`ProcessorSizes`): where one worked before, any error counts, a fresh processor's first
    call or start included (a fault over a few calls, such as a GPU reset on wake, isn't taken for a
    refusal); where none ever has, two fresh processors in a row erring at once make it a size VideoToolbox
    refuses (960×540 returns -19740 from the synchronous call, where the Metal call wrote an empty image), not
    asked for again and not counted. Three failures in a minute, or ten in a run, turn that feature off until
    the app restarts (`VideoProcessorHealth`), which retires every session it still has (both step counts at
    every prepared size, every ML tile: the renderer stops calling the lanes once it's off), and the stats
    say "interpolation off: video processor failed" or "ML off (video processor failed)" (`failed` in
    `pacing.interpolation` / `pacing.ml`). Retired processors are ended a second later, off the lane's queue,
    once no call is running (one still starting, once it has). A frame stuck in ML for 15 s no longer holds
    the picture; the stats say "ML idle (waiting on the model)" (`ml: "stalled"`) meanwhile, not `failed`,
    since a slow first model build can take that long.
  - Verified on this Mac (no console), with a hook counting the `MTLSharedEvent`s the process makes and keeps
    (the system-wide count wasn't run down: the release was streaming at the same time): before, +1 per
    interpolated pair, +1 per 720p ML frame, +2 per 1080p one; after, 0 over 20,000 calls of each (lanes
    driven on synthetic NV12 frames). Cost per call, before and after run turn about: interpolation 5.2 → 5.5
    ms a pair with scaling (1080p frames at 720p), 12.8–13.1 → 12.8–13.0 ms at quarters; ML 2.56 → 2.51 ms at
    720p, 8.1 → 8.3 ms at 1080p. 200 start/process/retire cycles of both features ended every processor, no
    crash. The crash in `endSession` right after a call (`FigSimpleMutexLock`) came from the un-awaited
    asynchronous call, reproduced; 200 cycles of the synchronous call with `endSession` at once didn't crash.
    MetalFX's spatial scaler and frame interpolator make no shared events. Unit tests with stand-in processors
    cover the exception → quarantine → fresh processor path, errors, the budget turning a feature off and the
    stats saying so, retirement waiting for a call still running, and nothing called on a quarantined
    processor at teardown. See docs/FRAME_INTERPOLATION.md, "Which VideoToolbox call".
  - After review (2026-11-20), each with a test that failed first: a fault over two processors (the one
    that worked errs, then the fresh one's first call) was taken as a refusal, so ML stayed off at that size
    for the run as "not for this stream size" and interpolation dropped the size; now counted and restarted
    (interpolation and ML, for errors and for starts). Turning a feature off left its other sessions started
    until the app quit; now all are ended without another call (stand-ins: halves, quarters and two ML tiles
    all ended). A session retired while still starting is ended once it has. `ml` reads `stalled` rather than
    `failed` while a frame is stuck. `SharedEventTests` (real VideoToolbox, skipped in a VM) hooks
    `_MTLSharedEvent`'s allocation: 10 Metal calls show +10, then 200 interpolated pairs and 200 ML frames
    through the app's code must make fewer than 20; it fails with `VTProcessor` switched back to the Metal
    call. The harness re-run on this build (in-process hook, not the system-wide count: the release was
    running): 20,000 interpolated pairs (1080p frames at 720p), 20,000 ML frames at 720p and 20,000 at 1080p,
    all made, 0 shared events created or left; 200 start/process/retire cycles all ended; real sessions
    (halves and quarters at two sizes, ML's two 1080p tiles) all ended when both budgets were tripped with no
    further call.
  - Left: a long session (an hour or more) on the console with both on, on a build with the fix.

## 3. Known issues / tech debt

- ℹ️ **Swift tests**: run them with `packages/streamcore/scripts/test.sh` or `coverage.sh`, which pass
  swift-testing's framework path (a bare `swift test` under the Command Line Tools runs none). Full
  Xcode is installed on this Mac now.
- ✅ **Rust coverage tooling**: `bun run coverage:rust` runs `src-tauri/scripts/coverage.sh` (tests and
  `main.rs` excluded), locally, in CI and in `release.sh`. Branch coverage needs nightly, so Rust gates
  lines and functions only.
- 🔶 `renderer_status` returns `stream: null` when stats JSON can't be parsed, which surfaces as a
  `CoreError`. Decide whether to soften this.
- 🔶 **Notarization**: the first release DMG (0.1.0) was accepted by Apple on 2026-11-19, stapled, and passes
  Gatekeeper (DMG and app: "Notarized Developer ID"). `release.sh` stopped before stapling then because one of
  `notarytool`'s status polls timed out after hours "In Progress". Fixed (2026-11-20, for v0.2.1): it submits
  with `--no-wait`, then waits on the submission id (`notarytool wait`, 1 h each, up to 6 times; the verdict
  read with `notarytool info`), so a timed-out or failed poll is retried, never resubmitted; Invalid or
  Rejected stops the release with `notarytool log` for the id, and running out of waits prints the id and how
  to check it. The app inside the DMG had no ticket of its own (Gatekeeper checked it online on first launch):
  the `.app` is now notarized and stapled first, then swapped into tauri's DMG (`hdiutil`: converted
  read-write, app replaced, back to the same compressed format and name, so the window, icon positions,
  Applications link and volume icon stay tauri's), and the DMG is notarized and stapled after.
  Verified without Apple or signing: `bash -n` on both scripts (shellcheck isn't installed);
  `scripts/test-release.sh` (20 checks) runs the wait against a fake `xcrun notarytool` on PATH (two timed-out
  waits then Accepted: one submit, three waits on the id; Invalid and Rejected: fails with the log; never
  finished: gives up after the allowed waits without resubmitting), under the release's own `set -euo
  pipefail`, and swaps an app into a small DMG made with `hdiutil`; dropping the Invalid case, adding a second
  submit or dropping the `|| true` that keeps a timed-out wait from ending the release makes it fail. The swap was also run on a copy
  of the 0.2.0 DMG and app: layout kept and the app's signature still verifies. Left: the first real run, at
  the next release (`xcrun stapler validate` on the app inside the DMG).
- 🔶 **FFI safety**: the Rust↔Swift boundary (CString lifetimes, `sc_free` once, main-thread
  rules) was reviewed and tested, but every new `@_cdecl` needs the same care.
- ℹ️ **Dev E2E harness** (`src/app/devSeed.ts` + autoplay) is env-gated and inert in production;
  the seed file holding keys is gitignored. Keep it dev-only.
- ℹ️ The `psrp` CLI is a debugging tool, not a shipped artifact.

---

### From PushFPS and Veyra (2026-11-20: built overnight, then a hardware round on the PS5 the same day)

Ideas from PushFPS (frame generation for console capture) and Veyra's Remote Play pull requests, plus two
requests and a bug report.

- 🔶 **ML skips a repeated picture** (issue #2, 2026-11-20): a 30 fps game in a 60 fps stream upscaled every
  frame, then interpolation threw the repeat away. The GPU time stayed ~14 ms (the model is not in the draw)
  while the shown rate fell toward 60 and interpolation misses climbed. The repeat is now told before the
  model, against the last frame submitted, so one still in the model counts. Interpolation on leaves it out;
  interpolation off shows the last upscaled frame again. A gap the clock starts over for still upscales the
  next picture. A repeat never takes the place of a new picture waiting for the model (it's dropped
  instead, uncounted); a repeat the clock starts over at is the new start, not left out; and after a stretch
  without ML (off, a window no larger, HDR, a stall) the next frame is told against the frame shown, not the
  last one upscaled. Verified with a stand-in upscaler, no console: six identical frames call it once; a repeat
  that arrives during the upscale is not upscaled; with interpolation off the shown frame stays the upscaled
  size; a new picture is upscaled; the same picture after a 0.5 s gap is upscaled again; a repeat behind a
  waiting picture is dropped and the picture kept; a repeat 100 frames on while the model runs restarts the
  clock and shows upscaled; a picture after ML was off is upscaled. Repeats now reach the clock before the
  model's time and new pictures after it: the delay planner's 90th percentile of lateness should cover that,
  for the pacing trace on the console to confirm. On this Mac the
  low-latency model is spatial (a second pass, and a frame run after a different one, match a fresh run,
  mean luma difference 0). macOS 27's `maximumDimension` / `maximumPixelCount` confirm the 1280 px and
  1,638,400 px caps at 1.5×; 1920×1080 lists no scale factor. MetalFX stays the spatial scaler, perceptual
  for SDR and HDR for float output. Help (`docs/HELP.md`, GTA VI) names the two setups: 1080p60 with ML
  and frame interpolation to play, 1080p30 with ML and interpolation off for the sharpest picture. Left:
  the live 1080p stream on the 120 Hz screen. Moving areas of in-between images are still bilinear from
  the decoded frame, so foliage there can look softer than MetalFX alone.
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
  screen): `Bilinear (no upscale needed)`, `ML idle (not for this stream size)`, `+30 generated (2/s missed)`,
  `no interpolation: 60 fps on a 60 Hz screen`, `30 fps game · 60 fps stream · 60 shown`; the Picture
  tab's Upscale card says "not needed". Seen live on the PS5: game 30 · stream 60 · ~100 shown on 120 Hz.
- ✅ **Missed and skipped as rates, not totals** (2026-11-20, requested: "this can go infinite in a long
  session"): the stats line shows `+45 generated (3/s missed) · 0 lost frames · 2/s skipped`, per second over
  the last 5 s (from the native totals' deltas between polls; starting over on a new stream, or when a total
  goes down), amber from 3 missed or 1 skipped a second, whatever the totals. "Missed" now counts only pairs
  that got no in-between images (the lane was busy, or the size gave nothing: `missedInterpolations`), not
  in-between images the screen skipped because it had fewer refreshes than images (quarters for a 75 Hz
  screen, the playhead passing several): those stay apart as `skippedGenerated` (dev control, `psrp play`).
  Unit-tested in Swift, Rust (fake JSON), the schema, the rates and the poll. Left: see the rates on the
  75 Hz screen with quarters, where the old count grew without anything being wrong.
- ✅ **Light bar colour and player number** from the console (`PadLight`); `psrp pad` has `/light` and
  `/player`. Unit-tested, and verified in a game from the 0.1.0 release's own log (2026-11-20, GTA VI over the
  internet, 14:56–15:11): libchiaki logged the console setting the light bar to red and blue flashes, fading
  reds, then pink (`ff74a6`), the colours `PadLight` puts on the pad. The player number in a game is left.
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
  Smoother and less lag in play. A 50 fps game in the 60 fps stream keeps its even grid (v0.2.1): a picture
  up to 13.3 ms ahead of the grid, as the stream's grid puts it, started the grid over and showed 6.7 ms
  after the last instead of 20; it now starts over only beyond one stream frame (and 0.6 of the game's
  interval). Verified in unit tests (`GameRateTests`: 50 fps with a fixed and with the measured rate, which
  failed before; a picture more than a stream frame ahead (a jump) and a pause still start over; a game going
  from 40 to 60 fps, with the measured rate behind it, keeps two pictures on the old grid, each at most a
  stream frame late, then starts over; 30/40/45 fps keep their grids); not yet seen in a 50 fps game. Left:
  the grid never moves earlier, so after that change it can stay a little behind the pictures (6 ms; 2 ms
  with the old rule) until the next break.
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
- **PushFPS, second page of commits** (reviewed 2026-11-20, 35 commits): little applies. ✅ Done: a
  worst-frame and worst-tile (16×9) quality score in `psrp interpolate --truth`, which catches a fast object
  vanishing from a generated frame that the mean hides. `FrameQuality` (StreamCore) scores a frame and its
  worst tile; `--truth` prints the mean, the worst frame and the worst tile for the engine and both baselines.
  Verified by unit tests (identical frames score perfect; one tile 20 off moves the frame 2.3 dB and the
  tile 20 dB; an image smaller than the grid) and on a synthetic clip, no console: a 40 px square crossing
  1080p at 1800 px/s scored VideoToolbox 42.4 dB mean, 36.8 worst frame, 16.0 worst tile. Their measured negative
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
3b. **On the console: an hour's stream with frame interpolation and ML upscaling on**, on a build with the
   shared-event fix (2026-11-20; v0.2.1 crashed after 10 minutes). The renderer status' `pacing.interpolation`
   and `pacing.ml` should never read `failed` (`ml` may read `stalled` for a few seconds while a first model
   builds). *(P0)*
4. ~~Rumble + adaptive triggers in a game~~ (done 2026-11-20: GTA VI, pad on USB, the user: works);
   touchpad built; **the motion axes in a game are left**. **Touchpad touches off, in GTA VI** (built
   2026-11-21, unit tests only): with it off a resting thumb on the touchpad doesn't open the map and a click
   does; turning it off with a thumb down leaves no touch stuck; back on, swipes work again; switching the pad
   off mid-press leaves nothing held. Then the built-in **GTA VI** profile (2026-11-21, ML upscaling off in it
   since 2026-11-24, unit tests only): picked mid-stream, ML upscaling turns off at once and it reconnects at
   1080p30 / 20 Mbps with frame interpolation filling toward the screen's rate, and a profile saved as "GTA VI" before shows as "GTA VI (saved)". *(P1)*
5. ~~Keychain credential storage~~ (done). *(P2)*
6. ~~Packaging + AGPL/licensing + CI, and the first public release~~ (done 2026-11-20: the repo is public and
   [v0.1.0](https://github.com/deblanco/PlayFX/releases/tag/v0.1.0) ships the notarized DMG; v0.2.0 to v0.2.4 followed). `release.sh` now survives a notarytool
   status timeout and staples the `.app` too (built and tested with a fake notarytool); left: its first real run,
   at the next release. *(P4)*
6b. **Release 0.2.4 with the updater, then verify the in-app update with 0.2.5** (built 2026-11-21, see "In-app
   updates through GitHub Releases"): first check the stored key went in whole (setup step 3's `wc -c`: the
   .key file's size + 1, not 129); publish 0.2.4's DMG, `.app.tar.gz` and `latest.json`; then 0.2.5, and on a
   0.2.4 copy see the banner, Update to "Restarting…" and 0.2.5 running (in `/Applications` and in
   `~/Applications`), Later until 0.2.5's successor, and Download from GitHub with the network off. *(P4)*
7. On the PS5 and the pad: ~~frame generation on the built-in 120 Hz screen~~ (done 2026-11-20: GTA VI, 30 fps
   in 60, ~100 shown/s); left: the 75 Hz external screen; ML upscaling on its lane on a live 1080p stream in a window larger than 1920×1080, now skipping repeated pictures (the shown rate should stay near 120 Hz); a stream measured with Steady Wi-Fi on (only pings
   were); the pad left quiet on `pkill` and ⌘Q mid-effect; ~~the light bar in a game that sets it~~ (done
   2026-11-20: GTA VI, red/blue flashes then pink, from the release's log); Bluetooth
   haptics in Astro's Playroom; ~~USB haptics in a game with the app~~ (done 2026-11-24: GTA VI on the PS5, pad on
   USB, the app logged "audio haptics enabled", the user: "now works perfect"; see "USB haptics felt").
7b. **On the console: an HDR game with frame interpolation on** (Silent Hill 2 on the MacBook Pro's XDR display),
   new since 2026-11-20 and only tested offscreen: `pacing.interpolation` reads `on` (not `failed`), about 60
   shown/s for a 30 fps game on 60 Hz and on 120 Hz (halves only in HDR), highlights still above SDR white in the
   in-between images, no colour shift between real and generated images, and `costMs` near 5 ms at 1080p. Also
   whether a 1080p HDR stream looks better with it than without (it was only level with a cross-fade over the
   synthetic frame, better on the moving object) and a 720p one not worse (it scored under a cross-fade there);
   and an SDR game with HDR on reads `sdrInHdr`, the stats line "no interpolation: SDR game with HDR on" and the
   Frame interpolation switch "This game is SDR, but HDR is on, …" (2026-11-21, unit tests only). *(P1)*
7c. **On the console: the measured reorder wait** (new 2026-11-21, unit-tested only). A normal session at
   1080p60 and one at 1080p30 HDR on the LAN: Settings › Diagnostics shows the wait settling (from 16 ms, likely
   down to 3–8 ms on the LAN) and the log's "Takion AV reorder wait now" lines; compare holes, lost frames and
   "waiting for IDR" with the earlier logs (5 holes in 50 min; no "queue full" skips dropping a frame); then over
   the internet, where the wait should stay higher, and in a loss burst not fall below what late packets showed.
   Detailed logs show each "queue full" and "reorder timeout" skip. *(P1)*
7d. **On the console: the adaptive input lane** (new 2026-11-21, unit tests only). With a pad in hand, that
   presses, sticks, touchpad and motion aim feel no worse than before (the loop's off-main reads of
   GameController's elements are the unverified part), also with a second pad connected and idle, and pulling a
   pad's battery or Bluetooth mid-press; the stream stays clean in the stats (motion no longer
   floods while a pad lies still); and the dev latency test (`POST /latency-test`) before and after, with the
   main thread busy and idle, shows what the lane bought — or doesn't, in which case the input leg wasn't the
   bottleneck and raw HID input (bypassing GameController entirely, the way the USB haptics output does) isn't
   worth its cost. *(P1)*
8. Smaller follow-ups: ~~the Wi-Fi stall warning~~ (done 2026-11-20, from AirDrop's state, and from the stall
   itself in the frames' arrival; left: seeing the second on a live stream with AWDL on); ~~the worst-tile
   quality score (from PushFPS)~~ (done 2026-11-20); ~~the 50 fps cadence~~ (done 2026-11-20 in unit tests; a
   50 fps game is left to see); ~~the PR #817 reorder-wait test~~ (replaced by the measured wait, 7c); ~~tests for the reconnect
   race and the audio output following the system default~~ (done 2026-11-20); the chiaki-ng upstream PR
   (needs the user's OK); echo cancellation for the microphone; audio jitter-buffer tuning; ~~a profile switch
   during a bitrate reconnect reconnecting on its own~~ (fixed 2026-11-20); the Play toast suggesting Steady
   Wi-Fi (built 2026-11-21, unit tests only: a look at it in the app, with AirDrop on, is left); a look at the Settings sheet's four
   tabs in the app (icons and labels on one line, measured only in headless Chrome).
9. Pairing, from the pairing review: ~~the guide and copy fixes~~ (done 2026-11-20; the menu names need a look on
   a PS5 and a PS4); ~~a real "No consoles found" state with next steps and the IP field~~ (done 2026-11-20; the
   Local Network button needs a look on the Mac); ~~the specific pairing failure reasons~~ (built); next, on the
   console: trigger each pairing failure once and record its reason code (see "Say why pairing failed"), and the
   denied Local Network permission. *(P2)*
10. Pairing through PSN on the console: pair with no code, then check the keys stream on the home network, over
   the internet, and that the console merges with its discovered row (see "Pair without a PIN through PSN").
   ~~Cancel ending at once, and its own message for a PS5 that never answers~~ (done 2026-11-20, fork and
   unit tests); on the console: a Cancel mid-pairing ends at once, and a PS5 signed in to another PSN account
   gets "didn't answer pairing through PSN" or "didn't accept" (which one isn't known yet). *(P0)*
11. **Our own Remote Play protocol** (branch `deblanco/rewrite-ps-remote-core`, see P4): ~~the facts-only spec for
   discovery, wake, registration, session init and ctrl~~ (done 2026-11-23); ~~the Swift discovery, wake and
   registration from the spec~~ (done 2026-11-23); ~~one hardware round: discover, wake and pair the PS5~~ (done 2026-11-23,
   all three work); ~~milestone 2: session init and the ctrl channel~~ (done 2026-11-23, on the PS5: a session with
   heartbeats, a clean stop, go to bed); ~~milestone 3: the stream (Takion, the stream connection, audio and
   video, FEC, input) specified, then built, with the stream's receive path measured on Network.framework against a
   BSD socket thread~~ (done 2026-11-24, `StreamSession` and `pfxp stream`, tested over loopback); ~~its first
   hardware round~~ (done 2026-11-24: H.264, HEVC and HDR streams on the PS5 with nothing lost, both transports);
   ~~a stream under load (a game, a pad)~~ (done 2026-11-24: in GTA VI with our own input and 5% simulated loss, FEC
   working); ~~the engine seam in StreamCore: libchiaki behind `StreamEngine`~~ (done 2026-11-24, unit tests, behaviour
   unchanged); ~~`PlayFXEngine` on that seam~~ (done 2026-11-24); ~~internet play, the PSN console list and PIN-less
   pairing on PlayFXProtocol~~ (done 2026-11-24); ~~StreamCore on PlayFXProtocol only~~ (done 2026-11-24: no
   libchiaki in StreamCore or psrp); ~~the app's build and CI without libchiaki~~ (done 2026-11-24); ~~the submodule and
   third_party/ removed~~ (done 2026-11-24); ~~PlayFX proprietary~~ (done 2026-11-24); ~~libopus built from source,
   no Homebrew~~ (done 2026-11-24); next, the parity round in
   the app on the console, and the provenance and risk page. *(P4)*
