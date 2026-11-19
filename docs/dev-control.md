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
| `mlUpscale` | `true`/`false`: Apple ML super-resolution before upscaling (streams up to 720p) | At once |
| `frameInterpolation` | `true`/`false`: frame generation, an in-between frame for each pair of stream frames | At once |
| `showStats` | `true`/`false`: keep the stats line on screen | At once |
| `height` | `540`, `720`, `1080` | On reconnect |
| `fps` | `30`, `60` | On reconnect |
| `hevc`, `hdr` | `true`/`false` | On reconnect |
| `bitrate` | kbps, `0` for the console's default | On reconnect |

Frame interpolation only adds frames when the screen refreshes at least twice per stream frame: a 30 fps
stream on a 60 or 75 Hz display, or a 60 fps stream on a 120 Hz one.

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
  "pacing": { "generatedFps": 0, "skippedFrames": 3, "skippedInterpolations": 0, "delayMs": 11.5,
              "latenessMs": 9.5, "costMs": 0, "clockRestarts": 0, "size": "" },
  "stream": { "active": true, "width": 1920, "height": 1080, "framesDecoded": 5400, "framesLost": 0, "rttMs": 4.2 }
}
```

`pacing` is the frame pacing (see [FRAME_INTERPOLATION.md](FRAME_INTERPOLATION.md)):

- `delayMs`: how far behind the stream clock images are shown.
- `latenessMs`: the 90th percentile of how late frames arrive behind that clock. It's the network and
  thread side of the delay; [NETWORK.md](NETWORK.md) uses it.
- `costMs` and `size`: an in-between image's cost and the size it's made at.
- `skippedFrames` and `skippedInterpolations`: images that were due but never shown.
- `clockRestarts`: how often the stream clock started over.

`shownFps` counts the new images put on screen each second. With Frame interpolation it's higher than the
stream's frame rate, which is how you can tell frame generation is working.

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
