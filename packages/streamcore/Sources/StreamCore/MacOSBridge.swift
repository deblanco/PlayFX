#if os(macOS)
import os
import AppKit

// C ABI for the Tauri (Rust) host. JSON in/out keeps the boundary small.
// - Functions marked (main) must be called on the main thread.
// - Functions marked (blocking) must NOT be called on the main thread.
// - Returned strings are malloc'd; release them with sc_free.
// iOS (Expo module) will use the Swift API (StreamRenderer, StreamSession, Console) directly.

private(set) var renderer: StreamRenderer? // internal for tests
private(set) var session: StreamSession? // internal for tests
/// Held while a session runs, so neither the Mac nor its display sleeps mid-game.
private var awakeActivity: NSObjectProtocol?
var keepingAwake: Bool { awakeActivity != nil } // for tests

private func keepAwake(_ on: Bool) {
    if on, awakeActivity == nil {
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Streaming from a PlayStation")
    } else if !on, let activity = awakeActivity {
        ProcessInfo.processInfo.endActivity(activity)
        awakeActivity = nil
    }
}
private var input: ControllerInput?
private var rumble: Rumble?
private var triggers: AdaptiveTriggers?
private var light: PadLight?
/// Watches the Mac's network while a session runs; a change becomes a "network" event for the host.
private var networkWatch: NetworkWatch?
private var eventCallback: (@convention(c) (UnsafePointer<CChar>) -> Void)?
nonisolated(unsafe) private var logCallback: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void)?

private func cString(_ s: String) -> UnsafeMutablePointer<CChar> { strdup(s)! }

private func json(_ object: Any) -> UnsafeMutablePointer<CChar> {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return cString(String(decoding: data, as: UTF8.self))
}

private func json<T: Encodable>(encodable value: T) -> UnsafeMutablePointer<CChar> {
    cString(String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self))
}

private func failure(_ message: String) -> UnsafeMutablePointer<CChar> { json(["error": message]) }

private func decode<T: Decodable>(_ type: T.Type, _ s: UnsafePointer<CChar>) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(String(cString: s).utf8))
}

private func emit(_ object: [String: Any]) {
    guard let cb = eventCallback, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    String(decoding: data, as: UTF8.self).withCString { cb($0) }
}

@_cdecl("sc_free")
public func sc_free(_ p: UnsafeMutablePointer<CChar>?) { free(p) }

/// Receives session events as JSON: {"type":"connected"} | {"type":"remoteProgress","stage":"linking"|"data"|"connected"} | {"type":"quit","reason":..,"error":bool,"kind":"final"|"busy"|"dropped"|"stopped"} |
/// {"type":"loginPin","incorrect":bool} | {"type":"nickname","name":..}. Called from any thread.
@_cdecl("sc_set_event_callback")
public func sc_set_event_callback(_ cb: (@convention(c) (UnsafePointer<CChar>) -> Void)?) {
    eventCallback = cb
}

/// Log entries for the host (its log file): level (0 debug … 3 error), area, scrubbed message. Called
/// from any thread. `detailed` adds debug entries, including libchiaki's verbose ones.
@_cdecl("sc_set_log_callback")
public func sc_set_log_callback(_ cb: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void)?,
                                _ detailed: Bool) {
    logCallback = cb
    let sink: Log.Sink? = cb.map { callback in
        { entry in
            entry.area.rawValue.withCString { area in
                entry.message.withCString { message in callback(Int32(entry.level.rawValue), area, message) }
            }
        }
    }
    Log.configure(detailed: detailed, sink: sink)
}

/// Switches detailed logs on or off, keeping the host's callback.
@_cdecl("sc_set_log_detailed")
public func sc_set_log_detailed(_ detailed: Bool) {
    sc_set_log_callback(logCallback, detailed)
}

// MARK: Renderer (main)

/// Embeds the stream view at the bottom of the window's content view, i.e. behind the
/// (transparent) webview, so the web UI can overlay the video.
@_cdecl("sc_attach_macos_window")
public func sc_attach_macos_window(_ nsWindow: UnsafeMutableRawPointer) -> Bool {
    let window = Unmanaged<NSWindow>.fromOpaque(nsWindow).takeUnretainedValue()
    guard renderer == nil, let content = window.contentView, let r = StreamRenderer() else { return false }
    r.view.frame = content.bounds
    r.view.autoresizingMask = [.width, .height]
    content.addSubview(r.view, positioned: .below, relativeTo: nil)
    renderer = r
    return true
}

/// `params`: RenderParams JSON ({"upscaler":"metalfx","sharpness":0.3,"compare":false}; missing keys
/// keep their defaults). Returns false (and changes nothing) when it doesn't decode.
@_cdecl("sc_set_render_params")
public func sc_set_render_params(_ params: UnsafePointer<CChar>) -> Bool {
    guard let p = try? decode(RenderParams.self, params) else { return false }
    renderer?.params = p
    return true
}

@_cdecl("sc_metalfx_supported")
public func sc_metalfx_supported() -> Bool {
    renderer?.metalFXSupported ?? false
}

/// Smoothed GPU time per rendered frame in milliseconds (0 = no renderer or no frame yet).
@_cdecl("sc_gpu_milliseconds")
public func sc_gpu_milliseconds() -> Double {
    renderer?.gpuMilliseconds ?? 0
}

/// Whether Apple's ML super-resolution can run here (macOS 26+, supported Mac).
@_cdecl("sc_ml_supported")
public func sc_ml_supported() -> Bool {
    renderer?.mlSupported ?? false
}

/// Whether the last frame went through ML super-resolution.
@_cdecl("sc_ml_active")
public func sc_ml_active() -> Bool {
    renderer?.mlActive ?? false
}

/// Time from a decoded frame arriving to it being on screen, smoothed (ms; 0 until measured).
@_cdecl("sc_display_milliseconds")
public func sc_display_milliseconds() -> Double {
    renderer?.displayMilliseconds ?? 0
}

/// New images put on screen per second (stream frames plus Frame interpolation's in-between frames; 0 when idle).
@_cdecl("sc_shown_fps")
public func sc_shown_fps() -> Double {
    renderer?.shownFramesPerSecond ?? 0
}

/// Frame pacing: in-between images presented per second, frames and in-between images never shown (a
/// later one was due first), pairs that got no in-between images (the lane was busy, or the size gave
/// nothing), and how far behind the stream clock images show (ms). All counts are totals for the stream.
/// Also what the optional picture steps are doing and why an idle one is idle (`PipelineState`), with the
/// screen's refresh rate and the stream's frame rate.
@_cdecl("sc_pacing_stats")
public func sc_pacing_stats() -> UnsafeMutablePointer<CChar> {
    let pipeline = renderer?.pipeline ?? PipelineState()
    let stats: [String: Any] = [
        "interpolation": pipeline.interpolation.rawValue,
        "upscale": pipeline.upscale.rawValue,
        "ml": pipeline.ml.rawValue,
        "displayHz": pipeline.displayHz,
        "streamFps": pipeline.streamFps,
        "gameFps": pipeline.gameFps,
        "repeatedFrames": renderer?.repeatedFrames ?? 0,
        "generatedFps": renderer?.generatedFramesPerSecond ?? 0,
        "skippedFrames": renderer?.skippedFrames ?? 0,
        "skippedGenerated": renderer?.skippedGenerated ?? 0,
        "missedInterpolations": renderer?.missedInterpolations ?? 0,
        "delayMs": renderer?.pacingDelayMilliseconds ?? 0,
        "latenessMs": renderer?.pacingParts.latenessMs ?? 0,
        "costMs": renderer?.pacingParts.costMs ?? 0,
        "clockRestarts": renderer?.pacingParts.restarts ?? 0,
        "size": renderer?.interpolationSize.map { "\($0.width)x\($0.height)" } ?? "",
    ]
    return json(stats)
}

/// AirDrop and Handoff's peer-to-peer Wi-Fi (AWDL): {"state": "absent" | "active" | "off" | "paused"}.
@_cdecl("sc_peer_wifi_status")
public func sc_peer_wifi_status() -> UnsafeMutablePointer<CChar> {
    json(["state": PeerWifi.state.rawValue])
}

/// Pauses AWDL (asking for the administrator password) or lets it back. Blocks while the password prompt is
/// open, so not on the main thread. {"state", "outcome": "done" | "cancelled"}, or {"error"}.
@_cdecl("sc_peer_wifi_set_paused")
public func sc_peer_wifi_set_paused(_ paused: Bool) -> UnsafeMutablePointer<CChar> {
    guard paused else { return json(["state": PeerWifi.resume().rawValue, "outcome": "done"]) }
    switch PeerWifi.pause() {
    case .done: return json(["state": PeerWifi.state.rawValue, "outcome": "done"])
    case .cancelled: return json(["state": PeerWifi.state.rawValue, "outcome": "cancelled"])
    case .failed(let message):
        Log.warning(.session, "Couldn't pause AirDrop and Handoff: \(message)")
        return failure("Couldn't pause AirDrop and Handoff: \(message)")
    }
}

/// Whether HDR10 frames are on screen (EDR output).
@_cdecl("sc_hdr_active")
public func sc_hdr_active() -> Bool {
    renderer?.hdrActive ?? false
}

/// Whether frame interpolation ("Frame interpolation") can run here (macOS 26+, supported Mac).
@_cdecl("sc_smooth_supported")
public func sc_smooth_supported() -> Bool {
    renderer?.interpolationSupported ?? false
}

/// Whether the last stream frame was preceded by an interpolated one.
@_cdecl("sc_smooth_active")
public func sc_smooth_active() -> Bool {
    renderer?.interpolationActive ?? false
}

/// Upscaler used for the last frame: 0 = bilinear, 1 = MetalFX, -1 = no renderer.
@_cdecl("sc_active_mode")
public func sc_active_mode() -> Int32 {
    renderer?.activeMode.rawValue ?? -1
}

// MARK: Consoles (blocking)

@_cdecl("sc_discover")
public func sc_discover(_ timeoutMs: Int32) -> UnsafeMutablePointer<CChar> {
    json(encodable: Console.discover(timeout: Double(timeoutMs) / 1000))
}

/// Asks one console directly at `host` (an IP), for when broadcast discovery can't reach it.
@_cdecl("sc_discover_host")
public func sc_discover_host(_ host: UnsafePointer<CChar>, _ timeoutMs: Int32) -> UnsafeMutablePointer<CChar> {
    json(encodable: Console.discover(host: String(cString: host), timeout: Double(timeoutMs) / 1000))
}

/// `request`: {"address","ps5","accountId","pin"} → ConsoleCredentials JSON or {"error"}.
@_cdecl("sc_register")
public func sc_register(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    struct Request: Decodable { let address: String; let ps5: Bool; let accountId: String; let pin: String }
    do {
        let r = try decode(Request.self, request)
        return json(encodable: try Console.register(address: r.address, ps5: r.ps5, accountId: r.accountId, pin: r.pin))
    } catch { return failure(error.localizedDescription) }
}

@_cdecl("sc_wakeup")
public func sc_wakeup(_ credentials: UnsafePointer<CChar>) -> Bool {
    guard let c = try? decode(ConsoleCredentials.self, credentials) else { return false }
    return Console.wakeup(c)
}

@_cdecl("sc_psn_login_url")
public func sc_psn_login_url() -> UnsafeMutablePointer<CChar> { cString(PSNAuth.loginURL.absoluteString) }

@_cdecl("sc_psn_redirect_url")
public func sc_psn_redirect_url() -> UnsafeMutablePointer<CChar> { cString(PSNAuth.redirectURL) }

/// Runs async work from a blocking C entry point: its result, or `timedOut` after `timeout` seconds, when
/// the work is cancelled so it can't finish later behind the caller's back (a sign-in that "timed out" then
/// saving tokens anyway). The result is kept behind a lock: the work finishes on another thread.
func blocking<T: Sendable>(timeout: TimeInterval = 30, timedOut: String,
                           _ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let result = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    let task = Task.detached {
        let outcome: Result<T, Error>
        do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
        result.withLock { if $0 == nil { $0 = outcome } }
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        task.cancel()
        result.withLock { if $0 == nil { $0 = .failure(ConsoleError.message(timedOut)) } }
    }
    return result.withLock { $0 ?? .failure(ConsoleError.message(timedOut)) }
}

/// sc_psn_account_id's reason when PSN doesn't answer. The app says "PSN sign-in failed:" before it.
let psnSignInTimedOut = "PlayStation Network didn't answer in time"

/// `redirect`: the redirect URL containing ?code=… → {"accountId"} or {"error"}.
@_cdecl("sc_psn_account_id")
public func sc_psn_account_id(_ redirect: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    guard let code = PSNAuth.code(fromRedirect: String(cString: redirect)) else { return failure("No sign-in code in URL") }
    // Also keeps the tokens (Keychain) for playing over the internet.
    switch blocking(timedOut: psnSignInTimedOut, { try await PSNAccount.shared.signIn(code: code) }) {
    case .success(let id): return json(["accountId": id])
    case .failure(let e): return failure(e.localizedDescription)
    }
}

/// Whether PSN tokens are kept (internet play is possible).
@_cdecl("sc_psn_signed_in")
public func sc_psn_signed_in() -> Bool { PSNAccount.shared.signedIn }

/// Blocking. The PS5s on the PSN account → [{"name","duid","remotePlay"}] or {"error"}.
@_cdecl("sc_psn_consoles")
public func sc_psn_consoles() -> UnsafeMutablePointer<CChar> {
    switch blocking(timedOut: "PSN didn't answer", { try await PSNAccount.shared.consoles() }) {
    case .success(let consoles): return json(encodable: consoles)
    case .failure(let e): return failure(e.localizedDescription)
    }
}

/// Blocking. A PSN access token valid for at least a minute (refreshed if needed) → {"token"} or {"error"}.
/// For the host to hand straight back in sc_session_start's "remote"; never shown to the web UI.
@_cdecl("sc_psn_access_token")
public func sc_psn_access_token() -> UnsafeMutablePointer<CChar> {
    switch blocking(timedOut: "PSN didn't answer", { try await PSNAccount.shared.validAccessToken() }) {
    case .success(let token): return json(["token": token])
    case .failure(let e): return failure(e.localizedDescription)
    }
}

/// Forgets the PSN tokens.
@_cdecl("sc_psn_sign_out")
public func sc_psn_sign_out() { PSNAccount.shared.signOut() }

// MARK: Session (main)

/// The session whose events reach the host; 0 while there is none. A replaced or stopped session keeps
/// reporting while it winds down (its "Stopped" quit, a late "connected"), and the host took those for the
/// current session's: it ended a new stream because the one it replaced had quit.
private let reporting = OSAllocatedUnfairLock(initialState: (current: UInt64(0), last: UInt64(0)))

/// `request`: {"credentials": ConsoleCredentials, "options": StreamSession.Options} → {"ok":true} or {"error"}.
@_cdecl("sc_session_start")
public func sc_session_start(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    struct Remote: Decodable { let token: String; let duid: String }
    struct Request: Decodable { let credentials: ConsoleCredentials; let options: StreamSession.Options?; let remote: Remote? }
    endSession(idle: false) // the new session replaces it; no idle pattern in between
    do {
        let r = try decode(Request.self, request)
        let s = try StreamSession(credentials: r.credentials, options: r.options ?? StreamSession.Options(),
                                  remote: r.remote.map { StreamSession.Remote(token: $0.token, duid: $0.duid) })
        renderer?.streamFrameRate = Double((r.options ?? StreamSession.Options()).fps)
        s.onFrame = { frame, index in renderer?.display(frame, index: index) }
        let haptics = Rumble()
        let adaptive = AdaptiveTriggers()
        let padLight = PadLight()
        let number = reporting.withLock { state in
            state.last += 1
            state.current = state.last
            return state.last
        }
        s.onEvent = { [weak s] event in
            if case .rumble(let left, let right) = event { haptics.apply(left: left, right: right) }
            if case .hapticRumble(let left, let right) = event { haptics.applyHaptics(left: left, right: right) }
            if case .triggerEffects(let left, let right) = event { adaptive.apply(left: left, right: right) }
            if case .light(let red, let green, let blue) = event { padLight.setColor(red: red, green: green, blue: blue) }
            if case .playerIndex(let index) = event { padLight.setPlayer(index) }
            if let payload = eventPayload(event), reporting.withLock({ $0.current == number }) { emit(payload) }
            // Clean up after a quit, unless the host has already moved on to another session. The last
            // frame stays up: the host may reconnect (busy console, dropped stream) or go home.
            if case .quit = event {
                DispatchQueue.main.async {
                    if let s { cleanUpAfterQuit(of: s) }
                }
            }
        }
        let i = ControllerInput()
        i.onChange = { [weak s] state in s?.setController(state) }
        session = s
        input = i
        rumble = haptics
        triggers = adaptive
        light = padLight
        networkWatch = NetworkWatch { change in emit(networkPayload(change)) }
        // The backdrop keeps moving until the first frame arrives (connecting can take a while).
        keepAwake(true)
        return json(["ok": true])
    } catch { return failure(error.localizedDescription) }
}

/// JSON sent to the host for a session event (nil for events the host doesn't get).
func eventPayload(_ event: StreamSession.Event) -> [String: Any]? {
    switch event {
    case .connected: return ["type": "connected"]
    case .remoteProgress(let stage): return ["type": "remoteProgress", "stage": stage.rawValue]
    case .quit(let reason, let isError, let kind): return ["type": "quit", "reason": reason, "error": isError, "kind": kind.rawValue]
    case .loginPinRequested(let incorrect): return ["type": "loginPin", "incorrect": incorrect]
    case .nickname(let name): return ["type": "nickname", "name": name]
    case .keyboard(let change, let text): return ["type": "keyboard", "change": change.rawValue, "text": text]
    case .rumble, .hapticRumble, .triggerEffects, .light, .playerIndex: return nil
    }
}

/// `online: true` when the Mac is on a (different) network again, so the stream should reconnect.
func networkPayload(_ change: NetworkWatch.Change) -> [String: Any] {
    ["type": "network", "online": change == .changed]
}

/// The app's secrets (pairing keys, account ID): Keychain in release builds, a 0600 file in development.
/// Replies `{"value": "…"}` or `{"value": null}`.
/// The Mac's sound outputs: [{"uid", "name"}].
@_cdecl("sc_audio_devices")
public func sc_audio_devices() -> UnsafeMutablePointer<CChar> {
    let devices = AudioOutput.devices().map { ["uid": $0.uid, "name": $0.name] }
    return json(devices)
}

/// Sound volume (0–1) and output device ({"volume", "deviceUID"?}; no UID = the system default), for the
/// playing stream and later ones.
@_cdecl("sc_set_audio_output")
public func sc_set_audio_output(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    do {
        let output = try decode(AudioOutput.self, request)
        AudioOutput.current = AudioOutput(volume: output.volume, deviceUID: output.deviceUID)
        session?.applyAudioOutput(AudioOutput.current)
        return json(["ok": true])
    } catch { return failure(error.localizedDescription) }
}

@_cdecl("sc_secret_get")
public func sc_secret_get(_ key: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    let value = SecretStores.shared.get(String(cString: key))
    return json(["value": value.map { $0 as Any } ?? NSNull()])
}

@_cdecl("sc_secret_set")
public func sc_secret_set(_ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    do {
        try SecretStores.shared.set(String(cString: key), String(cString: value))
        return json(["ok": true])
    } catch { return failure(error.localizedDescription) }
}

@_cdecl("sc_secret_remove")
public func sc_secret_remove(_ key: UnsafePointer<CChar>) {
    SecretStores.shared.remove(String(cString: key))
}

/// Puts the console in rest mode; it then ends the session itself. No-op without a session.
@_cdecl("sc_session_sleep")
public func sc_session_sleep() {
    session?.sleepConsole()
}

/// The latency test (dev tool, see LatencyTest.swift): presses PS `trials` times and times the picture's
/// answer. Blocks for a few seconds per trial: never on the main thread. {"error"} without a session.
/// Runs `read` on the main thread and returns what it gave, or nil when main didn't get to it within
/// `timeout`. On main itself it runs at once.
func readOnMain<T>(timeout: TimeInterval = 2, _ read: @escaping () -> T) -> T? {
    if Thread.isMainThread { return read() }
    let box = MainReadBox<T>(), done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        box.value = read()
        done.signal()
    }
    // The semaphore orders the write before this read; a late write after a timeout is never read.
    return done.wait(timeout: .now() + timeout) == .success ? box.value : nil
}

/// What `readOnMain` hands from main to the waiting thread (the semaphore orders the write and the read).
private final class MainReadBox<T>: @unchecked Sendable { var value: T? }

@_cdecl("sc_latency_test")
public func sc_latency_test(_ trials: Int32) -> UnsafeMutablePointer<CChar> {
    // `session` and `renderer` belong to main (a stop there could free the session mid-read): taken there,
    // waiting a bounded time: a main thread that never gets to it (stuck, or none running, as in a test
    // process) gives an error instead of a dev-control request hanging for good.
    guard let (current, displayMs) = readOnMain({ (session, renderer?.displayMilliseconds ?? 0) }) else {
        return failure("The app didn't answer")
    }
    guard let current else { return failure("No stream to test") }
    let data = current.latencyTest(trials: Int(min(max(trials, 1), 20)), displayMs: displayMs)
    return strdup(String(decoding: data, as: UTF8.self))
}

/// Asks the console for a keyframe (the picture stopped arriving whole). No-op without a session.
@_cdecl("sc_session_request_keyframe")
public func sc_session_request_keyframe() {
    session?.requestKeyframe()
}

@_cdecl("sc_session_stop")
public func sc_session_stop() {
    endSession(idle: true)
}

/// The app is quitting: leaves every pad quiet (rumble, trigger effects, DualSense haptics), which would
/// otherwise keep playing after the app is gone. (main)
@_cdecl("sc_quiet_pads")
public func sc_quiet_pads() {
    PadQuiet.now()
}

/// Leaves the pads quiet when the app is ended by SIGTERM, SIGINT or SIGHUP too (see PadQuiet). Once, at start.
@_cdecl("sc_install_signal_handlers")
public func sc_install_signal_handlers() {
    PadQuiet.installSignalHandlers()
}

/// Ends `quitted` if it is still the current session (a newer one may have replaced it meanwhile).
func cleanUpAfterQuit(of quitted: StreamSession) {
    if session === quitted { endSession(idle: false) }
}

/// Ends the current session. `idle` brings back the test pattern (the host went home); otherwise the
/// last frame stays on screen.
private func endSession(idle: Bool) {
    reporting.withLock { $0.current = 0 } // before stopping: its quit comes while it stops
    input = nil
    session?.stop()
    session = nil
    rumble?.stop()
    rumble = nil
    triggers?.reset()
    triggers = nil
    light?.reset()
    light = nil
    networkWatch = nil
    keepAwake(false)
    if idle { renderer?.showsTestPattern = true }
}

/// Voice chat: turns the Mac's microphone on or off. The outcome arrives as a "microphone" event with
/// state on / off / denied (no permission) / unavailable (no input, or this build can't ask).
@_cdecl("sc_session_set_mic")
public func sc_session_set_mic(_ on: Bool) {
    guard let session else { return emit(microphonePayload(.off)) }
    session.setMicrophone(on) { state in emit(microphonePayload(state)) }
}

func microphonePayload(_ state: Microphone.State) -> [String: Any] {
    ["type": "microphone", "state": state.rawValue]
}

@_cdecl("sc_session_keyboard_set_text")
public func sc_session_keyboard_set_text(_ text: UnsafePointer<CChar>) {
    session?.setKeyboardText(String(cString: text))
}

@_cdecl("sc_session_keyboard_done")
public func sc_session_keyboard_done(_ accept: Bool) {
    session?.finishKeyboard(accept: accept)
}

@_cdecl("sc_session_set_login_pin")
public func sc_session_set_login_pin(_ pin: UnsafePointer<CChar>) {
    session?.setLoginPin(String(cString: pin))
}

/// Pushes a controller state from the web UI (e.g. keyboard-as-controller for testing). This is
/// the same path as a physical pad; last writer wins if both are active.
@_cdecl("sc_session_set_controller")
public func sc_session_set_controller(_ buttons: UInt32, _ l2: UInt8, _ r2: UInt8,
                                      _ leftX: Int16, _ leftY: Int16, _ rightX: Int16, _ rightY: Int16) {
    var state = ControllerState()
    state.buttons = buttons
    state.l2 = l2
    state.r2 = r2
    state.leftX = leftX
    state.leftY = leftY
    state.rightX = rightX
    state.rightY = rightY
    // The Mac keyboard as a controller (the web UI's mapping): merged with the pad, not instead of it.
    if let input { input.setKeys(state) } else { session?.setController(state) }
}

/// The Mac's pointer as a touchpad finger: `down` = a finger at (x, y), 0–1 from the top-left of the
/// video; `pressed` = the touchpad is clicked. Merged with the pad's state.
@_cdecl("sc_session_set_pointer_touch")
public func sc_session_set_pointer_touch(_ down: Bool, _ x: Float, _ y: Float, _ pressed: Bool) {
    pointerTouchID = down ? pointerTouchID : (pointerTouchID &+ 1) & 0x7F
    let touch = down ? ControllerState.Touch(id: 100 + pointerTouchID % 27, x: min(1, max(0, x)), y: min(1, max(0, y))) : nil
    session?.setPointerTouch(StreamSession.PointerTouch(touch: touch, pressed: pressed))
}

/// A new id for each pointer touch (a lifted finger that comes back is a new touch to the console).
private var pointerTouchID: UInt8 = 0

@_cdecl("sc_session_stats")
public func sc_session_stats() -> UnsafeMutablePointer<CChar> {
    guard let session else { return json(["active": false]) }
    let s = session.stats
    return json(["active": true, "framesDecoded": s.framesDecoded, "decodeErrors": s.decodeErrors,
                 "framesLost": s.framesLost, "width": s.width, "height": s.height,
                 "bytesReceived": s.bytesReceived, "rttMs": s.rttMs, "decodeMs": s.decodeMs,
                 "targetBitrateKbps": s.targetBitrateKbps])
}
#endif
