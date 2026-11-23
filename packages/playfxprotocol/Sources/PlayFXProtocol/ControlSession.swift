import Foundation
import Network

// MARK: Public types

/// Client choices for a session. All defaults follow session.md and ctrl.md.
public struct ControlOptions: Sendable, Equatable {
    /// The codec announced on ctrl (PS5 only).
    public var streamingType: StreamingType = .h264
    /// Whether to send the DualSense feature messages after the session ID; nil means for a PS5 only.
    public var dualSense: Bool?
    /// Whether to send the keyboard-enable messages after the session ID. Off: sending them to a PS5 makes
    /// it end the stream (ctrl.md section 6.5).
    public var enableKeyboard = false
    /// Seconds to wait for a session ID (or a login PIN request) after ctrl comes up, and again after a
    /// PIN is sent (session.md section 8). Waiting for the user to type the PIN is not limited.
    public var startupTimeout = 10.0
    /// Seconds without a heartbeat request, counted from the first one, after which the channel ends. A PS5
    /// was observed sending one every 5 s (ctrl.md, "Observed on a real console") and the console gives up
    /// on a client after about 30 s without a reply, so 60 s is 12 missed requests and twice that limit.
    public var heartbeatTimeout = 60.0

    public init() {}
}

/// The session ID from ctrl (`0x33`). Its text goes to the stream stage; it is not printed by accident.
public struct SessionID: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let value: String
    public var customMirror: Mirror { Mirror(self, children: []) }
    public var length: Int { value.utf8.count }
    public var description: String { "SessionID(\(length) characters)" }
    public var debugDescription: String { description }
}

/// A display notice from the console (ctrl.md section 6.7; the meaning is inferred).
public enum DisplayNotice: Sendable, Equatable {
    /// `0x0001`: set means the picture may become unavailable; cleared means it may be back.
    case a(set: Bool)
    /// `0x0016`: `clearsState` is true for a payload starting `01 FF`; otherwise, while notice A is set,
    /// the console shows content that can't be streamed.
    case b(payload: [UInt8], clearsState: Bool)
}

/// Why the ctrl channel ended.
public enum ControlEndReason: Sendable, Equatable, CustomStringConvertible {
    /// `stop()` was called.
    case stoppedByClient
    /// The console closed the connection (also what follows go-to-bed). Not an error by itself.
    case consoleClosed
    /// A read or write failed.
    case connectionLost(FailureKind)
    /// No heartbeat request for `ControlOptions.heartbeatTimeout` after the first.
    case heartbeatTimeout
    /// No session ID or PIN request in time.
    case startupTimeout
    /// The console asked for a login PIN after the session ID, which can't be met.
    case loginPINAfterSessionID
    /// The session ID was malformed.
    case invalidSessionID
    /// A frame over the size limit (1 MiB).
    case frameTooLarge(length: UInt32)
    /// A payload could not be decrypted.
    case protocolError

    public var description: String {
        switch self {
        case .stoppedByClient: "stopped by client"
        case .consoleClosed: "console closed the connection"
        case .connectionLost(let kind): "connection lost (\(kind))"
        case .heartbeatTimeout: "no heartbeat request"
        case .startupTimeout: "no session ID in time"
        case .loginPINAfterSessionID: "login PIN requested after the session ID"
        case .invalidSessionID: "invalid session ID"
        case .frameTooLarge(let length): "frame of \(length) bytes is too large"
        case .protocolError: "payload could not be decrypted"
        }
    }
}

/// What the ctrl channel reports, delivered in order on the session's private serial queue.
public enum ControlEvent: Sendable, Equatable {
    /// Session init succeeded with this (negotiated) version after `attempts` requests.
    case sessionInitialized(version: RPTarget, attempts: Int)
    /// The ctrl HTTP exchange succeeded. `pictureProhibited` is `RP-Prohibit: 1`.
    case connected(model: ConsoleModel?, pictureProhibited: Bool)
    case loginPINRequested
    case loginPINResult(accepted: Bool)
    case sessionID(SessionID)
    /// A heartbeat request arrived and was answered; `count` is how many so far.
    case heartbeat(count: Int)
    case displayNotice(DisplayNotice)
    case keyboardOpened(text: String)
    case keyboardTextChanged(sequence: UInt32, text: String)
    case keyboardClosed
    /// A message of a type the client has no meaning for (or whose payload didn't fit its layout).
    case notice(type: UInt16, payload: [UInt8])
    /// Always the last event.
    case ended(ControlEndReason)
}

/// Everything the stream stage needs from session init and ctrl (session.md section 12). Keep the
/// `ControlSession` it came from alive, and don't call `stop()`, for the whole stream: ctrl must keep
/// answering heartbeats (ctrl.md section 7), and closing it ends the session.
public struct StreamHandoff: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var consoleAddress: String
    public var streamPort: UInt16 = 9296
    public var probePort: UInt16 = 9297
    public var negotiatedVersion: RPTarget
    /// The session cipher; `crypt.key` is `sessionAesKey` and `crypt.seed` is `sessionIvSeed`.
    public var crypt: RPCryptContext
    public var sessionID: SessionID
    /// 16 secure random bytes made when the session ID arrived (session.md section 6.3).
    public var streamHandshakeKey: [UInt8]
    public var consoleModel: ConsoleModel?
    /// What was announced on ctrl; nil for a PS4.
    public var streamingType: StreamingType?
    public var dualSenseEnabled: Bool

    public var description: String { "StreamHandoff(\(consoleAddress), \(negotiatedVersion), keys hidden)" }
    public var debugDescription: String { description }
    /// No children: `dump` must not print keys or the session ID.
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Why a command was not sent.
public enum ControlCommandError: Error, Sendable, Equatable {
    /// The channel isn't up (yet) or has ended.
    case notRunning
    /// `sendLoginPIN` with no login PIN request pending.
    case noPINRequested
    /// The PIN is not 1 to 32 ASCII digits.
    case invalidPIN
}

// MARK: Environment

/// Everything that touches the outside world or the clock, replaceable by tests.
struct ControlEnvironment: Sendable {
    var initPort: UInt16 = 9295
    var ctrlPort: UInt16 = 9295
    var connectTimeout = 5.0
    var sendTimeout = 5.0
    var initHeaderTimeout = 5.0
    var ctrlHeaderTimeout = 5.0
    /// Pause between session init and ctrl (session.md section 2).
    var pauseBeforeCtrl = 0.010
    /// Wait before resending after a reset before the response header (ctrl.md section 2).
    var resetRetryDelay = 0.035
    var maximumResetRetries = 3
    var makeInitConnection: @Sendable (_ host: String, _ port: UInt16) throws -> BlockingTCPConnection = { host, port in
        try NWBlockingTCPConnection(host: host, port: port)
    }
    var makeCtrlConnection: @Sendable (_ host: String, _ port: UInt16) throws -> NWConnection = { host, port in
        try CtrlFramer.makeConnection(host: host, port: port)
    }
    var randomBytes: @Sendable (_ count: Int) -> [UInt8] = secureRandomBytes
}

/// A cancellable one-shot timer on a queue.
private final class Deadline: @unchecked Sendable {
    private var item: DispatchWorkItem?

    func arm(on queue: DispatchQueue, after seconds: Double, _ body: @escaping @Sendable () -> Void) {
        cancel()
        let work = DispatchWorkItem(block: body)
        item = work
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    func cancel() {
        item?.cancel()
        item = nil
    }
}

// MARK: Session

/// Session init plus the ctrl channel of one Remote Play session (session.md, ctrl.md).
///
/// `start` runs session init, opens ctrl and returns once the console accepted the ctrl request. Everything
/// after that arrives as `ControlEvent`s on a private serial queue. The handler gets the session with each
/// event, because events (a login PIN request, say) can arrive before `start` returns. Commands may be
/// called from any thread, including the handler; each throws `ControlCommandError` when it can't be sent
/// (the channel isn't running, or `sendLoginPIN` has no request to answer). The session must stay alive,
/// and not be stopped, for the whole stream (ctrl keeps answering heartbeats).
/// Call `stop()` when done: it closes the connection and emits `.ended(.stoppedByClient)`.
public final class ControlSession: @unchecked Sendable {
    private enum Phase { case idle, connecting, awaitingHead, active, ended }

    // Fixed at creation.
    private let address: String
    private let registKey: [UInt8]
    private let options: ControlOptions
    private let environment: ControlEnvironment
    /// Confined to `queue`; released when the channel ends so a handler can't keep the session alive.
    private var events: (@Sendable (ControlEvent, ControlSession) -> Void)?
    private let queue = DispatchQueue(label: "PlayFXProtocol.ControlSession")

    // Readable from any thread.
    private let lock = NSLock()
    private var shared: Shared
    private struct Shared {
        var negotiated: RPTarget
        var model: ConsoleModel?
        var handoff: StreamHandoff?
        var ended: ControlEndReason?
        /// Ctrl is up and not ended.
        var running = false
        /// A login PIN request waits for an answer.
        var pinPending = false
    }

    // Confined to `queue`.
    private var phase = Phase.idle
    private var context: RPCryptContext?
    private var request: CtrlRequest?
    private var link: NWConnection?
    private var generation = 0
    private var resets = 0
    private var timeoutRetried = false
    private var localCounter: UInt64 = 0
    private var remoteCounter: UInt64 = 0
    private var heartbeats = 0
    private var sessionIDReceived = false
    private var keyboardSequence: UInt32 = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private let connectTimer = Deadline()
    private let headerTimer = Deadline()
    private let retryTimer = Deadline()
    private let startupTimer = Deadline()
    private let heartbeatTimer = Deadline()

    private init(
        address: String, target: RPTarget, registKey: [UInt8], options: ControlOptions,
        environment: ControlEnvironment, events: @escaping @Sendable (ControlEvent, ControlSession) -> Void
    ) {
        self.address = address
        self.registKey = registKey
        self.options = options
        self.environment = environment
        self.events = events
        shared = Shared(negotiated: target)
    }

    deinit {
        link?.cancel()
    }

    // MARK: Starting

    /// Runs session init, then opens ctrl. `target` is the version to start with (`.ps5v1` for a PS5,
    /// `.ps4v10` for a PS4); a console that answers with another version is followed (session.md 5.3).
    /// `registKey` and `rpKey` are 16 bytes each. Throws `SessionError`; cancelling the task stops it
    /// promptly and throws `.cancelled`. Once this returns, cancelling the task no longer matters: call `stop()`.
    public static func start(
        address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8],
        options: ControlOptions = ControlOptions(), events: @escaping @Sendable (ControlEvent, ControlSession) -> Void
    ) async throws -> ControlSession {
        try await start(
            environment: ControlEnvironment(), address: address, target: target, registKey: registKey,
            rpKey: rpKey, options: options, events: events)
    }

    static func start(
        environment: ControlEnvironment, address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8],
        options: ControlOptions, events: @escaping @Sendable (ControlEvent, ControlSession) -> Void
    ) async throws -> ControlSession {
        let session = ControlSession(
            address: address, target: target, registKey: registKey, options: options, environment: environment,
            events: events)
        do {
            try await session.run(target: target, rpKey: rpKey)
        } catch {
            session.queue.async { session.finish(nil) }
            throw error as? SessionError ?? SessionError.cancelled
        }
        return session
    }

    private func run(target: RPTarget, rpKey: [UInt8]) async throws {
        let token = CancelToken()
        var client = SessionInitClient()
        client.port = environment.initPort
        client.connectTimeout = environment.connectTimeout
        client.sendTimeout = environment.sendTimeout
        client.headerTimeout = environment.initHeaderTimeout
        client.token = token
        client.makeConnection = environment.makeInitConnection
        let ready = client
        let result: SessionInitResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try ready.run(address: self.address, target: target, registKey: self.registKey, rpKey: rpKey)
                    })
                }
            }
        } onCancel: {
            token.cancel()
        }
        let request: CtrlRequest
        do {
            request = try CtrlRequest.build(
                host: address, port: environment.ctrlPort, target: result.target, context: result.context,
                registKey: registKey, deviceID: CtrlRequest.deviceID(random: environment.randomBytes(16)),
                streamingType: options.streamingType)
        } catch {
            throw SessionError.cryptoFailure
        }
        queue.async {
            self.context = result.context
            self.request = request
            self.localCounter = request.nextLocalCounter
            self.update { $0.negotiated = result.target }
            self.emit(.sessionInitialized(version: result.target, attempts: result.attempts))
        }
        do {
            try await Task.sleep(nanoseconds: UInt64(environment.pauseBeforeCtrl * 1e9))
        } catch {
            throw SessionError.cancelled
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard self.phase == .idle else {
                        continuation.resume(throwing: SessionError.cancelled)
                        return
                    }
                    self.startContinuation = continuation
                    self.beginAttempt()
                }
            }
        } onCancel: {
            // Once ctrl is up the session belongs to the caller: only a start still in progress is cancelled.
            queue.async { if self.phase != .active { self.failStart(.cancelled) } }
        }
    }

    // MARK: Public state

    /// The version session init settled on.
    public var negotiatedVersion: RPTarget { lock.withLock { shared.negotiated } }
    /// The console model from `RP-Server-Type`, once ctrl is up.
    public var consoleModel: ConsoleModel? { lock.withLock { shared.model } }
    /// What the stream stage needs; nil until the session ID has arrived.
    public var handoff: StreamHandoff? { lock.withLock { shared.handoff } }
    /// Why ctrl ended; nil while it runs.
    public var endReason: ControlEndReason? { lock.withLock { shared.ended } }

    private func emit(_ event: ControlEvent) { events?(event, self) }

    private func update(_ change: (inout Shared) -> Void) { lock.withLock { change(&shared) } }

    // MARK: Commands

    /// Answers a pending login PIN request with the PIN's digits (1 to 32 of them). Throws
    /// `ControlCommandError`: `.invalidPIN`, `.noPINRequested` (nothing is sent) or `.notRunning`.
    public func sendLoginPIN(_ pin: String) throws {
        guard let message = CtrlOutgoing.loginPIN(pin) else { throw ControlCommandError.invalidPIN }
        try lock.withLock {
            guard shared.running else { throw ControlCommandError.notRunning }
            guard shared.pinPending else { throw ControlCommandError.noPINRequested }
            shared.pinPending = false
        }
        queue.async {
            if self.write(message), !self.sessionIDReceived { self.armStartupTimer() }
        }
    }

    /// Replaces the text of the console's focused text field. Messages are numbered from 1; the number
    /// advances only when a message is sent.
    public func keyboardSetText(_ text: String) throws {
        try requireRunning()
        queue.async {
            let next = self.keyboardSequence &+ 1
            if self.write(.keyboardSetText(sequence: next, text: text)) { self.keyboardSequence = next }
        }
    }

    /// Closes the console's keyboard as if Return was pressed.
    public func keyboardDone() throws { try send(.keyboardClose(accept: true)) }

    /// Closes the console's keyboard as if Esc was pressed.
    public func keyboardCancel() throws { try send(.keyboardClose(accept: false)) }

    /// Sends the keyboard-enable messages. A PS5 may end the stream when it gets them (ctrl.md section 6.5).
    public func enableKeyboard() throws {
        try send(.keyboardEnable)
        try send(.keyboardToggle)
    }

    /// Puts the console into rest mode. The console then closes the session.
    public func goToBed() throws { try send(.goToBed) }

    /// Asks the console to show its home screen.
    public func goHome() throws { try send(.goHome) }

    /// Announces that microphone audio will follow on the stream connection (`0x0030`).
    public func connectMicrophone() throws { try send(.microphoneConnect) }

    /// Sets the microphone state byte: `0x0036` with `00 01 XX 59`, XX = 1 for true. Which value means
    /// muted is not known (ctrl.md section 11): the start-up sequence sends 1.
    public func setMicrophone(_ on: Bool) throws { try send(.microphoneState(on ? 1 : 0)) }

    /// Closes everything and emits `.ended(.stoppedByClient)` (once). Safe to call at any time, repeatedly.
    public func stop() {
        queue.async { self.finish(.stoppedByClient) }
    }

    private func requireRunning() throws {
        guard lock.withLock({ shared.running }) else { throw ControlCommandError.notRunning }
    }

    private func send(_ message: CtrlOutgoing) throws {
        try requireRunning()
        queue.async { self.write(message) }
    }

    // MARK: Connection (queue only)

    private func beginAttempt() {
        guard phase == .idle || phase == .connecting || phase == .awaitingHead else { return }
        let connection: NWConnection
        do {
            connection = try environment.makeCtrlConnection(address, environment.ctrlPort)
        } catch {
            failStart(.from(error as? FailureKind ?? .badAddress))
            return
        }
        phase = .connecting
        link = connection
        generation += 1
        let attempt = generation
        connection.stateUpdateHandler = { [weak self] state in self?.linkState(state, attempt: attempt) }
        connection.start(queue: queue)
        connectTimer.arm(on: queue, after: environment.connectTimeout) { [weak self] in
            guard let self, attempt == self.generation, self.phase == .connecting else { return }
            self.failStart(.noAnswer(.timeout))
        }
    }

    private func linkState(_ state: NWConnection.State, attempt: Int) {
        guard attempt == generation else { return }
        switch state {
        case .ready:
            guard phase == .connecting, let request, let link else { return }
            connectTimer.cancel()
            phase = .awaitingHead
            headerTimer.arm(on: queue, after: environment.ctrlHeaderTimeout) { [weak self] in
                self?.headerTimedOut(attempt: attempt)
            }
            sendRaw(request.bytes, attempt: attempt)
            receiveNext(link, attempt: attempt)
        case .waiting(let error):
            if phase == .connecting { failStart(.from(NWBlockingTCPConnection.failure(error))) }
        case .failed(let error):
            lost(NWBlockingTCPConnection.failure(error), attempt: attempt)
        default:
            break
        }
    }

    /// The connection broke: a retryable reset before the response header, an end afterwards.
    private func lost(_ kind: FailureKind, attempt: Int) {
        guard attempt == generation else { return }
        switch phase {
        case .connecting: failStart(.from(kind))
        case .awaitingHead: retryAfterReset(kind)
        case .active: finish(.connectionLost(kind))
        default: break
        }
    }

    /// Reconnects with the byte-identical request, up to the retry limit (ctrl.md section 2).
    private func retryAfterReset(_ kind: FailureKind) {
        headerTimer.cancel()
        link?.cancel()
        link = nil
        guard resets < environment.maximumResetRetries else {
            failStart(.ctrlResetRepeatedly)
            return
        }
        resets += 1
        phase = .connecting
        generation += 1
        retryTimer.arm(on: queue, after: environment.resetRetryDelay) { [weak self] in self?.beginAttempt() }
    }

    private func headerTimedOut(attempt: Int) {
        guard attempt == generation, phase == .awaitingHead else { return }
        guard !timeoutRetried else {
            failStart(.noAnswer(.timeout))
            return
        }
        timeoutRetried = true
        link?.cancel()
        link = nil
        phase = .connecting
        beginAttempt()
    }

    private func sendRaw(_ bytes: [UInt8], attempt: Int) {
        link?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.lost(NWBlockingTCPConnection.failure(error), attempt: attempt)
        })
    }

    private func receiveNext(_ connection: NWConnection, attempt: Int) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, attempt == self.generation, self.phase != .ended else { return }
            if let error {
                self.lost(NWBlockingTCPConnection.failure(error), attempt: attempt)
                return
            }
            guard let data, !data.isEmpty else {
                // The console closed the stream.
                if self.phase == .active { self.finish(.consoleClosed) } else { self.lost(.disconnected, attempt: attempt) }
                return
            }
            self.handle(CtrlStreamSplitter.decode(Array(data)))
            if self.phase != .ended, self.generation == attempt { self.receiveNext(connection, attempt: attempt) }
        }
    }

    // MARK: Receiving (queue only)

    private func handle(_ item: CtrlStreamSplitter.Item?) {
        switch item {
        case .head(let bytes)?:
            if phase == .awaitingHead { handleHead(bytes) }
        case .frame(let type, let payload)?:
            if phase == .active { handleFrame(type: type, encrypted: payload) }
        case .oversize(let length)?:
            if phase == .active {
                finish(.frameTooLarge(length: length))
            } else {
                failStart(.invalidResponse)
            }
        case nil:
            if phase == .active { finish(.protocolError) } else { failStart(.invalidResponse) }
        }
    }

    /// The ctrl HTTP response (ctrl.md section 3.2).
    private func handleHead(_ bytes: [UInt8]) {
        guard case .head(let head) = MiniHTTP.parseHead(bytes), let context else {
            failStart(.invalidResponse)
            return
        }
        guard head.status == 200 else {
            failStart(head.applicationReason.map { .from(reason: $0) } ?? .ctrlRejected(status: head.status))
            return
        }
        var model: ConsoleModel?
        remoteCounter = 0
        if let text = head.headers["rp-server-type"] {
            guard let decoded = Data(base64Encoded: text) else {
                failStart(.invalidResponse)
                return
            }
            if decoded.count == 16, let plain = try? context.decrypted(Array(decoded), counter: 0) {
                model = ConsoleModel(rawValue: plain[0])
                remoteCounter = 1
            }
        }
        headerTimer.cancel()
        phase = .active
        let prohibited = head.headers["rp-prohibit"] == "1"
        update { $0.model = model; $0.running = true }
        emit(.connected(model: model, pictureProhibited: prohibited))
        armStartupTimer()
        startContinuation?.resume()
        startContinuation = nil
    }

    private func armStartupTimer() {
        startupTimer.arm(on: queue, after: options.startupTimeout) { [weak self] in self?.finish(.startupTimeout) }
    }

    private func handleFrame(type: UInt16, encrypted: [UInt8]) {
        var payload = encrypted
        if !payload.isEmpty {
            guard let context, (try? context.decrypt(&payload, counter: remoteCounter)) != nil else {
                finish(.protocolError)
                return
            }
            remoteCounter += 1
        }
        switch CtrlInbound.decode(type: type, payload: payload) {
        case .loginPINRequest:
            if sessionIDReceived {
                finish(.loginPINAfterSessionID)
            } else {
                startupTimer.cancel()
                update { $0.pinPending = true }
                emit(.loginPINRequested)
            }
        case .loginResult(let accepted):
            emit(.loginPINResult(accepted: accepted))
        case .sessionID(let raw):
            if !sessionIDReceived { acceptSessionID(raw) }
        case .heartbeatRequest:
            write(.heartbeatReply)
            heartbeats += 1
            heartbeatTimer.arm(on: queue, after: options.heartbeatTimeout) { [weak self] in
                self?.finish(.heartbeatTimeout)
            }
            emit(.heartbeat(count: heartbeats))
        case .displayNoticeA(let set):
            emit(.displayNotice(.a(set: set)))
        case .displayNoticeB(let bytes, let clears):
            emit(.displayNotice(.b(payload: bytes, clearsState: clears)))
        case .keyboardOpened(let text):
            emit(.keyboardOpened(text: text))
        case .keyboardClosedByConsole:
            emit(.keyboardClosed)
        case .keyboardTextChanged(let sequence, let text):
            emit(.keyboardTextChanged(sequence: sequence, text: text))
        case .unknown(let type, let bytes):
            emit(.notice(type: type, payload: bytes))
        }
    }

    /// The session ID arrived: hand-off values, then the start-up feature messages (ctrl.md section 8).
    private func acceptSessionID(_ raw: [UInt8]) {
        guard let parsed = CtrlInbound.parseSessionID(raw), let context else {
            finish(.invalidSessionID)
            return
        }
        sessionIDReceived = true
        startupTimer.cancel()
        let target = lock.withLock { shared.negotiated }
        let dualSense = options.dualSense ?? target.isPS5
        let id = SessionID(value: parsed.id)
        let handoff = StreamHandoff(
            consoleAddress: address, negotiatedVersion: target, crypt: context, sessionID: id,
            streamHandshakeKey: environment.randomBytes(16), consoleModel: lock.withLock { shared.model },
            streamingType: target.isPS5 ? options.streamingType : nil, dualSenseEnabled: dualSense)
        update { $0.handoff = handoff }
        emit(.sessionID(id))
        for message in CtrlOutgoing.startup(dualSense: dualSense, keyboard: options.enableKeyboard) { write(message) }
    }

    // MARK: Sending and ending (queue only)

    /// Encrypts with the next counter when the payload is not empty, and writes the frame.
    @discardableResult
    private func write(_ message: CtrlOutgoing) -> Bool {
        guard phase == .active, let link, let context else { return false }
        var payload = message.payload
        if !payload.isEmpty {
            guard (try? context.encrypt(&payload, counter: localCounter)) != nil else {
                finish(.protocolError)
                return false
            }
            localCounter += 1
        }
        let attempt = generation
        link.send(
            content: Data(CtrlWire.frame(type: message.type, payload: payload)),
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.lost(NWBlockingTCPConnection.failure(error), attempt: attempt)
            })
        return true
    }

    /// Fails `start`: wakes it with the error and tears down without an `.ended` event.
    private func failStart(_ error: SessionError) {
        guard phase != .ended else { return }
        let continuation = startContinuation
        startContinuation = nil
        finish(nil)
        continuation?.resume(throwing: error)
    }

    /// Closes everything. `reason` nil means no event (the session never became active).
    private func finish(_ reason: ControlEndReason?) {
        guard phase != .ended else { return }
        let wasActive = phase == .active
        phase = .ended
        connectTimer.cancel()
        headerTimer.cancel()
        retryTimer.cancel()
        startupTimer.cancel()
        heartbeatTimer.cancel()
        link?.stateUpdateHandler = nil
        link?.cancel()
        link = nil
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: SessionError.cancelled)
        }
        update { $0.running = false; $0.pinPending = false }
        if wasActive, let reason {
            update { $0.ended = reason }
            emit(.ended(reason))
        }
        events = nil
    }
}
