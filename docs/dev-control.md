# Dev control port

A small HTTP API for driving a running PlayFX from scripts: benchmarks, end-to-end runs, anything
that needs to change settings or press a button without clicking the window. It works with the
window in the background, on another display or Space, so a run never takes over your screen.

It exists only in **development builds** (`bun run desktop`). A release build contains none of it:
the Rust module and the web UI's listener are compiled out of release builds, so nothing in a
shipped app opens a port.

## Turning it on

Set `PLAYFX_DEV_CONTROL` to a port (1024 or higher) when starting the app:

```sh
PLAYFX_DEV_CONTROL=7780 bun run desktop
```

The app logs `Dev control port open on http://127.0.0.1:7780`. It listens on the loopback address
only, so other machines can't reach it. Without the variable, no port is opened.

Every request must carry the header `X-PlayFX-Dev: 1` and a `Host` of `127.0.0.1` or `localhost`; anything
else gets 403. A web page open in a browser can reach 127.0.0.1 too (a form post, or DNS rebinding), but it
can't add a custom header without a CORS preflight, which the port never answers, and a rebound name shows
in the `Host`. Connections that send nothing are closed after 5 seconds.

To start streaming without a click as well, add `VITE_PSRP_AUTOPLAY=1`. It plays the first paired
console as soon as it shows as ready on the home network.

## Endpoints

Every reply is JSON. Errors come back as HTTP 400 (or 404 for an unknown route) with
`{"error": "…"}` saying what was wrong.

| Method and path | What it does | Reply |
|---|---|---|
| `GET /status` | The renderer's state and the stream's numbers, the same data as the stats line | Renderer status (below) |
| `POST /settings` | Changes settings. The body is a JSON object with only the settings to change | `{"ok": true}` |
| `POST /play` | Plays the first paired console, as its **Play** button does (local, waking it, or over PSN by the Connect choice) | `{"ok": true}` |
| `POST /reconnect` | Restarts the stream, applying changed stream settings (resolution, frame rate, codec, bitrate, HDR) | `{"ok": true}` |
| `POST /fullscreen` | Toggles native full screen on the main window | `{"fullscreen": true}` |
| `POST /press?buttons=…&ms=…` | Holds controller buttons for `ms` milliseconds (default 150, at most 5000), then releases them | `{"ok": true}` |
| `POST /latency-test?trials=…` | Opens the control centre and times `trials` Right/Left presses (default 5, at most 20) to the picture's answer (below). About a second per trial | Summary (below) |

`/settings`, `/play` and `/reconnect` are carried out by the web UI through the same code paths as
its own controls. Changed settings are saved, applied to the picture at once, and shown in the
Settings panel. An invalid value is refused and the UI shows a toast.

### Settings

`POST /settings` takes any of the app's settings (`Settings` in `apps/desktop/src/core/schema.ts`).
The ones that matter for picture work:

| Setting | Values | Applies |
|---|---|---|
| `view` | `"original"` (the raw stream), `"split"` (original beside enhanced), `"enhanced"` | At once |
| `upscaler` | `"metalfx"`, `"bilinear"` | At once |
| `sharpness`, `deblock`, `deband` | 0–1 | At once |
| `mlUpscale` | `true`/`false`: Apple ML super-resolution before upscaling (1080p in two tiles) | At once |
| `frameInterpolation` | `true`/`false`: frame generation, images between the game's pictures, one per screen refresh | At once |
| `showStats` | `true`/`false`: keep the stats line on screen | At once |
| `height` | `540`, `720`, `1080` | On reconnect |
| `fps` | `30`, `60` | On reconnect |
| `hevc`, `hdr` | `true`/`false` | On reconnect |
| `bitrate` | kbps, `0` for the console's default | On reconnect (the app reconnects on its own when only the bitrate changed) |

Frame interpolation only adds frames when the screen refreshes at least 1.2× as often as the game makes
pictures: a 30 fps game on a 60 Hz display (also inside a 60 fps stream), or a 60 fps game on a 75 or
120 Hz one. `pacing.interpolation` says when and why it doesn't.

### Buttons

`buttons` is a comma-separated list: `cross`, `circle`, `square`, `triangle`, `up`, `down`, `left`,
`right`, `l1`, `r1`, `l3`, `r3`, `options`, `share` (Create), `touchpad`, `ps`.

### Renderer status

`GET /status` returns the same object as the UI's `renderer_status` command:

```json
{
  "metalfxSupported": true,
  "activeMode": "metalfx",
  "gpuMs": 1.42,
  "mlSupported": true,
  "mlActive": false,
  "interpolationSupported": true,
  "interpolationActive": true,
  "hdrActive": false,
  "displayMs": 9.8,
  "shownFps": 60,
  "pacing": { "generatedFps": 0, "skippedFrames": 3, "skippedGenerated": 0, "missedInterpolations": 0, "delayMs": 11.5,
              "latenessMs": 9.5, "costMs": 0, "clockRestarts": 0, "size": "",
              "interpolation": "screen", "upscale": "notLarger", "ml": "off",
              "displayHz": 75, "streamFps": 60, "gameFps": 0, "repeatedFrames": 0, "wifiStalls": false },
  "stream": { "active": true, "width": 1920, "height": 1080, "framesDecoded": 5400, "framesLost": 0, "rttMs": 4.2,
              "targetBitrateKbps": 19417 }
}
```

`pacing` is the frame pacing (see [FRAME_INTERPOLATION.md](FRAME_INTERPOLATION.md)):

- `delayMs`: how far behind the stream clock images are shown.
- `latenessMs`: the 90th percentile of how late frames arrive behind that clock. It's the network and
  thread side of the delay; [NETWORK.md](NETWORK.md) uses it.
- `costMs` and `size`: an in-between image's cost and the size it's made at.
- `skippedFrames` and `skippedGenerated`: stream frames and in-between images that were due but never shown
  (a later one was due first). Skipped in-between images are expected when more are made than the screen
  refreshes (quarters on a 75 Hz screen) or the playhead passes several at once.
- `missedInterpolations`: pairs of pictures that got no in-between images (the lane was still busy with the
  last pair, or the size gave nothing; scene cuts aren't counted).
- These counts are totals since the stream started. The stats line shows `skippedFrames` and
  `missedInterpolations` as rates over the last 5 s ("+45 generated (3/s missed) · 2/s skipped"), amber
  from 3 missed or 1 skipped a second.
- `clockRestarts`: how often the stream clock started over (the stream's start, gaps of over 200 ms, jumps
  of frames; a late stretch only slides it).
- `interpolation`, `upscale`, `ml`: what each optional step is doing, and why one that's on is idle.
  `interpolation`: `off`, `on`, `unsupported` (this Mac or macOS), `screen` (the screen doesn't refresh
  often enough for the game's rate), `still` (on, but the game holds its picture), `failed` (off until the app
  restarts: VideoToolbox's processor kept failing). `upscale`: `metalfx`, `bilinear` (chosen), `notLarger` (MetalFX only
  enlarges, and the picture on screen isn't larger than the stream), `unsupported`, `failed`. `ml`: `off`,
  `on`, `unsupported`, `streamTooLarge` (larger than 1080p, or a size the model refused), `notLarger`,
  `hdr` (the model takes 8-bit frames only), `failed` (off until the app restarts: its processor kept failing),
  `stalled` (a frame has been in the model over 15 s, such as a slow first model build: frames go around it
  meanwhile, and it clears once the model returns).
- `displayHz`: the screen's measured refresh rate. `streamFps`: the rate interpolation works from (the
  game's once measured). `gameFps`: the game's own rate, repeats left out. `repeatedFrames`: stream frames
  that repeated the picture before.
- `wifiStalls`: frames keep stopping for 70–400 ms and then coming in a burst, none lost, at a steady
  0.3–1.2 s period over the last 12 s: the Wi-Fi's periodic stall (AirDrop's radio). See
  [NETWORK.md](NETWORK.md), "Seeing the stall in the stream".

`stream.targetBitrateKbps` is what the console's encoder aims for, from its connection quality reports.

`shownFps` counts the new images put on screen each second. With Frame interpolation it's higher than the
stream's frame rate, which is how you can tell frame generation is working.

### Latency test

`POST /latency-test?trials=5` opens the PS5's control centre (PS), presses Right and Left in turn to move its
highlight, and times each press → the first changed picture decoded. Then it closes the control centre
(Circle, again if the highlight was off the first card). PS itself isn't timed: the control centre only
starts to show about 0.5 s after it, a delay of the console's menu, not of the stream.

```json
{ "trials": 5, "answered": 5, "medianMs": 48.5, "meanMs": 50.1, "minMs": 41.2, "maxMs": 63.0, "displayMs": 9.8 }
```

It covers the console, the network and decoding; add `displayMs` (the renderer's decoded-to-screen time)
for the Mac's whole share. It's the PS5 menu's response, not a game's, and the pad's own delay and the
display aren't in it. `psrp stream` has the same test at `/latency-test`.

## Examples

```sh
PORT=7780
DEV="X-PlayFX-Dev: 1"
# Start streaming and keep the stats on screen
curl -s -H "$DEV" -X POST localhost:$PORT/play
curl -s -H "$DEV" -X POST localhost:$PORT/settings -d '{"showStats": true}'

# Unpause a game (Options on the DualSense)
curl -s -H "$DEV" -X POST "localhost:$PORT/press?buttons=options"

# The raw stream, then the enhanced picture
curl -s -H "$DEV" -X POST localhost:$PORT/settings -d '{"view": "original"}'
curl -s -H "$DEV" -X POST localhost:$PORT/settings -d '{"view": "enhanced", "upscaler": "metalfx", "sharpness": 0.3}'

# Frame generation: a 30 fps stream, then Frame interpolation
curl -s -H "$DEV" -X POST localhost:$PORT/settings -d '{"fps": 30}'
curl -s -H "$DEV" -X POST localhost:$PORT/reconnect
curl -s -H "$DEV" -X POST localhost:$PORT/settings -d '{"frameInterpolation": true}'
curl -s -H "$DEV" localhost:$PORT/status | jq '{shownFps, interpolationActive}'
```

## Where it lives

- `apps/desktop/src-tauri/src/dev_control.rs`: the HTTP listener, request parsing and routes. Tests
  are in `src/tests/dev_control.rs`.
- `apps/desktop/src-tauri/src/lib.rs`: `AppDevHost`, the app side of each route, and
  `start_dev_control`, called while the app starts.
- `apps/desktop/src/app/devControl.ts`: the web UI's listener (`useDevControl`) and how a settings
  change is applied (`patchSettings`).
