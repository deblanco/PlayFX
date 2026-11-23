import Foundation

/// A console family.
public enum ConsoleKind: Sendable, Equatable, Hashable {
    case ps4, ps5
}

/// What a console's search answer says about its power state (discovery.md section 4.3).
public enum ConsoleState: Sendable, Equatable, Hashable {
    /// Status 200: on and awake.
    case ready
    /// Status 620: rest mode, can be woken.
    case standby
    case unknown
}

/// A console that answered a discovery search.
public struct DiscoveredConsole: Sendable, Equatable, Hashable {
    /// Source IP of the answer.
    public var address: String
    /// `host-id`: 12 hex digits, the console's MAC address; identifies the console across answers.
    public var hostID: String
    public var kind: ConsoleKind
    public var state: ConsoleState
    /// The answer's numeric HTTP status (200, 620, ...).
    public var status: Int
    /// `host-name`.
    public var name: String?
    /// `system-version`: 8 decimal digits, e.g. `07020001`.
    public var systemVersion: String?
    /// `running-app-name`.
    public var runningAppName: String?
    /// `running-app-titleid`.
    public var runningAppID: String?
    /// `host-request-port` as advertised (typically 997).
    public var requestPort: UInt16?
    /// `device-discovery-protocol-version`.
    public var protocolVersion: String?
    /// `host-type` as sent (`PS4` or `PS5`).
    public var hostType: String?
}

/// The sockets, ports and interface list discovery and wake use; tests replace them so nothing leaves loopback.
struct DiscoveryEnvironment: Sendable {
    var makeSocket: @Sendable (_ ipv6: Bool) throws -> DatagramSocket = { ipv6 in
        try POSIXDatagramSocket(ipv6: ipv6, broadcast: true, bindRange: Discovery.localPorts)
    }
    var broadcastAddresses: @Sendable () -> [String] = { directedBroadcastAddresses() }
    var ps4Port = Discovery.ps4Port
    var ps5Port = Discovery.ps5Port
    var interval = Discovery.roundInterval
}

/// LAN discovery and wake (discovery.md).
public enum Discovery {
    static let ps4Port: UInt16 = 987
    static let ps5Port: UInt16 = 9302
    static let ps4Version = "00020020"
    static let ps5Version = "00030010"
    /// Local ports tried for the discovery socket (client choice in discovery.md section 2).
    static let localPorts: ClosedRange<UInt16> = 9303...9319
    /// Pause between search rounds (PlayFX's 300 ms).
    static let roundInterval = 0.3

    static func port(ps5: Bool) -> UInt16 { ps5 ? ps5Port : ps4Port }
    static func version(ps5: Bool) -> String { ps5 ? ps5Version : ps4Version }

    /// `SRCH * HTTP/1.1\n device-discovery-protocol-version:<v>\n \0` (section 4.1).
    static func searchPacket(ps5: Bool) -> [UInt8] {
        Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(version(ps5: ps5))\n".utf8) + [0]
    }

    /// The wake datagram (section 6.1).
    static func wakePacket(credential: String, ps5: Bool) -> [UInt8] {
        Array((
            "WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\n"
                + "user-credential:\(credential)\ndevice-discovery-protocol-version:\(version(ps5: ps5))\n"
        ).utf8) + [0]
    }

    /// The decimal credential for a stored registration key field (section 6.2); nil when the key has no
    /// usable text (empty, not hex, or longer than 8 characters before the first zero byte).
    static func wakeCredential(registKey: [UInt8]) -> String? {
        let text = registKey.prefix { $0 != 0 }
        guard !text.isEmpty, text.count <= 8, let bytes = decodeHexDigits(text) else { return nil }
        return String(bytes)
    }

    private static func decodeHexDigits(_ text: ArraySlice<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        for c in text {
            guard let n = hexNibble(c) else { return nil }
            value = value << 4 | UInt64(n)
        }
        return value
    }

    /// Parses a search answer received from `source` (section 4.3); nil if it is not a usable answer.
    static func parseResponse(_ datagram: [UInt8], from source: String) -> DiscoveredConsole? {
        let prefix = Array("HTTP/1.1 ".utf8)
        let end = datagram.firstIndex(of: 0) ?? datagram.count
        let bytes = datagram[0..<end]
        guard bytes.starts(with: prefix) else { return nil }
        let lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { line in line.last == UInt8(ascii: "\r") ? line.dropLast() : line }
        let statusDigits = lines[0].dropFirst(prefix.count).prefix { $0 != UInt8(ascii: " ") }
        guard !statusDigits.isEmpty, statusDigits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let status = Int(String(decoding: statusDigits, as: UTF8.self)) else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
            var value = line[(colon + 1)...]
            if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
            guard !value.isEmpty else { return nil }
            fields[String(decoding: line[..<colon], as: UTF8.self)] = String(decoding: value, as: UTF8.self)
        }
        guard let hostID = fields["host-id"] else { return nil }
        let version = fields["device-discovery-protocol-version"]
        let isPS5 = version.map { $0 == ps5Version } ?? (fields["host-type"] == "PS5")
        return DiscoveredConsole(
            address: source, hostID: hostID, kind: isPS5 ? .ps5 : .ps4,
            state: status == 200 ? .ready : status == 620 ? .standby : .unknown, status: status,
            name: fields["host-name"], systemVersion: fields["system-version"],
            runningAppName: fields["running-app-name"], runningAppID: fields["running-app-titleid"],
            requestPort: fields["host-request-port"].flatMap { UInt16($0) }, protocolVersion: version,
            hostType: fields["host-type"])
    }

    /// Most hosts tracked at once (section 5).
    static let maximumHosts = 16

    /// Runs the polling service of section 5 for `timeout` seconds and returns the consoles that answered,
    /// deduplicated by `host-id` (a later answer updates the fields), in order of first answer, at most 16.
    /// Throws the first send error when no search at all could be sent, and `.cancelled` if the token fires.
    static func run(
        socket: DatagramSocket, target: String, broadcasts: [String], ps4Port: UInt16 = Discovery.ps4Port,
        ps5Port: UInt16 = Discovery.ps5Port, timeout: Double, interval: Double = roundInterval,
        token: CancelToken = CancelToken()
    ) throws -> [DiscoveredConsole] {
        let deadline = monotonicSeconds() + max(0, timeout)
        var order: [String] = []
        var found: [String: DiscoveredConsole] = [:]
        let destinations = [target] + broadcasts
        var nextRound = monotonicSeconds()
        var firstSendError: Error?
        var sentAny = false
        while true {
            if token.isCancelled { throw FailureKind.cancelled }
            let now = monotonicSeconds()
            if now >= nextRound {
                for ps5 in [false, true] {
                    for host in destinations {
                        do {
                            try socket.send(searchPacket(ps5: ps5), to: host, port: ps5 ? ps5Port : ps4Port)
                            sentAny = true
                        } catch {
                            firstSendError = firstSendError ?? error
                        }
                    }
                }
                nextRound = now + interval
            }
            // Short waits, so a cancelled task stops within a slice.
            let wait = min(nextRound, deadline, monotonicSeconds() + 0.05) - monotonicSeconds()
            if let datagram = try? socket.receive(timeout: max(0, wait)),
               let console = parseResponse(datagram.bytes, from: datagram.source),
               found[console.hostID] != nil || found.count < maximumHosts {
                if found.updateValue(console, forKey: console.hostID) == nil { order.append(console.hostID) }
            }
            if monotonicSeconds() >= deadline { break }
        }
        if !sentAny, let firstSendError { throw firstSendError }
        return order.compactMap { found[$0] }
    }

    /// Sends the wake packet to `address` and to every directed broadcast; true if any send succeeded.
    static func wake(
        socket: DatagramSocket, address: String, broadcasts: [String], registKey: [UInt8], ps5: Bool,
        port: UInt16? = nil
    ) -> Bool {
        guard let credential = wakeCredential(registKey: registKey) else { return false }
        let packet = wakePacket(credential: credential, ps5: ps5)
        var sent = false
        for host in [address] + broadcasts where (try? socket.send(packet, to: host, port: port ?? Self.port(ps5: ps5))) != nil {
            sent = true
        }
        return sent
    }

    // MARK: Entry points

    /// Finds consoles on the LAN and reports failures. With `host`, asks that address (unicast); with nil,
    /// broadcasts to every IPv4 broadcast address of the Mac's up interfaces. Blocks for `timeout` seconds and
    /// returns each console that answered, deduplicated by host ID (at most 16).
    ///
    /// Throws a `FailureKind` when no search could be sent: `.permissionDenied` (macOS Local Network access
    /// denied), `.networkUnreachable`, `.hostDown`, `.badAddress`... An empty array means nothing answered.
    public static func discoverThrowing(host: String? = nil, timeout: Double) throws -> [DiscoveredConsole] {
        try discover(host: host, timeout: timeout, environment: DiscoveryEnvironment(), token: CancelToken())
    }

    /// Like `discoverThrowing`, but returns an empty array on any failure.
    public static func discover(host: String? = nil, timeout: Double) -> [DiscoveredConsole] {
        (try? discoverThrowing(host: host, timeout: timeout)) ?? []
    }

    /// Async `discoverThrowing`: runs the blocking work off the caller's thread, and stops within about 50 ms
    /// of the task being cancelled by throwing `FailureKind.cancelled`.
    public static func discoverAsync(host: String? = nil, timeout: Double) async throws -> [DiscoveredConsole] {
        try await discoverAsync(host: host, timeout: timeout, environment: DiscoveryEnvironment())
    }

    static func discoverAsync(
        host: String?, timeout: Double, environment: DiscoveryEnvironment
    ) async throws -> [DiscoveredConsole] {
        let token = CancelToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try discover(host: host, timeout: timeout, environment: environment, token: token)
                    })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    static func discover(
        host: String?, timeout: Double, environment: DiscoveryEnvironment, token: CancelToken
    ) throws -> [DiscoveredConsole] {
        let socket = try environment.makeSocket(host.map(SocketAddress.isIPv6) ?? false)
        return try run(
            socket: socket, target: host ?? "255.255.255.255",
            broadcasts: host == nil ? environment.broadcastAddresses() : [], ps4Port: environment.ps4Port,
            ps5Port: environment.ps5Port, timeout: timeout, interval: environment.interval, token: token)
    }

    /// Wakes a console in rest mode: sends the wake packet to `address` and to every IPv4 directed broadcast
    /// address. `registKey` is the 16-byte registration key field from `PairingResult`. Returns true if a
    /// packet was sent (a console never answers a wake; search again to see it come up).
    public static func wake(address: String, registKey: [UInt8], ps5: Bool) -> Bool {
        wake(address: address, registKey: registKey, ps5: ps5, environment: DiscoveryEnvironment())
    }

    static func wake(address: String, registKey: [UInt8], ps5: Bool, environment: DiscoveryEnvironment) -> Bool {
        guard Discovery.wakeCredential(registKey: registKey) != nil,
              let socket = try? environment.makeSocket(SocketAddress.isIPv6(address)) else { return false }
        return wake(
            socket: socket, address: address, broadcasts: environment.broadcastAddresses(),
            registKey: registKey, ps5: ps5, port: ps5 ? environment.ps5Port : environment.ps4Port)
    }
}
