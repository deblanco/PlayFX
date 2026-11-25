import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// A fake IGD on loopback: an SSDP responder (a UDP socket on 127.0.0.1) and a SOAP/description HTTP server.
final class FakeGateway: @unchecked Sendable {
    let ssdp: LoopbackGuardedPunchSocket
    let http: LoopbackHTTPServer
    let searches = Locked<[String]>([])
    private let stopped = Locked(false)
    /// What each action answers: a body for 200, or a (status, body) override.
    let actions = Locked<[String: (Int, String)]>([:])

    static func description(control: String = "/ctl/IPConn", extra: String = "", base: String = "") -> String {
        """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0">\(base)<device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/ctl/L3F</controlURL>
        </service></serviceList><deviceList><device><deviceList><device><serviceList>\(extra)<service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>\(control)</controlURL></service></serviceList></device></deviceList></device></deviceList>
        </device></root>
        """
    }

    init(description: @escaping @Sendable (UInt16) -> String = { _ in FakeGateway.description() },
         answers: Int = 2, locations: @escaping @Sendable (UInt16) -> [String] = {
             ["http://127.0.0.1:\($0)/rootDesc.xml"] }) throws {
        ssdp = try loopbackSocket()
        let actions = actions
        let responder = ssdp
        let searches = searches
        let gatewayActions = actions
        let httpPort = Locked<UInt16>(0)
        http = try LoopbackHTTPServer { request in
            if request.hasPrefix("GET ") { return httpResponse(body: description(httpPort.with { $0 })) }
            let action = request.components(separatedBy: "SOAPAction: \"").dropFirst().first?
                .components(separatedBy: "\"").first?.components(separatedBy: "#").last ?? ""
            let (status, body) = gatewayActions.with { $0[action] } ?? (200, "")
            let envelope = "<s:Envelope><s:Body><u:\(action)Response>\(body)</u:\(action)Response></s:Body></s:Envelope>"
            return httpResponse(status: status, body: status == 200 ? envelope : body)
        }
        httpPort.with { $0 = http.port }
        let locationList = locations(http.port)
        actions.with {
            $0["GetStatusInfo"] = (200, "<NewConnectionStatus>Connected</NewConnectionStatus>")
            $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>203.0.113.5</NewExternalIPAddress>")
        }
        Thread { [stopped] in
            while !stopped.with({ $0 }) {
                guard let packet = try? responder.receive(timeout: 0.05) else { continue }
                searches.with { $0.append(String(decoding: packet.bytes, as: UTF8.self)) }
                for _ in 0..<answers {
                    for location in locationList {
                        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nlocation: \(location)\r\n"
                            + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
                        try? responder.send(Array(reply.utf8), to: packet.host, port: packet.port)
                    }
                }
            }
        }.start()
    }

    func stop() {
        stopped.with { $0 = true }
        http.stop()
    }

    /// The environment for tests: sockets and HTTP guarded to loopback, and loopback accepted as a "LAN" gateway.
    func environment(lan: String = "192.168.1.20", acceptsLoopback: Bool = true) -> UPnPEnvironment {
        let port = ssdp.localPort
        return UPnPEnvironment(makeSocket: { try loopbackSocket() }, ssdpHost: "127.0.0.1", ssdpPort: port,
                               searchWait: 0.5, discoveryLimit: 3, httpTimeout: 2, http: LoopbackGuardedHTTP(),
                               localAddress: { _ in lan },
                               acceptsGatewayAddress: { acceptsLoopback ? true : UPnPEnvironment.isLANAddress($0) })
    }
}

@Suite(.serialized) struct UPnPTests {
    @Test func discoversMapsAndCleansUp() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        let found = try #require(UPnPGateway.discover(environment: gateway.environment()))
        #expect(found.lanAddress == "192.168.1.20")

        // The searches went out: IGD versions 1 and 2, then the two WAN services.
        #expect(eventually { gateway.searches.with { $0.count } == 4 })
        let searches = gateway.searches.with { $0 }
        for target in ["device:InternetGatewayDevice:1", "device:InternetGatewayDevice:2", "service:WANIPConnection:1",
                       "service:WANPPPConnection:1"] {
            #expect(searches.contains { $0.contains("ST: urn:schemas-upnp-org:\(target)\r\n") })
        }
        #expect(searches[0].hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 127.0.0.1:\(gateway.ssdp.localPort)\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"))

        // H4's UPnP row: AddPortMapping(ext 50600, int 50600, client 192.168.1.20, "UDP", lease 0).
        let mapping = try #require(found.map(localPort: 50600))
        #expect(mapping == UPnPMapping(lanAddress: "192.168.1.20", publicAddress: "203.0.113.5"))
        let add = try #require(gateway.http.requests.with { $0.first { $0.contains("#AddPortMapping") } })
        #expect(add.hasPrefix("POST /ctl/IPConn HTTP/1.1\r\n"))
        #expect(add.contains("SOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"\r\n"))
        #expect(add.contains("Content-Type: text/xml; charset=\"utf-8\"\r\n"))
        #expect(add.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">"
            + "<NewRemoteHost></NewRemoteHost><NewExternalPort>50600</NewExternalPort><NewProtocol>UDP</NewProtocol>"
            + "<NewInternalPort>50600</NewInternalPort><NewInternalClient>192.168.1.20</NewInternalClient>"
            + "<NewEnabled>1</NewEnabled><NewPortMappingDescription>PlayFX</NewPortMappingDescription>"
            + "<NewLeaseDuration>0</NewLeaseDuration></u:AddPortMapping>"))

        // Cleanup deletes both ports, even when the first delete fails.
        gateway.actions.with { $0["DeletePortMapping"] = (500, "<errorCode>714</errorCode><errorDescription>NoSuchEntry</errorDescription>") }
        found.cleanup(ports: [50600, 50601])
        let deletes = gateway.http.requests.with { $0.filter { $0.contains("#DeletePortMapping") } }
        #expect(deletes.count == 2)
        #expect(deletes[0].contains("<NewExternalPort>50600</NewExternalPort><NewProtocol>UDP</NewProtocol>"))
        #expect(deletes[1].contains("<NewExternalPort>50601</NewExternalPort>"))
        #expect(gateway.ssdp.destinations.with { Set($0) } == ["127.0.0.1"])  // the responder only ever replied to loopback
    }

    @Test func failuresFallBackToSTUN() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        let found = try #require(UPnPGateway.discover(environment: gateway.environment()))
        gateway.actions.with { $0["AddPortMapping"] = (500, "<errorCode>725</errorCode><errorDescription>OnlyPermanentLeasesSupported</errorDescription>") }
        #expect(found.map(localPort: 1) == nil)
        #expect(throws: UPnPError.fault(code: 725, description: "OnlyPermanentLeasesSupported")) {
            try found.addPortMapping(port: 1, description: "x")
        }
        gateway.actions.with {
            $0["AddPortMapping"] = (200, "")
            $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress></NewExternalIPAddress>")
        }
        #expect(found.map(localPort: 1) == nil)
        #expect(throws: UPnPError.invalidResponse) { try found.externalIPAddress() }
        gateway.actions.with { $0["GetExternalIPAddress"] = (404, "") }
        #expect(throws: UPnPError.httpStatus(404)) { try found.externalIPAddress() }
        gateway.actions.with { $0["GetExternalIPAddress"] = (500, "<errorCode>x</errorCode>") }
        #expect(throws: UPnPError.httpStatus(500)) { try found.externalIPAddress() }
    }

    /// Item 14: what the gateway says its external address is must be dotted IPv4 and routable.
    @Test func externalAddressesAreValidated() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        let found = try #require(UPnPGateway.discover(environment: gateway.environment()))
        for bad in ["999.1.1.1", "1.2.3", "a.b.c.d", "203.0.113.5\r\nX: y", "203.0.113.5 ", "<script>", "::1", "1.2.3.4.5",
                    String(repeating: "1", count: 400)] {
            gateway.actions.with { $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>\(bad)</NewExternalIPAddress>") }
            #expect(throws: UPnPError.invalidResponse, "\(bad.prefix(20))") { try found.externalIPAddress() }
            #expect(found.map(localPort: 5) == nil)
        }
        for double in ["10.1.2.3", "192.168.0.5", "172.20.1.1", "100.64.1.1", "169.254.1.1", "127.0.0.1", "0.0.0.0", "224.0.0.1"] {
            gateway.actions.with { $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>\(double)</NewExternalIPAddress>") }
            #expect(throws: UPnPError.privateExternalAddress, "\(double)") { try found.externalIPAddress() }
            #expect(found.map(localPort: 5) == nil)
        }
        // A routable address passes; and the candidate builder won't take a bad one from an adapter either.
        gateway.actions.with { $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>198.51.100.9</NewExternalIPAddress>") }
        #expect(try found.externalIPAddress() == "198.51.100.9")
        let built = try CandidateBuilder.build(CandidateInputs(
            localPort: 9, interfaceAddress: "192.168.1.2", upnp: UPnPMapping(lanAddress: "192.168.1.2", publicAddress: "x\r\ny"),
            stun: NATPrediction(publicAddress: "203.0.113.5", basePort: 9, increment: 0, randomAllocation: false)))
        #expect(built.candidates.first?.address == "203.0.113.5")
    }

    @Test func aGatewayThatIsNotUsableIsSkipped() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        gateway.actions.with { $0["GetStatusInfo"] = (200, "<NewConnectionStatus>Disconnected</NewConnectionStatus>") }
        #expect(UPnPGateway.discover(environment: gateway.environment()) == nil)
        // A status action that fails, or an external address behind another NAT, also means "no gateway".
        gateway.actions.with { $0["GetStatusInfo"] = (500, "<errorCode>401</errorCode>") }
        #expect(UPnPGateway.discover(environment: gateway.environment()) == nil)
        gateway.actions.with {
            $0["GetStatusInfo"] = (200, "<NewConnectionStatus>Connected</NewConnectionStatus>")
            $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>192.168.0.5</NewExternalIPAddress>")
        }
        #expect(UPnPGateway.discover(environment: gateway.environment()) == nil)
        gateway.actions.with { $0["GetExternalIPAddress"] = (200, "<NewExternalIPAddress>203.0.113.5</NewExternalIPAddress>") }
        #expect(UPnPGateway.discover(environment: gateway.environment()) != nil)
    }

    @Test func nobodyAnswering() throws {
        let silent = try loopbackSocket()
        var environment = UPnPEnvironment(
            makeSocket: { try loopbackSocket() }, ssdpHost: "127.0.0.1", ssdpPort: silent.localPort, searchWait: 0.2,
            discoveryLimit: 1, http: LoopbackGuardedHTTP(), localAddress: { _ in "192.168.1.20" },
            acceptsGatewayAddress: { _ in true })
        let start = monotonicSeconds()
        #expect(UPnPGateway.discover(environment: environment) == nil)
        #expect(monotonicSeconds() - start < 1.5)
        // A socket that can't be made, and a cancelled search, find nothing either.
        environment.makeSocket = { throw FailureKind.permissionDenied }
        #expect(UPnPGateway.discover(environment: environment) == nil)
        environment.makeSocket = { try loopbackSocket() }
        environment.isCancelled = { true }
        #expect(UPnPGateway.discover(environment: environment) == nil)
    }

    @Test func descriptionsThatDontWork() throws {
        // A description without a WAN service ends the discovery quietly.
        let bad = try FakeGateway(description: { _ in "<root><device></device></root>" })
        defer { bad.stop() }
        #expect(UPnPGateway.discover(environment: bad.environment()) == nil)
        let environment = bad.environment()
        func open(_ text: String, timeout: Double = 1) -> UPnPGateway? {
            GatewayURL(text).flatMap { UPnPGateway.open(location: $0, environment: environment, timeout: timeout) }
        }
        #expect(open("http://127.0.0.1:1/x") == nil)  // nothing listens
        #expect(open("http://127.0.0.1:\(bad.http.port)/x", timeout: 0) == nil)  // no time left
        // No route to the gateway: no LAN address, no gateway.
        let good = try FakeGateway()
        defer { good.stop() }
        var noRoute = good.environment()
        noRoute.localAddress = { _ in nil }
        #expect(UPnPGateway.discover(environment: noRoute) == nil)
    }

    @Test func controlURLForms() throws {
        // Relative to URLBase, and absolute on the same host.
        let based = try FakeGateway(description: {
            FakeGateway.description(control: "ctl/IPConn", base: "<URLBase>http://127.0.0.1:\($0)/upnp/</URLBase>") })
        defer { based.stop() }
        let gateway = try #require(UPnPGateway.discover(environment: based.environment()))
        #expect(gateway.controlPath == "/upnp/ctl/IPConn" && gateway.port == based.http.port)
        let absolute = try FakeGateway(description: { FakeGateway.description(control: "http://127.0.0.1:\($0)/abs/ctl") })
        defer { absolute.stop() }
        let other = try #require(UPnPGateway.discover(environment: absolute.environment()))
        #expect(other.controlPath == "/abs/ctl" && other.port == absolute.http.port && other.host == "127.0.0.1")
        // Relative with no URLBase: below the root.
        let plain = try FakeGateway(description: { _ in FakeGateway.description(control: "ctl/IPConn") })
        defer { plain.stop() }
        #expect(UPnPGateway.discover(environment: plain.environment())?.controlPath == "/ctl/IPConn")
    }

    // MARK: Hostile devices (items 3, 4)

    /// A device on the LAN that points the client elsewhere is ignored, and nothing is connected to or resolved.
    @Test func aRogueDeviceCannotRedirectTheClient() throws {
        for location in ["http://10.9.9.9:80/desc.xml", "http://localhost:80/desc.xml", "http://example.com/desc.xml",
                         "http://127.0.0.1:70000/desc.xml", "http://127.0.0.1:0/desc.xml", "http://user@127.0.0.1/x",
                         "https://127.0.0.1/x", "http://[::1]/x", "http://127.0.0.1:99999999999999999999/x",
                         "http://127.0.0.1/x y", "http://127.0.0.1/\r\nX: y"] {
            let gateway = try FakeGateway(locations: { _ in [location] })
            defer { gateway.stop() }
            #expect(UPnPGateway.discover(environment: gateway.environment()) == nil, "\(location)")
            #expect(gateway.http.requests.with { $0.isEmpty }, "\(location)")
        }
        // An absolute controlURL on another host, or a URLBase on another host.
        for description in [FakeGateway.description(control: "http://10.9.9.9/ctl"),
                            FakeGateway.description(control: "ctl", base: "<URLBase>http://10.9.9.9/</URLBase>")] {
            let gateway = try FakeGateway(description: { _ in description })
            defer { gateway.stop() }
            #expect(UPnPGateway.discover(environment: gateway.environment()) == nil)
        }
    }

    /// By default only RFC 1918 and link-local sources count as a gateway: loopback doesn't.
    @Test func onlyLANSourcesAreGateways() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        #expect(UPnPGateway.discover(environment: gateway.environment(acceptsLoopback: false)) == nil)
        for text in ["192.168.1.1", "10.0.0.1", "172.16.0.1", "172.31.0.1", "169.254.1.1"] {
            #expect(UPnPEnvironment.isLANAddress(text), "\(text)")
        }
        for text in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "203.0.113.5", "example.com", ""] {
            #expect(!UPnPEnvironment.isLANAddress(text), "\(text)")
        }
    }

    @Test func controlPathsAndServiceTypesAreChecked() throws {
        for control in ["/ctl\r\nX: y", "/ctl x", "/ctl\"", "/ctl<", "\\evil", "/" + String(repeating: "a", count: 2000)] {
            let gateway = try FakeGateway(description: { _ in FakeGateway.description(control: control) })
            defer { gateway.stop() }
            #expect(UPnPGateway.discover(environment: gateway.environment()) == nil, "\(control.prefix(12).debugDescription)")
        }
        for type in ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:x\r\nX: y", "WANIPConnection", "urn:"] {
            let xml = "<service><serviceType>\(type)</serviceType><controlURL>/c</controlURL></service>"
            #expect(UPnPGateway.parseDescription(xml) == nil, "\(type.debugDescription)")
        }
        #expect(UPnPGateway.isValidServiceType("urn:a-b_c.d:1"))
        #expect(!UPnPGateway.isValidServiceType("urn:a b") && !UPnPGateway.isValidServiceType("urn:") && !UPnPGateway.isValidServiceType("x"))
    }

    @Test func gatewayURLs() {
        #expect(GatewayURL("http://192.168.1.1:5000/a/b?c=d") == GatewayURL(host: "192.168.1.1", port: 5000, path: "/a/b?c=d"))
        #expect(GatewayURL("http://192.168.1.1")?.path == "/" && GatewayURL("http://192.168.1.1")?.port == 80)
        #expect(GatewayURL("HTTP://192.168.1.1?x=1")?.path == "/?x=1")
        for bad in ["", "http://", "http://:80/", "http://1.2.3.4:/", "http://1.2.3.4:65536/", "http://1.2.3.4:-1/", "http://1.2.3.4:1:2/",
                    "http://1.2.3.4/#frag", "ftp://1.2.3.4/", "http://1.2.3.4/" + String(repeating: "a", count: 1100)] {
            #expect(GatewayURL(bad) == nil, "\(bad.prefix(30))")
        }
        #expect(GatewayURL(host: "1.2.3.4", port: 0, path: "/") == nil && GatewayURL(host: "1.2.3.4", port: 1, path: "x") == nil)
        #expect(GatewayURL("http://1.2.3.4:65535/")?.port == 65535)
    }

    @Test func strayCloseTagsDontTrap() {
        let xml = "</service><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>"
            + "<controlURL>/c</controlURL></service></service><service>"
        #expect(UPnPGateway.parseDescription(xml)?.controlURL == "/c")
        #expect(UPnPGateway.parseDescription("</service>") == nil)
        #expect(UPnPGateway.parseDescription("<service>") == nil)
        #expect(UPnPGateway.parseDescription("</service></service><service>") == nil)
        #expect(UPnPGateway.element("a", in: "</a><a>") == nil)
    }

    /// One stalling device mustn't starve the real gateway: each exchange is cut to what is left.
    @Test func aStallingDeviceDoesNotStarveTheGateway() throws {
        let stall = try LoopbackHTTPServer { _ in
            sleepSeconds(2.5)
            return httpResponse(body: "late")
        }
        defer { stall.stop() }
        let gateway = try FakeGateway(locations: { ["http://127.0.0.1:\(stall.port)/slow.xml", "http://127.0.0.1:\($0)/rootDesc.xml"] })
        defer { gateway.stop() }
        var environment = gateway.environment()
        environment.httpTimeout = 0.4
        environment.discoveryLimit = 3
        let start = monotonicSeconds()
        #expect(UPnPGateway.discover(environment: environment) != nil)
        #expect(monotonicSeconds() - start < 2.5)
    }

    @Test func parsesDescriptions() {
        let ppp = "<service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ppp</controlURL></service>"
        let parsed = UPnPGateway.parseDescription("<root>\(ppp)</root>")
        #expect(parsed?.serviceType.hasSuffix("WANPPPConnection:1") == true && parsed?.controlURL == "/ppp" && parsed?.urlBase == nil)
        // The first of the two services in document order wins.
        let ip = "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ip</controlURL></service>"
        #expect(UPnPGateway.parseDescription("<root>\(ppp)\(ip)</root>")?.controlURL == "/ppp")
        #expect(UPnPGateway.parseDescription("<root>\(ip)\(ppp)</root>")?.controlURL == "/ip")
        #expect(UPnPGateway.parseDescription("<root><service><serviceType>x:WANIPConnection:2</serviceType></service></root>") == nil)
        #expect(UPnPGateway.parseDescription("") == nil)
        #expect(UPnPGateway.element("a", in: "<a> x &lt;&amp;&gt;&quot;&apos; </a>") == "x <&>\"'")
        #expect(UPnPGateway.element("a", in: "<a>unterminated") == nil)
        #expect(UPnPGateway.escape("a&b<c>\"d") == "a&amp;b&lt;c&gt;&quot;d")
        #expect(UPnPGateway.header("location", in: Array("HTTP/1.1 200 OK\r\nLocation:  http://x/y \r\n\r\n".utf8)) == "http://x/y")
        #expect(UPnPGateway.header("st", in: Array("HTTP/1.1 200 OK\r\nbroken\r\n\r\n".utf8)) == nil)
    }

    // MARK: HTTP parsing (items 1, 5)

    private func outcome(_ text: String, closed: Bool = false) -> UPnPHTTPResponse.Outcome {
        UPnPHTTPResponse.parse(Array(text.utf8), connectionClosed: closed)
    }

    @Test func httpResponses() {
        #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc").response?.body == Array("abc".utf8))
        #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab") == .incomplete)
        #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab", closed: true).response?.body == Array("ab".utf8))
        #expect(outcome("HTTP/1.0 500 X\r\n\r\nrest", closed: true).response?.body == Array("rest".utf8))
        #expect(outcome("HTTP/1.0 500 X\r\n\r\nrest") == .incomplete)
        #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: 3") == .incomplete)
        #expect(outcome("garbage\r\n\r\n") == .invalid)
        #expect(outcome("HTTP/1.1 abc\r\n\r\n") == .invalid)
        let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\n\r\n"
        #expect(outcome(chunked).response?.body == Array("abcde".utf8))
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab") == .incomplete)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n") == .invalid)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3") == .incomplete)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab", closed: true) == .invalid)
    }

    /// Item 1: lengths and chunk sizes from the wire are never trusted.
    @Test func hostileLengthsAndChunks() {
        for length in ["-1", "-0", "+5", "0x10", "99999999999999999999", "9223372036854775807", "9999999", "262145", "1e3", "", " ", "١٢"] {
            #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: \(length)\r\n\r\nabc") == .invalid, "\(length)")
        }
        #expect(outcome("HTTP/1.1 200 OK\r\nContent-Length: 262144\r\n\r\n") == .incomplete)
        for size in ["7fffffffffffffff", "-5", "ffffffff", "fffffff", "+3", "0x3", "ggg", "", " ", "3 3"] {
            let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\nabc\r\n0\r\n\r\n"
            #expect(outcome(text) == .invalid, "\(size.debugDescription)")
        }
        // Chunks adding up to more than the cap, a size line that never ends, a chunk size one past the data.
        let big = String(repeating: "a", count: 100_000)
        let many = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + (0..<3).map { _ in "186a0\r\n\(big)\r\n" }.joined()
        #expect(outcome(many) == .invalid)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "1", count: 100)) == .invalid)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabc\r\n") == .incomplete)
        #expect(outcome("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc") == .incomplete)
        // Item 5: over the cap, or a header that never ends, is invalid at once.
        #expect(UPnPHTTPResponse.parse([UInt8](repeating: 0x41, count: 300_000), connectionClosed: false) == .invalid)
        #expect(UPnPHTTPResponse.parse(Array("HTTP/1.1 200 OK\r\n".utf8) + [UInt8](repeating: 0x41, count: 20_000), connectionClosed: false) == .invalid)
    }

    @Test func tcpClient() throws {
        let server = try LoopbackHTTPServer { _ in httpResponse(body: "hello") }
        defer { server.stop() }
        let bytes = try TCPHTTPClient().exchange(host: "127.0.0.1", port: server.port, request: Array("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 2)
        #expect(String(decoding: bytes, as: UTF8.self).hasSuffix("hello"))
        // A server that closes without a complete answer.
        let broken = try LoopbackHTTPServer { _ in Array("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8) }
        defer { broken.stop() }
        let partial = try TCPHTTPClient().exchange(host: "127.0.0.1", port: broken.port, request: Array("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 2)
        #expect(partial.count > 0)
        let empty = try LoopbackHTTPServer { _ in [] }
        defer { empty.stop() }
        #expect(throws: FailureKind.invalidResponse) {
            try TCPHTTPClient().exchange(host: "127.0.0.1", port: empty.port, request: Array("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 2)
        }
        // A body far over the cap, and a hostile length, are errors, not allocations.
        let huge = try LoopbackHTTPServer { _ in Array("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8) + [UInt8](repeating: 0x41, count: 600_000) }
        defer { huge.stop() }
        #expect(throws: FailureKind.invalidResponse) {
            try TCPHTTPClient().exchange(host: "127.0.0.1", port: huge.port, request: Array("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 5)
        }
        let negative = try LoopbackHTTPServer { _ in Array("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nabc".utf8) }
        defer { negative.stop() }
        #expect(throws: FailureKind.invalidResponse) {
            try TCPHTTPClient().exchange(host: "127.0.0.1", port: negative.port, request: Array("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 2)
        }
        // Nothing listening.
        let closed = try POSIXPunchSocket(bindHost: "127.0.0.1")
        #expect(throws: (any Error).self) {
            try TCPHTTPClient().exchange(host: "127.0.0.1", port: closed.localPort, request: [1], timeout: 1)
        }
    }

    @Test func addressText() {
        #expect(IPv4Text.octets("1.2.3.4") == [1, 2, 3, 4])
        for bad in ["", "1.2.3", "256.1.1.1", "1.2.3.4.5", " 1.2.3.4", "1.2.3.4\n", "0x1.2.3.4", "1.2.3.04", "::1", "localhost"] {
            #expect(IPv4Text.octets(bad) == nil || bad == "1.2.3.04", "\(bad.debugDescription)")
        }
        #expect(IPv4Text.isNotRoutable("not an ip") && !IPv4Text.isNotRoutable("198.51.100.9") && !IPv4Text.isNotRoutable("203.0.113.5"))
        #expect(IPv4Text.isLAN("127.0.0.1", loopback: true) && !IPv4Text.isLAN("127.0.0.1"))
    }
}
