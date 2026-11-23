import Darwin
import Testing

@testable import PlayFXProtocol

@Suite struct DiscoveryTests {
    static let ps5Answer =
        "HTTP/1.1 200 Ok\r\nhost-id:0A1B2C3D4E5F\r\nhost-type:PS5\r\nhost-name:PS5-TEST\r\n"
        + "host-request-port:997\r\ndevice-discovery-protocol-version:00030010\r\nsystem-version:09400000\r\n"
        + "running-app-titleid:PPSA01234\r\nrunning-app-name:Test Game\r\n\0"

    @Test func searchPackets() {
        #expect(Discovery.searchPacket(ps5: false) == hex(
            "53524348202a20485454502f312e310a6465766963652d646973636f766572792d70726f746f636f6c2d76657273696f6e3a30303032303032300a00"))
        #expect(Discovery.searchPacket(ps5: true) == hex(
            "53524348202a20485454502f312e310a6465766963652d646973636f766572792d70726f746f636f6c2d76657273696f6e3a30303033303031300a00"))
        #expect(Discovery.searchPacket(ps5: false).count == 60)
    }

    @Test func wakePackets() {
        let ps5 = Discovery.wakePacket(credential: "2712847316", ps5: true)
        #expect(ps5.count == 135)
        #expect(ps5 == hex("""
            57414b455550202a20485454502f312e310a636c69656e742d747970653a76720a617574682d747970653a520a6d6f64656c3a770a
            6170702d747970653a720a757365722d63726564656e7469616c3a323731323834373331360a6465766963652d646973636f7665
            72792d70726f746f636f6c2d76657273696f6e3a30303033303031300a00
            """))
        let ps4 = Discovery.wakePacket(credential: "2712847316", ps5: false)
        #expect(String(decoding: ps4, as: UTF8.self) == "WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\n"
            + "app-type:r\nuser-credential:2712847316\ndevice-discovery-protocol-version:00020020\n\0")
        #expect(ps4.count == 135)
    }

    @Test func wakeCredentials() {
        #expect(Discovery.wakeCredential(registKey: Vector.registKey) == "2712847316")
        #expect(Discovery.wakeCredential(registKey: Array("A1B2C3D4".utf8)) == "2712847316")
        #expect(Discovery.wakeCredential(registKey: Array("0000000a".utf8) + [0, 0]) == "10")
        #expect(Discovery.wakeCredential(registKey: [0, 0, 0]) == nil)
        #expect(Discovery.wakeCredential(registKey: Array("a1b2c3d4e".utf8)) == nil)
        #expect(Discovery.wakeCredential(registKey: Array("xyz".utf8)) == nil)
    }

    @Test func parsesTheVectorAnswer() throws {
        let console = try #require(Discovery.parseResponse(Array(Self.ps5Answer.utf8), from: "192.168.1.23"))
        #expect(console == DiscoveredConsole(
            address: "192.168.1.23", hostID: "0A1B2C3D4E5F", kind: .ps5, state: .ready, status: 200,
            name: "PS5-TEST", systemVersion: "09400000", runningAppName: "Test Game",
            runningAppID: "PPSA01234", requestPort: 997, protocolVersion: "00030010", hostType: "PS5"))
    }

    @Test func parseVariants() throws {
        // LF endings, one optional space, no NUL, PS4, standby.
        let lf = "HTTP/1.1 620 Server Standby\nhost-id: AABBCCDDEEFF\ndevice-discovery-protocol-version:00020020\nhost-name: My PS4\n"
        let standby = try #require(Discovery.parseResponse(Array(lf.utf8), from: "10.0.0.2"))
        #expect(standby.state == .standby && standby.kind == .ps4 && standby.name == "My PS4")
        #expect(standby.runningAppID == nil && standby.requestPort == nil)

        let other = try #require(Discovery.parseResponse(Array("HTTP/1.1 503 X\r\nhost-id:1\r\n".utf8), from: "a"))
        #expect(other.state == .unknown && other.kind == .ps4)

        // No protocol version: the host type decides.
        let byType = try #require(Discovery.parseResponse(Array("HTTP/1.1 200 Ok\r\nhost-id:1\r\nhost-type:PS5\r\n".utf8), from: "a"))
        #expect(byType.kind == .ps5)

        // Data after the first NUL is ignored; unknown names too.
        let nul = try #require(Discovery.parseResponse(Array("HTTP/1.1 200 Ok\r\nhost-id:1\r\nfoo:bar\r\n\0junk".utf8), from: "a"))
        #expect(nul.hostID == "1")
    }

    @Test(arguments: [
        "SRCH * HTTP/1.1\r\nhost-id:1\r\n",
        "HTTP/1.0 200 Ok\r\nhost-id:1\r\n",
        "HTTP/1.1 200 Ok\r\nhost-name:x\r\n",
        "HTTP/1.1 200 Ok\r\nhost-id:1\r\nhost-name:\r\n",
        "HTTP/1.1 200 Ok\r\nhost-id:1\r\nno colon here\r\n",
        "HTTP/1.1 abc Ok\r\nhost-id:1\r\n",
        "HTTP/1.1 \r\nhost-id:1\r\n",
        "",
    ])
    func rejectsBadAnswers(_ text: String) {
        #expect(Discovery.parseResponse(Array(text.utf8), from: "a") == nil)
    }

    @Test func roundsAreSentInSpecOrderAndAnswersDeduplicated() throws {
        let socket = FakeDatagramSocket()
        socket.onSend = { sent in
            guard sent.host == "10.0.0.1" else { return [] }
            let ps5 = sent.bytes == Discovery.searchPacket(ps5: true)
            let answer = ps5
                ? DiscoveryTests.ps5Answer
                : "HTTP/1.1 620 Server Standby\r\nhost-id:0A1B2C3D4E5F\r\ndevice-discovery-protocol-version:00020020\r\n"
            return [Datagram(bytes: Array(answer.utf8), source: "10.0.0.1")]
                + [Datagram(bytes: Array("garbage".utf8), source: "10.0.0.9")]
                + [Datagram(bytes: Array("HTTP/1.1 200 Ok\r\nhost-id:0000000000AA\r\n".utf8), source: "10.0.0.7")]
        }
        let found = try Discovery.run(
            socket: socket, target: "10.0.0.1", broadcasts: ["10.0.0.255"], ps4Port: 1, ps5Port: 2,
            timeout: 0.1, interval: 10)
        let sent = socket.sent.with { $0 }
        #expect(sent.count == 4)
        #expect(sent.map(\.host) == ["10.0.0.1", "10.0.0.255", "10.0.0.1", "10.0.0.255"])
        #expect(sent.map(\.port) == [1, 1, 2, 2])
        #expect(sent[0].bytes == Discovery.searchPacket(ps5: false))
        #expect(sent[2].bytes == Discovery.searchPacket(ps5: true))
        // Two hosts; the later PS5 answer of 0A1B... replaced its PS4-standby answer.
        #expect(found.map(\.hostID) == ["0A1B2C3D4E5F", "0000000000AA"])
        #expect(found[0].kind == .ps5 && found[0].state == .ready)
    }

    @Test func repeatsRoundsWhileTheSocketWorks() throws {
        let socket = FakeDatagramSocket()
        socket.queue(.failure(.disconnected))  // receive errors are ignored
        let found = try Discovery.run(
            socket: socket, target: "10.0.0.1", broadcasts: [], timeout: 0.25, interval: 0.1)
        #expect(found.isEmpty)
        // At least the first round (PS4 and PS5 search); how many more depends on scheduling.
        #expect(socket.sent.with { $0.count } >= 2)
    }

    @Test func reportsWhenNothingCouldBeSent() {
        for failure in [FailureKind.permissionDenied, .networkUnreachable, .hostDown] {
            let socket = FakeDatagramSocket()
            socket.onSend = { _ in throw failure }
            #expect(throws: failure) {
                try Discovery.run(socket: socket, target: "10.0.0.1", broadcasts: ["10.0.0.255"], timeout: 0.05, interval: 0.02)
            }
        }
        // One working destination is enough: the broadcast may fail on its own.
        let partial = FakeDatagramSocket()
        partial.onSend = { sent in
            if sent.host == "10.0.0.255" { throw FailureKind.permissionDenied }
            return []
        }
        #expect((try? Discovery.run(socket: partial, target: "10.0.0.1", broadcasts: ["10.0.0.255"], timeout: 0.05)) == [])
    }

    @Test func tracksAtMostSixteenHosts() throws {
        let socket = FakeDatagramSocket()
        for i in 0..<20 {
            let id = String(format: "%012d", i)
            socket.queue(.success(Datagram(bytes: Array("HTTP/1.1 200 Ok\r\nhost-id:\(id)\r\n".utf8), source: "10.0.0.\(i)")))
        }
        // A known host still updates after the cap is reached (from its own address).
        socket.queue(.success(Datagram(bytes: Array("HTTP/1.1 620 X\r\nhost-id:000000000000\r\n".utf8), source: "10.0.0.0")))
        let found = try Discovery.run(socket: socket, target: "255.255.255.255", broadcasts: [], timeout: 0.1, interval: 10)
        #expect(found.count == 16)
        #expect(found.first?.state == .standby && found.first?.address == "10.0.0.0")
        #expect(!found.contains { $0.hostID == "000000000016" })
    }

    @Test func discoveryThrowsFromTheEnvironment() {
        var environment = DiscoveryEnvironment()
        environment.makeSocket = { _ in throw FailureKind.permissionDenied }
        #expect(throws: FailureKind.permissionDenied) {
            try Discovery.discover(host: nil, timeout: 0.05, environment: environment, token: CancelToken())
        }
        let socket = FakeDatagramSocket()
        socket.onSend = { _ in throw FailureKind.networkUnreachable }
        environment.makeSocket = { _ in socket }
        environment.broadcastAddresses = { _ in ["10.0.0.255"] }
        #expect(throws: FailureKind.networkUnreachable) {
            try Discovery.discover(host: nil, timeout: 0.05, environment: environment, token: CancelToken())
        }
        // The first send of a broadcast search goes to the limited broadcast address.
        #expect(socket.sent.with { $0.map(\.host).prefix(2) } == ["255.255.255.255", "10.0.0.255"])
    }

    @Test func unicastSearchOnlyAcceptsTheTarget() throws {
        let socket = FakeDatagramSocket()
        socket.queue(.success(Datagram(bytes: Array("HTTP/1.1 200 Ok\r\nhost-id:00000000000B\r\n".utf8), source: "10.0.0.66")))
        socket.queue(.success(Datagram(bytes: Array(DiscoveryTests.ps5Answer.utf8), source: "10.0.0.1")))
        let found = try Discovery.run(socket: socket, target: "10.0.0.1", broadcasts: [], timeout: 0.1, interval: 10)
        #expect(found.map(\.hostID) == ["0A1B2C3D4E5F"])

        let v6 = FakeDatagramSocket()
        v6.queue(.success(Datagram(bytes: Array(DiscoveryTests.ps5Answer.utf8), source: "::1")))
        #expect(try Discovery.run(socket: v6, target: "0:0::1", broadcasts: [], timeout: 0.1, interval: 10).count == 1)
    }

    @Test func aKnownHostCannotMoveToAnotherAddress() throws {
        let socket = FakeDatagramSocket()
        socket.queue(.success(Datagram(bytes: Array(DiscoveryTests.ps5Answer.utf8), source: "10.0.0.1")))
        let spoof = "HTTP/1.1 620 X\r\nhost-id:0A1B2C3D4E5F\r\nhost-name:EVIL\r\n"
        socket.queue(.success(Datagram(bytes: Array(spoof.utf8), source: "10.0.0.66")))
        let found = try Discovery.run(socket: socket, target: "255.255.255.255", broadcasts: [], timeout: 0.1, interval: 10)
        #expect(found.count == 1)
        #expect(found.first?.address == "10.0.0.1" && found.first?.name == "PS5-TEST" && found.first?.state == .ready)
    }

    @Test func addressComparison() {
        #expect(Discovery.sameAddress("10.0.0.1", "10.0.0.1"))
        #expect(Discovery.sameAddress("::1", "0:0:0:0:0:0:0:1"))
        #expect(!Discovery.sameAddress("10.0.0.1", "10.0.0.2"))
        #expect(!Discovery.sameAddress("::1", "::2"))
        #expect(!Discovery.sameAddress("10.0.0.1", "::1"))
        #expect(!Discovery.sameAddress("console.local", "10.0.0.1"))
    }

    @Test func wakeBroadcastsOnlyOnTheConsolesSubnet() {
        let socket = FakeDatagramSocket()
        let asked = Locked<[String?]>([])
        var environment = DiscoveryEnvironment()
        environment.makeSocket = { _ in socket }
        environment.broadcastAddresses = { host in
            asked.with { $0.append(host) }
            return ["10.0.0.255"]
        }
        #expect(Discovery.wake(address: "10.0.0.5", registKey: Vector.registKey, ps5: true, environment: environment))
        #expect(asked.with { $0 } == ["10.0.0.5"])
        #expect(socket.sent.with { $0.map(\.host) } == ["10.0.0.5", "10.0.0.255"])
    }

    @Test func cancelledTokenStopsDiscovery() {
        let token = CancelToken()
        token.cancel()
        #expect(throws: FailureKind.cancelled) {
            try Discovery.run(socket: FakeDatagramSocket(), target: "10.0.0.1", broadcasts: [], timeout: 5, token: token)
        }
    }

    @Test func asyncDiscoveryStopsPromptlyWhenCancelled() async {
        let socket = FakeDatagramSocket()
        var environment = DiscoveryEnvironment()
        environment.makeSocket = { _ in socket }
        environment.broadcastAddresses = { _ in [] }
        let started = monotonicSeconds()
        let task = Task { try await Discovery.discoverAsync(host: "10.0.0.1", timeout: 30, environment: environment) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        #expect(monotonicSeconds() - started < 1)
        #expect(throws: FailureKind.cancelled) { try result.get() }
    }

    @Test func asyncDiscoveryReturnsAnswers() async throws {
        let socket = FakeDatagramSocket()
        socket.onSend = { _ in [Datagram(bytes: Array(DiscoveryTests.ps5Answer.utf8), source: "10.0.0.1")] }
        var environment = DiscoveryEnvironment()
        environment.makeSocket = { _ in socket }
        let found = try await Discovery.discoverAsync(host: "10.0.0.1", timeout: 0.1, environment: environment)
        #expect(found.map(\.hostID) == ["0A1B2C3D4E5F"])
    }

    @Test func wakeSendsToAddressAndBroadcasts() {
        let socket = FakeDatagramSocket()
        let ok = Discovery.wake(
            socket: socket, address: "10.0.0.5", broadcasts: ["10.0.0.255"], registKey: Vector.registKey, ps5: true)
        #expect(ok)
        let sent = socket.sent.with { $0 }
        #expect(sent.map(\.host) == ["10.0.0.5", "10.0.0.255"])
        #expect(sent.allSatisfy { $0.port == 9302 && $0.bytes == Discovery.wakePacket(credential: "2712847316", ps5: true) })

        let ps4 = FakeDatagramSocket()
        #expect(Discovery.wake(socket: ps4, address: "10.0.0.5", broadcasts: [], registKey: Vector.registKey, ps5: false))
        #expect(ps4.sent.with { $0[0].port } == 987)
    }

    @Test func wakeFailures() {
        let socket = FakeDatagramSocket()
        #expect(!Discovery.wake(socket: socket, address: "a", broadcasts: [], registKey: [0], ps5: true))
        #expect(socket.sent.with { $0.isEmpty })
        socket.onSend = { _ in throw FailureKind.hostDown }
        #expect(!Discovery.wake(socket: socket, address: "a", broadcasts: ["b"], registKey: Vector.registKey, ps5: true))
    }

    @Test func directedBroadcastsFromInterfaceData() {
        let up = IFF_UP | IFF_BROADCAST | IFF_RUNNING
        let interfaces = [
            InterfaceAddress(flags: up, address: 0xc0a8_0117, netmask: 0xffff_ff00),  // 192.168.1.23/24
            InterfaceAddress(flags: up, address: 0x0a00_0505, netmask: 0xffff_fc00),  // 10.0.5.5/22
            InterfaceAddress(flags: up, address: 0xc0a8_0118, netmask: 0xffff_ff00),  // same subnet again
            InterfaceAddress(flags: IFF_UP | IFF_LOOPBACK, address: 0x7f00_0001, netmask: 0xff00_0000),
            InterfaceAddress(flags: IFF_BROADCAST, address: 0xac10_0001, netmask: 0xffff_0000),  // down
            InterfaceAddress(flags: IFF_UP, address: 0xac11_0001, netmask: 0xffff_0000),  // no broadcast
            InterfaceAddress(flags: up, address: 0xc0a8_0201, netmask: 0xffff_ffff),  // /32
            InterfaceAddress(flags: up, address: 0xac12_0305, netmask: 0xffff_f000),  // 172.18.3.5/20
        ]
        #expect(directedBroadcastAddresses(of: interfaces) == ["192.168.1.255", "10.0.7.255", "172.18.15.255"])
        #expect(directedBroadcastAddresses(of: []).isEmpty)
        // Only the interface on the console's subnet.
        #expect(directedBroadcastAddresses(of: interfaces, containing: 0x0a00_0601) == ["10.0.7.255"])  // 10.0.6.1
        #expect(directedBroadcastAddresses(of: interfaces, containing: 0x0808_0808).isEmpty)
        #expect(ipv4Value("192.168.1.23") == 0xc0a8_0117)
        #expect(ipv4Value("::1") == nil && ipv4Value("nope") == nil)
        #expect(directedBroadcastAddresses(containing: "::1").isEmpty)
        #expect(directedBroadcastAddresses(containing: "not an address").isEmpty)
        #expect(directedBroadcastAddresses(containing: "127.0.0.1").isEmpty)  // loopback is never a broadcast
    }

    /// Smoke test of the real interface list (sends nothing).
    @Test func realInterfaceListIsWellFormed() {
        for address in directedBroadcastAddresses() {
            #expect(SocketAddress(host: address, port: 1) != nil)
            #expect(!address.hasPrefix("127."))
        }
    }

    @Test func socketAddressParsing() {
        #expect(SocketAddress(host: "192.168.1.1", port: 987) != nil)
        #expect(SocketAddress(host: "::1", port: 987) != nil)
        #expect(SocketAddress(host: "fe80::1%lo0", port: 987) != nil)
        #expect(SocketAddress(host: "fe80::1%1", port: 987) != nil)
        #expect(SocketAddress(host: "fe80::1%nosuchif0", port: 987) == nil)
        #expect(SocketAddress(host: "192.168.1.1%lo0", port: 987) == nil)
        #expect(SocketAddress(host: "not an address", port: 987) == nil)
        #expect(SocketAddress.isIPv6("fe80::1%en0") && SocketAddress.isIPv6("fe80::1") && !SocketAddress.isIPv6("1.2.3.4"))
    }

    /// Public wake with an unusable key must not even open a socket, so nothing can be sent.
    @Test func publicWakeRejectsBadKey() {
        #expect(!Discovery.wake(address: "127.0.0.1", registKey: [], ps5: true))
    }

    @Test func guardRefusesNonLoopbackDestinations() throws {
        let guarded = LoopbackGuardedSocket(FakeDatagramSocket())
        try guarded.send([1], to: "127.0.0.1", port: 1)
        try guarded.send([1], to: "::1", port: 1)
        withKnownIssue {
            #expect(throws: FailureKind.networkUnreachable) { try guarded.send([1], to: "192.168.1.255", port: 1) }
        }
        #expect((guarded.inner as? FakeDatagramSocket)?.sent.with { $0.count } == 2)
    }
}
