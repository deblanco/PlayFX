# Frame interpolation

Frame interpolation makes an image between each pair of stream frames, so a 30 fps stream reaches a 60 Hz
screen as 60 images a second (or a 60 fps stream a 120 Hz one). The feature was called "Smooth motion"
until November 2026. This document covers:

- how it works,
- why it is built this way,
- what was measured, and how to measure it again,
- what is known not to work.

Everything here runs in StreamCore (`packages/streamcore`); the app only switches it on and shows its
stats.

## The short version

- **Frames are shown by a stream clock, not when they arrive.** Network jitter neither drops nor bunches
  them, with or without interpolation.
- **In-between images are made on their own lane**: their own queue and command queue. A refresh never
  waits for one.
- **The display runs a stated delay behind the stream clock.** It covers the jitter, half a frame interval
  and the time an in-between image takes, so the image is ready at its moment. At 30 fps this is about
  36–45 ms. The setting says so.
- **VideoToolbox low-latency frame interpolation** makes the images, on the Neural Engine, so the GPU stays
  free for MetalFX upscaling. When the stream's own size is too slow, it works at 1280×720 or 960×544.
- **Still areas are blended back from the real frames.** Scene cuts get no in-between image. An empty
  result is never shown.
- **What reaches the screen is counted** from the drawable's presented callback, not from what was
  submitted.

## Why the first version added nothing

The first version asked VideoToolbox for the in-between frame *inside the draw that goes to the screen*.
VideoToolbox takes 14 ms at 1080p. With 2–7 ms of drawing on top, that misses a 16.7 ms refresh, so every
interpolating draw slipped and the loop fell to about 30 draws a second. The benchmark showed exactly this:
30 fps in, 31 images shown.

A second loss hit every stream. The renderer kept only the newest decoded frame, so when jitter delivered
two frames within one refresh, the older one was never shown. A steady 60 fps stream showed 39–49 images
a second on a 60 Hz screen.

## Research

Three projects solve parts of the same problem. PlayFX takes their ideas, not their code.

### Veyra (Windows, DirectX 12; PS5 Remote Play through chiaki), GPL-3.0

- **The failure mode.** The image between A and B can only be made after B arrives, and B's display time
  cannot move earlier. When making it takes more than half the input interval, the generated image and B
  fall in the same refresh, and B replaces it. The screen drops to the source rate, cycling with the beat
  between the two clocks.
- **Waiting longer saved the frames** but added up to a refresh of latency; Veyra dropped that. What worked
  was a faster, lower-quality tier for a pair that would miss its refresh.
- **Stream timestamps** (`RemotePlayClock`): `anchor + index / fps + phase`. The phase follows the *lower
  envelope* of `arrival − nominal` over the last second, because jitter only ever adds delay. The phase
  slews slowly and the clock re-anchors after a gap. The nominal fps is not the source's clock: a "60"
  stream can run at 59.94.
- **Measure frames displayed, never frames submitted.**

### MacNativeGames (Switch ports to Metal), technique only

- **`MTLFXFrameInterpolator` conventions:** motion vectors are in *pixels of the motion texture* and point
  to the *previous* position.
- **MetalFX refines motion itself:** zero motion vectors still give about 36 dB.
- Rebuilding identical interpolators grows device memory, so cache them.

### MetalGoose (macOS window frame generation, Swift, Metal 4), GPL-3.0

This is the closest match: captured windows have no depth or motion vectors either.

- **Two engines:** VideoToolbox on the Neural Engine, and MetalFX on the GPU (motion from
  `VTMotionEstimationSession`, multi-pass).
- **Separate queues** for capture, interpolation and presentation.
- **Size is a speed dial.** Above 1280×720 VideoToolbox takes a slower, better path; at or below it, a fast
  one.
- **The delay is explicit and eased,** so engine changes don't step the motion.
- **Engine hysteresis:** leave at once when an engine stops keeping up, and don't retry for 30 s. Climb only
  with room to spare, after 10 s.
- **Static content is blended back** and **scene cuts stop generation.**
- **Presentations are counted** in the presented callback.

## How it works

```
decoder ──frame + index──▶ StreamRenderer.display
                              │  stream clock → time
                              │  timeline.add(frame, time)
                              └─ pair (last, frame) ──▶ InterpolationLane (own queue)
                                                         cut? → skip
                                                         scale down · interpolate · scale up · blend still areas
                                                         empty? → drop the size
                              timeline.add(image, midpoint) ◀─┘
display link ─▶ StreamRenderer.nextFrame(now) ─▶ timeline.next(now, delay) ─▶ draw ─▶ presented callback
```

### Frame index

libchiaki reports how many frames were lost before each decoded frame. `StreamSession` turns that into an
index (`previous + 1 + framesLost`), and `VideoDecoder` hands each picture over with it
(`onIndexedFrame`). A lost frame therefore leaves a gap in the times, rather than shifting every later
frame early.

### Stream clock (`StreamClock` in `FramePacing.swift`)

A frame's time is `anchor + (index − first) / fps + phase`.

- **The phase** follows the minimum of `arrival − nominal` over the last second, kept as a monotonic deque.
  It moves at most `interval / 200` per frame, so a burst of jitter can't make times jump. Times always
  increase.
- **Starting over:** a gap of more than 200 ms, or a jump of more than half a second of frames, re-anchors
  the clock. The renderer also re-anchors when a frame's time runs more than half an interval ahead of its
  arrival (the stream fell behind for good).
- **After a restart** the first frame is shown at once (`time = arrival − delay`), so nothing waits on a
  clock that has just started.

### Timeline (`FrameTimeline`)

The timeline holds real and generated images in time order, up to 16. Each refresh shows the *newest*
image that is due (`time + delay ≤ now`). Older due images are skipped and counted; these are the "skipped
frames" and "skipped in-between images" stats. Beyond capacity, the oldest images go and are counted too.

### Delay (`DelayPlanner`)

The delay is:

- the 90th percentile of recent lateness (arrival behind the clock, over 120 frames),
- plus a 2 ms margin,
- plus, when interpolating, half an interval and the 90th percentile of the time an in-between image takes
  (over 60 images).

It moves at most +1 ms or −0.25 ms per frame, so turning interpolation on or off, or a change in size,
never steps the motion. The app shows it as "pacing delay" (`sc_pacing_stats` → `delayMs`).

### When interpolation runs

It runs when the setting is on, the Mac supports it, and the screen refreshes at least 1.8× as often as
the stream sends frames (`FrameInterpolator.helps`): 30 fps on 60 Hz, or 60 fps on 120 Hz. Otherwise every
image would just be replaced before it is shown. Interpolation is not available in virtual machines
(`kern.hv_vmm_present`), where VideoToolbox claims support and then crashes or writes nothing.

### The lane (`InterpolationLane.swift`)

When frame B arrives, the renderer submits the pair (A, B) with its midpoint time and a size. The lane has
its own `DispatchQueue` and `MTLCommandQueue`, and works on one pair at a time. A pair that arrives while
the lane is busy goes without its image; it is counted as `busyPairs`.

For each pair:

1. **Scene cut check:** the mean luma difference over a 32×18 grid. Above 40 out of 255 it's a cut, the
   pair is skipped and counted as `cutPairs` (`SceneCut`).
2. **One command buffer:**
   - GPU bilinear scaling of both frames down to the working size (when smaller),
   - VideoToolbox interpolation,
   - scaling the result back up,
   - the still-area blend.

   There is one commit and one wait. Using `VTPixelTransferSession` for the scaling cost about 6–8 ms per
   pair; on the GPU it costs about 1 ms.
3. **Still-area blend** (`blendStaticLuma` / `blendStaticChroma`): where A and B differ by less than
   2/255, the pixel comes from the real frames. Above 8/255 it comes from the generated image, with a
   smoothstep in between. Generated images are lossy exactly where nothing moves: HUDs, subtitles, menus.
4. **Empty output check.** VideoToolbox can report success and write nothing (see sizes below). A 16×9
   luma sample with a mean below 8 is "empty", since video-range black is 16. That image is dropped and its
   size is marked broken for the rest of the session.

The image goes back to the renderer with its cost (submit to ready). The first two images at each size are
marked as warming up: they include building that size's model (1–2 s the first time), so they say nothing
about the size's steady cost and are left out of the delay and the size choice.

### Size (`RungSelector`)

The rungs are the stream's own size, then 1280×720 and 960×544 where those are smaller.

- **The budget** is 75% of the stream interval (25 ms at 30 fps, 12.5 ms at 60 fps).
- **Stepping down:** a cost over the budget moves down at once, and blocks the size it left for 30 s.
- **Stepping up:** only after the choice has stood for 10 s, and only if that size's last measured cost was
  within 60% of the budget.
- **Broken sizes** (empty output) are blocked forever.

Each size's model is built by its first image (1–2 s), on the lane's queue, so a change of size costs one
or two late images rather than a stall.

**Why 960×544, not 960×540:** VideoToolbox's fast path (at or below 1280×720) wants both sides a multiple
of 16. At 960×540, 854×480 and 640×360 it returns success with an all-zero image, which shows as green.
So on the fast path a stream's own size is rounded down too (a 540p stream works at 960×528, 360p at
640×352), and the lane scales back to the frame's size. 1920×1080, on the slow path, is fine as it is.

The lane checks VideoToolbox's own image for emptiness, before the still-area blend. After the blend,
still areas come from the real frames and would hide an empty image: a first version checked the blended
result and let partly green images through. Measured:

| Working size | p50 per image | Output |
|---|---|---|
| 1280×720 | 7.0 ms | correct |
| 1024×576 | 7.0 ms | correct |
| 960×544 | 6.6 ms | correct |
| 960×540 | 0.1 ms | **empty** |
| 854×480 | 0.1 ms | **empty** |
| 640×360 | — | **empty** |

### Counting what reached the screen (`PresentationCounts`)

Each drawable carries a presented handler. A presented time above zero counts as shown, split into real and
generated; zero means the frame was dropped.

Sidecar (an iPad as a display) reports zero for *every* presentation. So after 30 zeros in a row, the
display is taken as one that doesn't report times, and each handled presentation counts as shown. The first
real time switches back.

The app reads the counts through:

- `sc_shown_fps`, for images shown per second,
- `sc_pacing_stats`, for `generatedFps`, `skippedFrames`, `skippedInterpolations` and `delayMs`,
- `sc_interpolation_status`.

## Measurements

All measurements are on an M2 Pro, with a 1080p30 GTA VI clip recorded from the PS5 with the character
standing still and NPCs moving.

### Engines, offline (`psrp interpolate --truth`, 120 frames)

Truth mode drops every other frame, predicts each dropped frame from its neighbours, and compares the
prediction with the real frame (PSNR over RGB). Two baselines run alongside: repeating the previous frame,
and a plain cross-fade.

The "Pan" columns use a synthetic pan made from the same clip: a moving 1920×1080 crop of a 2400×1350
upscale, moving 8 px right and 3 px down per frame. That gives true global motion with a known answer.

| Engine | Wall per image | Metal GPU | Still clip | Pan |
|---|---|---|---|---|
| Repeat previous frame (baseline) | — | — | 45.5 dB | 30.9 dB |
| Cross-fade (baseline) | — | — | 47.6 dB | 33.3 dB |
| **VideoToolbox (Neural Engine), 1080p** | 14.4 ms | 0 | 41.6 dB¹ | 37.1 dB |
| MetalFX, zero motion | 10.2 ms | 7.9 ms | 47.8 dB | 37.6 dB |
| MetalFX, media-engine motion (16×16, multi-pass) | 14.1 ms | 7.7 ms | 44.7 dB | 37.6 dB |
| MetalFX, optical flow at half size | 22.9 ms | 8.3 ms | 47.8 dB | 37.7 dB |

¹ Raw VideoToolbox output, before the lane's still-area blend. VideoToolbox is built for motion, and on
still areas it is less faithful than the frames themselves; this is what the blend fixes.

**Conclusion: VideoToolbox stays the engine.** On motion all four engines land within 0.6 dB of each other,
and all are 4 dB better than a cross-fade. MetalFX would need about 8 ms of GPU per image, and the GPU is
already busy with MetalFX upscaling in the default profile. VideoToolbox leaves the GPU free. MetalFX's
motion sources add nothing over zero motion here: MetalFX refines motion itself, as MacNativeGames found.
The media engine's block vectors even cost 3 dB on still content. The MetalFX engines stay in the bench,
in case a future case changes this (heavier camera motion, or an Apple Silicon generation with GPU to
spare).

### Live, on a real screen (`psrp play`, Sidecar iPad at 60 Hz)

`psrp play` plays the clip at its frame rate through the real `StreamRenderer` and lane, optionally adding
arrival jitter, and counts what was presented.

| Interpolation | Jitter | Shown/s | In-between/s | Delay | Skipped |
|---|---|---|---|---|---|
| Off | 0 | 30.0 | — | 6.9 ms | 0 |
| Off | up to 16 ms | 30.0 | — | 17 ms | 0 |
| On (60% budget, settled at 960×544) | up to 8 ms | 58.9 | 29.1 | 40.8 ms | 2 frames, 30 in-between |
| On (75% budget, settled at 1280×720) | up to 8 ms | 57.1 | 27.9 | 44.3 ms | 7 frames, 30 in-between |

Skipped counts are totals over the 10 s run. With jitter and no interpolation, every real frame is shown.
Before the stream clock, a 60 fps stream on the PS5 showed 39–49 of its 60 frames. With interpolation, the
screen gets 57–59 images a second from a 30 fps stream. The shipped budget is 75%: 1280×720 is the better
image, for about 3.5 ms more delay.

Where the time goes, per pair, on the live run:

| Stage | Time |
|---|---|
| Cut check | 0.3–0.7 ms |
| Scaling (GPU, both ways) | about 1 ms |
| Interpolation at 960×544 | 8–9 ms |
| Interpolation at 1280×720 | 14–15 ms |

These times are while the display is also drawing; offline, 1280×720 takes about 7 ms.

## How to test it

All of this runs without a console.

```sh
cd packages/streamcore
swift build -c release --product psrp      # release: the PSNR loop is slow in debug

# Cost and a doubled-rate video to look at
.build/release/psrp interpolate clip.mov --out doubled.mov [--frames 120]

# Quality against the real frames, per engine
.build/release/psrp interpolate clip.mov --truth --frames 120 \
  --engine vt|metalfx-zero|metalfx-estimate|metalfx-flow [--flow-scale 0.5]

# Live pacing on a real display (Sidecar by default; --screen NAME for another)
.build/release/psrp play clip.mov --interpolate --jitter 8 --seconds 10
```

`psrp play` prints a line per second:

```
shown 59.0/s · in-between 30.0/s · skipped 6 frames, 30 in-between · delay 44.3 ms ·
  made at 1280x720 in 16.7 ms (cut 0.6 · scale 1.8 · interpolate 13.7 · blend 0.0)
```

The bench needs a source clip:

- a recording from the PS5 (the benchmark ones are in `~/Movies/PlayFX benchmark 2026-11-19/`),
- converted to the size and rate to test, e.g. `ffmpeg -i in.mov -vf scale=1920:1080 -r 30 ...`.

To make a pan with a known answer:

```sh
ffmpeg -i source.mov -t 4 \
  -vf "scale=2400:1350,crop=1920:1080:'min(n*8\,470)':'min(n*3\,260)'" \
  -c:v hevc_videotoolbox -b:v 40M -tag:v hvc1 pan.mov
```

In the app, the stats overlay shows shown fps, in-between images per second, skipped frames and the pacing
delay. The dev control port (`docs/dev-control.md`) reads the same numbers from a script.

Unit tests (`swift test`) cover:

- the clock (jitter, real rate, restarts),
- the timeline,
- the delay planner,
- the size selector (including broken sizes),
- scene cuts,
- presentation counting (including Sidecar),
- empty-image detection,
- the lane (cuts, busy pairs, smaller sizes),
- an in-between image of a moving bar landing between its two positions.

## Code map

| What | Where |
|---|---|
| Clock, timeline, delay, size choice, scene cut | `Sources/StreamCore/FramePacing.swift` |
| The lane: queue, scaling, blend, empty check | `Sources/StreamCore/InterpolationLane.swift` |
| VideoToolbox wrapper, `helps`, VM check | `Sources/StreamCore/FrameInterpolation.swift` |
| Pacing state, display, nextFrame, presentation counts | `Sources/StreamCore/StreamRenderer.swift` |
| Frame index from libchiaki | `StreamSession.swift`, `VideoDecoder.swift` |
| Stats to the app | `MacOSBridge.swift` (`sc_pacing_stats`, `sc_shown_fps`, `sc_interpolation_status`) → `apps/desktop/src-tauri/src/native.rs` → `RendererStatus` in `apps/desktop/src/core/schema.ts` |
| Bench | `Sources/psrp/Interpolate.swift`, `MetalFXBench.swift`, `Play.swift` |
| Setting rename (`smoothMotion` → `frameInterpolation`) | `apps/desktop/src/core/preferences.ts` (`renamedSettingKeys`) |

## Known limits and open questions

- **Not verified against the PS5 yet.** Everything above is from the bench, on purpose. The next check is a
  real 30 fps stream on a 60 Hz screen, then 60 fps on a 120 Hz one. At 60 fps the budget is 12.5 ms, so the
  lane should settle at 960×544.
- **The delay costs latency.** About 40–45 ms at 30 fps, by design: the in-between image can't exist
  before the next real frame does. The setting states it. For fast games, 60 fps without interpolation will
  feel more responsive.
- **The quality of the smaller sizes** (scaled down, interpolated, scaled up) hasn't been measured against
  the truth yet. MetalGoose reports the fast path as 3–7 dB further from the real frame than the slow one.
- **HDR (10-bit) frames** get no in-between images. `FrameInterpolator` takes 8-bit 4:2:0 only, and
  refuses each pair.
- **The test clips** are a mostly still scene and a synthetic pan. Fast, uneven motion (a turning camera,
  explosions) is where every engine is weakest, and is not in the numbers above.
