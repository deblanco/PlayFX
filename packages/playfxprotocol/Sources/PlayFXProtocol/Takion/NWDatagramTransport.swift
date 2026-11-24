import Foundation
import Network

/// A lock-protected errno shared with the connection's state handler.
private final class ErrnoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ v: Int32) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

/// `NWConnection` UDP with the interactive-video service class and kernel receive times
/// (`NWProtocolIP.Options.calculateReceiveTime`). Several receives are kept outstanding inside `batch`, and each
/// datagram is copied into a preallocated buffer so the handler can decrypt in place.
final class NWDatagramTransport: DatagramTransport, @unchecked Sendable {
    let name = "nw"
    private let host: String
    private let port: UInt16
    private let dontFragment: Bool
    private let depth: Int
    private static let queueKey = DispatchSpecificKey<Void>()
    private let queue = DispatchQueue(label: "playfx.takion.nw", qos: .userInteractive)
    private var connection: NWConnection?
    private weak var handler: TransportHandler?
    private var timer: DispatchSourceTimer?
    private var armedFor: UInt64?
    private var stopped = false
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: TakionConstants.maxDatagram, alignment: 64)
    private let state = UnfairLock()
    private var port32: UInt16 = 0
    private var sendError: Int32?
    /// The last receive time handed on (the receive callbacks run one at a time on `queue`).
    private var lastStamp: UInt64 = 0

    init(host: String, port: UInt16, dontFragment: Bool = false, outstandingReceives: Int = 8) {
        self.host = host
        self.port = port
        self.dontFragment = dontFragment
        self.depth = outstandingReceives
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { buffer.deallocate() }

    var localPort: UInt16 { state.withLock { port32 } }

    func start(handler: TransportHandler) throws {
        guard let remote = NWEndpoint.Port(rawValue: port) else { throw FailureKind.badAddress }
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.shouldCalculateReceiveTime = true
            ip.disableFragmentation = dontFragment
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: remote, using: parameters)
        self.handler = handler
        state.withLock { self.connection = connection }
        let ready = DispatchSemaphore(value: 0)
        let failure = ErrnoBox()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let self, let path = connection.currentPath, case .hostPort(_, let p)? = path.localEndpoint {
                    self.state.withLock { self.port32 = p.rawValue }
                }
                ready.signal()
            case .failed(let error):
                failure.set(Self.errno(of: error))
                ready.signal()
                self?.fail(Self.errno(of: error))
            case .waiting(let error):
                failure.set(Self.errno(of: error))
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, failure.get() == nil || connection.state == .ready else {
            connection.cancel()
            throw FailureKind(errno: failure.get() ?? ETIMEDOUT)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.timerFired() }
        timer.resume()
        self.timer = timer
        queue.async { [self] in
            connection.batch { for _ in 0..<depth { postReceive() } }
            rearm()
        }
    }

    private static func errno(of error: NWError) -> Int32 {
        if case .posix(let code) = error { return code.rawValue }
        return EIO
    }

    func send(_ bytes: UnsafeRawBufferPointer) throws {
        // Network.framework reports a failed send through the completion, so the error surfaces on the next send.
        let (connection, previous) = state.withLock { () -> (NWConnection?, Int32?) in
            defer { sendError = nil }
            return (self.connection, sendError)
        }
        if let previous { throw FailureKind(errno: previous) }
        guard let connection else { throw FailureKind.disconnected }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.state.withLock { self?.sendError = Self.errno(of: error) } }
        })
    }

    func reschedule() { queue.async { [self] in rearm() } }

    func stop() {
        // Called from the receive queue itself when a delegate callback closes the connection.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { tearDown() } else { queue.sync { tearDown() } }
    }

    private func tearDown() {
        stopped = true
        timer?.cancel()
        timer = nil
        let old = state.withLock { () -> NWConnection? in
            defer { connection = nil }
            return connection
        }
        old?.cancel()
    }

    // MARK: On the queue

    private func postReceive() {
        connection?.receiveMessage { [weak self] data, context, _, error in
            self?.received(data, context, error)
        }
    }

    private func received(_ data: Data?, _ context: NWConnection.ContentContext?, _ error: NWError?) {
        guard !stopped, let handler else { return }
        if let error {
            fail(Self.errno(of: error))
            return
        }
        if let data, !data.isEmpty, data.count <= TakionConstants.maxDatagram {
            data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            var stamp = takionNow()
            var kernel = false
            // `receiveTime` is on the CLOCK_MONOTONIC_RAW timeline (measured against it on macOS 26): take its
            // age and subtract it from our own clock, so every timestamp is in `takionNow()` terms. Without it
            // the callback time is delivered and flagged as not a kernel time.
            if let meta = context?.protocolMetadata(definition: NWProtocolIP.definition) as? NWProtocolIP.Metadata,
               meta.receiveTime != 0 {
                let raw = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                if raw >= meta.receiveTime {
                    stamp &-= min(raw - meta.receiveTime, stamp)
                    kernel = true
                }
            }
            // The two clocks are read one after the other: a preemption between the reads makes the age look larger,
            // which could put this datagram before the previous one. Datagrams come in arrival order, so never go back.
            stamp = max(stamp, lastStamp)
            lastStamp = stamp
            handler.transportDidReceive(UnsafeMutableRawBufferPointer(start: buffer, count: data.count), at: stamp,
                                        kernelTimestamp: kernel)
        }
        postReceive()
        rearm()
    }

    private func fail(_ code: Int32) {
        guard !stopped else { return }
        stopped = true
        handler?.transportFailed(errno: code)
    }

    private func rearm() {
        guard !stopped, let handler, let timer else { return }
        let wanted = handler.transportNextWake()
        guard wanted != armedFor else { return }
        armedFor = wanted
        if let wanted {
            let now = takionNow()
            let delta = wanted > now ? Int(wanted - now) : 0
            timer.schedule(deadline: .now() + .nanoseconds(delta), leeway: .microseconds(100))
        } else {
            timer.schedule(deadline: .distantFuture)
        }
    }

    private func timerFired() {
        guard !stopped, let handler else { return }
        armedFor = nil
        handler.transportWake(now: takionNow())
        rearm()
    }
}
