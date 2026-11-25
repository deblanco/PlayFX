import Foundation
import os
@testable import StreamCore

/// A `StreamEngine` stand-in: records every command `StreamSession` sends, and plays the console's side through
/// the sink (video, audio, haptics, triggers, events) when a test asks. Keeps the contract's stop guarantee:
/// `stop()` delivers the `.stopped` quit (once, unless the session already quit) before it returns, and nothing
/// reaches the sink after it.
final class FakeStreamEngine: StreamEngine, @unchecked Sendable {
    enum Command: Equatable {
        case controller(ControllerState)
        case loginPin(String)
        case microphone(Bool)
        case microphoneFrame(count: Int)
        case keyboardText(String)
        case keyboardDone(accept: Bool)
        case keyFrame
        case goToBed
        case stop
    }

    let config: StreamEngineConfig
    /// Unretained, as the contract asks: the session owns the engine.
    private unowned(unsafe) let sink: any StreamEngineSink
    private struct State {
        var commands: [Command] = []
        var stopped = false
        var quit = false
        var stats = StreamEngineStats()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(config: StreamEngineConfig, sink: any StreamEngineSink) {
        self.config = config
        self.sink = sink
    }

    /// Starts a `StreamSession` on a fake engine.
    static func session(credentials: ConsoleCredentials = fakeCredentials(), options: StreamSession.Options = .init(),
                        remote: StreamSession.Remote? = nil) throws -> (StreamSession, FakeStreamEngine) {
        var made: FakeStreamEngine?
        let session = try StreamSession(credentials: credentials, options: options, remote: remote) { config, sink in
            let engine = FakeStreamEngine(config: config, sink: sink)
            made = engine
            return engine
        }
        return (session, made!)
    }

    var commands: [Command] { state.withLock { $0.commands } }
    var isStopped: Bool { state.withLock { $0.stopped } }
    /// What `stats()` reports while running.
    func report(_ stats: StreamEngineStats) { state.withLock { $0.stats = stats } }

    // MARK: The console's side (each refused, returning nil, once stopped)

    /// Runs `body` with the sink unless stopped: nothing reaches the sink after `stop()`.
    private func toSink<T>(_ body: (any StreamEngineSink) -> T) -> T? {
        guard !isStopped else { return nil }
        return body(sink)
    }

    @discardableResult
    func send(_ event: StreamSession.Event) -> Bool? {
        if case .quit = event { state.withLock { $0.quit = true } }
        return toSink { $0.deliver(event) }.map { true }
    }

    @discardableResult
    func sendVideo(_ unit: Data, framesLost: Int = 0) -> Bool? {
        toSink { sink in unit.withUnsafeBytes { sink.handleVideo($0, framesLost: framesLost) } }
    }

    @discardableResult
    func sendAudio(channels: Int, rate: Int, _ pcm: [Int16]) -> Bool? {
        toSink { sink in
            sink.handleAudioFormat(channels: channels, sampleRate: rate)
            pcm.withUnsafeBufferPointer { sink.handleAudio($0.baseAddress!, frames: pcm.count / channels) }
            return true
        }
    }

    /// One haptics frame (interleaved stereo); the sink's answer (true = played on a pad).
    func sendHaptics(_ samples: [Int16]) -> Bool? {
        toSink { sink in samples.withUnsafeBufferPointer { sink.handleHaptics($0) } }
    }

    @discardableResult
    func sendTriggerEffects(_ leftMode: UInt8, _ left: [UInt8], _ rightMode: UInt8, _ right: [UInt8]) -> Bool? {
        toSink { $0.handleTriggerEffects(leftMode, left, rightMode, right) }.map { true }
    }

    // MARK: StreamEngine

    private func record(_ command: Command) {
        state.withLock { if !$0.stopped { $0.commands.append(command) } }
    }

    func setController(_ state: ControllerState) { record(.controller(state)) }
    func setLoginPin(_ pin: String) { record(.loginPin(pin)) }
    func setMicrophone(_ on: Bool) { record(.microphone(on)) }
    func sendMicrophoneFrame(_ samples: UnsafeBufferPointer<Int16>) { record(.microphoneFrame(count: samples.count)) }
    func setKeyboardText(_ text: String) { record(.keyboardText(text)) }
    func finishKeyboard(accept: Bool) { record(.keyboardDone(accept: accept)) }
    func requestKeyFrame() { record(.keyFrame) }
    func goToBed() { record(.goToBed) }
    func stats() -> StreamEngineStats { state.withLock { $0.stopped ? StreamEngineStats() : $0.stats } }

    func stop() {
        let first = state.withLock { state -> (first: Bool, quit: Bool) in
            defer { state.stopped = true }
            if !state.stopped { state.commands.append(.stop) }
            return (!state.stopped, state.quit)
        }
        guard first.first, !first.quit else { return }
        // From an engine thread, as a real engine's ending would come, and before returning.
        let sink = sink
        let delivered = DispatchSemaphore(value: 0)
        Thread {
            sink.deliver(.quit(reason: "Stopped", error: false, kind: .stopped))
            delivered.signal()
        }.start()
        delivered.wait()
    }
}
