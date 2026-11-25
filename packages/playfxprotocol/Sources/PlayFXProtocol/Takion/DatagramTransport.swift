import Foundation

// The socket under a Takion connection. Two implementations sit behind this protocol so the console can decide
// which is better (DESIGN.md "Stream transport, the open question"): `NWDatagramTransport` (Network.framework)
// and `BSDDatagramTransport` (a user-interactive thread on a BSD socket).

/// What a transport calls, always from its single receive thread or queue.
protocol TransportHandler: AnyObject, Sendable {
    /// One datagram. The buffer is valid only during the call and may be modified in place.
    /// `timestamp` is when the packet hit the Mac, in `takionNow()` nanoseconds, when `kernelTimestamp` is true;
    /// otherwise the transport had no kernel time for it and `timestamp` is just the time of the callback.
    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool)
    /// The deadline (`takionNow()` ns) the transport must call `transportWake` by, or nil for none.
    func transportNextWake() -> UInt64?
    func transportWake(now: UInt64)
    /// The socket failed (for example ICMP port unreachable); the transport has stopped.
    func transportFailed(errno: Int32)
}

protocol DatagramTransport: AnyObject, Sendable {
    var name: String { get }
    /// Starts receiving into `handler`. Returns when the socket is usable.
    func start(handler: TransportHandler) throws
    /// Sends one datagram to the peer. Safe from any thread.
    func send(_ bytes: UnsafeRawBufferPointer) throws
    /// The handler's `transportNextWake()` may have changed (called from any thread).
    func reschedule()
    func stop()
    /// The local UDP port once started (0 if unknown).
    var localPort: UInt16 { get }
}

extension TransportHandler {
    /// A datagram with a kernel timestamp.
    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64) {
        transportDidReceive(datagram, at: timestamp, kernelTimestamp: true)
    }
}

extension DatagramTransport {
    func send(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try send($0) } }
}
