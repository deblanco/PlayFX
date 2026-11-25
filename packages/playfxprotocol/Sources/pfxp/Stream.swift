import Foundation
import PlayFXProtocol

// `pfxp stream`: a whole stream with PlayFXProtocol's StreamSession against a real console, side by side with
// `psrp stream`.
//
//   pfxp stream [--host IP] [--new] [--seconds N] [--resolution 360|540|720|1080] [--fps 30|60]
//               [--codec h264|hevc|hevc-hdr] [--bitrate KBPS] [--transport bsd|nw]
//               [--out FILE] [--audio-out FILE] [--login-pin PIN|-] [--mic-info]
//               [--press SCRIPT] [--trace-input] [--drop PERCENT [--drop-burst N]]
//
// It prints the connected info, one statistics line per second, the end reason and a summary. It sends a neutral
// controller state (no input) every 100 ms, or the --press script's state; the transport repeats the state packet
// every 200 ms by itself. Never printed: keys, the session ID, the nonce, the ECDH secret.
//
// --press SCRIPT    Timed inputs, from the moment of `connected`: comma-separated `BUTTONS@SECONDS[:HOLD_MS]`
//                   (buttons joined with `+`) or `AXIS=VALUE@SECONDS[:HOLD_MS]` (lx ly rx ry -1...1, l2 r2 0...1),
//                   hold 150 ms by default, e.g. `ps@2,circle@4,cross+up@7:300,ly=-1@9:2000`. See ControllerScript.
//                   Each press is printed as it happens.
// --trace-input     Prints every controller state actually handed to the session when it changes (time since
//                   connected, buttons, the four sticks, l2/r2), so what the console did can be matched to what was sent.
// --drop PERCENT    TESTING ONLY: drops that share (above 0, at most 50) of the datagrams received on the stream
//                   connection once it is up, so FEC, reordering, retransmission and corrupt-frame reports run on real
//                   traffic. --drop-burst N drops N in a row each time a drop starts (default 1). The statistics line
//                   shows `simDrop` (datagrams dropped).
// The first video packet's `codec` byte and the pad-info form the console sends (17 or 25 bytes) are printed when seen.
//
// --out FILE        The Annex-B elementary stream: the parameter sets of the profile first (and again whenever
//                   the console switches resolution), then every access unit as the receiver hands it over.
//                   `ffprobe FILE` or `ffmpeg -i FILE ...` can open it (H.264 or HEVC, as chosen by --codec).
// --audio-out FILE  The game audio's Opus packets, as records in arrival order, all big-endian:
//                     UInt16 length, then `length` bytes of one Opus packet (with its TOC byte);
//                     length 0           a frame that never arrived: run the decoder's packet-loss concealment;
//                     length 0xFFFF      a longer gap that is skipped without concealment, followed by a UInt32
//                                        with the number of frames skipped.
//                   The packets are 10 ms frames at the audio header's sample rate (printed when connected).

/// Appends to a new file from a serial queue, so the receive thread only copies and hands off. The file is made
/// with O_EXCL: an existing file (a pairing config, say) is never overwritten. Writes are POSIX `write`s, and a
/// closed flag stops a late handler call from touching the descriptor.
private final class FileSink: @unchecked Sendable {
    private var descriptor: Int32
    let path: String
    private let queue = DispatchQueue(label: "pfxp.sink")
    private(set) var bytesWritten = 0
    private var closed = false

    init(path: String) throws {
        self.path = path
        descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            throw fail(errno == EEXIST ? "\(path) already exists; pfxp won't overwrite it" : "Can't create \(path): \(String(cString: strerror(errno)))")
        }
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, data.count - offset) }
                if n < 0 {
                    if errno == EINTR { continue }
                    closed = true  // a full disk or similar: stop writing, the summary shows the byte count
                    return
                }
                offset += n
            }
            bytesWritten += data.count
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    /// Closes and removes the file (the stream never started).
    func discard() {
        close()
        unlink(path)
    }
}

/// Seconds on a monotonic clock (the script timeline and the input loop don't follow the wall clock).
private func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

/// A stricter `option`: a missing value, or a value that starts with `--`, is an error rather than "not given".
private func strictOption(_ name: String, in args: [String]) throws -> String? {
    guard let i = args.firstIndex(of: "--\(name)") else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw fail("--\(name) needs a value") }
    return args[i + 1]
}

private struct Summary {
    var videoFrames = 0
    var videoBytes = 0
    var keyFrames = 0
    var framesLostReported = 0
    var recoveredFrames = 0
    var fecRecovered = 0
    var audioPackets = 0
    var audioLost = 0
    var audioSkipped = 0
    var hapticsFrames = 0
    var rumbleEvents = 0
    var triggerEvents = 0
    var lastStats: StreamStats?
    var ended: StreamEndReason?
}

private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
private func be32(_ value: Int) -> [UInt8] { be16(value >> 16 & 0xffff) + be16(value & 0xffff) }

private func describe(_ stats: StreamStats, simulatedLoss: Bool) -> String {
    let congestion = stats.lastCongestion.map { "\($0.received)/\($0.lost)" } ?? "-"
    return String(
        format: "%5.1f s  video %2ld fps %6.2f Mbit/s (%ld frames, lost %ld, rec %ld, fec %ld, fecFail %ld, drop %ld, reject %ld, idr %ld, corrupt %ld)"
            + "  audio %ld (concealed %ld, skipped %ld)"
            + "  reorder wait %ld us, filled %ld, late %ld, lost %ld, full %ld, timeout %ld"
            + "  cong %@  rtt %ld us  mtu %ld/%ld  %@/%@  rx %ld, badGMAC %ld, retx %ld%@",
        stats.seconds, stats.videoFrames, stats.videoMbps, stats.videoFramesTotal, stats.framesLost, stats.framesRecovered,
        stats.fecRecoveries, stats.fecFailures, stats.framesDropped, stats.decoderRejects, stats.idrRequestsSent,
        stats.corruptFrameReportsSent, stats.audioPackets, stats.audioConcealed, stats.audioSkipped, stats.reorder.waitMicros,
        stats.reorder.holesFilled, stats.reorder.latePackets, stats.reorder.holesLost, stats.reorder.queueFullSkips,
        stats.reorder.timeoutSkips, congestion, stats.rttMicroseconds, stats.mtuIn, stats.mtuOut, stats.transport,
        stats.timestampSource, stats.datagramsReceived, stats.droppedBadGMAC, stats.retransmissions,
        simulatedLoss ? ", simDrop \(stats.simulatedDrops)" : "")
}

/// What the console sent that earlier rounds couldn't see (takion.md section 7, stream.md section 9.8).
private func describeCodecByte(_ byte: UInt8, asked: StreamCodec) -> String {
    "video codec byte 0x\(String(format: "%02x", byte)) (asked for \(asked))"
}

private func describePadInfo(_ length: Int) -> String {
    "pad info form: \(length)-byte body (\(length == 25 ? "with sequence and time stamp" : "short form"))"
}

private func describe(_ info: StreamConnectedInfo) -> [String] {
    let probe = info.probeSucceeded
        ? "ok: rtt \(info.probe.rttMicroseconds) us, mtu in \(info.probe.mtuIn) / out \(info.probe.mtuOut)"
        : "FAILED (\(info.probeFailure ?? "?")): using the fallbacks, rtt 1 ms, mtu 1454 / 1454"
    let request = info.requested
    var lines = [
        "target \(info.target.protocolVersion) \(info.target.isPS5 ? "PS5" : "PS4"), console model \(info.consoleModel.map { "\($0)" } ?? "unknown"), "
            + "Takion \(info.takionVersion), transport \(info.transport)",
        "probe \(probe)",
        "asked for \(request.width)x\(request.height) @ \(request.fps) fps, \(request.bitrateKbps) kbit/s, \(request.codec), "
            + "codec given to the AV layer: \(info.videoCodec)",
    ]
    for (index, profile) in info.profiles.enumerated() {
        lines.append("profile \(index): \(profile.width)x\(profile.height), \(profile.header.count) byte header")
    }
    let audio = info.audioHeader
    lines.append(
        "audio: \(audio.channels) ch, \(audio.bitsPerSample) bit, \(audio.sampleRate) Hz, frame size \(audio.frameSize), unknown \(audio.unknown)")
    lines.append(
        "console: serverVersion \(info.serverVersion.map { "\($0)" } ?? "none"), "
            + "text \(info.serverVersionText ?? "none"), signature matches HMAC(handshakeKey, its key): \(info.consoleSignatureMatches)")
    return lines
}

func stream(_ args: [String], configFile: URL) async throws {
    // The options that don't need the pairing are checked first, so a typo fails before anything else happens.
    var script: ControllerScript?
    if let text = try strictOption("press", in: args) {
        do { script = try ControllerScript(parsing: text) } catch { throw fail("--press: \(error)") }
    }
    var simulatedLoss: SimulatedLoss?
    let burstText = try strictOption("drop-burst", in: args)
    if let text = try strictOption("drop", in: args) {
        guard let percent = Double(text), percent.isFinite, percent > 0, percent <= 50 else {
            throw fail("--drop is a percentage above 0 and at most 50 (got \(text))")
        }
        var burst = 1
        if let burstText {
            guard let n = Int(burstText), (1...SimulatedLoss.maxBurst).contains(n) else {
                throw fail("--drop-burst is a whole number from 1 to \(SimulatedLoss.maxBurst) (got \(burstText))")
            }
            burst = n
        }
        guard let loss = SimulatedLoss(percent: percent, burst: burst) else {
            throw fail("--drop \(text) with --drop-burst \(burst) is too small to ever drop a datagram")
        }
        simulatedLoss = loss
    } else if burstText != nil {
        throw fail("--drop-burst needs --drop")
    }

    let config = Config.load(configFile)
    let host = try strictOption("host", in: args)
    guard let console = host.map({ h in config.consoles.first { $0.address == h } }) ?? config.consoles.first else {
        throw fail("No console paired in \(configFile.path)\(host.map { " at \($0)" } ?? "")")
    }
    guard let regist = Data(base64Encoded: console.registKey), regist.count == 16,
          let rp = Data(base64Encoded: console.rpKey), rp.count == 16 else {
        throw fail("The saved pairing for \(console.nickname) has no usable keys")
    }
    var seconds = 30.0
    if let text = try strictOption("seconds", in: args) {
        guard let value = Double(text), value.isFinite, value > 0 else { throw fail("--seconds is a positive number") }
        seconds = value
    }

    // The settings: 720p at 60 fps unless asked otherwise, so a first run asks for little.
    let resolution: StreamResolution
    switch try strictOption("resolution", in: args) ?? "720" {
    case "360": resolution = .p360
    case "540": resolution = .p540
    case "720": resolution = .p720
    case "1080": resolution = .p1080
    default: throw fail("--resolution is 360, 540, 720 or 1080")
    }
    let frameRate: StreamFrameRate
    switch try strictOption("fps", in: args) ?? "60" {
    case "30": frameRate = .fps30
    case "60": frameRate = .fps60
    default: throw fail("--fps is 30 or 60")
    }
    let codec: StreamCodec
    switch try strictOption("codec", in: args) ?? "h264" {
    case "h264": codec = .h264
    case "hevc": codec = .hevc
    case "hevc-hdr": codec = .hevcHDR
    default: throw fail("--codec is h264, hevc or hevc-hdr")
    }
    var bitrate = StreamBitrate.preset
    if let text = try strictOption("bitrate", in: args) {
        guard let kbps = Int(text), kbps > 0 else { throw fail("--bitrate is a number of kbit/s") }
        bitrate = .kbps(kbps)
    }
    let transport: StreamTransport
    switch try strictOption("transport", in: args) ?? "bsd" {
    case "bsd": transport = .bsd
    case "nw": transport = .nw
    default: throw fail("--transport is bsd or nw")
    }
    let settings = StreamSettings(resolution: resolution, frameRate: frameRate, bitrate: bitrate, codec: codec)

    let videoPath = try strictOption("out", in: args)
    let audioPath = try strictOption("audio-out", in: args)
    if let videoPath, videoPath == audioPath { throw fail("--out and --audio-out must be different files") }
    var options = StreamSessionOptions()
    options.microphone = args.contains("--mic-info")
    options.simulatedReceiveLoss = simulatedLoss
    let videoSink = try videoPath.map { try FileSink(path: $0) }
    let audioSink: FileSink?
    do { audioSink = try audioPath.map { try FileSink(path: $0) } } catch {
        videoSink?.discard()
        throw error
    }
    // `--login-pin -` reads the PIN from stdin, so it doesn't show in `ps`.
    var pin = try strictOption("login-pin", in: args)
    if pin == "-" { pin = readLine(strippingNewline: true) }

    let started = Date()
    @Sendable func stamp() -> String { String(format: "%6.2f s", Date().timeIntervalSince(started)) }
    let summary = Locked(Summary())
    let video = videoSink
    let audio = audioSink
    let current = Locked<StreamSession?>(nil)
    let startTask = Locked<Task<StreamSession, Error>?>(nil)
    let interrupts = Locked(0)
    let givenPIN = pin
    let connectedAt = Locked<Double?>(nil)
    let shownDiagnostics = Locked((codec: UInt8?.none, pad: Int?.none))
    let showsSimulatedLoss = simulatedLoss != nil

    let handler: @Sendable (StreamEvent, StreamSession) -> Void = { event, session in
        switch event {
        case .connected(let info):
            connectedAt.with { $0 = monotonicNow() }
            say("\(stamp())  connected")
            for line in describe(info) { say("            \(line)") }
        case .audioHeader:
            break
        case .videoAccessUnit(let bytes, let info):
            video?.write(Data(bytes))
            summary.with {
                $0.videoFrames += 1
                $0.videoBytes += bytes.count
                if info.isKeyFrame == true { $0.keyFrames += 1 }
                $0.framesLostReported += info.framesLost
                if info.recovered { $0.recoveredFrames += 1 }
                if info.fecRecovered { $0.fecRecovered += 1 }
            }
        case .parameterSets(let index, let profile, _):
            say("\(stamp())  parameter sets for profile \(index) (\(profile.width)x\(profile.height), \(profile.header.count) bytes)")
            video?.write(Data(profile.header))
        case .audioPacket(let packet):
            switch packet {
            case .packet(_, let opus):
                audio?.write(Data(be16(opus.count)) + Data(opus))
                summary.with { $0.audioPackets += 1 }
            case .lost:
                audio?.write(Data(be16(0)))
                summary.with { $0.audioLost += 1 }
            case .skipped(_, let count):
                audio?.write(Data(be16(0xffff) + be32(count)))
                summary.with { $0.audioSkipped += count }
            }
        case .haptics:
            summary.with { $0.hapticsFrames += 1 }
        case .rumble(let levels):
            summary.with { $0.rumbleEvents += 1 }
            say("\(stamp())  rumble left \(levels.left) right \(levels.right)")
        case .triggerEffects(let effects):
            summary.with { $0.triggerEvents += 1 }
            say("\(stamp())  trigger effects left mode 0x\(String(effects.leftMode, radix: 16)) right mode 0x\(String(effects.rightMode, radix: 16))")
        case .ledColor(let r, let g, let b):
            say("\(stamp())  light bar \(String(format: "%02x%02x%02x", r, g, b))")
        case .playerIndex(let index):
            say("\(stamp())  player index \(index)")
        case .motionReset:
            say("\(stamp())  motion reset")
        case .connectionQuality(let quality):
            say("\(stamp())  connection quality: target bitrate \(quality.targetBitrate.map { "\($0)" } ?? "-")")
        case .loginPINRequested:
            say("\(stamp())  login PIN requested")
            if let pin = givenPIN {
                do { try session.sendLoginPIN(pin); say("\(stamp())  login PIN sent") } catch {
                    say("\(stamp())  --login-pin is not a valid PIN")
                }
            }
        case .loginPINResult(let accepted):
            say("\(stamp())  login PIN \(accepted ? "accepted" : "wrong")")
        case .keyboardOpened(let text):
            say("\(stamp())  keyboard opened (\(text.utf8.count) bytes of text)")
        case .keyboardTextChanged(let sequence, let text):
            say("\(stamp())  keyboard text changed #\(sequence) (\(text.utf8.count) bytes)")
        case .keyboardClosed:
            say("\(stamp())  keyboard closed by console")
        case .stats(let stats):
            summary.with { $0.lastStats = stats }
            let fresh = shownDiagnostics.with { shown -> (codec: UInt8?, pad: Int?) in
                defer { shown = (stats.videoCodecByte ?? shown.codec, stats.padInfoBodyLength ?? shown.pad) }
                return (stats.videoCodecByte != shown.codec ? stats.videoCodecByte : nil,
                        stats.padInfoBodyLength != shown.pad ? stats.padInfoBodyLength : nil)
            }
            if let byte = fresh.codec { say("\(stamp())  \(describeCodecByte(byte, asked: codec))") }
            if let length = fresh.pad { say("\(stamp())  \(describePadInfo(length))") }
            say(describe(stats, simulatedLoss: showsSimulatedLoss))
        case .ended(let reason):
            summary.with { $0.ended = reason }
            say("\(stamp())  ended: code \(reason.code.rawValue) (\(reason.code)), \(reason.isError ? "error" : "not an error"), "
                + "retry class \(reason.retryClass)\(reason.remoteText.map { ", console said: \($0)" } ?? "")")
            say("            \(reason.userMessage(console: console.ps5 ? .ps5 : .ps4))")
        }
    }

    say("Starting a \(transport.name) stream with \(console.nickname) at \(console.address): \(resolution.rawValue)p, "
        + "\(frameRate.rawValue) fps, \(codec), \(seconds) s"
        + (simulatedLoss.map { ", simulated loss \(String(format: "%g", $0.percent)) % in bursts of \($0.burst)" } ?? ""))
    if let script {
        say("Input script: \(script.entries.count) entries, the last one ends \(String(format: "%.2f", script.duration)) s after connected")
        if script.duration > seconds {
            say("Warning: --seconds \(seconds) ends before the script does; the entries after that never run")
        }
    }
    // Ctrl-C: stop the stream cleanly (or cancel the start) and wait for `ended`; a second one exits at once.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        let count = interrupts.with { n -> Int in n += 1; return n }
        if count > 1 { exit(130) }
        say("\(stamp())  Ctrl-C: stopping (press again to exit at once)")
        startTask.with { $0 }?.cancel()
        current.with { $0 }?.stop()
    }
    interrupt.resume()
    defer { interrupt.cancel() }

    let session: StreamSession
    do {
        let task = Task {
            try await StreamSession.start(
                address: console.address, target: console.ps5 ? .ps5v1 : .ps4v10, registKey: Array(regist), rpKey: Array(rp),
                settings: settings, transport: transport, options: options, events: handler)
        }
        startTask.with { $0 = task }
        session = try await task.value
        current.with { $0 = session }
        if interrupts.with({ $0 }) > 0 { session.stop() }
    } catch let error as StreamStartError {
        videoSink?.discard()
        audioSink?.discard()
        let detail: String
        switch error {
        case .cancelled: detail = "cancelled"
        case .session(let cause, let stage): detail = "\(stage): \(cause)"
        case .stream(let reason, let text): detail = "code \(reason.code.rawValue) (\(reason.code)): \(text)"
        }
        throw fail("Stream failed to start (\(detail)): \(error.userMessage(console: console.ps5 ? .ps5 : .ps4))")
    }

    // Neutral input (or the script's state) until the time is up, or the stream ends: sent at least every 100 ms,
    // and at once, by waking at the script's next change, whenever the state changes. The script's `Player` walks
    // every start and end since the last wake-up in order, so a short press or a late wake-up still sends both
    // the press and the release.
    let deadline = Date().addingTimeInterval(seconds)
    let traces = args.contains("--trace-input")
    var player = script.map { ControllerScript.Player($0) }
    var lastSent: ControllerState?
    var lastSentAt = 0.0
    let loopStart = monotonicNow()
    func hand(_ state: ControllerState, at now: Double) {
        let sent = session.setControllerState(state)
        if traces && state != lastSent {
            let t = now - (connectedAt.with { $0 } ?? loopStart)
            say(String(format: "%6.2f s  sent ", t) + state.traceDescription + (sent ? "" : " (held until the stream is ready)"))
        }
        lastSent = state
        lastSentAt = now
    }
    while Date() < deadline && summary.with({ $0.ended == nil }) && interrupts.with({ $0 }) == 0 {
        let now = monotonicNow()
        var state = ControllerState.idle
        var wait = 0.1
        if player != nil, let origin = connectedAt.with({ $0 }) {
            let step = player!.step(to: now - origin)
            for send in step.sends {
                hand(send.state, at: now)
                for label in send.announcements { say(String(format: "%6.2f s  ", now - origin) + label) }
            }
            state = step.current
            if let next = step.nextWake { wait = min(wait, max(next - (now - origin), 0.001)) }
        }
        if state != lastSent || now - lastSentAt >= 0.1 { hand(state, at: now) }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }
    if summary.with({ $0.ended == nil }) {
        if interrupts.with({ $0 }) == 0 { say("\(stamp())  stopping") }
        session.stop()
    }
    for _ in 0..<100 where summary.with({ $0.ended == nil }) { try? await Task.sleep(nanoseconds: 50_000_000) }
    videoSink?.close()
    audioSink?.close()

    let final = summary.with { $0 }
    say("Summary after \(stamp()):")
    say("  video: \(final.videoFrames) access units, \(final.videoBytes) bytes, \(final.keyFrames) key frames, "
        + "\(final.framesLostReported) frames lost, \(final.recoveredFrames) recovered, \(final.fecRecovered) rebuilt by FEC")
    say("  audio: \(final.audioPackets) packets, \(final.audioLost) lost, \(final.audioSkipped) skipped; "
        + "haptics frames \(final.hapticsFrames); rumble \(final.rumbleEvents); trigger effects \(final.triggerEvents)")
    if let sink = videoSink { say("  wrote \(sink.bytesWritten) bytes to \(sink.path)") }
    if let sink = audioSink { say("  wrote \(sink.bytesWritten) bytes to \(sink.path)") }
    if let last = final.lastStats {
        say("  last statistics: " + describe(last, simulatedLoss: showsSimulatedLoss))
        say("  from the console: "
            + (last.videoCodecByte.map { describeCodecByte($0, asked: codec) } ?? "no video packet seen") + "; "
            + (last.padInfoBodyLength.map(describePadInfo) ?? "no pad info seen"))
    }
    guard let reason = final.ended else { throw fail("The stream did not report its end") }
    if reason.isError { throw fail("The stream ended with an error: \(reason.userMessage(console: console.ps5 ? .ps5 : .ps4))") }
}
