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

The only engine today is `ChiakiEngine` (`Sources/StreamCore/ChiakiEngine.swift`), over libchiaki through the
C shim in `Sources/CChiaki`. `StreamSession`'s internal initialiser takes a `StreamEngineFactory`, which is how
tests run it on `FakeStreamEngine` (`Tests/StreamCoreTests/FakeStreamEngine.swift`) and how a second engine
(`PlayFXEngine`, on `packages/playfxprotocol`) will plug in.
