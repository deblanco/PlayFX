#if os(macOS)
import AppKit

// C ABI for the Tauri (Rust) host. JSON in/out keeps the boundary small.
// - Functions marked (main) must be called on the main thread.
// - Functions marked (blocking) must NOT be called on the main thread.
// - Returned strings are malloc'd; release them with sc_free.
// iOS (Expo module) will use the Swift API (StreamRenderer, StreamSession, Console) directly.

private var renderer: StreamRenderer?
private var session: StreamSession?
private var input: ControllerInput?
private var eventCallback: (@convention(c) (UnsafePointer<CChar>) -> Void)?

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

/// Receives session events as JSON: {"type":"connected"} | {"type":"quit","reason":..,"error":bool} |
/// {"type":"loginPin","incorrect":bool} | {"type":"nickname","name":..}. Called from any thread.
@_cdecl("sc_set_event_callback")
public func sc_set_event_callback(_ cb: (@convention(c) (UnsafePointer<CChar>) -> Void)?) {
    eventCallback = cb
    Console.configureLogging(verbose: ProcessInfo.processInfo.environment["PSRP_VERBOSE"] != nil)
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

/// `redirect`: the redirect URL containing ?code=… → {"accountId"} or {"error"}.
@_cdecl("sc_psn_account_id")
public func sc_psn_account_id(_ redirect: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    guard let code = PSNAuth.code(fromRedirect: String(cString: redirect)) else { return failure("No sign-in code in URL") }
    let done = DispatchSemaphore(value: 0)
    var result: Result<String, Error> = .failure(ConsoleError.message("PSN sign-in timed out"))
    Task.detached {
        do { result = .success(try await PSNAuth.accountId(code: code)) } catch { result = .failure(error) }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 30)
    switch result {
    case .success(let id): return json(["accountId": id])
    case .failure(let e): return failure(e.localizedDescription)
    }
}

// MARK: Session (main)

/// `request`: {"credentials": ConsoleCredentials, "options": StreamSession.Options} → {"ok":true} or {"error"}.
@_cdecl("sc_session_start")
public func sc_session_start(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    struct Request: Decodable { let credentials: ConsoleCredentials; let options: StreamSession.Options? }
    sc_session_stop()
    do {
        let r = try decode(Request.self, request)
        let s = try StreamSession(credentials: r.credentials, options: r.options ?? StreamSession.Options())
        s.onFrame = { frame in renderer?.display(frame) }
        s.onEvent = { event in
            if let payload = eventPayload(event) { emit(payload) }
            if case .quit = event { DispatchQueue.main.async { sc_session_stop() } }
        }
        let i = ControllerInput()
        i.onChange = { [weak s] state in s?.setController(state) }
        session = s
        input = i
        renderer?.showsTestPattern = false
        return json(["ok": true])
    } catch { return failure(error.localizedDescription) }
}

/// JSON sent to the host for a session event (nil for events the host doesn't get).
func eventPayload(_ event: StreamSession.Event) -> [String: Any]? {
    switch event {
    case .connected: return ["type": "connected"]
    case .quit(let reason, let isError): return ["type": "quit", "reason": reason, "error": isError]
    case .loginPinRequested(let incorrect): return ["type": "loginPin", "incorrect": incorrect]
    case .nickname(let name): return ["type": "nickname", "name": name]
    case .rumble: return nil
    }
}

@_cdecl("sc_session_stop")
public func sc_session_stop() {
    input = nil
    session?.stop()
    session = nil
    renderer?.showsTestPattern = true
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
    session?.setController(state)
}

@_cdecl("sc_session_stats")
public func sc_session_stats() -> UnsafeMutablePointer<CChar> {
    guard let session else { return json(["active": false]) }
    let s = session.stats
    return json(["active": true, "framesDecoded": s.framesDecoded, "decodeErrors": s.decodeErrors,
                 "framesLost": s.framesLost, "width": s.width, "height": s.height,
                 "bytesReceived": s.bytesReceived])
}
#endif
