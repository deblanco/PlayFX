# ML upscaling

ML upscaling runs Apple's low-latency super-resolution model on each decoded frame, before anything else in
the picture pipeline. It adds real detail (hair, edges, text) where MetalFX and bilinear only enlarge. It
is on by default, and it runs whenever the picture on screen is larger than the stream, at every stream
resolution: 540p, 720p and 1080p. This document covers:

- how it works,
- why 1080p goes through in tiles,
- what was measured, and how to measure it again,
- what is known not to work.

Everything here runs in StreamCore (`packages/streamcore`); the app only switches it on and shows why it is
idle.

## The short version

- **The model is `VTLowLatencySuperResolutionScaler`** (VideoToolbox, macOS 26+). It runs on the Neural
  Engine, so the GPU's time per frame barely moves. It takes 8-bit NV12 frames and scales them 1.5×, or 2×
  for small ones.
- **It only takes sides up to 1280 px that are multiples of 16.** It reports other sizes as supported, then
  fails on them. 1080 and 540 aren't multiples of 16. On macOS 27 the new queries agree:
  `maximumDimension(forSpatialScaleFactor: 1.5)` is 1280 and `maximumPixelCount` is 1,638,400 (1280×1280).
  2× is capped at 960 and 921,600 px; 4× at 480 and 230,400. 1920×1080 lists no scale factor. The header's
  example of a whole 1080p frame is only valid if those limits allow it, and on this OS they do not.
- **540p is padded to 960×544**: the last 4 rows are repeated, and the extra rows are dropped from the
  output. 540p gets 2× when the window has room for it.
- **1080p is cut into two overlapping 1088×1088 tiles.** Each tile goes through the model on its own
  session, and the middle of each output is copied into one 2880×1620 frame. The tiles overlap by 128
  columns, so each side of the cut has 64 columns of context and no seam shows.
- **Cutting and joining are GPU blits**, one command buffer before the model and one after. No pixels are
  converted.
- **It runs on its own lane, not in the draw** (`UpscaleLane`): its own queue and Metal command queue, one
  frame at a time. A refresh never waits for the model. A new picture is upscaled first and joins the
  stream clock when that's done, so the pacing delay covers the model's time like any other lateness.
  A repeat of that picture does not run the model: with frame interpolation on it is left out, and with it
  off the last upscaled frame is shown again.
- **It upscales stream frames only.** In-between images are made from upscaled frames, so the model doesn't
  run again for each of them.
- **When it falls behind, it drops a frame instead of queueing.** One frame is upscaled while at most one
  waits. A newer frame takes the waiting one's place, and the dropped one is counted in the frames lost.
- **It skips frames it doesn't need to upscale**: when the picture on screen isn't larger than the stream,
  the frame passes through untouched, and ML runs again as soon as the window grows.
- **Cost:** about 6 ms of latency per frame at 720p and up to 15 ms at 1080p. The setting says so.

## How it works

`StreamRenderer.display` hands each decoded frame to the `UpscaleLane`, with the area the picture fills on
screen (from the last draw). On the lane's queue, `MLSuperResolution.upscale` returns an upscaled NV12
buffer, or nil to use the frame as is. Whichever it is then goes on the stream clock, into the timeline, and
to frame interpolation, exactly as a decoded frame did before. The draw only shows what's due. The rest of
the pipeline (colour conversion, cleanup, MetalFX, sharpening) works from it.

### Why it's off the draw path (`UpscaleLane`)

The first version ran the model inside the draw that goes to the screen, on every image shown. At 1080p on a
120 Hz screen, a live PS5 stream showed what that does (20 November 2026, GTA VI, 30 fps game in a 60 fps
stream):

| | Screen rate | Shown per second | GPU per draw | Frames lost |
|---|---|---|---|---|
| ML on, interpolation on | 54 Hz | 46–56 | 14 ms | 3/s |
| ML on, interpolation off | 42 Hz | 36–45 | 18 ms | 17/s |
| ML off, interpolation on | 115 Hz | 82–117 | 5.6 ms | 3/s |

ML added about 12 ms to each draw. A 60 fps stream gives a frame 16.7 ms, and a 120 Hz refresh gives 8.3 ms,
so every draw with ML in it missed refreshes and held up the next one. It wasn't a clash with frame
interpolation: turning that off made it worse.

The lane follows `InterpolationLane`:

- **Its own queue.** The draw never encodes ML work and never waits for it.
- **Ahead of the stream clock.** A frame goes on the clock when it's upscaled, with that moment as its
  arrival. The delay planner sees the model's time as lateness and raises the delay to cover it. The
  display-latency stat still counts from when the frame was decoded, so it includes the model.
- **In order, one at a time, at most one waiting.** A newer frame takes the waiting one's place; the one it
  replaces is dropped and counted in `skippedFrames`. A dropped frame leaves a one-frame gap in the indices,
  which the stream clock takes without starting over.
- **The decoded frame goes with the upscaled one**, as a CoreVideo attachment (`UpscaleLane.decodedKey`).
  The split view shows it on the left, and the deblocking grid is worked out from its width. It propagates,
  so in-between images made from upscaled frames carry it too.
- **Repeats are told on the decoded frames**, before upscaling, as before.
- **Only frames the model can enlarge go to the lane.** When the picture on screen isn't larger than the
  frame, or ML is off, or the frame is 10-bit, it goes straight on the clock. While the lane still holds
  earlier frames, it queues behind them instead, passing through untouched. That way frames reach the clock
  in order, and from one thread at a time.
- **A frame from the stream before is left out.** `streamFrameRate` (set for every new stream) bumps a
  generation. A frame the lane finishes after that is discarded: its index would otherwise sit on the new
  stream's clock and keep the new frames off it.
- **Frame interpolation picks its sizes from the decoded frame.** It works on the upscaled frames, but its
  sizes (`RungSelector`) come from the decoded size, so a 720p stream is still interpolated at 1280×720 on
  VideoToolbox's fast path. The in-between image is then scaled up to the upscaled size, and still areas
  are blended back from the upscaled frames. So moving areas in an in-between image have no ML detail.
- **In the split view, an in-between image is its own baseline.** It carries the decoded frame of the later
  picture it was made towards, which isn't its moment. The interpolation lane clears the attachment from
  its pooled output buffers before copying attachments on, so a stale one never survives ML being turned
  off.
- **The engine is injected** (`FrameUpscaler`). Tests use a stand-in, so the lane's order, dropping and
  attachment are tested in CI's VM, where the model never runs.

### The tiles (`MLSuperResolution.tiling`)

`tiling(width:height:)` decides how a frame goes through the model, from its size alone:

| Stream | Tiles | Output at 1.5× | Output at 2× |
|---|---|---|---|
| 1280×720 | one 1280×720 tile: the frame itself | 1920×1080 | — |
| 960×540 | one 960×544 tile: 4 rows of padding | 1440×810 | 1920×1080 |
| 1920×1080 | two 1088×1088 tiles at x = 0 and x = 832, 8 rows of padding | 2880×1620 | — |

The rules:

- The tile height is the frame height rounded up to a multiple of 16. It must stay within 1280 px, and the
  padding can't be larger than the frame.
- The frame width must be a multiple of 16. Every stream resolution's is.
- A frame up to 1280 px wide is one tile. A wider one is cut into as many tiles as it takes for each to keep
  at most 1152 columns (1280 minus 64 of context on each side). All tiles have the same size, so one
  configuration serves every session.
- Cuts fall on multiples of 4 columns. At 1.5× that lands on whole pixels in both the luma plane and the
  half-width chroma plane.
- A frame taller than 1280 px (1440p and up) gets no tiling, and the renderer reports `streamTooLarge`.

### Scale factor

The model lists its factors for the tile size (`supportedScaleFactors`). The renderer keeps those that give
whole, even output sizes, then takes the largest one that fits on screen. If none fits but the screen is
still larger than the stream, it takes the smallest one, and the rest of the pipeline scales down from
there. If the screen isn't larger than the stream at all, ML is skipped for that frame.

### One frame, step by step (`upscaleTiles`)

1. **Cut.** One blit encoder copies each tile's region out of the frame into a buffer from the tile pool,
   luma and chroma planes separately. The last rows are copied again into the padding. The command buffer
   is committed and waited for: the model reads the tiles next.
2. **Model.** Each tile goes to its own `VTFrameProcessor` session through VideoToolbox's synchronous call,
   into a buffer from the model's output pool, one tile after the other. Separate sessions keep any state
   the model carries between frames apart per tile. Not the Metal command-buffer call: it leaks a Metal
   shared event per call, which crashed long sessions (see "Which VideoToolbox call" in
   [FRAME_INTERPOLATION.md](FRAME_INTERPOLATION.md)).
3. **Join.** A second command buffer's blit encoder copies the middle of each output, the columns the tile
   keeps times the factor, into one buffer from the output pool. The padded rows aren't copied. It's
   waited for before the frame goes on the clock.
4. The output gets the frame's colour attachments (matrix, range, chroma siting), so the NV12 conversion
   reads it like the original.

A frame the model takes whole (720p) skips the cut and join and goes straight to step 2: no Metal work at all.

Sessions and pools are made on the first frame of a size and factor, and remade when either changes. A
size that fails to start, or whose first frame two fresh processors in a row refuse, is remembered and never
tried again; the renderer reports it as `streamTooLarge`. A size (and factor) that was upscaled before in the
run is never taken as refused: an error there, even a fresh processor's first, counts as a failure and is
restarted with the next frame, as is an exception; failures past a budget turn ML upscaling off until the app
restarts (`ml: "failed"`), and every tile's session is ended then. See "When a processor fails anyway" in [FRAME_INTERPOLATION.md](FRAME_INTERPOLATION.md).

## What was measured

All on this Mac (Apple silicon, macOS 27.2.1), November 2026.

### Which sizes the model really takes

A probe (outside the repo) asked `supportedScaleFactors` for each size, then processed a frame with the
async API, which returns errors that the command-buffer API hides:

| Size | Factors listed | Processes? |
|---|---|---|
| 1280×720, 1280×736, 1280×768, 1280×800 | 1.5 | yes |
| 1024×1088, 1088×1088, 1280×1088 | 1.5 | yes |
| 960×544 | 1.5, 2 | yes |
| 960×540 | 1.5, 2 | **no** (`-19730`) |
| 1024×1080, 1280×1080 | 1.5 | **no** (`-19730`) |
| 1024×600, 992×572 | 1.5 | **no** (`-19730`) |
| 1920×1080, 1920×1088, 1920×540 | none | — |

Each failing size has a side that isn't a multiple of 16; every passing one has both.

### Time per tile (the model alone, async API, median of 20)

| Tile | ms |
|---|---|
| 960×544 | 1.5 |
| 1280×720 | 2.5 |
| 1024×1088 | 3.2 |
| 1088×1088 | 3.3 |
| 1280×1088 | 3.7 |

Two 1088×1088 tiles for a 1080p frame: about 6.6 ms of model time.

### Whole frame in the renderer

With ML still in the draw, a throwaway test rendered 50 frames to a 3840×2160 target, ML off and on, in a
debug build. The absolute times include the test's readback; the difference is what ML cost each draw:

| Stream | ML off | ML on | Cost |
|---|---|---|---|
| 1280×720 | 43.2 ms | 49.2 ms | ~6 ms |
| 1920×1080 | 42.6 ms | 54.0 ms | ~11 ms |

At 1080p the cost is more than the model's 6.6 ms, because everything after it works on a 2880×1620
picture instead of 1920×1080.

With the lane, the same kind of test (1080p, 32 frames, debug build) times the two parts apart:

| | Lane, per frame | GPU per draw |
|---|---|---|
| ML off | 0.7 ms (nothing to do) | 6.7 ms |
| ML on | 15.5 ms | 3.5 ms |

The lane's 15.5 ms includes the repeat check on the decoded frame, which at the time ran on the lane's queue
too. It now runs before the model, and a repeat doesn't enter it. It fits a 60 fps stream's 16.7 ms, with
little to spare; the draw no longer carries any of it. The two GPU
figures are smoothed averages and noisy: what matters is that ML adds nothing to the draw.

### How to measure it again

- **Which sizes work, and how long a tile takes:** a short Swift script that makes a
  `VTLowLatencySuperResolutionScalerConfiguration` for a size, starts a `VTFrameProcessor` session, and
  times `try await processor.process(parameters:)` on a filled NV12 buffer. Use the async API (or the
  synchronous one from Objective-C, as the app does): it throws where `process(with: commandBuffer, …)` fails
  silently.
- **Cost in the renderer:** with `params.mlUpscale` off and on, time `display` plus `waitForUpscaling`
  (the lane) apart from the render after it (the draw), as the `show` helper in `MLTests.swift` does.
- **On a real stream:** with the dev control port, stream at 1080p in a window larger than 1920×1080 and
  check `mlActive: true` and `"ml": "on"` in the renderer status. Shrink the window to 1920×1080 or less and
  `ml` reads `notLarger`. See [dev-control.md](dev-control.md).
- **Picture quality, same frame A/B:** `psrp`'s `/grid.png?vary=ml` renders one frame with ML off and on.

## How to test it

- `swift test --package-path packages/streamcore --filter "ML|PipelineState"`:
  - `MLTilingTests`: the tile layout for each resolution, including overlap and coverage, and what it refuses.
  - `cutsAPaddedTileOutOfTheFrame`: the cut, padding included, with plain Metal and CoreVideo. It runs
    without the model, so in CI's VM too.
  - `mlUpscales1080pInTiles` and `mlUpscales540p`: the whole path on a real model. They check the output
    size and that brightness holds across the cut and in the padded rows. Both are skipped where ML isn't
    available.
  - `mlSaysWhyItIsIdle`: the reasons the HUD shows.
- `swift test --package-path packages/streamcore --filter "UpscaleLane|upscalesOnItsLane|comparesAgainst|framesSkip|aDropped|aRepeated|aRepeat|aNewPicture"`:
  the lane with a stand-in engine, so these run in CI's VM too. They cover:
  - order, and dropping the waiting frame;
  - the decoded frame kept with the upscaled one;
  - the engine running once per frame, not once per draw;
  - the split view's baseline;
  - frames skipping the lane with ML off or nothing to enlarge;
  - frames queueing behind one still in the lane;
  - a frame from the stream before left out;
  - dropped frames counted as lost;
  - a repeated picture upscaled once (also when the repeat arrives while the model is still busy), the
    last upscaled frame kept when interpolation is off, a new picture upscaled, and a picture after a
    clock gap upscaled again.

  Not covered by a test: interpolation sizes from the decoded frame, and the in-between baseline in the
  split view. Both need VideoToolbox's frame interpolation running on frames from the lane; check them on a
  live stream.
- `bun run --cwd apps/desktop check`: the setting defaults to on, and the pipeline view shows "ML + …" at
  every resolution.

## Code map

| What | Where |
|---|---|
| Tile layout, scale factor, cut/model/join | `packages/streamcore/Sources/StreamCore/MLSuperResolution.swift` |
| The lane: queue, dropping, the decoded frame attachment, `FrameUpscaler` | `packages/streamcore/Sources/StreamCore/UpscaleLane.swift` |
| Frames to the lane, then the clock (`display`, `intake`); why it's idle (`mlState`) | `packages/streamcore/Sources/StreamCore/StreamRenderer.swift` |
| Tests | `packages/streamcore/Tests/StreamCoreTests/MLTests.swift`, `UpscaleLaneTests.swift`, `PipelineStateTests.swift` |
| Setting and its default | `apps/desktop/src/core/schema.ts` (`mlUpscale`) |
| Pipeline view, HUD reasons | `apps/desktop/src/app/format.ts` (`mlApplies`, `mlRow`) |
| The switch and its latency note | `apps/desktop/src/app/SettingsSheet.tsx` |

## Known limits and open questions

- **The lane's repeat skip hasn't been on a live stream yet.** A 30 fps game in a 60 fps stream used to
  upscale every frame and then throw the repeat away, which is the headroom problem below. The repeat is
  now told before the model. The next check is the same 1080p stream on the 120 Hz screen: the shown rate
  should stay near the refresh rate with ML on, and the frames lost near 0.
- **Latency.** Up to 15 ms at 1080p, almost a whole 60 fps frame, added to the pacing delay. The setting
  says so; users who play fast games may want it off. A repeated picture no longer adds that cost.
- **Little headroom at 1080p60.** The lane takes about 15.5 ms per new picture in a debug build, against
  16.7 ms. With frame interpolation also using the Neural Engine, a stream of all-new pictures may still
  fall behind; it then drops frames, counted as lost. A 30 fps game no longer pays that cost twice. The
  model itself is spatial: running a frame twice, or after a different frame, matches a fresh run.
- **1080p only helps on large windows.** The output is 2880×1620, and the frame only goes through when the
  picture on screen is larger than 1920×1080.
- **Existing installs keep their saved choice.** The default only applies to new installs and to settings
  saved before the switch existed. Anyone who had it off keeps it off. Since the Recommended profile now has
  ML on, their settings show as their own mix rather than Recommended.
- **In-between images have no ML detail where things move** (see "Frame interpolation picks its sizes from
  the decoded frame" above). On a 120 Hz screen, detail in moving areas may look softer than MetalFX alone,
  because the generated image is bilinear from the decoded frame and MetalFX then only covers the last step.
  Seen on a 1080p recording (issue #2); not separately rechecked after the repeat skip.
- **HDR (10-bit) streams** get no ML. The model takes 8-bit frames only.
- **Seams** don't show on the test frames, which have flat areas and one hard edge. Fine diagonal detail
  crossing the cut hasn't been checked side by side.
- **The size rule is inferred.** "Multiples of 16" fits every size tried, but Apple doesn't document it. If
  a later macOS lifts it, `tiling` still works; it would just pad when it doesn't need to.
