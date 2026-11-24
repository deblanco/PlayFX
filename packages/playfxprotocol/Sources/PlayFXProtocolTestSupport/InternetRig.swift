import Darwin
import Foundation

@testable import PlayFXProtocol

// The rig of the internet tests (shared with StreamCore's): a fake PSN (`FakePSN` and its WebSocket, no network), a fake console on loopback
// (`InternetConsole`: hole-punch answers, RUDP, Takion) and a router that maps ports. Nothing here reaches beyond
// 127.0.0.1: the sockets the client punches with are wrapped in the loopback guard.

/// A router: maps every port, answers with a made-up external address, and records what was mapped and removed.
final class FakeMapper: PortMapper, @unchecked Sendable {
    let mapped = Locked<[UInt16]>([])
    let removed = Locked<[[UInt16]]>([])
    /// Maps nothing: the hole falls back to STUN.
    var failsMapping = false

    func mapPort(_ port: UInt16) -> UPnPMapping? {
        mapped.with { $0.append(port) }
        return failsMapping ? nil : UPnPMapping(lanAddress: "127.0.0.1", publicAddress: "127.0.0.1")
    }

    func removeMappings(_ ports: [UInt16]) { removed.with { $0.append(ports) } }

    var removedPorts: [UInt16] { removed.with { Array($0.joined()) } }
}

/// A STUN server on loopback: answers a Binding Request with the sender's address and port (XOR-MAPPED-ADDRESS).
final class FakeSTUNServer: @unchecked Sendable {
    let socket: LoopbackGuardedPunchSocket
    let requests = Locked<Int>(0)
    private let stopped = Locked(false)

    init() throws {
        socket = try loopbackSocket()
        Thread { [self] in
            while !stopped.with({ $0 }) {
                guard let packet = try? socket.receive(timeout: 0.05), packet.bytes.count == 20 else { continue }
                requests.with { $0 += 1 }
                let cookie = StunClient.cookie
                let port = packet.port ^ 0x2112
                let octets = packet.host.split(separator: ".").compactMap { UInt8($0) }
                let address = zip(octets, cookie).map { $0 ^ $1 }
                let attribute: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xff)] + address
                let reply: [UInt8] = [0x01, 0x01, 0x00, UInt8(attribute.count)] + cookie + Array(packet.bytes[8..<20]) + attribute
                try? socket.send(reply, to: packet.host, port: packet.port)
            }
        }.start()
    }

    func stop() { stopped.with { $0 = true } }
}

/// The console OFFER and ACCEPT texts of psn.md section 7, for the fake console's sockets.
enum ConsoleMessages {
    static func offer(reqID: Int, endpoint: PunchedUDPEndpoint) -> String {
        let hashed = Data(endpoint.hashedID).base64EncodedString()
        return #"{"action":"OFFER","reqId":\#(reqID),"error":0,"connRequest":{"sid":\#(endpoint.sid),"peerSid":0,"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":2,"candidate":[{"type":"STATIC","addr":"127.0.0.1","mappedAddr":"0.0.0.0","port":\#(endpoint.port),"mappedPort":0},{"type":"LOCAL","addr":"127.0.0.1","mappedAddr":"0.0.0.0","port":\#(endpoint.port),"mappedPort":0}],"defaultRouteMacAddr":"0a:1b:2c:3d:4e:5f","localPeerAddr":,"localHashedId":"\#(hashed)"}}"#
    }

    static func accept(reqID: Int, endpoint: PunchedUDPEndpoint) -> String {
        PSNVector.consoleAcceptText(reqID: reqID, sid: Int(endpoint.sid))
    }
}

/// Everything an internet test needs, wired together. Configure it, then call `start` or `register`.
final class InternetRig: @unchecked Sendable {
    let console: InternetConsole
    let psn: FakePSN
    let mapper: FakeMapper
    let stun: FakeSTUNServer
    let stages = Locked<[InternetStage]>([])
    let logs = Locked<[String]>([])
    let remote = PSNRemote(accessToken: PSNVector.token, consoleDUID: PSNVector.duid)
    var options = InternetOptions()
    var environment = InternetEnvironment()
    var streamEnvironment: StreamEnvironment
    /// Sockets the client made for its holes, in order (ctrl, then data).
    let holeSockets = Locked<[LoopbackGuardedPunchSocket]>([])
    /// The link of the run, to look at what was given back.
    let link = Locked<InternetLink?>(nil)

    init(useUPnP: Bool = true, tweakPSN: (inout FakePSN.Script) -> Void = { _ in }) throws {
        let secrets = RUDPConsole.Secrets(
            data1: PSNVector.data1, data2: PSNVector.data2, customData1: PSNVector.customData1,
            accountID: (0..<8).map { UInt8(truncatingIfNeeded: PSNVector.accountID >> UInt64(8 * $0)) })
        console = try InternetConsole(secrets: secrets)
        mapper = FakeMapper()
        stun = try FakeSTUNServer()
        psn = FakePSN()
        streamEnvironment = loopbackStreamEnvironment(console.stream)

        let ctrl = console.ctrlEndpoint, data = console.dataEndpoint
        let console = console
        var script = psn.script
        script.afterStart = [
            PSNVector.memberFrame(), PSNVector.customDataFrame(),
            PSNVector.messageFrame(ConsoleMessages.offer(reqID: 1, endpoint: ctrl)),
        ]
        script.onMessage = { message in
            switch message.action {
            case .offer:
                guard let request = message.connRequest else { return [] }
                let hole = message.reqID == 2 ? ctrl : data
                _ = console
                hole.startProbing(clientOffer: PunchOffer(
                    sid: UInt16(truncatingIfNeeded: request.sid), peerSid: 0, hashedID: request.localHashedID,
                    candidates: request.candidates.map(PunchCandidate.init)))
                return [PSNVector.consoleResultText(reqID: message.reqID)]
            case .accept:
                return [ConsoleMessages.accept(reqID: message.reqID == 3 ? 7 : 9, endpoint: message.reqID == 3 ? ctrl : data)]
            case .result:
                // The client's RESULT for the console's ctrl ACCEPT: the data hole's OFFER follows.
                return message.reqID == 7 ? [ConsoleMessages.offer(reqID: 8, endpoint: data)] : []
            case .terminate:
                return []
            }
        }
        tweakPSN(&script)
        psn.script = script

        var timeouts = PSNVector.patientTimeouts()
        timeouts.notification = 10
        timeouts.deletion = 0.3
        options.psnTimeouts = timeouts
        options.useUPnP = useUPnP
        let stages = stages, logs = logs
        options.progress = { stage in stages.with { $0.append(stage) } }
        options.log = { line in logs.with { $0.append(line) } }

        let psn = psn, mapper = mapper, holeSockets = holeSockets
        environment.transport = psn
        environment.makeWebSocket = { psn.socket }
        environment.discoverGateway = { _ in mapper }
        environment.makeSocket = {
            let socket = LoopbackGuardedPunchSocket(try POSIXPunchSocket())
            holeSockets.with { $0.append(socket) }
            return socket
        }
        environment.interfaceAddress = { "127.0.0.1" }
        let link = link
        environment.linkCreated = { made in link.with { $0 = made } }
        let stunPort = stun.socket.localPort
        environment.stunServers = { Array(repeating: StunServer(host: "127.0.0.1", port: stunPort), count: 4) }
        environment.stun = StunEnvironment(resolve: { $0 }, timeout: 1)
        environment.punch.signalingWait = 5
        environment.punch.probeWait = 0.05
        environment.punch.resends = 40
        environment.punch.quietTime = 0.25
        environment.punch.extraSocketCount = 0
        environment.rudp.stepWait = 0.3
        environment.rudp.switchWait = 2
        environment.makeParameters = { try! PSNVector.parameters() }
        environment.registrationTimeout = 5
        environment.drainStep = 0.02
        environment.drainLimit = 0.1
        environment.ctrlHeaderTimeout = 5
        environment.unsolicitedHeartbeatInterval = 0.1
    }

    func stop() {
        console.stop()
        stun.stop()
    }

    var deletes: [PSNHTTPRequest] { psn.requests.filter { $0.method == "DELETE" } }

    /// The client left the PSN session (the DELETE was sent).
    var leftPSN: Bool { !deletes.isEmpty }

    func start(recorder: EventRecorder = EventRecorder(), settings: StreamSettings = avcSettings) async throws
        -> StreamSession
    {
        let session = try await StreamSession.start(
            remote: remote, settings: settings, options: StreamSessionOptions(), internet: options,
            internetEnvironment: environment, streamEnvironment: streamEnvironment, events: recorder.handler)
        recorder.session.with { $0 = session }
        return session
    }

    /// Descriptors of this process connected to one of the console's two sockets: the ctrl hole's, the data hole's and
    /// every copy made of it. (Other tests' sockets, running alongside, are never connected to these ports.)
    func descriptorsConnectedToTheConsole() -> [Int32] {
        let ports = [console.ctrlEndpoint.port, console.dataEndpoint.port]
        return (0..<4096).filter { descriptor in
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(Int32(descriptor), $0, &length) }
            }
            return named == 0 && address.sin_family == sa_family_t(AF_INET)
                && ports.contains(UInt16(bigEndian: address.sin_port))
        }.map { Int32($0) }
    }
}
