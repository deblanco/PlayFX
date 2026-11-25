import Foundation
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

extension Serial {
    @Suite struct ConsoleTests {
        @Test func mapsDiscoveredHosts() {
            let answer = PlayFXProtocol.DiscoveredConsole(
                address: "192.168.0.40", hostID: "ABCDEF", kind: .ps5, state: .ready, status: 200, name: "PS5-123",
                systemVersion: "09060008", runningAppName: "Astro Bot")
            let c = Console.console(from: answer)
            #expect(c.address == "192.168.0.40" && c.name == "PS5-123" && c.hostId == "ABCDEF")
            #expect(c.systemVersion == "09060008" && c.runningApp == "Astro Bot" && c.ps5 && c.state == .ready)

            var bare = PlayFXProtocol.DiscoveredConsole(
                address: "10.0.0.2", hostID: "H", kind: .ps4, state: .standby, status: 620, runningAppName: "")
            let s = Console.console(from: bare)
            #expect(s.state == .standby && s.runningApp == nil && s.name.isEmpty && s.systemVersion.isEmpty && !s.ps5)
            bare.state = .unknown
            #expect(Console.console(from: bare).state == .unknown)
        }

        @Test func discoverMergesAnswersAndSurvivesFailure() {
            let many = (0..<20).map {
                PlayFXProtocol.DiscoveredConsole(address: "10.0.0.\($0)", hostID: "H\($0)", kind: .ps5, state: .ready, status: 200)
            }
            var stub = Console.Backend.live
            stub.discover = { _, _ in many }
            #expect(withConsoleBackend(stub) { Console.discover(timeout: 0.1) }.map(\.hostId) == (0..<16).map { "H\($0)" })
            stub.discover = { _, _ in [] }
            #expect(withConsoleBackend(stub) { Console.discover(timeout: 0.1) }.isEmpty)
            stub.discover = { _, _ in throw FailureKind.permissionDenied }
            #expect(withConsoleBackend(stub) { Console.discover(timeout: 0.1) }.isEmpty)
        }

        @Test func discoversOnLoopback() {
            let ready = DiscoveryResponder(answer: DiscoveryResponder.answer())
            defer { ready.stop() }
            let backend = Console.Backend.loopback(discoveryPort: ready.port)
            let found = withConsoleBackend(backend) { Console.discover(host: "127.0.0.1", timeout: 0.5) }
            #expect(found.count == 1)
            let c = found.first
            #expect(c?.address == "127.0.0.1" && c?.hostId == "0A1B2C3D4E5F" && c?.name == "PS5-TEST")
            #expect(c?.ps5 == true && c?.state == .ready && c?.runningApp == "Astro Bot" && c?.systemVersion == "09060008")
            // The LAN form (no host) is redirected to loopback by the test backend.
            #expect(withConsoleBackend(backend) { Console.discover(timeout: 0.5) }.count == 1)

            let resting = DiscoveryResponder(answer: DiscoveryResponder.answer(
                status: "620 Server Standby", ps5: false, name: "PS4-TEST", app: nil))
            defer { resting.stop() }
            let standby = withConsoleBackend(.loopback(discoveryPort: resting.port)) {
                Console.discover(host: "127.0.0.1", timeout: 0.5)
            }
            #expect(standby.first?.state == .standby && standby.first?.ps5 == false && standby.first?.runningApp == nil)

            let odd = DiscoveryResponder(answer: DiscoveryResponder.answer(status: "500 Odd"))
            defer { odd.stop() }
            #expect(withConsoleBackend(.loopback(discoveryPort: odd.port)) {
                Console.discover(host: "127.0.0.1", timeout: 0.5)
            }.first?.state == .unknown)

            let silent = DiscoveryResponder(answer: nil)
            defer { silent.stop() }
            #expect(withConsoleBackend(.loopback(discoveryPort: silent.port)) {
                Console.discover(host: "127.0.0.1", timeout: 0.2)
            }.isEmpty)
        }

        @Test func mapsAPairingToCredentials() throws {
            let r = PairingResult(
                registKey: Array("0123abcd".utf8) + [UInt8](repeating: 0, count: 8), rpKey: (0..<16).map(UInt8.init),
                nickname: "PS5-454", mac: [0x00, 0x1a, 0x2b, 0xc3, 0xd4, 0xff], target: .ps5v1, keyType: nil,
                apSSID: nil, apBSSID: nil, apKey: nil, apName: nil)
            let c = Console.credentials(from: r, address: "192.168.0.40", ps5: true, accountId: "AQEBAQEBAQE=")
            #expect(c.address == "192.168.0.40" && c.ps5 && c.nickname == "PS5-454" && c.accountId == "AQEBAQEBAQE=")
            #expect(c.mac == "00:1a:2b:c3:d4:ff")
            #expect(Data(base64Encoded: c.registKey) == Data("0123abcd".utf8) + Data(repeating: 0, count: 8))
            #expect(Data(base64Encoded: c.rpKey) == Data((0..<16).map(UInt8.init)))
            // The JSON shape the desktop app stores and sends back.
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any]
            #expect(Set(obj.map { Array($0.keys) } ?? []) == ["address", "ps5", "nickname", "mac", "registKey", "rpKey", "accountId"])
        }

        @Test func discoveredConsoleJSONShape() throws {
            let c = DiscoveredConsole(address: "1.2.3.4", name: "n", hostId: "h", systemVersion: "v", runningApp: nil,
                                      ps5: false, state: .standby)
            let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any]
            #expect(obj?["state"] as? String == "standby")
            #expect(obj?["hostId"] as? String == "h")
            #expect(try JSONDecoder().decode(DiscoveredConsole.self, from: JSONEncoder().encode(c)).address == "1.2.3.4")
        }

        @Test func liveDiscoveryAgainstLoopbackReturns() {
            // A unicast search of 127.0.0.1 (no broadcast); nothing answers.
            #expect(Console.discover(host: "127.0.0.1", timeout: 0.3).isEmpty)
        }

        @Test func registerValidatesInput() {
            #expect(throws: ConsoleError.self) {
                try Console.register(address: "127.0.0.1", ps5: true, accountId: "not base64!", pin: "12345678")
            }
            do {
                _ = try Console.register(address: "127.0.0.1", ps5: true, accountId: "AQID", pin: "12345678")
                Issue.record("expected an error")
            } catch {
                #expect(error.localizedDescription == "The PSN account ID must be 8 bytes encoded as base64")
            }
            let account = Data(repeating: 1, count: 8).base64EncodedString()
            for pin in ["1234", "123456789", "abcdefgh"] {
                #expect(throws: ConsoleError.message("The PIN must have 8 digits")) {
                    try Console.register(address: "127.0.0.1", ps5: true, accountId: account, pin: pin)
                }
            }
        }

        private static let account = Data(Vector.accountID).base64EncodedString()

        private func pair(_ console: FakeConsole, ps5: Bool = true, pin: String = "1234-5678") throws -> ConsoleCredentials {
            let backend = Console.Backend.loopback(searchPort: console.searchPort, requestPort: console.requestPort)
            return try withConsoleBackend(backend) {
                try Console.register(address: "127.0.0.1", ps5: ps5, accountId: Self.account, pin: pin)
            }
        }

        private func failure(_ console: FakeConsole, searchPort: UInt16? = nil, ps5: Bool = true) -> String? {
            let backend = Console.Backend.loopback(searchPort: searchPort ?? console.searchPort, requestPort: console.requestPort)
            do {
                _ = try withConsoleBackend(backend) {
                    try Console.register(address: "127.0.0.1", ps5: ps5, accountId: Self.account, pin: "12345678")
                }
                Issue.record("expected a pairing error")
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        @Test(arguments: [true, false]) func pairsWithAConsole(_ ps5: Bool) throws {
            let console = FakeConsole(target: ps5 ? .ps5v1 : .ps4v10, pin: Vector.pin) { _ in
                .encrypted(status: "200 OK", plaintext: FakeConsole.pairingPlaintext(ps5: ps5))
            }
            defer { console.stop() }
            let c = try pair(console, ps5: ps5)
            #expect(c.address == "127.0.0.1" && c.ps5 == ps5 && c.nickname == (ps5 ? "PS5-TEST" : "PS4-TEST"))
            #expect(c.mac == "0a:1b:2c:3d:4e:5f" && c.accountId == Self.account)
            #expect(Data(base64Encoded: c.registKey) == Data("a1b2c3d4".utf8) + Data(repeating: 0, count: 8))
            #expect(Data(base64Encoded: c.rpKey) == Data((0..<16).map { UInt8($0 * 0x11) }))
            #expect(console.requests.with { $0.count } == 1)
            // The stored keys wake what they paired.
            let sent = DiscoveryResponder(answer: nil)
            defer { sent.stop() }
            #expect(withConsoleBackend(.loopback(discoveryPort: sent.port)) { Console.wakeup(c) } == true)
        }

        @Test func pairingFailuresSayWhatToDo() {
            func refusing(_ reason: String) -> FakeConsole {
                FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in
                    .header("HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: \(reason)\r\nContent-Length: 0\r\n\r\n")
                }
            }
            let wrongPin = refusing("80108b09")
            defer { wrongPin.stop() }
            #expect(failure(wrongPin)?.hasPrefix("The code is wrong or has expired") == true)
            let wrongAccount = refusing("80108b02")
            defer { wrongAccount.stop() }
            #expect(failure(wrongAccount)?.contains("account ID PlayFX used doesn't belong") == true)
            let busy = refusing("80108b10")
            defer { busy.stop() }
            #expect(failure(busy, ps5: true)?.hasPrefix("The PS5 is already in a Remote Play session") == true)

            // Nothing answers the search: the console "didn't answer".
            let silent = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .close }
            defer { silent.stop() }
            #expect(failure(silent, searchPort: FakeConsole.closedUDPPort())?.hasPrefix("The PS5 didn't answer") == true)

            // It answered the search, then dropped the connection.
            #expect(failure(silent)?.hasPrefix("The PS5 stopped answering partway through pairing") == true)

            // It answered with something that isn't HTTP.
            let garbage = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .raw(Array("not http\r\n\r\n".utf8)) }
            defer { garbage.stop() }
            #expect(failure(garbage)?.hasPrefix("Registration failed: check the PIN") == true)
        }

        @Test func pairingErrorsThatAreNotRegistrationErrorsKeepTheirText() {
            var stub = Console.Backend.live
            stub.register = { _, _, _, _ in throw ConsoleError.message("boom") }
            #expect(throws: ConsoleError.message("boom")) {
                try withConsoleBackend(stub) {
                    try Console.register(address: "127.0.0.1", ps5: true, accountId: Self.account, pin: "12345678")
                }
            }
        }

        @Test func registerRoutesLogs() {
            let logs = LockedLines()
            Log.configure(detailed: true) { entry in if entry.area == .console { logs.append(entry.message) } }
            defer { Log.configure(detailed: false, sink: nil) }
            let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .close }
            defer { console.stop() }
            _ = failure(console)
            #expect(logs.lines.contains { $0.hasPrefix("Pairing with 127.0.0.1 failed") })
        }

        @Test func wakeSendsTheWakePacketOnLoopback() {
            let responder = DiscoveryResponder(answer: nil)
            defer { responder.stop() }
            let backend = Console.Backend.loopback(discoveryPort: responder.port)
            // "0123abcd" as the 8 hex characters of the stored key: credential 0x0123abcd = 19114957.
            #expect(withConsoleBackend(backend) { Console.wakeup(fakeCredentials()) })
            sleepSeconds(0.2)
            #expect(responder.received.contains { $0.hasPrefix("WAKEUP * HTTP/1.1") && $0.contains("user-credential:19114957") })
        }

        @Test func wakeupRejectsBadKeys() {
            var stub = Console.Backend.live
            stub.wake = { _, _, _ in Issue.record("must not send"); return true }
            withConsoleBackend(stub) {
                var c = fakeCredentials()
                c.registKey = "%%%"
                #expect(!Console.wakeup(c))
                c.registKey = Data(repeating: 1, count: 4).base64EncodedString() // wrong size
                #expect(!Console.wakeup(c))
            }
            // Well-formed but not hex: PlayFXProtocol refuses it (nothing is sent).
            let responder = DiscoveryResponder(answer: nil)
            defer { responder.stop() }
            #expect(!withConsoleBackend(.loopback(discoveryPort: responder.port)) { Console.wakeup(fakeCredentials(registKey: "zz")) })
            stub.wake = { _, _, _ in false }
            #expect(!withConsoleBackend(stub) { Console.wakeup(fakeCredentials()) })
        }

        @Test func consoleErrorDescribesItself() {
            #expect(ConsoleError.message("boom").errorDescription == "boom")
        }
    }
}

extension ConsoleError: Equatable {
    public static func == (a: ConsoleError, b: ConsoleError) -> Bool { a.errorDescription == b.errorDescription }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ s: String) { lock.withLock { _lines.append(s) } }
    var lines: [String] { lock.withLock { _lines } }
    func clear() { lock.withLock { _lines.removeAll() } }
}
