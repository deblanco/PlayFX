# Frame interpolation: findings and design

Frame interpolation (called "Smooth motion" until now) makes an image between each pair of stream frames,
so a 30 fps stream reaches a 60 Hz screen at 60 images a second. This document records why the first
version added no frames, what three projects that solved the same problem do, and the design the
refactor follows.

## Why the first version adds nothing

The renderer asks VideoToolbox for the in-between frame **inside the same draw that goes to the screen**,
shows it, and keeps the real frame for the next refresh. On the bench (`psrp interpolate`, a 1080p30 GTA VI
clip, M2 Pro), VideoToolbox takes **14.2 ms** per in-between frame at 1080p, all of it off the Metal GPU.
Waiting 14 ms plus 2–7 ms of drawing misses a 16.7 ms refresh, so every interpolating draw slips and the
loop falls to about 30 draws a second. The benchmark measured exactly that: 30 fps in, 31 images shown.

A second loss affects every stream: the renderer keeps only the newest decoded frame, so when internet
jitter delivers two frames within one refresh, the older one is never shown (a steady 60 fps stream
showed 39–49 images a second on a 60 Hz screen).

## What the bench measured

`psrp interpolate <clip> [--engine vt|metalfx] [--flow-scale s] [--out doubled.mov]` reads a video's
frames as the decoder hands them over (NV12 IOSurfaces), makes each in-between frame, and times it.

| 1080p30 clip, M2 Pro | Per in-between frame | Metal GPU |
|---|---|---|
| VideoToolbox low-latency interpolation (Neural Engine) | 14.2 ms | 0 |
| MetalFX + VideoToolbox optical flow at half size | ~39 ms wall (incl. format conversions) | ~9 ms |
| MetalFX + optical flow at quarter size | ~26 ms wall | ~8 ms |

Both produce believable halfway frames on this clip.

## Research

### Veyra (Windows, DirectX 12; PS5 Remote Play through chiaki) — GPL-3.0

Engineering notes on the same failure, frame generation falling to the source rate on a 60 Hz screen:

- **The mechanism.** The image between A and B can only be made after B arrives, and B's display time
  cannot move earlier. When making it takes more than half the input interval (16.7 ms at 30 fps), the
  generated image and B fall in the same refresh, B replaces it, and the screen drops to 30 fps, cycling
  with the beat between the two clocks. Loss ≈ (refresh interval − gap between the two) / refresh / 2.
- **Waiting more was tried and retired**: queueing saved the frames but added up to a refresh of
  latency, which was not acceptable.
- **What worked:** per pair, when the image would miss its refresh or the budget cannot cover it, use a
  faster, lower-quality tier for that pair (41–43 → 59 shown fps on a slow GPU).
- **Stream timestamps** (`RemotePlayClock`): a frame's time is `anchor + index / fps + phase`, where the phase
  follows the *lower envelope* of `arrival − nominal` over the last second (network jitter only ever adds
  delay), slewing at most 0.5% of a frame per frame, strictly increasing, and re-anchoring after a gap
  over 200 ms or a jump of more than half a second of frames. The profile's nominal fps is not the
  source's clock (a "60" stream can be 59.94).
- Counts frames overwritten in the latest-frame mailbox, and measures frames *displayed*, never submitted.

### MacNativeGames (Switch ports to Metal) — technique only

- `MTLFXFrameInterpolator` conventions, measured with a synthetic scene whose middle frame is known:
  motion vectors in **pixels of the motion texture, pointing to the previous position**; UI given apart and
  premultiplied (the "composited" mode returned a black frame).
- **MetalFX refines motion itself: zero motion vectors still give about 36 dB**, so wrong vectors cost a few
  dB, not tens.
- Rebuilding identical interpolators grew device memory; they cache them by configuration.

### MetalGoose (macOS window frame generation, Swift, Metal 4) — GPL-3.0

The closest match: frame generation on captured windows, which have no depth or motion either.

- **Two engines.** VideoToolbox low-latency interpolation on the **Neural Engine** (leaves the GPU free), and
  MetalFX on the GPU (more faithful, midpoint only, costs GPU time).
- **Separate queues** for capture, interpolation and presentation, "so an interpolation never holds up a
  capture or the image a refresh is waiting for".
- **Size is a speed dial for the Neural Engine.** Above 1280×720 pixels VideoToolbox runs a slower path that
  is 3–7 dB closer to the real frame; at or below it, a fast path. Where time is short (60 fps on 120 Hz,
  uneven arrivals) it works at 1280×720 or 960×540 rather than skipping pairs. Each size builds a model
  (1–2 s the first time), so common sizes are built at launch.
- **MetalFX's motion comes from the media engine** (`VTMotionEstimationSession`): one search pass explained
  1440p video *worse* than assuming no motion (31 vs 35 dB) and "swims like dough"; multi-pass ("true
  motion") cost a fraction of a millisecond more and gave 38 dB; 4×4 blocks 43 dB but slow. Requests queue
  in the media engine, so a too-fine search falls behind (200 ms at 1440p); the search is chosen to fit
  60% of the frame interval, with hysteresis.
- **The delay is explicit:** the newest frame is held back by most of an interval plus the time the first
  generated image takes (40–50 ms at 30 fps), eased so engine changes don't step the motion, and chosen so
  refreshes don't land on the points where one image hands over to the next.
- **Scheduling uses presentation timestamps**, not arrival.
- **Engine hysteresis:** leave an engine at once when it stops keeping up and don't retry for 30 s; take a
  better one only with room to spare after 10 s.
- **Static content is blended back** (UI, text, still areas), where generated images are lossy; **scene
  cuts** stop generation.
- Counts actual presentations (the drawable's presented callback): *Generated + Passthrough = Presented*.

The code is GPL-3.0 (compatible with PlayFX's AGPL-3.0), but PlayFX takes the ideas, not the code.

## Design

1. **Stream clock.** Each decoded frame gets a timestamp from its index (previous + 1 + frames lost, which
   libchiaki reports) and the lower-envelope phase above. Presentation follows the clock, not arrival, which
   also fixes the jitter losses for streams without interpolation.
2. **Interpolation off the display path.** When frame B arrives, the pair (A, B) goes to an interpolation
   lane with its own queue. The display shows A, then the in-between image at the midpoint, then B, each
   when its time comes; a refresh never waits for interpolation.
3. **Delay, stated.** Real frames are shown one interval plus the generation time late (about 40–50 ms at
   30 fps). The setting says so.
4. **Neural Engine first, sized to fit.** VideoToolbox low-latency interpolation at the stream's size when it
   fits the time (1080p: 14 ms, fine at 30 fps), at 1280×720 or 960×540 when it does not (60 fps on 120 Hz).
   Per pair, a frame that would miss its refresh uses the faster size; engine/size changes use the
   hysteresis above. Common sizes are built when the stream starts.
5. **MetalFX later, if it earns it.** Motion from `VTMotionEstimationSession` (multi-pass) or zero, flat
   depth, cached interpolators. It competes with MetalFX upscaling for the GPU, so it is only worth it if the
   bench shows better images at a cost that fits.
6. **Protect static content and cuts.** Blend unchanged areas (HUD, subtitles) back from the real frame;
   skip generation across scene cuts.
7. **Measure what reaches the screen.** Count presentations from the presented callback, split into
   generated and passthrough, plus frames overwritten before display.
8. **Rename** "Smooth motion" to "Frame interpolation" in the app and its settings (old saved settings
   keep working).

Verification runs on the bench first (offline timing and quality, and a live mode that plays a clip at its
frame rate on a real display and counts presentations), then on the console.
