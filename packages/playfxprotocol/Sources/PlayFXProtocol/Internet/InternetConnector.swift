import Darwin
import Foundation

// Internet Remote Play, end to end (holepunch.md section 8): UPnP, the PSN session, the ctrl hole, the registration
// through PSN, session init and ctrl over RUDP, the data hole, the probe, the switch and the stream connection, and
// the leaving at the end on every path.
//
// `InternetConnector.prepare` runs steps 1 to 8 and returns an `InternetLink`; `StreamSession` runs session init and
// ctrl on it (steps 9 and 10) and then asks it for the data hole, the probe and stream sockets and the switch (steps
// 11 to 14). The link owns everything that must be given back: its `shutdown()` closes the sockets and the RUDP
// connection, leaves the PSN session and removes the UPnP mappings, whichever way the session ends.

/// The part of a UPnP gateway the connector uses (so tests can stand in for the router).
protocol PortMapper: Sendable {
    /// `AddPortMapping` for one hole's port and the external address; nil when either fails (the hole then uses STUN).
    func mapPort(_ port: UInt16) -> UPnPMapping?
    /// `DeletePortMapping` for each port, attempted even when its mapping had failed.
    func removeMappings(_ ports: [UInt16])
}

extension UPnPGateway: PortMapper {
    func mapPort(_ port: UInt16) -> UPnPMapping? { map(localPort: port) }
    func removeMappings(_ ports: [UInt16]) { cleanup(ports: ports) }
}

/// Everything the connector takes from the outside world, replaceable by tests (as `StreamEnvironment` is for the
/// stream): PSN's HTTP and WebSocket, the router, the sockets, STUN, the interface list, timings and randomness.
struct InternetEnvironment: Sendable {
    var transport: any PSNTransport = URLSessionPSNTransport()
    var makeWebSocket: @Sendable () -> any PSNWebSocket = { URLSessionPSNWebSocket() }
    /// The UPnP gateway, found within 7 s; the closure is the cancel check.
    var discoverGateway: @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> (any PortMapper)? = { cancelled in
        UPnPGateway.discover(environment: UPnPEnvironment(isCancelled: cancelled))
    }
    /// A UDP socket bound to `0.0.0.0` on a port the system chooses (holepunch.md section 2).
    var makeSocket: @Sendable () throws -> any UDPPunchSocket = { try POSIXPunchSocket() }
    var interfaceAddress: @Sendable () -> String? = { LocalInterfaces.firstUsableIPv4(LocalInterfaces.all()) }
    /// The STUN servers in the order to ask. The built-in list, shuffled as holepunch.md section 3.2 says; the
    /// third-party host list it may fetch first is not used (that fetch is a network call of its own).
    var stunServers: @Sendable () -> [StunServer] = {
        var generator = SystemRandomNumberGenerator()
        return StunClient.builtInServers(using: &generator)
    }
    var stun = StunEnvironment()
    var punch = HolePunchOptions()
    var rudp = RUDPTimings()
    var makeParameters: @Sendable () -> PSNSessionParameters = { PSNSessionParameters.random() }
    /// The whole registration through PSN (registration.md section 8.6).
    var registrationTimeout = 10.0
    /// Draining the data socket before each Takion connection (holepunch.md section 7).
    var drainStep = 0.2
    var drainLimit = 1.0
    /// Ctrl's response header wait: longer than the RUDP handshake and request tries add up to.
    var ctrlHeaderTimeout = 15.0
    /// How long ctrl is waited on for the session ID before the data hole starts without it (holepunch.md section 8), and
    /// how much longer after the hole.
    var sessionIDWait = 10.0
    var sessionIDWaitAfterHole = 5.0
    /// Called with each link as it is made (tests keep it to look at what was given back).
    var linkCreated: @Sendable (InternetLink) -> Void = { _ in }
    /// The unrequested heartbeat reply over RUDP (ctrl.md section 10).
    var unsolicitedHeartbeatInterval = 4.95
}

/// Runs blocking work on a thread of its own, so neither the cooperative pool nor a dispatch queue is held.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try body() }) }
        thread.name = "PlayFXProtocol.internet"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

enum InternetConnector {
    /// Steps 1 to 8 of holepunch.md section 8. On failure, and on cancellation, everything made so far is given back
    /// before this throws.
    static func prepare(remote: PSNRemote, options: InternetOptions, environment: InternetEnvironment) async throws
        -> (link: InternetLink, pairing: PairingResult)
    {
        let link = InternetLink(remote: remote, options: options, environment: environment)
        environment.linkCreated(link)
        do {
            let pairing = try await withTaskCancellationHandler {
                try await link.establish()
            } onCancel: {
                link.cancel()
            }
            return (link, pairing)
        } catch {
            // Classified first: giving everything back cancels the token, which would make every error "cancelled".
            let failure = link.classify(error)
            if failure != .cancelled { link.logFailure(failure) }
            // A cancel returns at once: the leaving (up to 13 s on a bad network) goes on in the background.
            if failure == .cancelled { link.shutdown() } else { await link.shutdownAndWait() }
            throw failure
        }
    }
}

/// An internet session in progress: the PSN session, the ctrl hole's RUDP channel, what was registered, and the
/// resources to give back.
final class InternetLink: @unchecked Sendable {
    /// What `shutdown` gives back, and whether it already did.
    private struct Held {
        var session: PSNRemotePlaySession?
        var gateway: (any PortMapper)?
        var ports: [UInt16] = []
        var sockets: [any UDPPunchSocket] = []
        var rudp: RUDPConnection?
        /// The data hole's descriptor, until a transport adopts it.
        var descriptor: Int32?
        var shut = false
        var finished: Task<Void, Never>?
        var statistics: (any DispatchSourceTimer)?
    }

    let remote: PSNRemote
    let options: InternetOptions
    let environment: InternetEnvironment
    let token = CancelToken()
    private let held = NSLock()
    private var heldState = Held()

    // Set once by `establish`, before the link is handed out.
    private(set) var session: PSNRemotePlaySession?
    private(set) var signaling: PSNPunchSignaling?
    private(set) var identity = PunchIdentity.random()
    private(set) var rudp: RUDPConnection?
    private(set) var ctrlHole: PunchedHole?
    private var gateway: (any PortMapper)?
    private var ctrlPrediction: NATPrediction?
    private var consoleStarted: PSNStartedConsole?
    /// The first thing the data-hole, probe-to-stream steps failed with (StreamSession only sees "stream failed").
    private let failureLock = NSLock()
    private var recordedFailure: InternetStartError?

    init(remote: PSNRemote, options: InternetOptions, environment: InternetEnvironment) {
        self.remote = remote
        self.options = options
        self.environment = environment
    }

    var failure: InternetStartError? { failureLock.withLock { recordedFailure } }

    func record(_ error: InternetStartError) {
        failureLock.withLock { if recordedFailure == nil { recordedFailure = error } }
    }

    /// The stage most recently reported, for the line a failure logs.
    private(set) var stage: InternetStage?

    func report(_ stage: InternetStage) {
        self.stage = stage
        note("stage \(stage.rawValue)")
        options.progress(stage)
    }

    func note(_ line: String) { options.log(line) }

    /// The exact error a start failed with and the stage it was in (always logged: the app shows only a message).
    func logFailure(_ error: InternetStartError) {
        note("start failed during stage \(stage?.rawValue ?? "none"): \(error)")
    }

    /// With the trace on, the RUDP counters every 2 s; the last ones are logged by `shutdown` either way.
    private func startStatisticsTimer(for rudp: RUDPConnection) {
        guard options.rudpTrace else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        let log = options.log
        timer.setEventHandler { [weak rudp] in
            guard let rudp else { return }
            log(Self.describe(rudp.statistics))
        }
        timer.resume()
        held.withLock { heldState.statistics = timer }
    }

    static func describe(_ s: RUDPStatistics) -> String {
        "rudp stats: \(s.datagramsOut) datagram(s) out, \(s.datagramsIn) in, \(s.frames) ctrl frame(s), "
            + "\(s.retransmissions) retransmission(s), \(s.abandoned) abandoned, \(s.unkept) unkept, "
            + "\(s.duplicates) duplicate(s), \(s.malformed) malformed, \(s.unknownTypes) unknown type(s)"
            + (s.retransmissionsByKind.isEmpty ? "" : "; retransmitted: "
                + s.retransmissionsByKind.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
    }

    var cancelCheck: @Sendable () -> Bool { { [token] in token.isCancelled } }

    // MARK: Steps 1 to 8

    func establish() async throws -> PairingResult {
        report(.linkingPSN)
        let check = cancelCheck
        // 1. UPnP discovery (at most 7 s). Any gateway found goes in the cleanup, whatever happens next.
        if options.useUPnP {
            let discover = environment.discoverGateway
            let found = try await runBlocking { discover(check) }
            gateway = found
            held.withLock { heldState.gateway = found }
            note(found == nil ? "UPnP: no usable gateway, STUN will be used" : "UPnP: gateway found")
        }
        try Task.checkCancellation()

        // 2 and 3. The push server and its WebSocket, open before the session exists.
        let client = PSNClient(
            accessToken: remote.accessToken, transport: environment.transport, timeouts: options.psnTimeouts)
        let channel = try await client.openPushChannel(socket: environment.makeWebSocket())
        // 4. The session (it takes the channel, and leaves again if it can't finish creating itself).
        let session = try await PSNRemotePlaySession.create(
            client: client, channel: channel, parameters: environment.makeParameters())
        self.session = session
        held.withLock { heldState.session = session }
        let adapter = PSNPunchSignaling(session: session)
        signaling = adapter
        token.onCancel { adapter.cancel() }
        identity = PunchIdentity(sid: session.parameters.localSid, hashedID: session.parameters.localHashedID)
        note("PSN session created")

        // 5. The ctrl socket and the client's candidates (the OFFER is built, not sent yet).
        let socket = try makeHoleSocket()
        let environment = self.environment
        let (candidates, prediction) = try await runBlocking { [self] in
            try buildCandidates(socket: socket, hole: .ctrl, answersWanted: 4, ctrlPrediction: nil, environment: environment)
        }
        ctrlPrediction = prediction
        try Task.checkCancellation()

        // 6. The start command, then the console's join and `customData1`.
        report(.wakingConsole)
        let started = try await session.start(
            remote.platform == .ps5 ? .ps5(duid: remote.consoleDUID) : .ps4)
        consoleStarted = started
        note("console joined (\(started.platform.rawValue))")

        // 7. The ctrl hole.
        report(.ctrlHole)
        let hole = try await runBlocking { [self] in
            try punch(socket: socket, candidates: candidates, peerSid: 0, hole: .ctrl)
        }
        ctrlHole = hole
        note("ctrl hole open: \(Self.describe(hole.selected))")

        // 8. RUDP on it, and the registration through PSN, whose keys this whole session then uses.
        let trace: (@Sendable (String) -> Void)? = options.rudpTrace ? options.log : nil
        let channelRUDP = RUDPConnection(socket: hole.socket, timings: environment.rudp, trace: trace, log: options.log)
        rudp = channelRUDP
        startStatisticsTimer(for: channelRUDP)
        held.withLock { heldState.rudp = channelRUDP }
        token.onCancel { channelRUDP.close() }
        report(.registering)
        let registered = try await register(over: channelRUDP, started: started, host: candidates.local?.address ?? "")
        note("registered through PSN")
        return registered
    }

    private func register(over rudp: RUDPConnection, started: PSNStartedConsole, host: String) async throws
        -> PairingResult
    {
        guard let session else { throw InternetStartError.cancelled }
        let accountID = (0..<8).map { UInt8(truncatingIfNeeded: session.accountID >> UInt64(8 * $0)) }
        let (data1, data2) = (session.parameters.data1, session.parameters.data2)
        let target = remote.target
        let fired = LockedFlag(false)
        let watchdog = DispatchWorkItem { fired.set(true); rudp.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + environment.registrationTimeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            return try await runBlocking {
                try PSNRegistration.run(
                    over: rudp, target: target, accountID: accountID, data1: data1, data2: data2,
                    customData1: started.customData1, host: host)
            }
        } catch var error as RegistrationError {
            if fired.get() { error = RegistrationError(kind: .timeout, consoleAnswered: false) }
            throw InternetStartError.registration(error)
        }
    }

    // MARK: Candidates and holes

    private func makeHoleSocket() throws -> any UDPPunchSocket {
        do {
            let socket = try environment.makeSocket()
            let lost = held.withLock { () -> Bool in
                if heldState.shut { return true }
                heldState.sockets.append(socket)
                return false
            }
            if lost {
                socket.close()
                throw InternetStartError.cancelled
            }
            return socket
        } catch let error as InternetStartError {
            throw error
        } catch let kind as FailureKind {
            throw InternetStartError.socket(kind)
        }
    }

    /// UPnP mapping or STUN for one hole, then the candidate list (holepunch.md sections 3, 4). Blocking.
    private func buildCandidates(
        socket: any UDPPunchSocket, hole: InternetHole, answersWanted: Int, ctrlPrediction: NATPrediction?,
        environment: InternetEnvironment
    ) throws -> (ClientCandidates, NATPrediction?) {
        let port = socket.localPort
        // The mapping is attempted for the hole's port and always removed later, even when it failed.
        let isShut = held.withLock { () -> Bool in
            if heldState.shut { return true }
            heldState.ports.append(port)
            return false
        }
        if isShut { throw InternetStartError.cancelled }
        let mapping = gateway?.mapPort(port)
        var prediction: NATPrediction?
        if mapping == nil {
            if gateway != nil {
                note("\(hole.rawValue) hole: UPnP found a gateway but the mapping or the external address failed (or the address isn't public); using STUN")
            }
            var stun = environment.stun
            stun.isCancelled = cancelCheck
            let log = options.log
            stun.log = { log("\(hole.rawValue) hole: \($0)") }
            let answers = StunClient.collect(
                socket: socket, servers: environment.stunServers(), wanted: answersWanted, environment: stun)
            if answersWanted == 1 {
                prediction = answers.first.map { NATPrediction.forDataHole(answer: $0, ctrl: ctrlPrediction) }
                note("\(hole.rawValue) hole: \(answers.count) STUN answer(s); "
                    + (prediction.map { "base port \($0.basePort), step \($0.increment) and random allocation "
                        + "\($0.randomAllocation ? "yes" : "no") taken from the ctrl hole" } ?? "no public address from STUN"))
            } else {
                prediction = NATPrediction.predict(answers)
                note("\(hole.rawValue) hole: " + NATPrediction.explain(answers: answers, prediction: prediction, localPort: port))
            }
        } else {
            note("\(hole.rawValue) hole: UPnP mapped port \(port); external address \(AddressMask.describe(mapping?.publicAddress ?? ""))")
        }
        if token.isCancelled { throw InternetStartError.cancelled }
        do {
            let inputs = CandidateInputs(
                localPort: port, interfaceAddress: environment.interfaceAddress(), upnp: mapping, stun: prediction,
                forcePortGuessing: options.forcePortGuessing)
            let built = try CandidateBuilder.build(inputs)
            let stunCount = built.candidates.filter { $0.type == .stun }.count
            let plan: String
            if built.randomAllocation {
                plan = "port guesses: \(stunCount), extra low-TTL sockets: \(environment.punch.extraSocketCount)"
                    + (options.forcePortGuessing ? " (forcePortGuessing)" : "")
            } else if stunCount > 0 {
                plan = "predicted ports: \(stunCount), no extra sockets"
            } else {
                plan = "no STUN candidates (the NAT keeps the port or UPnP mapped it), no extra sockets"
            }
            if let prediction, prediction.isPerDestination {
                note("\(hole.rawValue) hole: per-destination NAT: ports differ between servers; using port guesses and "
                    + "\(environment.punch.extraSocketCount) extra sockets")
            }
            note("\(hole.rawValue) hole: local port \(port), offering \(AddressMask.describe(built.candidates)); \(plan)")
            return (built, prediction)
        } catch {
            throw InternetStartError.noPublicAddress
        }
    }

    /// One hole: the probes and the PSN exchange around them (holepunch.md section 5). Blocking. Closes `socket` on
    /// failure.
    private func punch(socket: any UDPPunchSocket, candidates: ClientCandidates, peerSid: UInt16, hole: InternetHole)
        throws -> PunchedHole
    {
        guard let signaling else { throw InternetStartError.cancelled }
        var punchOptions = environment.punch
        punchOptions.isCancelled = cancelCheck
        punchOptions.probeIdentity = options.probeIdentity
        let log = options.log
        punchOptions.log = { log("\(hole.rawValue) hole: \($0)") }
        do {
            return try HolePunch.run(
                socket: socket, identity: identity, client: candidates, peerSid: peerSid, signaling: signaling,
                options: punchOptions)
        } catch PunchError.cancelled {
            throw InternetStartError.cancelled
        } catch let error as PunchError {
            if case .signalingFailed = error, let psn = signaling.failure { throw InternetStartError.psn(psn) }
            throw InternetStartError.holePunch(hole: hole, error)
        } catch let kind as FailureKind {
            // The selected pair couldn't be connected to: the system's refusal, as for any socket.
            throw InternetStartError.socket(kind)
        }
    }

    // MARK: Steps 11 to 14 (called by StreamSession on its start thread)

    /// The data hole (step 11), after ctrl has the session ID. Blocking. Keeps the punched descriptor for the probe
    /// and the stream connection.
    func punchDataHole() throws {
        report(.dataHole)
        let socket = try makeHoleSocket()
        let (candidates, _) = try buildCandidates(
            socket: socket, hole: .data, answersWanted: 1, ctrlPrediction: ctrlPrediction, environment: environment)
        let hole = try punch(socket: socket, candidates: candidates, peerSid: ctrlHole?.consoleSid ?? 0, hole: .data)
        note("data hole open: \(Self.describe(hole.selected))")
        guard let descriptor = hole.socket.releaseDescriptor() else {
            throw InternetStartError.socket(.disconnected)
        }
        guard holdDescriptor(descriptor) else {
            Darwin.close(descriptor)
            throw InternetStartError.cancelled
        }
    }

    /// Keeps the punched descriptor for the probe and the stream transport; false (the caller closes it) when the link
    /// was already shut down.
    func holdDescriptor(_ descriptor: Int32) -> Bool {
        held.withLock { () -> Bool in
            if heldState.shut { return false }
            heldState.descriptor = descriptor
            return true
        }
    }

    /// Whether the data hole is open (and not yet handed to a transport).
    var hasDataHole: Bool { held.withLock { heldState.descriptor != nil } }

    /// The probe's transport (step 12): the data socket drained, then a `dup` of it, so the probe's end leaves the
    /// socket open for the stream connection (takion.md section 18).
    func probeTransport() throws -> DatagramTransport {
        report(.probing)
        // The copy is made under the lock, so the descriptor can't have been closed (and its number reused) by then;
        // the drain and the transport work on the copy.
        let copy = try held.withLock { () -> Int32 in
            guard !heldState.shut, let descriptor = heldState.descriptor else { throw InternetStartError.cancelled }
            let copy = dup(descriptor)
            guard copy >= 0 else { throw InternetStartError.socket(FailureKind(errno: errno)) }
            return copy
        }
        let drained = PunchedSocket.drain(descriptor: copy, step: environment.drainStep, limit: environment.drainLimit)
        note("probe: drained \(drained) datagram(s)")
        return BSDDatagramTransport(adopting: copy, dontFragment: true)
    }

    /// The RUDP switch message and the console's ctrl `0x0034` (step 13).
    enum SwitchResult: Equatable {
        case acknowledged
        /// No `0x0034` in 5 s.
        case timedOut
        /// The start was cancelled or the connection closed under the wait.
        case aborted
        /// The console ended ctrl (FINISH) during the wait.
        case ctrlEnded
    }

    func switchToStream() -> SwitchResult {
        report(.streamConnecting)
        guard let rudp, (try? rudp.sendSwitch()) != nil else { return .aborted }
        let result: SwitchResult
        switch rudp.waitForSwitch() {
        case .acknowledged: result = .acknowledged
        case .timedOut: result = .timedOut
        case .consoleFinished: result = .ctrlEnded
        case .closed: result = .aborted
        }
        note(result == .acknowledged ? "switch acknowledged (ctrl 0x0034)" : "switch failed: \(result)")
        return result
    }

    /// The stream connection's transport (step 14): the same socket, drained again, which the transport now owns.
    func streamTransport(dontFragment: Bool) throws -> DatagramTransport {
        // The transport owns the descriptor from here; a shutdown after this point no longer closes it.
        guard let descriptor = held.withLock({ () -> Int32? in
            guard !heldState.shut else { return nil }
            defer { heldState.descriptor = nil }
            return heldState.descriptor
        }) else { throw InternetStartError.cancelled }
        let drained = PunchedSocket.drain(descriptor: descriptor, step: environment.drainStep, limit: environment.drainLimit)
        note("stream: drained \(drained) datagram(s)")
        return BSDDatagramTransport(adopting: descriptor, dontFragment: dontFragment)
    }

    // MARK: Session init and ctrl over RUDP

    /// The ctrl environment for `ControlSession`: `base` (what was injected) with RUDP instead of TCP and the ctrl hole's
    /// selection as `Host`.
    func controlEnvironment(base: ControlEnvironment = ControlEnvironment()) -> ControlEnvironment {
        var control = base
        let port = ctrlHole?.selected.port ?? 0
        control.internet = true
        control.initPort = port
        control.ctrlPort = port
        control.ctrlHeaderTimeout = environment.ctrlHeaderTimeout
        control.unsolicitedHeartbeatInterval = environment.unsolicitedHeartbeatInterval
        guard let rudp else { return control }
        control.makeInitConnection = { _, _ in RUDPHTTPConnection(rudp) }
        control.makeCtrlConnection = { _, _ in RUDPCtrlLink(rudp) }
        return control
    }

    /// The `Host` header's address: the ctrl hole's selected candidate (holepunch.md section 6).
    var consoleAddress: String { ctrlHole?.selected.address ?? "" }

    // MARK: Ending

    /// Stops what is running: the hole punches, STUN, the PSN waits and the RUDP channel give up. Nothing is given
    /// back yet; `shutdown` does that.
    func cancel() { token.cancel() }

    /// Gives everything back, once: closes the sockets and the RUDP connection, leaves the PSN session (DELETE, the
    /// wait for its notification, the push channel closed) and removes the UPnP mappings. Returns at once; the
    /// leaving finishes in the background. Safe from any thread, repeatedly.
    func shutdown() { _ = startShutdown() }

    /// `shutdown`, and waits until the PSN session is left and the mappings are gone.
    func shutdownAndWait() async { await startShutdown().value }

    private func startShutdown() -> Task<Void, Never> {
        let note = options.log
        // Everything that decides who gives what back happens in this one section: the flag, the descriptor (so no
        // transport can take it after it is closed) and the task that waits for the leaving.
        let (items, task) = held.withLock { () -> (Held?, Task<Void, Never>) in
            if let finished = heldState.finished { return (nil, finished) }
            heldState.shut = true
            let items = heldState
            heldState.descriptor = nil
            let task = Task.detached {
                if let session = items.session {
                    let result = await session.leave()
                    note("PSN session left (DELETE \(result.deleteSucceeded ? "ok" : "failed"), "
                        + "deletion \(result.deletionConfirmed ? "confirmed" : "not confirmed"))")
                }
                if let gateway = items.gateway, !items.ports.isEmpty {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        Thread {
                            gateway.removeMappings(items.ports)
                            done.resume()
                        }.start()
                    }
                    note("UPnP mappings removed (\(items.ports.count) port(s))")
                }
            }
            heldState.finished = task
            return (items, task)
        }
        guard let items else { return task }
        items.statistics?.cancel()
        if let rudp = items.rudp { options.log(Self.describe(rudp.statistics) + " (final)") }
        token.cancel()
        for socket in items.sockets { socket.close() }
        items.rudp?.close()
        if let descriptor = items.descriptor { Darwin.close(descriptor) }
        return task
    }

    /// What `prepare` throws for whatever failed.
    func classify(_ error: any Error) -> InternetStartError {
        if let typed = error as? InternetStartError {
            return typed == .cancelled || !token.isCancelled ? typed : .cancelled
        }
        if token.isCancelled || error is CancellationError { return .cancelled }
        if let psn = error as? PSNError { return .psn(psn) }
        if let kind = error as? FailureKind { return .socket(kind) }
        return .stream(StreamEndReason(code: .streamFailed), detail: "\(error)")
    }

    // MARK: Logging helpers

    static func describe(_ candidate: PunchCandidate) -> String {
        "\(candidate.type.rawValue) \(AddressMask.describe(candidate.address, port: candidate.port))"
    }
}

/// A lock around one value (the registration watchdog's flag).
final class LockedFlag<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
