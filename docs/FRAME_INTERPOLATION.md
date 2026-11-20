# Frame interpolation

Frame interpolation makes images between the game's pictures, one for each screen refresh between two of
them, so the screen shows as many different images as it refreshes: a 30 fps game at 60 on a 60 Hz screen
and at 120 on a 120 Hz one, a 60 fps game at 75 on a 75 Hz screen. It works from the *game's* frame rate,
not the stream's: a 30 fps game in a 60 fps stream arrives with every picture twice, and those repeats are
left out first. The feature was called "Smooth motion" until November 2026. This document covers:

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
- **Repeats are left out, and the game's rate measured** (2026-11-20; see "The game's frame rate" below).
  Images are planned per screen refresh, at the points VideoToolbox offers (½, or ¼ ½ ¾).
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
never steps the motion. `sc_pacing_stats` reports it as `delayMs` (the app doesn't show it; the dev control
port's `/status` does).

With quarters (below) the earliest image is a quarter of the way along, so the delay covers three quarters
of the game's interval instead of half (`DelayPlanner.update(lead:)`).

### When interpolation runs

It runs when the setting is on, the Mac supports it, and the screen refreshes at least 1.2× as often as the
game makes pictures (`FrameInterpolator.helps`, `minimumRatio`): a 30 fps game on 60 Hz, a 60 fps game on
75 or 120 Hz. On a 60 Hz screen a 60 fps game gets none: no refresh is left over. Until 2026-11-20 the rule
was 1.8× the *stream's* rate, so a 30 fps game in a 60 fps stream never got images on a 60 Hz screen.
Interpolation is not available in virtual machines (`kern.hv_vmm_present`), where VideoToolbox claims
support and then crashes or writes nothing.

`sc_pacing_stats` says what it's doing (`interpolation`: `off`, `on`, `unsupported`, `screen`), with the
screen's measured rate (`displayHz`) and the rate it works from (`streamFps`, the game's once measured), so
the stats line can say "no interpolation: 60 fps on a 60 Hz screen" instead of nothing.

### The game's frame rate (repeats)

A game slower than the stream reaches the Mac with each picture repeated (30 fps in 60: every picture twice;
40 fps: 1, 2, 1, 2 times). The console keeps sending frames even for a still picture.

- **Repeats** (`RepeatDetector`): the console doesn't send a repeat as an exact copy. It spends a few KB
  refining the same picture, so the decoded repeat differs a little everywhere and up to ~60 levels at a few
  pixels. Measured on a PS5 (GTA VI, 30 fps in a 1080p60 HEVC stream): a repeat's mean luma change from the
  frame before is 0.02–0.4, a new picture's 0.6–8. So each frame's mean change is measured (every 4th pixel,
  each sampled row one column further on, so an edge moving 2 px can't hide between samples; about 0.6 ms at
  1080p even in a debug build) and a frame is a repeat when it changed by less than half as much as the last
  new picture. That reference halves with each repeat, so a camera that stops costs a frame or two, not more;
  no change at all is always a repeat. It runs on the decoder's output thread: a slow check there holds up
  the next decode, and with it the receiving of packets (a first version at 26 ms per frame dropped two
  thirds of the stream).
- **Only left out while interpolating.** With interpolation off a repeat is shown as before, so a wrong call
  can't cost anything there. Repeats are counted either way (`repeatedFrames`).
- **The game's rate** (`ContentRate`): the mean gap between its last 12 pictures on the stream clock. A
  median would say 30 or 60 for 40 fps's 1/2/1/2 rhythm; the mean says 40. `gameFps` in the stats.
- **Even times** (`CadenceClock`, while interpolating): the pictures reach the stream on its 60 fps grid
  (40 fps arrives 16.7 and 33.3 ms apart), so they are put on an even grid at the game's rate, never earlier
  than their own time, starting over when the cadence breaks.
- **Not across a still stretch**: a pair more than 4.5 stream intervals apart (a paused game) gets no images,
  and the game's rate starts over after it (the pause isn't its rate). While the game holds its picture,
  `interpolation` says `still` instead of `on`, so the stats line doesn't flag "+0 generated".

### The images, and the playhead that shows them

VideoToolbox doesn't take any phase. With `numberOfInterpolatedFrames` n it offers 2ⁿ − 1 evenly spaced
points (the SDK header: n = 1 gives ½, n = 2 gives ¼, ½, ¾), and more points cost latency. So:

- up to about two refreshes per game picture (30 on 60 Hz, 60 on 75 or 120 Hz): halves, one image;
- more (30 on 75 or 120 Hz): quarters, three images;
- each change rebuilds VideoToolbox's session, so it has hysteresis: quarters are taken from 2.3× and kept
  down to 2.1×; and the screen's rate is its fastest recent one (`InBetween.fastest`), since a ProMotion
  screen dips to 60 Hz for moments and would otherwise flip the choice.

`InBetween.images` makes every point, each stamped with its own moment between the two pictures. Which
refresh shows which image isn't predicted any more (the first version guessed the refreshes from the last
draw time and the delay, and every change of the delay or wobble of the draw callback landed images on the
wrong refresh: one shown twice, the next skipped).

That's the playhead's job (`Playhead`). Each refresh shows the newest image at or before it. It follows
`now − delay`, but as a moving point with a speed: the speed may leave 1 by at most 8%, so a change of the
delay runs the motion slightly slower or faster for a moment instead of holding a picture and then jumping;
one refresh moves it by the screen's steady period, not the draw callback's wobbly one; and it never passes
the first moment whose images aren't made yet, so a late picture is waited for just before the gap and then
caught up through every image. It's what a voice call does with late sound (play out a little slower or
faster); the generated images are what make it possible for video, since they give moments close enough
together to pass through at a changed speed.

Measured on the same recorded GTA session replayed through both: refreshes with no new image 19.4/s → 8.6/s
(about 8/s is the floor there: the game's picture came late), jumps of more than 1.5 refreshes 17.1/s →
8.4/s, at the same latency.

All of a pair's images come from one VideoToolbox call and one command buffer; the pair's cost is observed
once.

### Pacing trace

`STREAMCORE_PACING_TRACE=<file>` (environment, e.g. before `bun run desktop`) writes one line per event, times
in seconds on the host clock:

- `F index arrival time restarted delay interpolating repeat steps jitter cost`: each stream frame;
- `I readyAt time cost width delay`: each image the lane made, and the stream time it's for;
- `R now shownTime generated refreshInterval`: each refresh, and what it showed (`- -`: nothing new).

The `R` lines give what the screen actually did: refreshes with no new image (holds), how far the shown
moment moved per refresh (jumps), and the shown moment against a smooth line (judder).

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
- `sc_pacing_stats`, for `generatedFps`, `skippedFrames`, `skippedInterpolations` and `delayMs`, what the
  optional steps are doing (`interpolation`, `upscale`, `ml`), `displayHz`, `streamFps`, `gameFps` and
  `repeatedFrames`,
- `sc_smooth_supported` / `sc_smooth_active`.

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

In the app, the stats line shows the game's and the stream's rate when they differ, images shown, images
generated per second (with the ones missed), skipped frames, and why a step that's on is idle. The dev
control port (`docs/dev-control.md`) reads the same numbers, and the pacing delay, from a script.

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
