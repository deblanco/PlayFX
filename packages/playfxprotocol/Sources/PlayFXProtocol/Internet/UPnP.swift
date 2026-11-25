import Foundation

// UPnP IGD port mapping (holepunch.md section 3.1): SSDP discovery of the gateway, its description, and the
// WANIPConnection / WANPPPConnection actions GetExternalIPAddress, AddPortMapping and DeletePortMapping.
// The actions and their arguments are the standard UPnP IGD ones (UPnP Forum, "WANIPConnection:1/2 Service").

/// Why a UPnP step failed.
public enum UPnPError: Error, Sendable, Equatable {
    /// The gateway answered a SOAP action with a fault (`errorCode`, `errorDescription`).
    case fault(code: Int, description: String)
    /// An HTTP status other than 200.
    case httpStatus(Int)
    /// The answer lacked what the action returns, or what it returned isn't what it should be.
    case invalidResponse
    /// The gateway's external address is private or reserved: it sits behind another NAT (holepunch.md section 3.1).
    case privateExternalAddress
}

/// The seams of UPnP: the SSDP socket and address, the HTTP client, and how to find the local address towards the
/// gateway. Tests point them at loopback; the defaults are the real network.
public struct UPnPEnvironment: Sendable {
    /// Makes the SSDP socket (multicast TTL 2, holepunch.md section 3.1).
    public var makeSocket: @Sendable () throws -> any UDPPunchSocket
    /// Where the M-SEARCH goes: `239.255.255.250:1900`.
    public var ssdpHost: String
    /// The SSDP port.
    public var ssdpPort: UInt16
    /// Seconds to wait for SSDP answers: 2.
    public var searchWait: Double
    /// The bound on the whole discovery: 7 s.
    public var discoveryLimit: Double
    /// The most seconds one HTTP exchange may take (it is also cut to what is left of `discoveryLimit`).
    public var httpTimeout: Double
    /// The HTTP client.
    public var http: any UPnPHTTPClient
    /// The local address used to reach a gateway host (`lanIp`).
    public var localAddress: @Sendable (String) -> String?
    /// Checked while waiting.
    public var isCancelled: @Sendable () -> Bool
    /// Which SSDP source addresses may be a gateway: RFC 1918 and link-local by default. A device anywhere else, or one
    /// pointing the client at another host, is ignored.
    public var acceptsGatewayAddress: @Sendable (String) -> Bool

    /// RFC 1918 or link-local dotted IPv4 text.
    public static func isLANAddress(_ text: String) -> Bool { IPv4Text.isLAN(text) }

    public init(makeSocket: @escaping @Sendable () throws -> any UDPPunchSocket = {
                    try POSIXPunchSocket(multicastTimeToLive: 2) },
                ssdpHost: String = "239.255.255.250", ssdpPort: UInt16 = 1900, searchWait: Double = 2,
                discoveryLimit: Double = 7, httpTimeout: Double = 3, http: any UPnPHTTPClient = TCPHTTPClient(),
                localAddress: @escaping @Sendable (String) -> String? = { LocalInterfaces.address(toward: $0) },
                isCancelled: @escaping @Sendable () -> Bool = { false },
                acceptsGatewayAddress: @escaping @Sendable (String) -> Bool = { UPnPEnvironment.isLANAddress($0) }) {
        self.makeSocket = makeSocket
        self.ssdpHost = ssdpHost
        self.ssdpPort = ssdpPort
        self.searchWait = searchWait
        self.discoveryLimit = discoveryLimit
        self.httpTimeout = httpTimeout
        self.http = http
        self.localAddress = localAddress
        self.isCancelled = isCancelled
        self.acceptsGatewayAddress = acceptsGatewayAddress
    }
}

/// A literal `http://<IPv4>[:port]/path` URL; hostnames are never accepted (so nothing is ever resolved).
struct GatewayURL: Equatable {
    var host: String
    var port: UInt16
    var path: String

    /// Characters a path may hold: URL path and query characters, with `%` for escapes. Nothing that could end the
    /// request line (space, CR, LF, quotes) gets through.
    static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024 && path.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a)
                || "-._~!$&'()*+,;=:@/%?".utf8.contains(b)
        }
    }

    init?(host: String, port: UInt16, path: String) {
        guard IPv4Text.octets(host) != nil, port != 0, Self.isValidPath(path) else { return nil }
        self.host = host
        self.port = port
        self.path = path
    }

    init?(_ text: String) {
        guard text.lowercased().hasPrefix("http://"), text.utf8.count <= 1024 else { return nil }
        let rest = text.dropFirst(7)
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        var tail = String(rest[authorityEnd...])
        if tail.isEmpty { tail = "/" } else if tail.hasPrefix("?") { tail = "/" + tail }
        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        var port = 80
        if pieces.count == 2 {
            guard !pieces[1].isEmpty, pieces[1].utf8.count <= 5, pieces[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = Int(pieces[1]) else { return nil }
            port = value
        }
        guard let port16 = UInt16(exactly: port) else { return nil }
        self.init(host: String(pieces[0]), port: port16, path: tail)
    }
}

/// An Internet Gateway Device found on the LAN.
public struct UPnPGateway: Sendable {
    /// The client's LAN address towards the gateway (`lanIp`).
    public let lanAddress: String
    let host: String
    let port: UInt16
    let controlPath: String
    let serviceType: String
    let environment: UPnPEnvironment

    /// The two WAN connection services the reference uses (holepunch.md section 3.1).
    static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    /// The search targets sent: the IGD device types (versions 1 and 2) and the two WAN services.
    static let searchTargets = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
    ] + serviceTypes

    static func searchRequest(target: String, host: String, port: UInt16, wait: Int) -> [UInt8] {
        Array(("M-SEARCH * HTTP/1.1\r\nHOST: \(host):\(port)\r\nMAN: \"ssdp:discover\"\r\nMX: \(wait)\r\n"
            + "ST: \(target)\r\n\r\n").utf8)
    }

    /// Finds the first valid, connected IGD with a routable external address. Sends the search, collects answers for
    /// `searchWait` seconds, then tries them in turn, each exchange cut to what remains of `discoveryLimit` (so one
    /// stalling device can't starve the real gateway). An answer counts only from an acceptable LAN address and when
    /// its location is a literal IPv4 URL on that same host. Nil when none is found.
    public static func discover(environment: UPnPEnvironment = UPnPEnvironment()) -> UPnPGateway? {
        guard let socket = try? environment.makeSocket() else { return nil }
        defer { socket.close() }
        let start = monotonicSeconds()
        for target in searchTargets {
            let request = searchRequest(target: target, host: environment.ssdpHost, port: environment.ssdpPort,
                                        wait: max(1, Int(environment.searchWait)))
            try? socket.send(request, to: environment.ssdpHost, port: environment.ssdpPort)
        }
        var answers: [(url: GatewayURL, source: String)] = []
        var seen = Set<String>()
        let collectUntil = start + min(environment.searchWait, environment.discoveryLimit)
        while !environment.isCancelled(), answers.count < 32 {
            let wait = collectUntil - monotonicSeconds()
            guard wait > 0 else { break }
            guard let packet = try? socket.receive(timeout: wait), environment.acceptsGatewayAddress(packet.host),
                  IPv4Text.octets(packet.host) != nil, let location = header("location", in: packet.bytes),
                  let url = GatewayURL(location), url.host == packet.host,
                  seen.insert("\(url.host):\(url.port)\(url.path)").inserted else { continue }
            answers.append((url, packet.host))
        }
        for answer in answers {
            let remaining = start + environment.discoveryLimit - monotonicSeconds()
            if remaining <= 0 || environment.isCancelled() { break }
            if let gateway = open(location: answer.url, environment: environment, timeout: min(environment.httpTimeout, remaining)) {
                return gateway
            }
        }
        return nil
    }

    /// A header of an SSDP answer (`HTTP/1.1 200 OK` with `LOCATION`, `ST`, ...), looked up case-insensitively.
    static func header(_ name: String, in bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Fetches the description at `location`, finds the WAN connection service and checks the gateway is connected
    /// and has a routable external address.
    static func open(location: GatewayURL, environment: UPnPEnvironment, timeout: Double) -> UPnPGateway? {
        let request = Array("GET \(location.path) HTTP/1.1\r\nHost: \(location.host):\(location.port)\r\nConnection: close\r\n\r\n".utf8)
        guard timeout > 0, let bytes = try? environment.http.exchange(host: location.host, port: location.port,
                                                                       request: request, timeout: timeout),
              let response = UPnPHTTPResponse.parse(bytes, connectionClosed: true).response, response.status == 200,
              let description = parseDescription(String(decoding: response.body, as: UTF8.self)),
              let control = controlURL(description, location: location),
              let lan = environment.localAddress(location.host) else { return nil }
        let gateway = UPnPGateway(lanAddress: lan, host: control.host, port: control.port, controlPath: control.path,
                                  serviceType: description.serviceType, environment: environment)
        guard gateway.reportsConnected(), (try? gateway.externalIPAddress()) != nil else { return nil }
        return gateway
    }

    /// Where the SOAP actions go: an absolute `controlURL` must be on the gateway's own host; a relative one is
    /// resolved against `URLBase` (same host) or the root.
    static func controlURL(_ description: (serviceType: String, controlURL: String, urlBase: String?),
                           location: GatewayURL) -> GatewayURL? {
        let control = description.controlURL
        if control.lowercased().hasPrefix("http://") {
            guard let absolute = GatewayURL(control), absolute.host == location.host else { return nil }
            return absolute
        }
        if control.hasPrefix("/") { return GatewayURL(host: location.host, port: location.port, path: control) }
        var base = GatewayURL(host: location.host, port: location.port, path: "/")!
        if let text = description.urlBase {
            guard let parsed = GatewayURL(text), parsed.host == location.host else { return nil }
            base = parsed
        }
        let directory = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return GatewayURL(host: base.host, port: base.port, path: directory + control)
    }

    /// The first WANIPConnection:1 or WANPPPConnection:1 service of a device description (document order).
    static func parseDescription(_ xml: String) -> (serviceType: String, controlURL: String, urlBase: String?)? {
        var cursor = xml.startIndex
        while let open = xml.range(of: "<service>", range: cursor..<xml.endIndex),
              let close = xml.range(of: "</service>", range: open.upperBound..<xml.endIndex) {
            let block = String(xml[open.upperBound..<close.lowerBound])
            cursor = close.upperBound
            if let type = element("serviceType", in: block), serviceTypes.contains(type), isValidServiceType(type),
               let control = element("controlURL", in: block) {
                return (type, control, element("URLBase", in: xml))
            }
        }
        return nil
    }

    /// `^urn:[A-Za-z0-9:._-]+$`.
    static func isValidServiceType(_ text: String) -> Bool {
        text.hasPrefix("urn:") && text.utf8.count > 4 && text.utf8.count <= 128 && text.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a)
                || b == 0x3a || b == 0x2e || b == 0x5f || b == 0x2d
        }
    }

    /// The text of the first `<name>...</name>`, with the five XML entities decoded.
    static func element(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `GetStatusInfo` says `Connected` (holepunch.md section 3.1). A gateway whose status can't be read isn't used.
    func reportsConnected() -> Bool {
        (try? call("GetStatusInfo", arguments: []))?["NewConnectionStatus"] == "Connected"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The SOAP request of one action.
    func soapRequest(action: String, arguments: [(String, String)]) -> [UInt8] {
        let args = arguments.map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(serviceType)\">\(args)</u:\(action)></s:Body></s:Envelope>\r\n"
        let head = "POST \(controlPath) HTTP/1.1\r\nHOST: \(host):\(port)\r\n"
            + "Content-Type: text/xml; charset=\"utf-8\"\r\nContent-Length: \(body.utf8.count)\r\n"
            + "SOAPAction: \"\(serviceType)#\(action)\"\r\nConnection: close\r\n\r\n"
        return Array((head + body).utf8)
    }

    /// Calls an action and returns the `<NewXxx>` values of its answer.
    @discardableResult
    func call(_ action: String, arguments: [(String, String)]) throws -> [String: String] {
        let bytes = try environment.http.exchange(host: host, port: port,
                                                  request: soapRequest(action: action, arguments: arguments),
                                                  timeout: environment.httpTimeout)
        guard let response = UPnPHTTPResponse.parse(bytes, connectionClosed: true).response else {
            throw UPnPError.invalidResponse
        }
        let text = String(decoding: response.body, as: UTF8.self)
        guard response.status == 200 else {
            if response.status == 500, let code = Self.element("errorCode", in: text).flatMap({ Int($0) }) {
                throw UPnPError.fault(code: code, description: Self.element("errorDescription", in: text) ?? "")
            }
            throw UPnPError.httpStatus(response.status)
        }
        var fields: [String: String] = [:]
        var cursor = text.startIndex
        while let open = text.range(of: "<New", range: cursor..<text.endIndex),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            let name = "New" + text[open.upperBound..<close.lowerBound]
            cursor = close.upperBound
            guard !name.contains(" "), let end = text.range(of: "</\(name)>", range: close.upperBound..<text.endIndex)
            else { continue }
            fields[name] = String(text[close.upperBound..<end.lowerBound])
            cursor = end.upperBound
        }
        return fields
    }

    /// `GetExternalIPAddress`: dotted IPv4 text, not private or reserved (a gateway behind another NAT is no use).
    public func externalIPAddress() throws -> String {
        guard let address = try call("GetExternalIPAddress", arguments: [])["NewExternalIPAddress"],
              IPv4Text.octets(address) != nil else { throw UPnPError.invalidResponse }
        guard !IPv4Text.isNotRoutable(address) else { throw UPnPError.privateExternalAddress }
        return address
    }

    /// `AddPortMapping(external = internal = port, UDP, no remote host, lease 0)` towards `lanAddress`
    /// (holepunch.md section 3.1).
    public func addPortMapping(port: UInt16, description: String) throws {
        try call("AddPortMapping", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", "UDP"),
            ("NewInternalPort", String(port)), ("NewInternalClient", lanAddress), ("NewEnabled", "1"),
            ("NewPortMappingDescription", description), ("NewLeaseDuration", "0"),
        ])
    }

    /// `DeletePortMapping(port, UDP)`.
    public func deletePortMapping(port: UInt16) throws {
        try call("DeletePortMapping", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", "UDP"),
        ])
    }

    /// Maps one hole's port and reads the external address; nil when either fails (the client then uses STUN).
    public func map(localPort: UInt16, description: String = "PlayFX") -> UPnPMapping? {
        guard (try? addPortMapping(port: localPort, description: description)) != nil,
              let publicAddress = try? externalIPAddress() else { return nil }
        return UPnPMapping(lanAddress: lanAddress, publicAddress: publicAddress)
    }

    /// Deletes the mappings of the session's holes, trying each even when its mapping had failed.
    public func cleanup(ports: [UInt16]) {
        for port in ports { try? deletePortMapping(port: port) }
    }
}
