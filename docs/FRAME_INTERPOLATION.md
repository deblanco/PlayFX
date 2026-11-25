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
- **HDR streams use MetalFX's frame interpolator instead** (2026-11-20), since VideoToolbox's takes 8-bit
  frames only: the frames go to it as PQ-encoded R'G'B' and come back as 10-bit YCbCr, one image per pair
  (halves only), at the stream's own size. See "HDR" below.
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

The engine reports how many frames were lost before each decoded frame. `StreamSession` turns that into an
index (`previous + 1 + framesLost`), and `VideoDecoder` hands each picture over with it
(`onIndexedFrame`). A lost frame therefore leaves a gap in the times, rather than shifting every later
frame early.

### Stream clock (`StreamClock` in `FramePacing.swift`)

A frame's time is `anchor + (index − first) / fps + phase`.

- **The phase** follows the minimum of `arrival − nominal` over the last second, kept as a monotonic deque.
  It moves at most `interval / 200` per frame, so a burst of jitter can't make times jump. Times always
  increase, across a start-over too.
- **Sliding, not starting over:** when that minimum is more than half an interval from the phase (frames
  come earlier than the clock expects, or a stall shifted the stream's cadence later for good), the phase
  slides there by up to 8% of an interval per frame (`Playhead.stretch`). Frames stay evenly spaced to
  within 8%, and the playhead plays through them, so the change isn't seen.
- **Starting over:** only a gap of more than 200 ms, a jump of more than half a second of frames, or a frame
  more than a quarter second off the clock (a stream too far from its nominal rate to slide after,
  `StreamClock.reach`). Then no images are made across the break, and the game's rate and cadence start
  over; the timeline keeps what it has, and the playhead starts at the new frame (`Playhead.start(at:)`):
  it shows at once, and the playhead slows (never back) until it's behind by the delay again.

Until 2026-11-20 the clock also started over after a second of frames more than two intervals late, and the
renderer at any frame more than half an interval earlier than the clock. Each start-over cleared the
timeline (the in-between images with it), the game's rate and the playhead, and showed the frame at
`arrival − delay`: the picture fell back to the plain stream for a moment and then held for a whole delay.
A 7-minute session (`STREAMCORE_PACING_TRACE`) had 51: 33 "far earlier", most of them in a row on the
frames of the burst after a ~100 ms stall (each earlier than a clock just started on a late frame), 14 late
runs, and 4 real gaps. Replayed through both (the trace's arrivals and refreshes through a port of the
pacing, content measured by frame index):

| | Start-overs | Back-steps | Holds > 100 ms | Holds/s | Jumps > 1.5 refreshes/s | Latency p50 |
|---|---|---|---|---|---|---|
| Before | 42 (28 early, 11 late, 3 gaps) | 4 | 44 | 17.0 | 10.8 | 97.8 ms |
| Sliding | 3 (the gaps) | 0 | 37 | 17.0 | 10.9 | 97.1 ms |

Around the old start-overs (from 0.2 s before to 1 s after): holds 42.8/s → 38.6/s, in-between images
shown 36.6/s → 39.0/s, jumps 17.3/s → 18.5/s (the burst after a stall is played through quickly rather
than skipped). Most holds are the stalls themselves, which no pacing can hide. The replay puts back the
repeats that aren't traced while interpolating at a guessed arrival, so it finds 42 of the 51 start-overs.
Two earlier sessions: 21 → 0 start-overs (holds around them 30.1/s → 23.2/s) and 4 → 0 (26.4/s → 10.5/s).

### Timeline (`FrameTimeline`)

The timeline holds real and generated images in time order, up to 16. Each refresh shows the *newest*
image that is due (`time + delay ≤ now`). Older due images are skipped and counted (`skippedFrames`,
`skippedGenerated`). Beyond capacity, the oldest images go and are counted too. A skipped in-between image
isn't a miss: there are more of them than refreshes when quarters are made for a 75 Hz screen, or when the
playhead passes several at once.

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
support and then crashes or writes nothing. For HDR streams "supported" means MetalFX's frame interpolator
runs here (macOS 26, `MTLFXFrameInterpolatorDescriptor.supportsDevice`, not a virtual machine); the state
follows the stream as it is, so an HDR stream on a Mac without it reads `hdrUnsupported` (an SDR one without
VideoToolbox's, `unsupported`). With the HDR setting on, an SDR game's frames are 10-bit SDR, which neither
engine takes: `sdrInHdr`.

`sc_pacing_stats` says what it's doing (`interpolation`: `off`, `on`, `unsupported`, `hdrUnsupported`,
`sdrInHdr`, `screen`, `still`, `failed`; `StreamRenderer.interpolationState`, a pure function with its truth
table in `PipelineStateTests`), with the screen's measured rate (`displayHz`) and the rate it works from
(`streamFps`, the game's once measured), so the stats line can say "no interpolation: 60 fps on a 60 Hz
screen" or "no interpolation: SDR game with HDR on" instead of nothing. While streaming, the Frame
interpolation switch in Settings says the same for the HDR cases (`interpolationReason` in the app).

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
  than their own time, starting over when the cadence breaks: a picture further off the grid than one stream
  frame and 0.6 of the game's interval. The stream frame is the most its grid can move a picture (13.3 ms for
  50 fps in 60, beyond 0.6 of 20 ms); a pause, a jump or a faster game goes further.
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

All of a pair's images come from one VideoToolbox call; the pair's cost is observed once.

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
the lane is busy goes without its image; it is counted as `busyPairs`. A pair that gets nothing (VideoToolbox
couldn't start at its size, refused it, wrote an empty image, or failed: see "Which VideoToolbox call" below)
is counted as `failedPairs`. The two together are the stats' missed pairs (`missedInterpolations`).

For each pair:

0. **SDR or HDR:** HDR pairs (10-bit, PQ) go to MetalFX's engine, others to VideoToolbox's, each with its own
   engines per size and its own failure budget. A pair with one of each (the moment the stream switches) gets
   no images, like a cut, and MetalFX's history starts afresh after it.
1. **Scene cut check:** the mean luma difference over a 32×18 grid. Above 40 out of 255 it's a cut, the
   pair is skipped and counted as `cutPairs` (`SceneCut`).
2. **Three steps, each finished before the next:**
   - GPU bilinear scaling of both frames down to the working size (when smaller): one command buffer,
     committed and waited for (`stages.scale`),
   - VideoToolbox interpolation, its synchronous call on the lane's queue (`stages.interpolate`),
   - scaling the result back up and the still-area blend: one more command buffer, waited for
     (`stages.blend`).

   VideoToolbox's command-buffer call would put all of it in one command buffer, but leaks a Metal shared
   event per call (see "Which VideoToolbox call" below). The extra wait costs about 0.3 ms a pair when the
   frames are scaled, nothing otherwise. Using `VTPixelTransferSession` for the scaling cost about 6–8 ms per
   pair; on the GPU it costs about 1 ms.
3. **Still-area blend** (`blendStaticLuma` / `blendStaticChroma`): where A and B differ by less than
   2/255, the pixel comes from the real frames. Above 8/255 it comes from the generated image, with a
   smoothstep in between. Generated images are lossy exactly where nothing moves: HUDs, subtitles, menus.
   10-bit planes are read as 16-bit unorm, on the same 0–1 scale, so the thresholds are the same share of
   the signal (8 and 32 10-bit codes); the CPU checks (cuts, repeats, empty images) read a 10-bit sample's
   high byte, so their thresholds hold unchanged.
4. **Empty output check**, on VideoToolbox's own image, before the blend. Its command-buffer call reported
   success and wrote nothing at some sizes (see sizes below); the synchronous call returns an error there
   instead, but the check stays. A 16×9 luma sample with a mean below 8 is "empty", since video-range black
   is 16. That image is dropped and its size is marked broken for the rest of the session.

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
- **HDR pairs have one rung**, the stream's own size: MetalFX makes a 1080p image in about 4–5 ms, inside even
  a 60 fps game's budget, and a scaled copy would be a new frame to it every time, losing the history it
  carries from pair to pair. A cost over the budget has nowhere to go; the delay planner still covers it.

Each size's model is built by its first image (1–2 s), on the lane's queue. The playhead waits for a pair's
images for the delay and one picture's time at most; past that it goes on from the newest picture, so a
change of size costs the images of the pairs meanwhile rather than a stall.

**Why 960×544, not 960×540:** VideoToolbox's fast path (at or below 1280×720) wants both sides a multiple
of 16. At 960×540, 854×480 and 640×360 its command-buffer call returned success with an all-zero image,
which shows as green; its synchronous call returns `VTFrameProcessorProcessingError` (-19740) there. Once
two fresh processors in a row have erred on their first pair at a size that has never made an image in this
run, the size is taken as refused: it isn't asked for again, and it doesn't count against the feature (below).
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

### Which VideoToolbox call, and when it fails (`VideoProcessor.swift`)

`VTFrameProcessor` has three ways to run a frame: the Metal call `process(with: commandBuffer, parameters:)`,
the asynchronous ones, and the synchronous `processWithParameters:error:`. The app uses the synchronous one,
for interpolation and ML upscaling alike, on each lane's own queue. Swift doesn't see it (it's marked
unavailable there), so `playfx_vt_process` in `Sources/CObjCCatch` calls it.

**Why not the Metal call:** it makes a Metal shared event per call (`[device newSharedEvent]`, added to the
processor's own `events` array) and never frees it: not on `endSession`, not when the processor is released,
only when the process exits. Shared events are limited for the whole system (a fresh process could make
about 52,000 on this Mac, fewer while another app held some). Once they run out, `newSharedEvent` returns
nil, and VideoToolbox raises "insertObject:atIndex: object cannot be nil" with its own lock held. That is the
v0.1.0 crash (39 minutes, interpolation, the exception uncaught) and the v0.2.1 one (10 minutes,
interpolation and ML upscaling on: the exception was caught, then `endSession` on the same processor took
the held lock again, and libplatform killed the app). At 60 interpolated pairs a second plus two ML tiles a
frame at 60 fps, the events run out within minutes.

**Why not the asynchronous calls:** Swift's `process(parameters:)` without `await` resolves to the
`AsyncSequence` overload, which returns before the work is done. Ending the session right after it crashes
in VideoToolbox's completion block (`FigSimpleMutexLock`, `SIGSEGV`), reproduced in 1 of 1 runs of 50
start/process/end cycles. Measured with the real synchronous call, the completion-handler call waited on,
and the Metal call (`MTLSharedEvent` objects made and still alive in the process, counted by a hook on their
allocation, so nothing system-wide runs out while measuring):

| Call | Interpolation, 960×544 | ML ×1.5, 1280×720 | Cost per call |
|---|---|---|---|
| Metal command buffer | +1 alive per call | +1 alive per call (per tile) | 2.28 / 2.57 ms |
| Synchronous | 0 | 0 | 2.21 / 2.51 ms |
| Completion handler, waited for | 0 | 0 | 2.22 / 2.53 ms |

In the lanes (synthetic NV12 frames, 400 calls, before and after run turn about):

| | Before (Metal call) | After (synchronous) | Events alive |
|---|---|---|---|
| Interpolation, 1080p frames at 1280×720, halves | 5.2 ms a pair | 5.5 ms | +1 a pair → 0 |
| Interpolation, 720p, quarters | 12.8–13.1 ms | 12.8–13.0 ms | +1 a pair → 0 |
| ML, 720p whole | 2.56 ms a frame | 2.51 ms | +1 a frame → 0 |
| ML, 1080p in two tiles | 8.1 ms | 8.3 ms | +2 a frame → 0 |

Over 20,000 calls of each, the count stays at 0. The two tiles run one after the other: side by side
measured no faster. MetalFX's spatial scaler (2,000 encodes) and frame interpolator (1,000) make no shared
events. The `psrp` bench's optical-flow engine (`MetalFXBench.swift`) keeps the Metal call: one clip at a
time, dev only.

**When a processor fails anyway** (`GuardedProcessor`, `VideoProcessorHealth`):

- Every call into a processor (start, process, end) runs inside `playfx_catch` as well as Swift's `try`.
- A processor that raises an Objective-C exception is poisoned: its lock may be held for good. Nothing is
  called on it again, not even `endSession`, and it's kept in a quarantine list for the rest of the run
  (releasing it may call into it). The next pair (or frame) starts a fresh processor.
- An error gives that pair (or frame) nothing and retires the processor; the next starts a fresh one. Whether
  it counts depends on the configuration (size, with steps or factor), remembered per feature for the run
  (`ProcessorSizes`), not on the one processor: at a configuration that has made images before, any error
  counts as a failure, a fresh processor's first call or start included (a fault that lasts a few calls,
  such as a GPU reset on wake, mustn't pass for a refusal). At one that never has, the error isn't counted,
  and two fresh processors in a row erring at once make it a size VideoToolbox refuses (above); one alone
  may have been a passing fault.
- Three failures within a minute, or ten in a run, turn the feature off until the app restarts, instead of
  starting processor after processor. The picture goes on without it (real frames, MetalFX or bilinear),
  and the stats line says "interpolation off: it kept failing" (`interpolation: "failed"`, which also covers
  MetalFX's HDR engine, said as "interpolation off: MetalFX kept failing (HDR)" while `hdrActive`, and a stream
  with no size left that works) or "ML off (video processor failed)"
  (`ml: "failed"`).
- Turning the feature off retires every processor still running for it, on the spot: the renderer stops
  calling the lanes once the feature is off, so waiting for the next call would keep their sessions (both
  step counts at every prepared size, every ML tile) until the app quits. `VideoProcessorHealth` keeps a
  weak list of the processors made for the feature. A processor made or called after that is never started.
- Retiring a processor (a new size or factor, a failed one restarted, the feature turned off, its owner
  going away) never ends its session on the spot: `endSession` runs a second later on a queue of its own,
  once no call into it is running (a session still starting is ended once it has). The synchronous call
  returns with nothing left running, and 200 start/process/end cycles with `endSession` at once didn't
  crash, so this is a margin, not a fix.
- A frame stuck in ML upscaling for 15 s (a call that never returns) no longer holds the picture for good:
  frames go around the lane, and what it finishes later is left out. `ml` reads `stalled` ("ML idle
  (waiting on the model)") while it lasts, not `failed`: a slow first model build on a busy Mac can take
  that long and clears by itself. (15 s: building 1080p's tile model took 9 s the first time on this Mac,
  0.03 s once macOS had it cached.)
- A test makes sure the leak can't come back unnoticed: it hooks the allocation of `_MTLSharedEvent` and
  runs 200 interpolated pairs and 200 ML frames through the app's code (expecting no events), after 10
  Metal calls to show the hook sees one per call (`SharedEventTests`, skipped in a VM).

### Counting what reached the screen (`PresentationCounts`)

Each drawable carries a presented handler. A presented time above zero counts as shown, split into real and
generated; zero means the frame was dropped.

Sidecar (an iPad as a display) reports zero for *every* presentation. So after 30 zeros in a row, the
display is taken as one that doesn't report times, and each handled presentation counts as shown. The first
real time switches back.

The app reads the counts through:

- `sc_shown_fps`, for images shown per second,
- `sc_pacing_stats`, for `generatedFps`, `skippedFrames`, `skippedGenerated`, `missedInterpolations` and
  `delayMs`, what the optional steps are doing (`interpolation`, `upscale`, `ml`), `displayHz`, `streamFps`,
  `gameFps` and `repeatedFrames`,
- `sc_smooth_supported` / `sc_smooth_active`.

## HDR (`HDRFrameInterpolation.swift`)

HDR10 streams decode to 10-bit `x420` (BT.2020, PQ). VideoToolbox's low-latency frame interpolation takes
`420v` only (8-bit 4:2:0, video range; verified on an M2 Pro), so until 2026-11-20 frame interpolation sat out
in HDR. MetalFX's frame interpolator (`MTLFXFrameInterpolator`, macOS 26) takes float and 10-bit colour:
`bgra8Unorm`, `rgba16Float`, `rgb10a2Unorm`, `bgr10a2Unorm`, `rg11b10Float` and `rgba32Float` were all
accepted. It's built for games and wants motion vectors and depth; a stream has neither, and with zero motion
it finds the motion itself (the same setup as in the SDR comparison above).

### What it's fed: PQ R'G'B', not light

A spike (synthetic 1080p HDR scene: a textured ground panning 8,3 px a frame, a 400-nit sky band, a sun with a
1000-nit disc and a 2600-nit core, a red square crossing at 60 px a frame) scored the generated midpoint against
the exact in-between picture, as PSNR in PQ over RGB, mean over the frames · worst 64 px tile, 40 pairs:

| | Mean | Worst tile | Notes |
|---|---|---|---|
| Repeat previous | 39.0 dB | 18.0 dB | |
| Cross-fade (in PQ) | 44.4 dB | 22.5 dB | |
| MetalFX on **linear light** | 35.4 dB | 23.1 dB | worse than a cross-fade: don't |
| MetalFX on **PQ-encoded R'G'B'** | 45.0 dB | 26.3 dB | 2600-nit peak survives, no NaN or infinity |

MetalFX's maths is perceptual; linear light puts almost all the code values in the darks. Cost per image, M2
Pro: 720p 1.9 ms GPU (2.2 ms wall), 1080p 4.2 ms GPU (4.5 ms wall).

### How a pair goes through

`HDRFrameInterpolator`, one per size, on the lane's queue, one command buffer per pair, waited for:

1. **YCbCr → R'G'B'**: the present pass's own kernel (`nv12ToRGB` in `Shaders.swift`) with the frame's own
   matrix, range and chroma siting (no user overrides) and its PQ → light step off, into `rgba16Float`.
   Values are clipped to 0–1, as the present pass clips them before PQ anyway.
2. **MetalFX**: colour and previous colour, a zero `rg16Float` motion field and a `depth32Float` depth cleared to
   0.5, both at 1/16 of the frame, cleared at each fresh start; placeholder camera values (it has no camera);
   `shouldResetHistory` on a fresh start.
3. **R'G'B' → YCbCr** (`rgbToLuma` / `rgbToChroma`): the inverse of the same matrix and range, rounded to whole
   10-bit codes, into a buffer of the frame's own format (`x420` or `xf20`), and the frame's attachments
   (matrix, primaries, transfer, chroma siting) copied on. Chroma is filtered down to where its samples sit, a
   tent two luma pixels wide each way ([1 2 1]/4 on a co-sited axis, [1 3 3 1]/8 on a centred one). From here
   the image is a decoded frame to the rest: the still-area blend, the timeline, the HDR present path, MetalFX
   upscaling, EDR.

**History:** the two R'G'B' images are used in turn. A pair that starts from the last pair's newer frame (the
same buffer, which the engine holds so it can't come back as another frame) goes on from it, without
converting it again, and keeps MetalFX's history; any other pair (the first, after a busy or skipped pair, a
cut, a switch from SDR) starts afresh. **Halves only:** MetalFX makes the midpoint and nothing else, so HDR
pairs get one image (`HDRFrameInterpolator.maxSteps`); where SDR would make quarters (a 30 fps game on a
120 Hz screen), HDR makes halves. **Failures:** GPU work that can't be encoded or ends in a command-buffer
error counts against its own budget (`VideoProcessorHealth.hdrInterpolation`, the same 3-a-minute or 10-a-run
rule as VideoToolbox's), after which it's `failed` for the run; VideoToolbox's on SDR streams isn't touched.
An Objective-C exception from MetalFX's encode quarantines that interpolator, as VideoToolbox's processors are
(kept for good and never called again, counted as a failure), and the next pair sets up a fresh one. A size
MetalFX can't be set up for is never tried again. HDR pairs have one size, the stream's own: when the lane drops
it (5 pairs in a row with no image, MetalFX refusing the size among them), there's nowhere smaller to go, and the
renderer reports `failed` instead of `on` with nothing made (a dropped size stays dropped for the run); the same
holds for SDR once all its sizes are dropped. The lane's empty-image check (for VideoToolbox's silent failures) doesn't
apply to HDR images: MetalFX's failures come back as command-buffer errors, and in full range black is code 0, so
a fade to black would read as empty. **Memory:** HDR engines (MetalFX, three float images, a pool, the last frame
of the stream) are let go when the stream turns SDR and when a new stream starts. **No shared events:** MetalFX
makes no Metal shared event per call, unlike VideoToolbox's Metal call (`SharedEventTests`).

**10-bit SDR:** with HDR on in Settings, an SDR game still decodes to 10-bit frames (`x420`, not PQ). Neither
engine takes them (VideoToolbox: 8-bit only; the HDR engine: PQ only), so interpolation reports `sdrInHdr` for
such a stream and changes nothing about it (repeats show as they come, no game grid), rather than `on` with no
images. Routing them through the HDR engine (gamma-encoded R'G'B' is perceptual like PQ) is possible but not
built or measured.

### Measured through the app's code

The same scene drawn into `x420` frames (by the unit tests' generator), 9 frames, and its 8 pairs run through
`HDRFrameInterpolator` in turn (the first without history), each midpoint scored against the true in-between
picture in R'G'B' from the output codes, next to a cross-fade of the frames: mean PSNR over the pairs, the worst
32 px tile over all of them, and the mean around the fast square (where it was and is, with a 50 px margin). To
rerun it (about a minute, on a Mac with MetalFX's frame interpolator):

```sh
cd packages/streamcore
STREAMCORE_HDR_QUALITY=1 scripts/test.sh --filter hdrQualityTable
```

| Size | MetalFX mean · worst tile | Cross-fade mean · worst tile | Around the square, MetalFX vs cross-fade |
|---|---|---|---|
| 1920×1080 | 43.4 · 15.9 dB | 43.4 · 19.3 dB | 27.2 vs 25.1 dB |
| 1280×720 | 40.6 · 18.6 dB | 43.5 · 21.9 dB | 26.2 vs 25.1 dB |
| 960×540 | 39.0 · 20.3 dB | 43.4 · 22.9 dB | 27.0 vs 25.1 dB |

M2 Pro, 2026-11-20. At 1080p (what the PS5 sends) it's level with a cross-fade over the frame and about 2 dB
better around the fast square, but its worst tile is 3.4 dB under the cross-fade's. At smaller sizes the
whole-frame score drops below the cross-fade (the panning texture picks up small blob artifacts), while the
square is still better. It differs from the spike's 45.0 vs 44.4 dB (64 px tiles, 40 pairs): the spike drew the
scene straight into float R'G'B', here it goes through 10-bit 4:2:0 codes both ways. The YCbCr round trip alone costs
little (65–68 dB over the frame). The whole pair through the app's code, 1080p, wall clock: 4.9 ms median
(`metalFXCostAt1080p`). Earlier figures in this section (44.4 vs 43.3 dB at 1080p) came from a one-off harness
that wasn't kept; these replace them.

Unit tests: the round trip lands on the same codes (±1) in limited and full range; luma detail survives pixel
for pixel and chroma stays at its siting; attachments are copied; history only across following pairs; no
quarters, no SDR frames, no mixed sizes; one engine follows a change of size; a size MetalFX refuses isn't
retried; failures (encode refused, a command buffer that doesn't complete) turn it off for the run; an exception
quarantines the interpolator and the next pair gets a fresh one; the lane routes HDR, SDR and mixed pairs, lets
go of HDR engines at a switch to SDR or a new stream, doesn't take a dark full-range image for an empty one, and
blends still areas on 10-bit planes against an engine image unlike either frame (4 codes apart: the frames'
average; 40 apart: the engine's); the renderer asks the HDR engine for halves only at 120 Hz (SDR: quarters),
reports `on` / `hdrUnsupported` (HDR) or `unsupported` (SDR) per stream kind, `sdrInHdr` for 10-bit SDR frames
(whose repeats still show), `failed` once HDR's only size is dropped, and shows an HDR in-between image before
the new frame. On a Mac with
MetalFX (skipped in CI's VMs): the midpoint beats a cross-fade around the square by more than 1 dB, the sun's
core stays above 1000 nits, no NaN or infinity, 1080p under 12.5 ms, and 200 pairs make no shared event.

## Measurements

All measurements are on an M2 Pro, with a 1080p30 GTA VI clip recorded from the PS5 with the character
standing still and NPCs moving.

### Engines, offline (`psrp interpolate --truth`, 120 frames)

Truth mode drops every other frame, predicts each dropped frame from its neighbours, and compares the
prediction with the real frame (PSNR over RGB). Two baselines run alongside: repeating the previous frame,
and a plain cross-fade. Each line gives the mean over the frames, the worst frame, and the worst tile of a
16×9 grid over all frames. A fast, small object missing from a generated frame barely moves the mean or
even that frame's score, but sinks its tile (an idea from PushFPS):

```
PSNR against the real frame, dB: mean · worst frame · worst tile (16x9)
  engine            42.35 ·  36.76 ·  16.02
  repeat previous   34.76 ·  34.75 ·  13.18
  cross-fade        36.02 ·  36.01 ·  15.22
```

That is a synthetic clip, a 40 px square crossing a grey 1080p frame at 1800 px/s. The table below predates
the worst-frame and worst-tile scores and gives the means.

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

**Conclusion: VideoToolbox stays the engine** (for SDR streams; HDR ones need MetalFX, see "HDR"). On motion
all four engines land within 0.6 dB of each other, and all are 4 dB better than a cross-fade. MetalFX would
need about 8 ms of GPU per image, and the GPU is already busy with MetalFX upscaling in the default profile.
VideoToolbox leaves the GPU free. MetalFX's motion sources add nothing over zero motion here: MetalFX
refines motion itself, as MacNativeGames found. The media engine's block vectors even cost 3 dB on still
content. The MetalFX engines stay in the bench, in case a future case changes this (heavier camera motion,
or an Apple Silicon generation with GPU to spare).

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
shown 59.0/s · in-between 30.0/s · skipped 6 frames, 30 in-between · missed 0 pairs · delay 44.3 ms ·
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
generated per second (with the pairs missed per second), skipped frames per second (both over the last
5 s, amber from 3 missed or 1 skipped a second), and why a step that's on is idle. The dev
control port (`docs/dev-control.md`) reads the same numbers, and the pacing delay, from a script.

Unit tests (`swift test`) cover:

- the clock (jitter, real rate, sliding through a late stretch, a stall and its burst, restarts),
- the timeline,
- the delay planner,
- the size selector (including broken sizes),
- scene cuts,
- presentation counting (including Sidecar),
- empty-image detection,
- the lane (cuts, busy pairs, smaller sizes, SDR and HDR routing, the switch between them, 10-bit planes),
- an in-between image of a moving bar landing between its two positions, in SDR and in HDR,
- the HDR engine (see "HDR": the colour round trip, history, failures, and MetalFX itself on a Mac that has it).

## Code map

| What | Where |
|---|---|
| Clock, timeline, delay, size choice, scene cut | `Sources/StreamCore/FramePacing.swift` |
| The lane: queue, scaling, blend, empty check | `Sources/StreamCore/InterpolationLane.swift` |
| VideoToolbox wrapper, `helps`, VM check | `Sources/StreamCore/FrameInterpolation.swift` |
| HDR engine: MetalFX, PQ R'G'B' round trip | `Sources/StreamCore/HDRFrameInterpolation.swift` |
| Processor calls, quarantine, failure budget, retirement | `Sources/StreamCore/VideoProcessor.swift`, `Sources/CObjCCatch` |
| Pacing state, display, nextFrame, presentation counts | `Sources/StreamCore/StreamRenderer.swift` |
| Frame index from the engine | `StreamSession.swift`, `VideoDecoder.swift` |
| Stats to the app | `MacOSBridge.swift` (`sc_pacing_stats`, `sc_shown_fps`, `sc_interpolation_status`) → `apps/desktop/src-tauri/src/native.rs` → `RendererStatus` in `apps/desktop/src/core/schema.ts` |
| Bench | `Sources/psrp/Interpolate.swift`, `MetalFXBench.swift`, `Play.swift` |
| Setting rename (`smoothMotion` → `frameInterpolation`) | `apps/desktop/src/core/preferences.ts` (`renamedSettingKeys`) |

## Known limits and open questions

- **The shared-event fix isn't verified on a long console session yet.** The harness ran 20,000 calls of
  each path with no events left behind; an hour's stream with interpolation and ML upscaling on is the
  check that's left.
- **Not verified against the PS5 yet.** Everything above is from the bench, on purpose. The next check is a
  real 30 fps stream on a 60 Hz screen, then 60 fps on a 120 Hz one. At 60 fps the budget is 12.5 ms, so the
  lane should settle at 960×544.
- **The delay costs latency.** About 40–45 ms at 30 fps, by design: the in-between image can't exist
  before the next real frame does. The setting states it. For fast games, 60 fps without interpolation will
  feel more responsive.
- **The quality of the smaller sizes** (scaled down, interpolated, scaled up) hasn't been measured against
  the truth yet. MetalGoose reports the fast path as 3–7 dB further from the real frame than the slow one.
- **HDR frame generation isn't verified on the PS5 yet.** Everything in "HDR" is offscreen, on synthetic HDR
  frames. The check left: an HDR game with frame interpolation on (Silent Hill 2 on the XDR display), at 30
  fps on 60 and 120 Hz. On the synthetic scene, MetalFX with no motion given is level with a plain cross-fade
  over the whole frame at 1080p (and worse in its worst tile), under it below 1080p, and better around the fast
  object at every size; the repeat detector's thresholds were measured
  on SDR frames and are applied to PQ codes as they are.
- **The test clips** are a mostly still scene and a synthetic pan. Fast, uneven motion (a turning camera,
  explosions) is where every engine is weakest, and is not in the numbers above.
