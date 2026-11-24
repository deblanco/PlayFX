import Foundation

// The seam between `StreamSession` and the Remote Play protocol. `StreamSession` keeps everything that isn't the
// protocol (video decode, audio playback, DualSense haptics on a USB pad, the pointer-as-touchpad merge, microphone
// capture, stats, event buffering) and talks to the console only through a `StreamEngine`; the engine talks back
// through the session's `StreamEngineSink`. libchiaki (`ChiakiEngine`) is the only engine for now.
//
// Lifetime, in order:
// 1. `StreamSession.init` builds a `StreamEngineConfig` and calls a `StreamEngineFactory` with it and itself as the
//    sink. The factory starts connecting in the background and returns at once (it never waits for the console);
//    it throws only when the session can't even start (bad configuration, no thread), with a user-facing message.
// 2. The engine calls the sink from its own threads while it runs, and sends commands to the console as the
//    session calls them.
// 3. The session calls `stop()` (when it's stopped, or deinitialised): the engine ends the session, waits for its
//    threads, and never calls the sink again.

/// What an engine needs to start a session: the console, its pairing keys and the stream asked for. Built by
/// `StreamSession` from `ConsoleCredentials` and `StreamSession.Options`; values are already checked and decoded.
struct StreamEngineConfig: Sendable {
    /// The pairing keys' sizes in bytes (the session refuses credentials whose keys aren't these sizes).
    static let registKeySize = 16
    static let rpKeySize = 16
    static let accountIDSize = 8

    /// The video codec the console is asked to encode with.
    enum Codec: Equatable, Sendable {
        case h264
        case hevc
        /// HEVC Main10 with HDR10 (PQ, BT.2020) when the game and the console allow it; plain HEVC otherwise.
        case hevcHDR
    }

    /// The console's IP address (IPv4 dotted or a host name) on the local network. Ignored when `remote` is set.
    var host: String
    /// A PS5 (true) or a PS4 (false).
    var ps5: Bool
    /// The registration key from pairing, `registKeySize` bytes (an ASCII hex string, zero-padded).
    var registKey: Data
    /// The RP key from pairing ("morning"), `rpKeySize` bytes.
    var rpKey: Data
    /// The PSN account ID, `accountIDSize` bytes.
    var accountID: Data
    /// The resolution asked for, as a height: 360, 540, 720 or 1080 (anything else: the largest of those at or
    /// below it, 360 at least).
    var height: Int
    /// Frames per second asked for: 30 or 60 (60 when ≥ 60, else 30).
    var fps: Int
    /// `.h264` whenever `ps5` is false (a PS4 only streams H.264); the session already makes sure of it.
    var codec: Codec
    /// The video bitrate asked for in kbit/s; 0 = the default for `height` and `fps`.
    var bitrateKbps: Int
    /// Whether the console may lower the resolution when the network can't keep up.
    var autoDowngrade: Bool
    /// Set to connect over the internet through PSN (PS5 only) instead of to `host`: a valid PSN OAuth token and
    /// the console's PSN device ID (64 hex characters). Setting up the route can take a minute; its steps arrive
    /// as `.remoteProgress` events and a failure as `.quit`, never as a throw from the factory (except for a
    /// PS4 or a device ID that isn't 64 hex characters, which throw "Internet play needs a PS5 and its PSN
    /// device ID").
    var remote: StreamSession.Remote?
}

/// Figures about the link that only the engine knows, polled by `StreamSession.stats` (about once a second).
struct StreamEngineStats: Equatable, Sendable {
    /// How long a missing video packet is waited for before it's skipped, and what that wait was learned from.
    /// Totals for the stream; all zero until the stream connects.
    struct Reorder: Equatable, Sendable {
        /// The wait now, in µs.
        var waitMicros = 0
        /// Holes in the packet sequence that filled while being waited for.
        var holesFilled = 0
        /// Packets that came after their hole had already been skipped.
        var latePackets = 0
        /// Skipped holes nothing ever came for.
        var holesLost = 0
        /// Holes skipped early because the reorder queue was full.
        var queueFullSkips = 0
    }

    /// Round trip to the console in µs (0 until measured; measuring it once while connecting is enough).
    var rttMicros = 0
    /// The bitrate the console's encoder aims for now, in bit/s, from its latest connection-quality report
    /// (0 before the first).
    var targetBitrate = 0
    var reorder = Reorder()
}

/// Starts an engine for `config` that reports to `sink` (see `StreamEngine` for what it must do). Throws
/// `ConsoleError.message` with a user-facing reason when it can't start at all.
typealias StreamEngineFactory = (_ config: StreamEngineConfig, _ sink: any StreamEngineSink) throws -> any StreamEngine

/// One Remote Play session with a console, as `StreamSession` drives it: the protocol, and nothing else (no
/// decoding, no playback, no devices).
///
/// **Ownership.** `StreamSession` owns the engine. The engine must not keep its sink alive (`unowned(unsafe)` or
/// an unretained reference: the sink owns the engine). The sink stays valid until `stop()` returns, including
/// while `stop()` runs from the session's `deinit`, where a `weak` reference would already read nil.
///
/// **Commands** (everything but `stop()`): called from any thread, possibly concurrently (the session doesn't
/// serialise them all: microphone frames come from Core Audio's thread), so the engine serialises what it must.
/// Each returns quickly (no waiting on the network). Before the connection is up they're dropped (or kept and
/// sent once it is: the session doesn't rely on either); after `stop()` they do nothing and must not crash.
protocol StreamEngine: AnyObject {
    /// The pad's whole state, sent to the console as soon as possible (the session calls this on every change of
    /// a pad, the keyboard-as-pad or the pointer-as-touchpad; it doesn't repeat an unchanged state, so an engine
    /// that has to send periodically keeps the last one). Fields:
    /// - `buttons`: bits, 1 = held: cross 1<<0, circle 1<<1, square 1<<2, triangle 1<<3, d-pad left 1<<4,
    ///   right 1<<5, up 1<<6, down 1<<7, L1 1<<8, R1 1<<9, L3 1<<10, R3 1<<11, options 1<<12, share/create 1<<13,
    ///   touchpad click 1<<14, PS 1<<15 (`ControllerState.buttonNames` names them).
    /// - `l2`, `r2`: 0 (released) … 255 (fully pressed).
    /// - `leftX/leftY/rightX/rightY`: the full `Int16` range, centre 0; +x is right, +y is **down**.
    /// - `touches`: up to 2 fingers (more are ignored), x and y from the touchpad's top-left, 0…1 (clamp values
    ///   outside), mapped onto the console's touchpad; `id` 0…127 stays the same while a finger is down (only
    ///   its low 7 bits count). A slot with no finger is "not touching".
    /// - `motion`: nil = no motion sensors (send the pad at rest, upright). Else the gyro in rad/s, the
    ///   accelerometer in g with gravity included, and the reading's time in µs (a monotonic clock that wraps at
    ///   2^32); the engine derives the pad's orientation from successive readings if the protocol needs it.
    func setController(_ state: ControllerState)
    /// Answers `.loginPinRequested`: the console's login passcode, as typed (digits).
    func setLoginPin(_ pin: String)
    /// Turns voice chat from this Mac on or off. The first `true` sets up the microphone stream with the console;
    /// `false` mutes it. The session turns it on right after capture has started, and stops capture before it
    /// turns it off.
    func setMicrophone(_ on: Bool)
    /// 10 ms of microphone audio: 48 kHz, stereo, signed 16-bit, interleaved (L, R, L, R…): exactly 480 frames, so
    /// `samples.count` is 960. Encode and send it (the console expects Opus). Called about 100 times a second on
    /// Core Audio's capture thread, never after `stop()`. The first frames can arrive just before
    /// `setMicrophone(true)` (capture starts first): drop frames while the microphone is off. `samples` is valid
    /// only during the call.
    func sendMicrophoneFrame(_ samples: UnsafeBufferPointer<Int16>)
    /// Replaces the whole text of the console's focused text field (after `.keyboard(.open, …)`).
    func setKeyboardText(_ text: String)
    /// Closes the console's text keyboard: `accept` true = Return (submit the text), false = Escape (cancel).
    func finishKeyboard(accept: Bool)
    /// Asks the console for a key frame (IDR) now, e.g. after the app's own decoder was reset.
    func requestKeyFrame()
    /// Puts the console into rest mode. The console ends the session soon after, which arrives as `.quit`.
    func goToBed()
    /// The link's figures now: cheap, from any thread; all zero before they're known, and after `stop()`.
    func stats() -> StreamEngineStats
    /// Ends the session and returns only when every thread of the engine has finished: **no sink call starts
    /// after it returns, and none is still running**. If the session hadn't ended yet, its `.quit(kind: .stopped,
    /// error: false)` is delivered before it returns. Called from any thread (the main thread, or the session's
    /// `deinit`), at most once by the session (a second call must do nothing); it may block (up to a few
    /// seconds while a connection attempt is cancelled), and may run while sink calls are in flight on the
    /// engine's threads, so the engine must not hold a lock its own sink calls need while it waits for them.
    func stop()
}

/// What the engine hands back to the session: implemented by `StreamSession`.
///
/// **Threads.** The engine calls these from threads it owns: never on the main thread, and never synchronously
/// from inside a command, `stop()` or the factory (the app's event handler may call commands back). Calls of one
/// kind come from one thread at a time and in stream order: video calls never overlap each other, nor do audio
/// calls (format and PCM) or haptics calls; different kinds may run concurrently. Nothing is called after `stop()` returns.
///
/// **Blocking.** The calls return quickly (video hands the unit to an asynchronous decoder; the rest copy into
/// buffers), but `deliver` runs the app's event handler, which may take a lock or dispatch: don't hold a lock
/// that a command or `stop()` takes while calling it.
///
/// **Pointers** passed in are valid only during the call; the session copies what it keeps.
protocol StreamEngineSink: AnyObject {
    /// One complete video access unit (one frame) in Annex-B form: NAL units, each after a 00 00 00 01 or
    /// 00 00 01 start code, with the parameter sets (VPS for HEVC, SPS, PPS) in front of every key frame, in the
    /// codec of `StreamEngineConfig.codec`. `framesLost`: how many frames were lost between the previous unit and
    /// this one (≥ 0; 0 when none): the session numbers frames with it, for pacing. Pass only complete units; a
    /// frame lost beyond repair isn't passed on, the next unit's `framesLost` counts it. Returns false when the
    /// decoder couldn't decode this unit or one before it (it decodes asynchronously): the engine should then ask
    /// the console for a key frame (as `requestKeyFrame()` does), without flooding it (one request until a key
    /// frame arrives is enough).
    func handleVideo(_ accessUnit: UnsafeRawBufferPointer, framesLost: Int) -> Bool
    /// The game audio's format: the number of channels (2 on today's consoles) and the sample rate in Hz (48000).
    /// Called before the first `handleAudio`; again only when the console announces a format again (each call
    /// rebuilds the audio output, so don't repeat it for nothing).
    func handleAudioFormat(channels: Int, sampleRate: Int)
    /// Decoded game audio: signed 16-bit PCM, interleaved, `frames` frames of the last `handleAudioFormat`'s
    /// channels (so `frames × channels` values at `samples`). Called as each packet is decoded (Opus: typically
    /// 480 frames, 10 ms); a lost packet may simply be missing.
    func handleAudio(_ samples: UnsafePointer<Int16>, frames: Int)
    /// One frame of the DualSense haptics stream (PS5 only) as it arrives: signed 16-bit PCM at 3000 Hz, stereo
    /// interleaved, left motor then right motor, so `samples.count` is twice the frame count (always even, never
    /// 0). Returns true when it was played on a DualSense connected by USB. When it returns false the engine
    /// turns the stream into rumble itself and sends it as `deliver(.hapticRumble(left:right:))`: each motor's
    /// strength 0…255, rising with that channel's average loudness (0 for near-silence, 255 at full scale). Send a
    /// new value as soon as it changes, and repeat an unchanged non-zero value about every 50 ms (not more often)
    /// while haptics frames keep coming: the console sends nothing once an effect is over, so the app ends the
    /// rumble when the events stop. They stop with the haptics, and with the session.
    func handleHaptics(_ samples: UnsafeBufferPointer<Int16>) -> Bool
    /// The DualSense adaptive-trigger effects the game sets (PS5), for L2 and R2, in the controller's own format:
    /// a mode byte and its 10 parameter bytes per trigger (`TriggerEffect(mode:parameters:)` decodes them; mode 0x05
    /// = off). Sent whenever the game changes them.
    func handleTriggerEffects(_ leftMode: UInt8, _ left: [UInt8], _ rightMode: UInt8, _ right: [UInt8])
    /// Everything else the session reports, as `StreamSession.Event` (trigger effects come through
    /// `handleTriggerEffects` instead). May be called from more than one of the engine's threads; events from one
    /// thread keep their order. The session keeps events until the app sets its handler, so they may come
    /// before the factory has returned. What each means and when it's sent:
    /// - `.remoteProgress(stage)` (internet play only): `.linking` as PSN setup starts, `.data` as the data
    ///   connection is being opened, `.connected` once it's open; in that order, and before the stream's own
    ///   `.connected` event.
    /// - `.loginPinRequested(incorrect:)`: the console wants its login passcode before streaming (answer with
    ///   `setLoginPin`); `incorrect` true when it's asking again after a wrong one.
    /// - `.connected`: exactly once, when the stream itself is up (the console accepted the session and the
    ///   stream's handshake finished, so video can start); never after `.quit`. The app shows the stream and
    ///   counts the attempt as a success from here.
    /// - `.quit(reason:error:kind:)`: exactly once per session that started (including one that never
    ///   connected), and the last event. `reason` is user-facing text (shown, and logged). `error` says whether it
    ///   ended in failure (always false for `.stopped`). `kind` says what to do next:
    ///   - `.stopped`: this client ended it (`stop()`).
    ///   - `.busy`: the console refused because Remote Play is still in use (it is for about 9 s after a session
    ///     ends): the app retries soon.
    ///   - `.dropped`: the connection was lost mid-stream with no reason from the console (stream or control
    ///     connection timed out or failed): the app reconnects.
    ///   - `.final`: anything else, not retried: the console ended it on purpose (rest mode, another device took
    ///     over, it disconnected with a reason), refused it (wrong keys, versions), the connection couldn't be
    ///     made at all, or internet setup failed.
    /// - `.rumble(left:right:)`: the console's classic rumble, 0…255 per motor (left = low frequency, right =
    ///   high); it lasts until the next one.
    /// - `.hapticRumble(left:right:)`: see `handleHaptics`.
    /// - `.light(red:green:blue:)`: the light-bar colour the game asks for.
    /// - `.playerIndex(n)`: the pad's player number as the console counts it (0 = player 1).
    /// - `.nickname(name)`: the console's name, when it tells it.
    /// - `.keyboard(change, text:)`: the console's text keyboard: `.open` when a text field is focused (with its
    ///   current text), `.change` when the console changed the text (with the new text), `.close` when the
    ///   console closed it itself (the text then carries nothing the session uses).
    func deliver(_ event: StreamSession.Event)
}

extension ControllerState {
    /// The touchpad click in `buttons` (see `StreamEngine.setController` for every bit).
    static let touchpadButton: UInt32 = 1 << 14
}
