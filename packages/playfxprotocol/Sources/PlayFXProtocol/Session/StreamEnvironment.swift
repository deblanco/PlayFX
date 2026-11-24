import Foundation

/// The timeouts of the network probe (stream.md sections 5 and 12). The defaults are the spec's; tests shorten them.
struct ProbeTiming: Sendable {
    /// The probe's Takion handshake as a whole.
    var connectTimeout = 30.0
    /// One INIT or COOKIE try.
    var stepTimeout = 5.0
    /// The version ack, the HelloReply, the echo and client-MTU acknowledgements, the client-MTU answer.
    var answerTimeout = 5.0
    /// One ping's pong.
    var pongTimeout = 1.0
    var pings = 10
    /// `T = clamp(5 x rtt, minimum, maximum)`, the wait per MTU attempt.
    var mtuWaitMinimum = 0.005
    var mtuWaitMaximum = 0.5
}

/// Everything `StreamSession` takes from the outside world, replaceable by tests (as `ControlEnvironment` is for
/// ctrl): ports, clocks, transports and the key pair.
struct StreamEnvironment: Sendable {
    var control = ControlEnvironment()
    /// Replace the console's ports 9297 and 9296 (the hand-off's) when set.
    var probePort: UInt16?
    var streamPort: UInt16?
    var probe = ProbeTiming()
    /// The stream connection's Takion handshake (stream.md section 12), the HelloReply and the StreamInfo waits.
    var streamConnectTimeout = 5.0
    var streamStepTimeout = 5.0
    var helloReplyTimeout = 5.0
    var streamInfoTimeout = 5.0
    /// How long a ctrl end waits for the console's Takion Disconnect before it becomes the end reason.
    var ctrlEndGrace = 0.2
    /// Clock of the manual IDR throttle.
    var clock: @Sendable () -> Double = monotonicSeconds
    var heartbeatInterval = 1.0
    var statsInterval = 1.0
    /// `(transport, host, port, dontFragment)`.
    var makeTransport: @Sendable (StreamTransport, String, UInt16, Bool) -> DatagramTransport = { kind, host, port, dontFragment in
        switch kind {
        case .bsd: BSDDatagramTransport(host: host, port: port, dontFragment: dontFragment)
        case .nw: NWDatagramTransport(host: host, port: port, dontFragment: dontFragment)
        }
    }
    var makeKeyPair: @Sendable () throws -> StreamKeyPair = { try StreamKeyPair() }
}
