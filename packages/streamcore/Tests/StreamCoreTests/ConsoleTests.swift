import CChiaki
import Foundation
import Testing
@testable import StreamCore

private func fill<T>(_ field: inout T, _ s: String) {
    withUnsafeMutableBytes(of: &field) { $0.copyBytes(from: Array(s.utf8)) }
}

extension Serial {
    @Suite struct ConsoleTests {
        @Test func mapsDiscoveredHosts() {
            var h = PsrpHost()
            fill(&h.address, "192.168.0.40")
            fill(&h.name, "PS5-123")
            fill(&h.host_id, "ABCDEF")
            fill(&h.system_version, "09060008")
            fill(&h.running_app_name, "Astro Bot")
            h.ps5 = true
            h.state = Int32(PSRP_HOST_READY.rawValue)
            let c = Console.console(from: h)
            #expect(c.address == "192.168.0.40" && c.name == "PS5-123" && c.hostId == "ABCDEF")
            #expect(c.systemVersion == "09060008" && c.runningApp == "Astro Bot" && c.ps5 && c.state == .ready)

            var standby = PsrpHost()
            standby.state = Int32(PSRP_HOST_STANDBY.rawValue)
            let s = Console.console(from: standby)
            #expect(s.state == .standby && s.runningApp == nil && s.address.isEmpty && !s.ps5)

            var unknown = PsrpHost()
            unknown.state = 42
            #expect(Console.console(from: unknown).state == .unknown)
        }

        @Test func mapsRegistrationToCredentials() throws {
            var r = PsrpRegistration()
            fill(&r.regist_key, "0123abcd")
            withUnsafeMutableBytes(of: &r.rp_key) { $0.copyBytes(from: (0..<16).map(UInt8.init)) }
            withUnsafeMutableBytes(of: &r.mac) { $0.copyBytes(from: [0x00, 0x1a, 0x2b, 0xc3, 0xd4, 0xff]) }
            fill(&r.nickname, "PS5-454")
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

        @Test func discoverAgainstLoopbackReturns() {
            // Nothing answers on loopback; a late reply to an earlier LAN broadcast may still show up.
            let consoles = Console.discover(host: "127.0.0.1", timeout: 0.3)
            #expect(consoles.allSatisfy { $0.address != "127.0.0.1" })
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

        @Test func registerFailsWithoutAConsoleAndRoutesLogs() {
            let logs = LockedLines()
            Log.configure(detailed: true) { entry in if entry.area == .chiaki { logs.append(entry.message) } }
            defer { Log.configure(detailed: false, sink: nil) }
            let account = Data(repeating: 1, count: 8).base64EncodedString()
            for ps5 in [true, false] {
                do {
                    _ = try Console.register(address: "127.0.0.1", ps5: ps5, accountId: account, pin: "1234-5678")
                    Issue.record("registration against loopback should fail")
                } catch {
                    #expect(error.localizedDescription.hasPrefix("Registration failed"))
                }
            }
            #expect(!logs.lines.isEmpty)
        }

        @Test func wakeupRejectsBadKeys() {
            var c = fakeCredentials()
            c.registKey = "%%%"
            #expect(!Console.wakeup(c))
            c.registKey = Data(repeating: 1, count: 4).base64EncodedString() // wrong size
            #expect(!Console.wakeup(c))
            c = fakeCredentials(registKey: "zz")                             // not hex
            #expect(!Console.wakeup(c))
            // Well-formed: a UDP packet to loopback, nobody listening.
            _ = Console.wakeup(fakeCredentials())
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
}
