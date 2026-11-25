import Foundation

/// TESTING ONLY, off by default: drop datagrams the stream connection receives, before Takion sees them, so that
/// FEC, the reorder queue, Takion retransmission and corrupt-frame reports run on real console traffic.
/// Set through `StreamSessionOptions.simulatedReceiveLoss`. Dropping starts once the stream is up (the
/// handshake isn't touched), and the probe is never affected.
public struct SimulatedLoss: Sendable, Equatable {
    /// The long-run share of received datagrams dropped, in percent (above 0, at most 50).
    public var percent: Double
    /// Datagrams dropped in a row each time a drop starts (1 to `maxBurst`). The share stays `percent`: bursts start
    /// less often when they are longer.
    public var burst: Int
    /// Seeds the generator; the same seed over the same arrivals drops the same datagrams.
    public var seed: UInt64

    /// The longest burst accepted.
    public static let maxBurst = 1000

    /// Nil unless `percent` is above 0 and at most 50, `burst` is 1 to `maxBurst`, and the chance that a drop
    /// starts is not so small that it rounds to zero (a loss that could never drop anything).
    public init?(percent: Double, burst: Int = 1, seed: UInt64 = 0x5EED_1055) {
        guard percent.isFinite, percent > 0, percent <= 50, (1...Self.maxBurst).contains(burst),
              LossGate.threshold(percent: percent, burst: burst) > 0 else { return nil }
        self.percent = percent
        self.burst = burst
        self.seed = seed
    }
}

/// The decision, one datagram at a time: splitmix64 and integer maths only, so it allocates nothing.
struct LossGate: Sendable {
    private var state: UInt64
    /// The chance a drop starts at a datagram, scaled to 2^53. With a start chance `s` and bursts of `n`, the
    /// share dropped is `n / (n + (1 - s) / s)`; solving for the share `p` gives `s = p / (n (1 - p) + p)`.
    private let threshold: UInt64
    private let burst: Int
    private var remaining = 0

    init(_ loss: SimulatedLoss) {
        state = loss.seed
        burst = loss.burst
        threshold = Self.threshold(percent: loss.percent, burst: loss.burst)
    }

    static func threshold(percent: Double, burst: Int) -> UInt64 {
        let p = percent / 100
        let start = p / (Double(burst) * (1 - p) + p)
        return UInt64(start * 9_007_199_254_740_992)
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func shouldDrop() -> Bool {
        if remaining > 0 {
            remaining -= 1
            return true
        }
        guard next() >> 11 < threshold else { return false }
        remaining = burst - 1
        return true
    }
}

/// The gate plus its on/off switch and its count, safe to read from any thread.
final class LossFilter: @unchecked Sendable {
    private let lock = UnfairLock()
    private var gate: LossGate
    private var armed: Bool
    private var count = 0

    init(_ loss: SimulatedLoss, armed: Bool = false) {
        gate = LossGate(loss)
        self.armed = armed
    }

    /// Starts dropping (the session does this when the stream is up).
    func arm() { lock.withLock { armed = true } }

    /// True when this datagram is to be dropped (and counted).
    func shouldDrop() -> Bool {
        lock.withLock {
            guard armed, gate.shouldDrop() else { return false }
            count += 1
            return true
        }
    }

    var dropped: Int { lock.withLock { count } }
}

/// A `TransportHandler` that drops what its filter says and passes on the rest.
final class LossyTransportHandler: TransportHandler, @unchecked Sendable {
    private let inner: TransportHandler
    private let filter: LossFilter

    init(inner: TransportHandler, filter: LossFilter) {
        self.inner = inner
        self.filter = filter
    }

    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {
        if filter.shouldDrop() { return }
        inner.transportDidReceive(datagram, at: timestamp, kernelTimestamp: kernelTimestamp)
    }

    func transportNextWake() -> UInt64? { inner.transportNextWake() }
    func transportWake(now: UInt64) { inner.transportWake(now: now) }
    func transportFailed(errno: Int32) { inner.transportFailed(errno: errno) }
}

/// Wraps the stream connection's transport so what it receives goes through the loss filter first.
final class LossyDatagramTransport: DatagramTransport, @unchecked Sendable {
    let inner: DatagramTransport
    let filter: LossFilter
    private let wrapperLock = UnfairLock()
    private var wrapper: LossyTransportHandler?

    init(_ inner: DatagramTransport, filter: LossFilter) {
        self.inner = inner
        self.filter = filter
    }

    /// The wrapper while started (tests check that it lives exactly from `start` to `stop`).
    var activeWrapper: AnyObject? { wrapperLock.withLock { wrapper } }

    var name: String { inner.name }
    var localPort: UInt16 { inner.localPort }
    func start(handler: TransportHandler) throws {
        // Held here: Network.framework's transport keeps its handler weakly.
        let wrapper = LossyTransportHandler(inner: handler, filter: filter)
        wrapperLock.withLock { self.wrapper = wrapper }
        do { try inner.start(handler: wrapper) } catch {
            wrapperLock.withLock { self.wrapper = nil }
            throw error
        }
    }
    func send(_ bytes: UnsafeRawBufferPointer) throws { try inner.send(bytes) }
    func reschedule() { inner.reschedule() }
    func stop() {
        inner.stop()
        wrapperLock.withLock { wrapper = nil }
    }
}
