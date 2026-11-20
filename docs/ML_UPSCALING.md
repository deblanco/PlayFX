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
  fails on them. 1080 and 540 aren't multiples of 16.
- **540p is padded to 960×544**: the last 4 rows are repeated, and the extra rows are dropped from the
  output. 540p gets 2× when the window has room for it.
- **1080p is cut into two overlapping 1088×1088 tiles.** Each tile goes through the model on its own
  session, and the middle of each output is copied into one 2880×1620 frame. The tiles overlap by 128
  columns, so each side of the cut has 64 columns of context and no seam shows.
- **Cutting and joining are GPU blits in the frame's own command buffer.** Nothing waits on the CPU, and no
  pixels are converted.
- **It skips frames it doesn't need to upscale**: when the picture on screen isn't larger than the stream,
  the frame passes through untouched, and ML runs again as soon as the window grows.
- **Cost:** about 6 ms per frame at 720p and about 11 ms at 1080p, measured in the renderer. The setting
  says so.

## How it works

`StreamRenderer.encode` hands each new frame to `MLSuperResolution.encode` with the size of the picture on
screen. That returns an upscaled NV12 buffer, or nil to use the frame as is. The rest of the pipeline
(colour conversion, cleanup, MetalFX, sharpening) then works from whichever it got.

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

### One frame, step by step (`encodeTiles`)

1. **Cut.** One blit encoder copies each tile's region out of the frame into a buffer from the tile pool,
   luma and chroma planes separately. The last rows are copied again into the padding.
2. **Model.** Each tile goes to its own `VTFrameProcessor` session with `process(with: commandBuffer, …)`,
   into a buffer from the model's output pool. Separate sessions keep any state the model carries between
   frames apart per tile.
3. **Join.** A second blit encoder copies the middle of each output, the columns the tile keeps times the
   factor, into one buffer from the output pool. The padded rows aren't copied.
4. The output gets the frame's colour attachments (matrix, range, chroma siting), so the NV12 conversion
   reads it like the original. A completion handler keeps every buffer and texture alive until the GPU is
   done.

A frame the model takes whole (720p) skips the cut and join and goes straight to step 2.

Sessions and pools are made on the first frame of a size and factor, and remade when either changes. A
size that fails to start is remembered and never tried again; the renderer reports it as `streamTooLarge`.

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

A throwaway test rendered 50 frames to a 3840×2160 target, ML off and on, in a debug build. The absolute
times include the test's readback; the difference is what ML costs:

| Stream | ML off | ML on | Cost |
|---|---|---|---|
| 1280×720 | 43.2 ms | 49.2 ms | ~6 ms |
| 1920×1080 | 42.6 ms | 54.0 ms | ~11 ms |

At 1080p the cost is more than the model's 6.6 ms, because everything after it works on a 2880×1620
picture instead of 1920×1080.

### How to measure it again

- **Which sizes work, and how long a tile takes:** a short Swift script that makes a
  `VTLowLatencySuperResolutionScalerConfiguration` for a size, starts a `VTFrameProcessor` session, and
  times `try await processor.process(parameters:)` on a filled NV12 buffer. Use the async API: it throws
  where `process(with: commandBuffer, …)` fails silently.
- **Cost in the renderer:** render the same frame with `params.mlUpscale` off and on, as the tests in
  `MLTests.swift` do, and time the render.
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
- `bun run --cwd apps/desktop check`: the setting defaults to on, and the pipeline view shows "ML + …" at
  every resolution.

## Code map

| What | Where |
|---|---|
| Tile layout, scale factor, cut/model/join | `packages/streamcore/Sources/StreamCore/MLSuperResolution.swift` |
| Where the renderer calls it; why it's idle (`mlState`) | `packages/streamcore/Sources/StreamCore/StreamRenderer.swift` |
| Tests | `packages/streamcore/Tests/StreamCoreTests/MLTests.swift`, `PipelineStateTests.swift` |
| Setting and its default | `apps/desktop/src/core/schema.ts` (`mlUpscale`) |
| Pipeline view, HUD reasons | `apps/desktop/src/app/format.ts` (`mlApplies`, `mlRow`) |
| The switch and its latency note | `apps/desktop/src/app/SettingsSheet.tsx` |

## Known limits and open questions

- **Not verified against the PS5 yet.** The 1080p path has been checked on synthetic frames in the tests,
  not on a live stream.
- **Latency.** About 11 ms at 1080p is most of a 60 fps frame. The setting says so; users who play fast
  games may want it off.
- **1080p only helps on large windows.** The output is 2880×1620, and the frame only goes through when the
  picture on screen is larger than 1920×1080.
- **Existing installs keep their saved choice.** The default only applies to new installs and to settings
  saved before the switch existed. Anyone who had it off keeps it off.
- **HDR (10-bit) streams** get no ML. The model takes 8-bit frames only.
- **Seams** don't show on the test frames, which have flat areas and one hard edge. Fine diagonal detail
  crossing the cut hasn't been checked side by side.
- **The size rule is inferred.** "Multiples of 16" fits every size tried, but Apple doesn't document it. If
  a later macOS lifts it, `tiling` still works; it would just pad when it doesn't need to.
