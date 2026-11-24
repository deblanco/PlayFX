import COpus
import Foundation
import os
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

// What the PlayFX engine's tests share: a sink that records every call, a harness that runs the engine over
// loopback against PlayFXProtocol's fake console, and helpers to make Opus and haptics packets for it.

/// StreamCore's own (both it and PlayFXProtocol have a `StreamSession`).
typealias CoreSession = StreamCore.StreamSession
typealias CoreController = StreamCore.ControllerState

/// A `StreamEngineSink` that records everything the engine hands it, in order, and checks the contract's rules as
/// it goes: no call after `.quit`, none on the main thread, video/audio/haptics calls of one kind never overlap.
final class RecordingSink: StreamEngineSink, @unchecked Sendable {
    struct Unit: Equatable {
        var bytes: [UInt8]
        var framesLost: Int
    }
    struct State {
        var order: [String] = []
        var events: [CoreSession.Event] = []
        var units: [Unit] = []
        var audioFormats: [(channels: Int, rate: Int)] = []
        var audio: [[Int16]] = []
        var haptics: [[Int16]] = []
        var triggers: [(UInt8, [UInt8], UInt8, [UInt8])] = []
        var quitSeen = false
        var callsAfterQuit = 0
        var mainThreadCalls = 0
        var overlaps = 0
        var running: [String: Int] = [:]
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    /// What `handleVideo` answers for the unit with this index (0-based); true by default.
    nonisolated(unsafe) var videoResult: @Sendable (Int) -> Bool = { _ in true }
    /// What `handleHaptics` answers (true = played on a pad).
    nonisolated(unsafe) var hapticsPlayed = false
    /// Called inside each `deliver`, on the engine's thread, before it returns.
    nonisolated(unsafe) var onEvent: (@Sendable (CoreSession.Event) -> Void)?
    /// Called inside each `handleVideo`, before it answers.
    nonisolated(unsafe) var onVideo: (@Sendable (Int) -> Void)?

    private func begin(_ kind: String, _ text: String) {
        state.withLock { s in
            s.order.append(text)
            if s.quitSeen { s.callsAfterQuit += 1 }
            if Thread.isMainThread { s.mainThreadCalls += 1 }
            // Video, audio and haptics calls of one kind never overlap; events and triggers may come from two threads.
            if s.running[kind, default: 0] > 0, ["video", "audio", "haptics"].contains(kind) { s.overlaps += 1 }
            s.running[kind, default: 0] += 1
        }
    }
    private func end(_ kind: String) { state.withLock { $0.running[kind, default: 1] -= 1 } }

    func handleVideo(_ accessUnit: UnsafeRawBufferPointer, framesLost: Int) -> Bool {
        begin("video", "video")
        let unit = Unit(bytes: Array(accessUnit), framesLost: framesLost)
        let index = state.withLock { s -> Int in
            s.units.append(unit)
            return s.units.count - 1
        }
        onVideo?(index)
        defer { end("video") }
        return videoResult(index)
    }

    func handleAudioFormat(channels: Int, sampleRate: Int) {
        begin("audio", "audioFormat")
        state.withLock { $0.audioFormats.append((channels, sampleRate)) }
        end("audio")
    }

    func handleAudio(_ samples: UnsafePointer<Int16>, frames: Int) {
        begin("audio", "audio")
        let pcm = Array(UnsafeBufferPointer(start: samples, count: frames * 2))
        state.withLock { $0.audio.append(pcm) }
        end("audio")
    }

    func handleHaptics(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        begin("haptics", "haptics")
        let frame = Array(samples)
        state.withLock { $0.haptics.append(frame) }
        end("haptics")
        return hapticsPlayed
    }

    func handleTriggerEffects(_ leftMode: UInt8, _ left: [UInt8], _ rightMode: UInt8, _ right: [UInt8]) {
        begin("triggers", "triggers")
        state.withLock { $0.triggers.append((leftMode, left, rightMode, right)) }
        end("triggers")
    }

    func deliver(_ event: CoreSession.Event) {
        begin("event", label(event))
        state.withLock { s in
            s.events.append(event)
            if case .quit = event { s.quitSeen = true }
        }
        onEvent?(event)
        end("event")
    }

    var order: [String] { state.withLock { $0.order } }
    var labels: [String] { state.withLock { $0.events.map(label) } }
    var events: [CoreSession.Event] { state.withLock { $0.events } }
    var units: [Unit] { state.withLock { $0.units } }
    var audio: [[Int16]] { state.withLock { $0.audio } }
    var haptics: [[Int16]] { state.withLock { $0.haptics } }
    var quits: [String] { labels.filter { $0.hasPrefix("quit") } }

    /// The haptic-rumble events as (left, right).
    var hapticRumbles: [(UInt8, UInt8)] {
        events.compactMap { if case .hapticRumble(let l, let r) = $0 { (l, r) } else { nil } }
    }
}

/// The engine under test, its sink, and the fake console it talks to.
final class PlayFXHarness: @unchecked Sendable {
    let console: StreamConsole
    let sink = RecordingSink()
    let engine: PlayFXEngine

    /// The config of a session with the fake console (its keys, 127.0.0.1).
    static func config(ps5: Bool = true, codec: StreamEngineConfig.Codec = .h264) -> StreamEngineConfig {
        StreamEngineConfig(
            host: "127.0.0.1", ps5: ps5, registKey: Data(SessionVector.registKey), rpKey: Data(SessionVector.rpKey),
            accountID: Data(repeating: 1, count: 8), height: 1080, fps: 60, codec: codec, bitrateKbps: 0,
            autoDowngrade: false, remote: nil)
    }

    /// The engine's start, run against `console`'s loopback ports with fast timers.
    static func starter(_ console: StreamConsole, tweak: @escaping @Sendable (inout StreamEnvironment) -> Void = { _ in })
        -> PlayFXEngine.Starter
    {
        { _, target, regist, rp, settings, options, events in
            var environment = loopbackStreamEnvironment(console)
            tweak(&environment)
            return try await PlayFXLibrarySession.start(
                environment: environment, address: "127.0.0.1", target: target, registKey: regist, rpKey: rp,
                settings: settings, transport: .bsd, options: options, events: events)
        }
    }

    /// The library's session once started (to inject events as its receive thread would).
    let librarySession = OSAllocatedUnfairLock<PlayFXLibrarySession?>(initialState: nil)

    /// `onEvent` runs inside each `deliver` (with the engine, once it exists), before the engine starts connecting.
    init(console: StreamConsole? = nil, config: StreamEngineConfig = PlayFXHarness.config(),
         onEvent: (@Sendable (CoreSession.Event, PlayFXEngine) -> Void)? = nil, sinkReady: ((RecordingSink) -> Void)? = nil,
         tweak: @escaping @Sendable (inout StreamEnvironment) -> Void = { _ in }) throws {
        let console = try console ?? StreamConsole()
        self.console = console
        sinkReady?(sink)
        let engineBox = OSAllocatedUnfairLock<PlayFXEngine?>(initialState: nil)
        if let onEvent {
            sink.onEvent = { event in if let engine = engineBox.withLock({ $0 }) { onEvent(event, engine) } }
        }
        let box = librarySession
        // The engine's start, run against `console`'s loopback ports with fast timers.
        let starter: PlayFXEngine.Starter = { _, target, regist, rp, settings, options, events in
            var environment = loopbackStreamEnvironment(console)
            tweak(&environment)
            let session = try await PlayFXLibrarySession.start(
                environment: environment, address: "127.0.0.1", target: target, registKey: regist, rpKey: rp,
                settings: settings, transport: .bsd, options: options, events: events)
            box.withLock { $0 = session }
            return session
        }
        engine = try PlayFXEngine(config: config, sink: sink, start: starter)
        engineBox.withLock { $0 = engine }
    }

    deinit {
        engine.stop()
        console.stop()
    }

    /// Waits for `.connected`.
    func connect() async -> Bool {
        await waitUntil(timeout: 10) { sink.labels.contains("connected") && librarySession.withLock { $0 } != nil }
    }

    // MARK: The console's side

    private let packetIndex = OSAllocatedUnfairLock(initialState: UInt16(0))

    /// An audio packet of frame `frame`: its own Opus packet and the two before it, as the console repeats them
    /// (source unit, then frames `frame - 2` and `frame - 1`).
    func sendAudio(frame: UInt16, packets: [UInt16: [UInt8]]) {
        let payload = packets[frame]! + packets[frame &- 2]! + packets[frame &- 1]!
        let index = packetIndex.withLock { $0 &+= 1; return $0 }
        console.streamLink.perform { [console] in
            console.streamLink.send(console.streamConsole.av(
                video: false, packetIndex: index, frameIndex: frame,
                word: audioWord(total: 3, unitSize: 40, redundant: 2, source: 1), codec: 5, stream: 0, payload: payload))
        }
    }

    /// One haptics packet: `samples` interleaved stereo at 3000 Hz.
    func sendHaptics(frame: UInt16, samples: [Int16]) {
        let bytes = samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        let index = packetIndex.withLock { $0 &+= 1; return $0 }
        console.streamLink.perform { [console] in
            console.streamLink.send(console.streamConsole.av(
                video: false, packetIndex: index, frameIndex: frame,
                word: audioWord(total: 1, unitSize: bytes.count, redundant: 0, source: 1), codec: 5, stream: 2,
                payload: bytes))
        }
    }
}


/// `frames` frames of a 440 Hz tone, 10 ms each, as Opus packets the way the console makes them (CBR 32 kbit/s:
/// 40 bytes), keyed by frame index from `first`; and the PCM they were made from.
func opusTone(first: UInt16, frames: Int) -> [UInt16: [UInt8]] {
    let encoder = PlayFXOpusMicrophone()!
    var packets: [UInt16: [UInt8]] = [:]
    for n in 0..<frames {
        let pcm = (0..<960).map { i -> Int16 in
            let t = Double(n * 480 + i / 2) / 48000
            return Int16(8000 * sin(2 * .pi * 440 * t))
        }
        packets[first &+ UInt16(n)] = pcm.withUnsafeBufferPointer { encoder.encode($0) }!
    }
    return packets
}

/// libopus decoding `packets` in order on its own, for comparing with what the engine handed over; a nil packet
/// is concealed.
func referenceDecode(_ packets: [[UInt8]?]) -> [[Int16]] {
    let decoder = copus_decoder_create(48000, 2)!
    defer { copus_decoder_destroy(decoder) }
    var out = [Int16](repeating: 0, count: 5760 * 2)
    return packets.map { packet in
        let frames: Int32 = packet.map { p in p.withUnsafeBufferPointer { copus_decode(decoder, $0.baseAddress, Int32(p.count), &out, 5760) } }
            ?? copus_decode(decoder, nil, 0, &out, 480)
        return Array(out[0..<Int(frames) * 2])
    }
}
