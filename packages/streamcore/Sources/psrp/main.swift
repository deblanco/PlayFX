import CoreImage
import CoreText
import Foundation
import Network
import os
import StreamCore

// psrp — headless Remote Play tool built on StreamCore, for debugging without the desktop UI.
//
//   psrp discover [--host IP] [--timeout S]
//   psrp login-url                          print the PSN sign-in URL
//   psrp account-id <redirect-url|code>     exchange the sign-in redirect for the account ID (saved)
//   psrp register --host IP --pin PIN [--account-id B64] [--ps4]   pair; credentials saved
//   psrp consoles                           list saved consoles
//   psrp psn-consoles                       list the PS5s on the PSN account (after account-id)
//   psrp wake [--host IP]
//   psrp stream [--host IP] [--height 1080] [--fps 60] [--h264] [--hdr] [--bitrate KBPS] [--no-audio] [--no-downgrade] [--psn] [--port 7777]
//               [--frame-log FILE]
//        --psn connects over the internet through PSN (PS5; run `psrp account-id` first)
//        --frame-log writes a line per frame: "sample INDEX BYTES MS" as it reaches the decoder, then
//          "frame INDEX REPEAT CHANGE MS" once decoded (REPEAT 1: the same picture as the frame before; CHANGE:
//          its mean luma change from it; MS: milliseconds since the start), to see
//          whether a game slower than the stream comes as repeats and how small they are
//        control API on http://127.0.0.1:PORT
//          /status  /snapshot.png  /press?buttons=cross,up&ms=120  /stick?lx=0&ly=-32767&ms=300
//          /hold?buttons=r2  /release  /keyframe  /latency-test?trials=5  /sleep  /quit  /type?text=hi&done=accept (console keyboard)  /frameinfo (latest frame's colorimetry)
//          /render.png?mode=metalfx|bilinear|compare&sharpness=0.3&deblock=0&deband=0&chroma=bicubic&w=3840&h=2160   latest frame, on the GPU
//                       (compare = left baseline, right MetalFX + sharpness; bilinear defaults to sharpness 0)
//          /grid.png?vary=sharpness&values=0,0.3,1&crop=2400,500,600,600   one frame, one tile per value
//                       (also &ml=1: Apple ML super-resolution first, for streams up to 1280 px wide)
//   psrp interpolate <in.mov> [--out out.mov] [--frames N]   frame interpolation bench on a video file (no console)
//   psrp play <clip.mov> [--interpolate] [--jitter MS] [--seconds N] [--screen NAME]   frame pacing on a real screen
//   psrp pad [--port 7778]                  the Mac's controller without a console: live state, rumble and
//                                           trigger-effect tests (see Pad.swift)
//
// Saved state: ~/.config/psrp/config.json (contains pairing keys — keep it private).

struct Config: Codable {
    var accountId: String?
    var consoles: [ConsoleCredentials] = []

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/psrp/config.json")
    static func load() -> Config {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    }
    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(enc.encode(self), to: Self.url) // the pairing keys: never readable by anyone else
    }
    func console(host: String?) throws -> ConsoleCredentials {
        if let host {
            guard let c = consoles.first(where: { $0.address == host }) else { throw fail("No saved console at \(host); run `psrp register` first") }
            return c
        }
        guard let c = consoles.first else { throw fail("No saved consoles; run `psrp register` first") }
        return c
    }
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 1 } else { options[key] = "" }
            } else { positional.append(a) }
            i += 1
        }
    }
    subscript(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { options[key] != nil }
}

func fail(_ message: String) -> Error { ConsoleError.message(message) }

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self))
}

func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

// MARK: - Commands

/// Blocks the calling thread until an async effect finishes (the CLI is otherwise synchronous so
/// `stream` can own the main run loop via dispatchMain).
func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result.get()
}

func run() throws {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard !argv.isEmpty else { throw fail("usage: psrp <discover|login-url|account-id|register|consoles|wake|stream|pad> ...") }
    let command = argv.removeFirst()
    let args = Args(argv)
    Log.configure(detailed: args.has("verbose")) { entry in
        FileHandle.standardError.write(Data("[\(entry.area.rawValue)] \(entry.message)\n".utf8))
    }
    var config = Config.load()

    switch command {
    case "discover":
        let consoles = Console.discover(host: args["host"], timeout: Double(args["timeout"] ?? "") ?? 2)
        printJSON(consoles)

    case "login-url":
        print(PSNAuth.loginURL.absoluteString)

    case "account-id":
        guard let input = args.positional.first, let code = PSNAuth.code(fromRedirect: input) else {
            throw fail("usage: psrp account-id <redirect URL containing ?code=...>")
        }
        let id = try blocking { try await PSNAccount.shared.signIn(code: code) } // also keeps the tokens
        config.accountId = id
        try config.save()
        print(id)

    case "register":
        guard let host = args["host"], let pin = args["pin"] else { throw fail("usage: psrp register --host IP --pin PIN") }
        guard let account = args["account-id"] ?? config.accountId else { throw fail("No account ID; run `psrp account-id` first") }
        let creds = try Console.register(address: host, ps5: !args.has("ps4"), accountId: account, pin: pin)
        config.accountId = account
        config.consoles.removeAll { $0.address == host }
        config.consoles.append(creds)
        try config.save()
        log("Paired with \(creds.nickname) (\(host)); saved to \(Config.url.path)")

    case "psn-status": // whether a PSN sign-in is kept and when its access token expires (no secrets)
        let expiry = PSNAccount.shared.tokenExpiry
        print(expiry.map { "signed in; access token expires \($0) (\(Int($0.timeIntervalSinceNow)) s from now)" } ?? "not signed in")

    case "psn-consoles": // the PS5s on the signed-in PSN account (internet play)
        printJSON(try blocking { try await PSNAccount.shared.consoles() })

    case "consoles":
        printJSON(config.consoles.map { ["address": $0.address, "nickname": $0.nickname, "ps5": "\($0.ps5)"] })

    case "wake":
        let c = try config.console(host: args["host"])
        print(Console.wakeup(c) ? "wakeup sent to \(c.address)" : "wakeup failed")

    case "stream":
        try stream(try config.console(host: args["host"]), args)

    case "pad":
        try pad(args)

    case "interpolate":
        try interpolate(args)

    case "play":
        try play(args)

    default:
        throw fail("unknown command \(command)")
    }
}

// MARK: - Stream + control API

final class Controller {
    let session: StreamSession
    var held = ControllerState()
    var events: [String] = []
    var connected = false
    /// Rumble updates from the console (rumble events and the DualSense haptics stream), and the last one.
    var rumbles = 0
    var lastRumble = [0, 0]
    let queue = DispatchQueue(label: "psrp.input")

    init(session: StreamSession) { self.session = session }

    func apply(_ s: ControllerState) { session.setController(s) }

    /// Presses `buttons` (and optional stick values) for `ms`, then returns to the held state.
    func tap(_ s: ControllerState, ms: Int) {
        queue.async {
            var merged = s
            merged.buttons |= self.held.buttons
            self.apply(merged)
            Thread.sleep(forTimeInterval: Double(ms) / 1000)
            self.apply(self.held)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

func parseButtons(_ list: String?) throws -> ControllerState {
    var s = ControllerState()
    for name in (list ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
        switch name {
        case "l2": s.l2 = 255
        case "r2": s.r2 = 255
        default:
            guard let bit = ControllerState.buttonNames[name] else {
                throw fail("unknown button \(name); valid: \(ControllerState.buttonNames.keys.sorted().joined(separator: ",")),l2,r2")
            }
            s.buttons |= bit
        }
    }
    return s
}

/// `--frame-log`: each frame's compressed size, and whether it decoded to the same picture as the one before.
func logFrames(_ session: StreamSession, to path: String) throws {
    guard FileManager.default.createFile(atPath: path, contents: nil), let file = FileHandle(forWritingAtPath: path) else {
        throw fail("Can't write \(path)")
    }
    let queue = DispatchQueue(label: "psrp.frame-log")
    let start = DispatchTime.now().uptimeNanoseconds
    func write(_ line: String) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        queue.async { file.write(Data(String(format: "%@ %.2f\n", line, ms).utf8)) }
    }
    session.onVideoSample = { index, bytes in write("sample \(index) \(bytes)") }
    let last = OSAllocatedUnfairLock<CVPixelBuffer?>(initialState: nil)
    let repeats = OSAllocatedUnfairLock(initialState: RepeatDetector())
    session.onFrame = { frame, index in
        let before = last.withLock { previous in defer { previous = frame }; return previous }
        let difference = before.flatMap { StreamSession.pictureDifference($0, frame) }
        let repeated = difference.map { d in repeats.withLock { $0.isRepeat(difference: d) } } ?? false
        write(String(format: "frame %@ %d %.3f", index.map(String.init) ?? "-", repeated ? 1 : 0, difference ?? 0))
    }
    log("Frame log: \(path)")
}

func stream(_ console: ConsoleCredentials, _ args: Args) throws {
    var options = StreamSession.Options()
    options.height = Int(args["height"] ?? "") ?? 1080
    options.fps = Int(args["fps"] ?? "") ?? 60
    options.hevc = !args.has("h264")
    options.bitrate = Int(args["bitrate"] ?? "") ?? 0
    options.audio = !args.has("no-audio")
    options.autoDowngrade = !args.has("no-downgrade")
    options.hdr = args.has("hdr")

    log("Connecting to \(console.nickname) at \(console.address) (\(options.height)p\(options.fps), \(options.hevc ? "HEVC" : "H.264"))…")
    // --psn: reach the console over the internet through PSN (needs `psrp account-id` first).
    var remote: StreamSession.Remote?
    if args.has("psn") {
        let (token, consoles) = try blocking {
            (try await PSNAccount.shared.validAccessToken(), try await PSNAccount.shared.consoles())
        }
        guard let match = consoles.first(where: { $0.remotePlay && $0.name == console.nickname }) else {
            throw fail("PSN doesn't list \(console.nickname) with Remote Play on (found: \(consoles.map(\.name)))")
        }
        remote = StreamSession.Remote(token: token, duid: match.duid)
        log("Connecting over the internet via PSN…")
    }
    let session = try StreamSession(credentials: console, options: options, remote: remote)
    let ctl = Controller(session: session)
    session.onEvent = { event in
        let text: String
        switch event {
        case .connected: ctl.connected = true; text = "connected"
        case .quit(let reason, let error, _): ctl.connected = false; text = "quit (\(error ? "error" : "ok")): \(reason)"
        case .loginPinRequested(let incorrect): text = "login PIN requested (incorrect: \(incorrect))"
        case .rumble(let l, let r), .hapticRumble(let l, let r):
            ctl.queue.async { ctl.rumbles += 1; ctl.lastRumble = [Int(l), Int(r)] }; return
        case .triggerEffects: return
        case .light(let red, let green, let blue): text = String(format: "light bar #%02x%02x%02x", red, green, blue)
        case .playerIndex(let index): text = "player \(index + 1)"
        case .nickname(let n): text = "nickname: \(n)"
        case .remoteProgress(let stage): text = "over the internet: \(stage.rawValue)"
        case .keyboard(let change, let field): text = "keyboard \(change.rawValue): \"\(field)\""
        }
        log("[event] \(text)")
        ctl.queue.async { ctl.events.append(text) }
        if case .quit = event { PadQuiet.now(); exit(0) }
    }

    if let path = args["frame-log"] { try logFrames(session, to: path) }

    let port = UInt16(args["port"] ?? "") ?? 7777
    try serve(port: port) { handle(path: $0, query: $1, ctl) }
    log("Control API: http://127.0.0.1:\(port)/status  (/snapshot.png, /press?buttons=cross, /quit)")
    // Ctrl-C (or SIGTERM, SIGHUP): stop the session and leave the pad quiet (its DualSense haptics).
    PadQuiet.installSignalHandlers { session.stop() }
    dispatchMain()
}

let ciContext = CIContext()

/// Picture settings from /render.png and /grid.png queries: mode=metalfx|bilinear|compare,
/// sharpness, deblock, deband (0–1), chroma=bicubic|bilinear.
func renderParams(_ query: [String: String]) throws -> RenderParams {
    var params = RenderParams()
    switch query["mode"] ?? "metalfx" {
    case "bilinear": params.upscaler = .bilinear
    case "metalfx": params.upscaler = .metalFX
    case "compare": params.compare = true
    default: throw fail("mode must be bilinear, metalfx or compare")
    }
    params.sharpness = query["sharpness"].flatMap(Float.init) ?? (params.upscaler == .bilinear ? 0 : 0.3)
    params.deblock = query["deblock"].flatMap(Float.init) ?? 0
    params.deband = query["deband"].flatMap(Float.init) ?? 0
    params.mlUpscale = query["ml"] == "1"
    if let chroma = query["chroma"] {
        guard let filter = ChromaFilter(rawValue: chroma) else { throw fail("chroma must be bicubic or bilinear") }
        params.chroma = filter
    }
    return params
}

/// Tiles side by side with a label strip above each, as PNG.
func grid(_ tiles: [(label: String, image: CGImage)]) -> Data? {
    guard let first = tiles.first?.image else { return nil }
    let (tw, th, gap, strip) = (first.width, first.height, 6, 48)
    let width = tiles.count * tw + (tiles.count - 1) * gap, height = th + strip
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
    for (i, tile) in tiles.enumerated() {
        let x = i * (tw + gap)
        ctx.draw(tile.image, in: CGRect(x: x, y: 0, width: tw, height: th))
        let text = NSAttributedString(string: tile.label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: CGFloat(x) + (CGFloat(tw) - bounds.width) / 2, y: CGFloat(th) + 14)
        CTLineDraw(line, ctx)
    }
    guard let image = ctx.makeImage() else { return nil }
    return ciContext.pngRepresentation(of: CIImage(cgImage: image), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

/// Wall-clock time of the last offscreen render (GPU work + ML + readback), for latency checks.
let lastRenderMs = OSAllocatedUnfairLock<Double>(initialState: 0)

/// Offscreen renderer for /render.png (created lazily; GPU access serialized by the lock).
let offscreen = OSAllocatedUnfairLock<StreamRenderer?>(initialState: nil)

func render(_ frame: CVPixelBuffer, params: RenderParams, width: Int, height: Int) -> CGImage? {
    offscreen.withLock { r in
        if r == nil { r = StreamRenderer(); r?.showsTestPattern = false }
        guard let r else { return nil }
        r.params = params
        r.display(frame)
        let start = DispatchTime.now()
        let image = r.snapshot(width: width, height: height)
        lastRenderMs.withLock { $0 = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }
        return image
    }
}

func handle(path: String, query: [String: String], _ ctl: Controller) -> (Int, String, Data) {
    func json<T: Encodable>(_ v: T) -> (Int, String, Data) { (200, "application/json", (try? JSONEncoder().encode(v)) ?? Data()) }
    func ok() -> (Int, String, Data) { (200, "text/plain", Data("ok\n".utf8)) }
    do {
        switch path {
        case "/status":
            struct Render: Encodable { let gpuMs: Double; let wallMs: Double; let mlSupported: Bool; let mlActive: Bool }
            struct Status: Encodable {
                let connected: Bool; let stats: StreamSession.Stats; let events: [String]; let render: Render?
                let rumbles: Int; let lastRumble: [Int]
            }
            let render = offscreen.withLock { r in r.map { Render(gpuMs: $0.gpuMilliseconds, wallMs: lastRenderMs.withLock { $0 }, mlSupported: $0.mlSupported, mlActive: $0.mlActive) } }
            let (rumbles, lastRumble) = ctl.queue.sync { (ctl.rumbles, ctl.lastRumble) }
            return json(Status(connected: ctl.connected, stats: ctl.session.stats, events: ctl.queue.sync { ctl.events },
                               render: render, rumbles: rumbles, lastRumble: lastRumble))
        case "/snapshot.png":
            guard let frame = ctl.session.latestFrame else { return (503, "text/plain", Data("no frame yet\n".utf8)) }
            let image = CIImage(cvPixelBuffer: frame)
            guard let png = ciContext.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { return (500, "text/plain", Data("encode failed\n".utf8)) }
            return (200, "image/png", png)
        case "/render.png":
            guard let frame = ctl.session.latestFrame else { return (503, "text/plain", Data("no frame yet\n".utf8)) }
            let params = try renderParams(query)
            let w = Int(query["w"] ?? "") ?? 3840, h = Int(query["h"] ?? "") ?? 2160
            guard let image = render(frame, params: params, width: w, height: h),
                  let png = ciContext.pngRepresentation(of: CIImage(cgImage: image), format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { return (500, "text/plain", Data("render failed\n".utf8)) }
            return (200, "image/png", png)
        case "/grid.png":
            // The same frame rendered once per value of one setting, cropped and labelled side by side.
            guard let frame = ctl.session.latestFrame else { return (503, "text/plain", Data("no frame yet\n".utf8)) }
            guard let key = query["vary"], let values = query["values"]?.split(separator: ",").map(String.init), !values.isEmpty
            else { throw fail("usage: /grid.png?vary=sharpness&values=0,0.3,1[&crop=x,y,w,h][&w=3840&h=2160][&mode=…]") }
            let w = Int(query["w"] ?? "") ?? 3840, h = Int(query["h"] ?? "") ?? 2160
            let crop = query["crop"].map { $0.split(separator: ",").compactMap { Int($0) } }
            let rect = crop.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
                ?? CGRect(x: 0, y: 0, width: w, height: h)
            var tiles: [(String, CGImage)] = []
            for value in values {
                var variant = query
                variant[key] = value
                guard let image = render(frame, params: try renderParams(variant), width: w, height: h)?.cropping(to: rect)
                else { return (500, "text/plain", Data("render failed\n".utf8)) }
                tiles.append(("\(key) \(value)", image))
            }
            guard let png = grid(tiles) else { return (500, "text/plain", Data("grid failed\n".utf8)) }
            return (200, "image/png", png)
        case "/frameinfo":
            guard let frame = ctl.session.latestFrame else { return (503, "text/plain", Data("no frame yet\n".utf8)) }
            var info: [String: String] = ["pixelFormat": String(CVPixelBufferGetPixelFormatType(frame), radix: 16)]
            for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
                info[key as String] = CVBufferCopyAttachment(frame, key, nil).map { "\($0)" } ?? "(none)"
            }
            return json(info)
        case "/press":
            var s = try parseButtons(query["buttons"] ?? query["b"])
            if let v = query["lx"].flatMap(Int16.init) { s.leftX = v }
            if let v = query["ly"].flatMap(Int16.init) { s.leftY = v }
            ctl.tap(s, ms: Int(query["ms"] ?? "") ?? 120)
            return ok()
        case "/stick":
            var s = ControllerState()
            s.leftX = query["lx"].flatMap(Int16.init) ?? 0
            s.leftY = query["ly"].flatMap(Int16.init) ?? 0
            s.rightX = query["rx"].flatMap(Int16.init) ?? 0
            s.rightY = query["ry"].flatMap(Int16.init) ?? 0
            ctl.tap(s, ms: Int(query["ms"] ?? "") ?? 300)
            return ok()
        case "/hold":
            let s = try parseButtons(query["buttons"] ?? query["b"])
            ctl.queue.async { ctl.held = s; ctl.apply(s) }
            return ok()
        case "/release":
            ctl.queue.async { ctl.held = ControllerState(); ctl.apply(ctl.held) }
            return ok()
        case "/keyframe":
            ctl.session.requestKeyframe()
            return ok()
        case "/latency-test":
            // Times Right/Left in the control centre (see LatencyTest.swift); blocks for about a second per trial.
            let trials = min(max(Int(query["trials"] ?? "") ?? 5, 1), 20)
            log("[latency] \(trials) trials…")
            return (200, "application/json", ctl.session.latencyTest(trials: trials, displayMs: 0))
        case "/type":
            // /type?text=hello&done=accept|reject — types into the console's open text field.
            if let text = query["text"] { ctl.session.setKeyboardText(text) }
            if let done = query["done"] { ctl.session.finishKeyboard(accept: done == "accept") }
            return ok()
        case "/sleep":
            ctl.session.sleepConsole()
            return ok()
        case "/quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ctl.session.stop(); PadQuiet.now(); exit(0) }
            return ok()
        default:
            return (404, "text/plain", Data("not found\n".utf8))
        }
    } catch {
        return (400, "text/plain", Data("\(error.localizedDescription)\n".utf8))
    }
}

/// Minimal HTTP/1.0 server on localhost (one request per connection).
func serve(port: UInt16, _ handler: @escaping (String, [String: String]) -> (Int, String, Data)) throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: params)
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard controlAllowed(request, port: port) else {
                let body = Data("Send the header X-PSRP: 1 (and Host 127.0.0.1 or localhost)\n".utf8)
                var head = Data("HTTP/1.0 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                head.append(body)
                conn.send(content: head, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: target)
            var query: [String: String] = [:]
            comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
            let (status, type, body) = handler(comps?.path ?? target, query)
            var head = Data("HTTP/1.0 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            head.append(body)
            conn.send(content: head, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
    listener.start(queue: .global())
    servers.append(listener)
}
var servers: [NWListener] = []

/// Whether a request may drive the console. A web page in a browser can reach 127.0.0.1 too (an image
/// pointing at /press, or DNS rebinding), but it can't add a custom header without a CORS preflight, which
/// this server never answers; and the Host must be this machine, not a rebound name.
func controlAllowed(_ request: String, port: UInt16) -> Bool {
    let headers = request.split(separator: "\r\n").dropFirst().map { $0.lowercased() }
    let hosts = ["host: 127.0.0.1:\(port)", "host: localhost:\(port)"]
    return headers.contains("x-psrp: 1") && headers.contains { hosts.contains($0) }
}

// MARK: - Entry

do {
    try run()
} catch {
    log("error: \(error.localizedDescription)")
    exit(1)
}
