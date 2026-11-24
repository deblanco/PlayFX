import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// STUN asked of all servers at once (a client choice, DESIGN.md): the same socket, the spec's server order, one 5 s wait
/// for all instead of one each.
@Suite(.serialized) struct StunConcurrencyTests {
    /// A STUN server on loopback with a delay and a port shift; `nil` delay never answers. Records who asked.
    final class Server: @unchecked Sendable {
        let socket: LoopbackGuardedPunchSocket
        let askedFrom = Locked<[UInt16]>([])
        let firstRequestAt = Locked<Double?>(nil)
        private let stopped = Locked(false)

        init(delay: Double?, shift: Int = 0, onFirstRequest: (@Sendable () -> Void)? = nil) throws {
            socket = try loopbackSocket()
            Thread { [self] in
                while !stopped.with({ $0 }) {
                    guard let packet = try? socket.receive(timeout: 0.02), packet.bytes.count == 20 else { continue }
                    if firstRequestAt.with({ let first = $0 == nil; if first { $0 = monotonicSeconds() }; return first }) {
                        onFirstRequest?()
                    }
                    askedFrom.with { $0.append(packet.port) }
                    guard let delay else { continue }
                    let reply = Self.reply(to: packet, shift: shift)
                    let socket = socket
                    Thread {
                        sleepSeconds(delay)
                        try? socket.send(reply, to: packet.host, port: packet.port)
                    }.start()
                }
            }.start()
        }

        static func reply(to packet: UDPPacket, shift: Int) -> [UInt8] {
            let cookie = StunClient.cookie
            let port = UInt16(truncatingIfNeeded: Int(packet.port) + shift) ^ 0x2112
            let address = zip(packet.host.split(separator: ".").compactMap { UInt8($0) }, cookie).map { $0 ^ $1 }
            let attribute: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xff)] + address
            return [0x01, 0x01, 0x00, UInt8(attribute.count)] + cookie + Array(packet.bytes[8..<20]) + attribute
        }

        var entry: StunServer { StunServer(host: "127.0.0.1", port: socket.localPort) }
        func stop() { stopped.with { $0 = true } }
    }

    static func environment(timeout: Double, cancelled: @escaping @Sendable () -> Bool = { false },
                            log: @escaping @Sendable (String) -> Void = { _ in }) -> StunEnvironment {
        StunEnvironment(resolve: { $0 == "gone.example" ? nil : "127.0.0.1" }, timeout: timeout, isCancelled: cancelled, log: log)
    }

    @Test func serversThatNeverAnswerCostOneTimeoutNotOneEach() throws {
        let silent = try (0..<4).map { _ in try Server(delay: nil) }
        defer { silent.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let lines = Locked<[String]>([])
        let began = monotonicSeconds()
        let answers = StunClient.collectConcurrently(
            socket: socket, servers: silent.map(\.entry), wanted: 4,
            environment: Self.environment(timeout: 0.5, log: { line in lines.with { $0.append(line) } }))
        let elapsed = monotonicSeconds() - began
        #expect(answers.isEmpty)
        // The last server is asked 0.3 s in and waited for 0.5 s; one after the other it would be 2 s.
        #expect(elapsed >= 0.7 && elapsed < 1.3, "\(elapsed)")
        #expect(lines.with { $0 }.filter { $0.contains(": no answer in 0 s") }.count == 4)
        #expect(lines.with { $0 }.last?.hasPrefix("STUN: 0 answer(s) of 4 wanted from 4 server(s) in ") == true)
    }

    @Test func answersKeepTheServerOrderNotTheArrivalOrder() throws {
        // Server 0 answers last, server 1 first, server 2 in between.
        let servers = try [Server(delay: 0.3, shift: 1), Server(delay: 0, shift: 2), Server(delay: 0.1, shift: 3)]
        defer { servers.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let answers = StunClient.collectConcurrently(
            socket: socket, servers: servers.map(\.entry), wanted: 3, environment: Self.environment(timeout: 2))
        #expect(answers.map(\.port) == [1, 2, 3].map { socket.localPort &+ UInt16($0) })
        // And it is the order the prediction sees: a step of 1 each.
        #expect(NATPrediction.predict(answers)?.increment == 1)
    }

    @Test func itStopsAsSoonAsEnoughHaveAnswered() throws {
        let servers = try [Server(delay: 0), Server(delay: 0.05, shift: 1), Server(delay: nil), Server(delay: nil)]
        defer { servers.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let began = monotonicSeconds()
        let answers = StunClient.collectConcurrently(
            socket: socket, servers: servers.map(\.entry), wanted: 2, environment: Self.environment(timeout: 5))
        #expect(answers.count == 2 && monotonicSeconds() - began < 0.5)
        // One answer wanted (the data hole): done with the first.
        let one = StunClient.collectConcurrently(
            socket: socket, servers: servers.map(\.entry), wanted: 1, environment: Self.environment(timeout: 5))
        #expect(one.count == 1)
    }

    @Test func everyRequestComesFromTheHolesOwnSocket() throws {
        let servers = try (0..<4).map { _ in try Server(delay: 0) }
        defer { servers.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        _ = StunClient.collectConcurrently(
            socket: socket, servers: servers.map(\.entry), wanted: 4, environment: Self.environment(timeout: 2))
        for server in servers { #expect(server.askedFrom.with { $0 } == [socket.localPort]) }
    }

    /// An early stop leaves no worker acting afterwards: not a send, not a log line, not even a request to the servers it
    /// hadn't reached yet. Repeated with the socket closed as soon as the call returns (the way a caller drops it).
    @Test func anEarlyStopLeavesNoWorkerBehind() throws {
        // Server 0 answers at once; the five others would be asked 0.1 s to 0.5 s in.
        let servers = try [Server(delay: 0)] + (0..<5).map { _ in try Server(delay: nil) }
        defer { servers.forEach { $0.stop() } }
        struct Run {
            var socket: LoopbackGuardedPunchSocket
            var lines: Locked<[String]>
            var sentAtReturn: Int
            var loggedAtReturn: Int
        }
        var runs: [Run] = []
        for _ in 0..<40 {
            let socket = try loopbackSocket()
            let lines = Locked<[String]>([])
            let answers = StunClient.collectConcurrently(
                socket: socket, servers: servers.map(\.entry), wanted: 1,
                environment: Self.environment(timeout: 5, log: { line in lines.with { $0.append(line) } }))
            #expect(answers.count == 1)
            runs.append(Run(socket: socket, lines: lines, sentAtReturn: socket.destinations.with { $0.count },
                            loggedAtReturn: lines.with { $0.count }))
            socket.close()  // gone as soon as the call returns
        }
        // Well after the staggered servers' turns: nothing more was sent or logged by any of the calls.
        sleepSeconds(0.8)
        for run in runs {
            #expect(run.socket.destinations.with { $0.count } == run.sentAtReturn)
            #expect(run.lines.with { $0.count } == run.loggedAtReturn)
        }
        for server in servers.dropFirst() { #expect(server.askedFrom.with { $0.isEmpty }, "a server behind the stop was asked") }
        #expect(servers[0].askedFrom.with { $0.count } == 40)
    }

    @Test func aServerThatDoesNotResolveDoesNotHoldTheOthersBack() throws {
        let good = try [Server(delay: 0), Server(delay: 0, shift: 1)]
        defer { good.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let lines = Locked<[String]>([])
        let servers = [StunServer(host: "gone.example", port: 3478)] + good.map(\.entry)
        let answers = StunClient.collectConcurrently(
            socket: socket, servers: servers, wanted: 4,
            environment: Self.environment(timeout: 0.5, log: { line in lines.with { $0.append(line) } }))
        #expect(answers.map(\.port) == [socket.localPort, socket.localPort &+ 1])
        #expect(lines.with { $0 }.contains("STUN gone.example:3478: did not resolve"))
    }

    @Test func cancellingEndsItAtOnce() throws {
        let silent = try (0..<3).map { _ in try Server(delay: nil) }
        defer { silent.forEach { $0.stop() } }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let began = monotonicSeconds()
        let answers = StunClient.collectConcurrently(
            socket: socket, servers: silent.map(\.entry), wanted: 4,
            environment: Self.environment(timeout: 30, cancelled: { monotonicSeconds() - began > 0.2 }))
        #expect(answers.isEmpty && monotonicSeconds() - began < 1)
    }
}

/// The start command goes out while STUN runs (a client choice, DESIGN.md); every failure still gives everything back.
extension StreamSessionSuites {
    @Suite struct EarlyStartTests {
        static let commandPath = "/api/cloudAssistedNavigation/v2/users/me/commands"

        /// A PSN request list that includes the start command.
        static func commandSent(_ rig: InternetRig) -> Bool { !rig.psn.requests(containing: commandPath).isEmpty }

        @Test func theStartCommandGoesOutBeforeStunFinishes() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            // Server 3 is asked 0.3 s in; the command was sent long before.
            let seen = Locked<Bool?>(nil)
            let spy = try StunConcurrencyTests.Server(delay: nil) { seen.with { $0 = Self.commandSent(rig) } }
            defer { spy.stop() }
            let real = rig.stun.socket.localPort
            let real1 = StunServer(host: "127.0.0.1", port: real)
            rig.environment.stunServers = { [real1, real1, real1, spy.entry, real1] }
            let session = try await rig.start()
            defer { session.stop() }
            #expect(await waitUntil { seen.with { $0 } != nil })
            #expect(seen.with { $0 } == true, "the start command was sent before STUN's fourth server was asked")
            // The console's OFFER was answered and ours went out after the command and after STUN.
            let kinds = rig.psn.requests.map { $0.url.path }
            let command = try #require(kinds.firstIndex(of: Self.commandPath))
            let offer = try #require(rig.psn.requests.firstIndex { $0.url.path.hasSuffix("/sessionMessage") && $0.bodyText.contains("OFFER") })
            #expect(command < offer)
            #expect(rig.stages.with { $0 }.prefix(3) == [.linkingPSN, .wakingConsole, .ctrlHole])
        }

        @Test func aRefusedStartCommandCutsStunShortAndGivesEverythingBack() async throws {
            let rig = try InternetRig { $0.startStatus = 500 }
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            let silent = try (0..<4).map { _ in try StunConcurrencyTests.Server(delay: nil) }
            defer { silent.forEach { $0.stop() } }
            rig.environment.stunServers = { silent.map(\.entry) }
            rig.environment.stun = StunEnvironment(resolve: { $0 }, timeout: 30)
            let began = monotonicSeconds()
            let error = await rig.startFailure()
            #expect(error == .psn(.httpStatus(step: .startCommand, status: 500)))
            #expect(monotonicSeconds() - began < 5, "STUN was not waited out")
            await rig.expectGivenBack()
            #expect(rig.mapper.mapped.with { $0.count } == 1)
        }

        @Test func noCandidatesWhileTheConsoleBootsLeavesPSN() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            rig.environment.stunServers = { [] }
            // The command may or may not have gone out before the candidates failed; either way the session is left.
            #expect(await rig.startFailure() == .noPublicAddress)
            await rig.expectGivenBack()
        }

        @Test func cancellingDuringStunGivesEverythingBack() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            let silent = try (0..<4).map { _ in try StunConcurrencyTests.Server(delay: nil) }
            defer { silent.forEach { $0.stop() } }
            rig.environment.stunServers = { silent.map(\.entry) }
            rig.environment.stun = StunEnvironment(resolve: { $0 }, timeout: 30)
            let task = Task { await rig.startFailure() }
            #expect(await waitUntil { silent.contains { $0.firstRequestAt.with { $0 } != nil } })
            let began = monotonicSeconds()
            task.cancel()
            #expect(await task.value == .cancelled)
            #expect(monotonicSeconds() - began < 3)
            await rig.expectGivenBack()
        }
    }
}
