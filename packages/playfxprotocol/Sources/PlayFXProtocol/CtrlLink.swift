import Foundation
import Network

/// What the ctrl channel's link reports about itself.
enum CtrlLinkState: Sendable, Equatable {
    case ready
    /// It can't proceed (refused, no route): during connecting this ends the attempt.
    case waiting(FailureKind)
    case failed(FailureKind)
    case cancelled
}

/// The byte link under `ControlSession`: a TCP connection with the ctrl framer on the LAN (`NWCtrlLink`), the
/// RUDP channel of the ctrl hole over the internet (`RUDPCtrlLink`). Everything above it (the request, the
/// header, the frames, the encryption) is the same.
///
/// A link delivers what `CtrlStreamSplitter.encode` makes of each item (the response header, then one frame at a
/// time), so `ControlSession` reads both the same way.
protocol CtrlLink: AnyObject, Sendable {
    /// Starts connecting; `state` is called on `queue` (or any queue for a link with nothing to connect).
    func start(queue: DispatchQueue, state: @escaping @Sendable (CtrlLinkState) -> Void)
    /// Sends the request, then each frame. `completion` gets nil when it went out.
    func send(_ bytes: [UInt8], completion: @escaping @Sendable (FailureKind?) -> Void)
    /// The next item: bytes, or nil bytes and nil failure when the console closed the channel.
    func receiveMessage(_ handler: @escaping @Sendable (_ item: [UInt8]?, _ failure: FailureKind?) -> Void)
    /// Stops everything the link does; no callback follows.
    func cancel()
}

/// `CtrlLink` over `NWConnection` (TCP with `CtrlFramer`).
final class NWCtrlLink: CtrlLink, @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue, state: @escaping @Sendable (CtrlLinkState) -> Void) {
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready: state(.ready)
            case .waiting(let error): state(.waiting(NWBlockingTCPConnection.failure(error)))
            case .failed(let error): state(.failed(NWBlockingTCPConnection.failure(error)))
            case .cancelled: state(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ bytes: [UInt8], completion: @escaping @Sendable (FailureKind?) -> Void) {
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            completion(error.map { NWBlockingTCPConnection.failure($0) })
        })
    }

    func receiveMessage(_ handler: @escaping @Sendable ([UInt8]?, FailureKind?) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let error {
                handler(nil, NWBlockingTCPConnection.failure(error))
            } else {
                handler(data.map { Array($0) }, nil)
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    deinit { connection.cancel() }
}

/// `CtrlLink` over the ctrl hole's RUDP channel (rudp.md sections 5 to 7, ctrl.md section 10). The first `send` is
/// the HTTP start request: it runs the RUDP exchange on a thread of its own (up to 3 tries of 1 s per step, so the
/// caller's queue is never held), and the response and then every ctrl frame the console sends are handed on as
/// items. Later `send`s are ctrl frames, one RUDP data message each.
final class RUDPCtrlLink: CtrlLink, @unchecked Sendable {
    private struct State {
        var started = false
        var cancelled = false
        var splitter = CtrlStreamSplitter()
        var items: [[UInt8]] = []
        var waiter: (@Sendable ([UInt8]?, FailureKind?) -> Void)?
        var ended: (closed: Bool, failure: FailureKind?)?
    }

    private let rudp: RUDPConnection
    private let lock = NSLock()
    private var state = State()

    init(_ rudp: RUDPConnection) { self.rudp = rudp }

    func start(queue: DispatchQueue, state report: @escaping @Sendable (CtrlLinkState) -> Void) {
        // Nothing to connect: the socket is punched already.
        queue.async { report(.ready) }
    }

    func send(_ bytes: [UInt8], completion: @escaping @Sendable (FailureKind?) -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { state.started = true }
            return !state.started
        }
        if first {
            let thread = Thread { [self] in runStartRequest(bytes, completion: completion) }
            thread.name = "PlayFXProtocol.rudp.ctrl-start"
            thread.qualityOfService = .userInitiated
            thread.start()
            return
        }
        do {
            try rudp.sendCtrlFrame(bytes)
            completion(nil)
        } catch {
            completion(Self.failure(error))
        }
    }

    private func runStartRequest(_ request: [UInt8], completion: @escaping @Sendable (FailureKind?) -> Void) {
        let response: [UInt8]
        do {
            response = try rudp.exchange(request: request, expectFinish: false)
        } catch {
            if lock.withLock({ state.cancelled }) { return }
            completion(Self.failure(error))
            return
        }
        // The response goes in first and ctrl starts after it, so no frame can overtake the header.
        deliver(response)
        do {
            try rudp.startCtrl { [weak self] event in self?.handle(event) }
        } catch {
            completion(Self.failure(error))
            return
        }
        completion(nil)
    }

    private func handle(_ event: RUDPEvent) {
        switch event {
        case .ctrlFrame(let frame): deliver(frame)
        case .finished: end(failure: nil)
        case .failed(let error): end(failure: Self.failure(error))
        }
    }

    typealias Handler = @Sendable ([UInt8]?, FailureKind?) -> Void

    /// Hands the waiting reader its next item, if both exist. Call with the lock held.
    private func takeReady() -> (Handler, [UInt8]?, FailureKind?)? {
        guard let waiter = state.waiter else { return nil }
        if !state.items.isEmpty {
            state.waiter = nil
            return (waiter, state.items.removeFirst(), nil)
        }
        if let ended = state.ended {
            state.waiter = nil
            return (waiter, nil, ended.failure)
        }
        return nil
    }

    private func deliver(_ bytes: [UInt8]) {
        let ready = lock.withLock { () -> (Handler, [UInt8]?, FailureKind?)? in
            guard !state.cancelled else { return nil }
            state.items += state.splitter.feed(bytes).map(CtrlStreamSplitter.encode)
            return takeReady()
        }
        if let (handler, item, failure) = ready { handler(item, failure) }
    }

    private func end(failure: FailureKind?) {
        let ready = lock.withLock { () -> (Handler, [UInt8]?, FailureKind?)? in
            guard state.ended == nil, !state.cancelled else { return nil }
            state.ended = (true, failure)
            return takeReady()
        }
        if let (handler, item, failure) = ready { handler(item, failure) }
    }

    func receiveMessage(_ handler: @escaping @Sendable ([UInt8]?, FailureKind?) -> Void) {
        let ready = lock.withLock { () -> (Handler, [UInt8]?, FailureKind?)? in
            guard !state.cancelled else { return nil }
            state.waiter = handler
            return takeReady()
        }
        if let (handler, item, failure) = ready { handler(item, failure) }
    }

    func cancel() {
        lock.withLock {
            state.cancelled = true
            state.waiter = nil
            state.items = []
        }
    }

    static func failure(_ error: any Error) -> FailureKind {
        switch error as? RUDPError {
        case .timeout?: .timeout
        case .closed?: .disconnected
        case .messageTooLarge?, .invalidArgument?, .wrongState?: .invalidInput
        case .receiveFailed?: .disconnected
        case nil: .other(errno: 0)
        }
    }
}
