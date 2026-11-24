# StreamCore

The Swift package behind PlayFX's streaming: a Remote Play session, VideoToolbox decode, Metal and MetalFX
upscaling, audio, controller input, and the `psrp` CLI for headless debugging. See the repo's README for
building, testing (`scripts/coverage.sh`) and debugging with `psrp`.

## Protocol engine

`StreamSession` doesn't speak the Remote Play protocol itself: it drives a `StreamEngine` and receives the
stream through `StreamEngineSink`, both declared in
[`Sources/StreamCore/StreamEngine.swift`](Sources/StreamCore/StreamEngine.swift). Their doc comments are the
whole contract (formats, units, threads, lifetimes, how each ending maps to a `QuitKind`). The session keeps
everything else: the decoder, the audio player, DualSense haptics on a USB pad, the pointer-as-touchpad merge,
microphone capture, stats and event buffering.

There are two engines: `ChiakiEngine` (`Sources/StreamCore/ChiakiEngine.swift`), over libchiaki through the C shim
in `Sources/CChiaki`, the default; and `PlayFXEngine`, on PlayFX's own `packages/playfxprotocol` (below).
`StreamSession.Options.engine` (`"chiaki"` by default, `"playfx"`; JSON without it decodes as `"chiaki"`) picks one in
the public initialiser, and internet play (`remote`) always uses libchiaki. `StreamSession`'s internal initialiser
takes a `StreamEngineFactory`, which is how tests run it on `FakeStreamEngine`
(`Tests/StreamCoreTests/FakeStreamEngine.swift`) or on `PlayFXEngine` against a fake console.

## PlayFX engine

`PlayFXEngine` (`Sources/StreamCore/PlayFXEngine*.swift`) implements `StreamEngine` on PlayFXProtocol's `StreamSession`.
It's opted into with `options.engine = "playfx"`; nothing else about a session changes.

**Supported:** everything in the contract on the local network: video (with the parameter sets in front of each key
frame, and a key frame asked for once when the decoder refuses a unit), game audio decoded with libopus (lost frames
concealed with libopus's packet-loss concealment, a gap too long to conceal resets the decoder), haptics, adaptive-trigger
effects, rumble, light bar, player index, the login PIN (with the "incorrect" flag), the text keyboard's events and
commands, microphone voice chat, rest mode, stats, and the quit kinds (busy, dropped, stopped, final).

**Not supported:**
- Internet play: the factory throws "Internet play isn't available with the PlayFX engine yet" (`StreamSession` never
  asks for it: it uses libchiaki whenever `remote` is set).
- PIN-less pairing and registration: pairing stays with `Console` / libchiaki; the engine only streams.
- The console's nickname: PlayFXProtocol doesn't carry it, so `.nickname` is never sent.
- The text keyboard's enabling handshake: a PS5 ends the stream when it gets it (ctrl.md section 6.5), so the engine
  doesn't send it and keyboard events may not come until the right handshake is known; `setKeyboardText` and
  `finishKeyboard` are sent anyway.
- `autoDowngrade == false` on a PS5: the launch spec always asks for `adaptiveStreamMode: "resize"` on a PS5 and
  docs/protocol/stream.md defines no value or omission for "never resize", so with this engine a PS5 may always step the
  resolution down when the network can't keep up (the flag only reaches the library's base-PS4 rule). Spec request: what
  the launch spec says for "don't resize".
- The account ID in the config isn't used (the stream's keys are the registration and RP keys). A PS4 is streamed as
  Remote Play version 10 (the config doesn't say which one it is).

**Defaults chosen.** Resolution is the largest of 360/540/720/1080 at or below `height`; 60 fps from 60 up, else 30;
`bitrate` 0 is the library's preset for the resolution (2000, 6000, 10000, 15000 kbit/s at 360, 540, 720, 1080 p, at
either frame rate); `autoDowngrade` goes to the library (it lowers a base PS4's 1080p to 720p); a PS4 always gets H.264.
Voice chat: `setMicrophone(false)` before any `true` does nothing; `true` before the stream is up is applied when it is;
the engine counts the microphone as on only once the console was told. The microphone is announced to the console when the
stream starts, so voice chat can be turned on later (PlayFXProtocol
only sends that announcement at the start; whether a console needs it is for a hardware round).

**Stats.** `rttMicros` is the probe's round trip (0 when the probe failed), `targetBitrate` the console's latest
connection-quality report in bit/s, and the reorder figures are the library's, refreshed once a second (they are totals
as of the last statistics event).

**Haptic rumble** (when `handleHaptics` returns false). Each 10 ms haptics frame gives a strength per motor from that
channel's loudness: `rms * sqrt(2) / 32768` (1.0 for a full-scale sine, at most 1), 0 below 0.004 (about -48 dBFS, near
silence), otherwise `255 * sqrt(loudness)`, rounded to one of 64 levels so a wobbling waveform doesn't make an event per
frame. A strength that differs from the last one is sent at once as `.hapticRumble`; an unchanged non-zero one is repeated
every 50 ms while frames keep coming; silence sends (0, 0) once. Nothing is sent when the haptics stop. A frame played on a
pad makes the next one start afresh. See `PlayFXHapticRumble`.

**Threads and stopping.** The library's receive thread calls the sink for video, audio, haptics and `.connected`; its
serial queue for everything else; the engine passes them straight through, inside a gate (`PlayFXSinkGate`) that `stop()`
closes and then waits on (excluding the caller's own call, so `stop()` from inside a sink callback works: it holds the
`.quit(.stopped)` until that thread's outermost sink call has returned, delivers it from there, and doesn't wait for the
library; the gate's depth is per gate, so being inside another engine's call doesn't count). `stop()` delivers `.quit(.stopped)` before returning unless
the session already quit, waits up to 5 s each for in-flight sink calls, the quit's delivery, a connection attempt to wind down and the library's
`ended` (logging when one runs out), and does nothing the second time. `StreamSession.stop()` takes the engine out under
its lock and stops it outside it, so an app handler may call commands or `stop()` while it runs. A start that fails is a `.quit`: busy is `.busy`, anything else `.final` (a connection that was
never made isn't "dropped").

**Opus.** libopus is the static one libchiaki brings. `Sources/COpus` declares the few libopus calls the engine makes
(Swift can't call the variadic `opus_encoder_ctl`) and links nothing of its own, so the build needs no pkg-config and can't
pick up a second, dynamic libopus. The decode path allocates nothing per packet (one PCM buffer per audio header); the
microphone path allocates one 40-byte array per packet because the library's API takes an array (and its packetiser and
Takion send allocate the 120-byte payload anyway, so a buffer overload alone wouldn't remove the allocation).

**Tests.** `Tests/StreamCoreTests/PlayFXEngine*Tests.swift` run the engine over loopback against PlayFXProtocol's fake
console (`PlayFXProtocolTestSupport`, a test-only product of `packages/playfxprotocol`; it imports the library with
`@testable`, so it builds in debug or with `-Xswiftc -enable-testing`).
