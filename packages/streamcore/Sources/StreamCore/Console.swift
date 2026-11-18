import CChiaki
import Foundation

/// A console found on the local network.
public struct DiscoveredConsole: Codable, Sendable {
    public enum State: String, Codable, Sendable { case ready, standby, unknown }
    public let address: String
    public let name: String
    public let hostId: String
    public let systemVersion: String
    public let runningApp: String?
    public let ps5: Bool
    public let state: State
}

/// Credentials obtained by pairing with a console. Everything needed to stream later;
/// the host app decides where to persist it (e.g. the webview's localStorage).
public struct ConsoleCredentials: Codable, Sendable {
    public var address: String
    public var ps5: Bool
    public var nickname: String
    public var mac: String
    /// 16 bytes, base64.
    public var registKey: String
    /// 16 bytes ("morning"), base64.
    public var rpKey: String
    /// PSN account ID, 8 bytes, base64.
    public var accountId: String
}

public enum ConsoleError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

public enum Console {
    /// Routes libchiaki logs. Call before anything else to change the default (stderr, info+).

    /// Blocking; pings `host` or the whole LAN for `timeout` seconds.
    public static func discover(host: String? = nil, timeout: TimeInterval = 2) -> [DiscoveredConsole] {
        var hosts = [PsrpHost](repeating: PsrpHost(), count: 16)
        let n = hosts.withUnsafeMutableBufferPointer { buf in
            psrp_discover(host, Int32(timeout * 1000), buf.baseAddress, Int32(buf.count))
        }
        guard n > 0 else {
            Log.debug(.console, "Discovery found no consoles")
            return []
        }
        let found = hosts[0..<Int(n)].map(console(from:))
        Log.debug(.console, "Discovery: " + found.map { "\($0.name) \($0.state.rawValue) at \($0.address)" }.joined(separator: ", "))
        return found
    }

    static func console(from host: PsrpHost) -> DiscoveredConsole {
        var h = host
        let app = string(&h.running_app_name)
        return DiscoveredConsole(
            address: string(&h.address), name: string(&h.name), hostId: string(&h.host_id),
            systemVersion: string(&h.system_version), runningApp: app.isEmpty ? nil : app, ps5: h.ps5,
            state: h.state == Int32(PSRP_HOST_READY.rawValue) ? .ready
                : h.state == Int32(PSRP_HOST_STANDBY.rawValue) ? .standby : .unknown)
    }

    /// Blocking pairing with the 8-digit PIN shown on the console.
    public static func register(address: String, ps5: Bool, accountId: String, pin: String) throws -> ConsoleCredentials {
        guard let account = Data(base64Encoded: accountId), account.count == Int(PSRP_ACCOUNT_ID_SIZE) else {
            throw ConsoleError.message("The PSN account ID must be 8 bytes encoded as base64")
        }
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let pinValue = UInt32(digits) else {
            throw ConsoleError.message("The PIN must have 8 digits")
        }
        var out = PsrpRegistration()
        var error = [CChar](repeating: 0, count: 512)
        let ok = account.withUnsafeBytes { acc in
            psrp_register(address, ps5, acc.bindMemory(to: UInt8.self).baseAddress, pinValue, &out, &error, error.count)
        }
        guard ok else {
            Log.error(.console, "Pairing with \(address) failed: \(String(cString: error))")
            throw ConsoleError.message(String(cString: error))
        }
        let paired = credentials(from: out, address: address, ps5: ps5, accountId: accountId)
        Log.info(.console, "Paired with \(paired.nickname) at \(address)")
        return paired
    }

    static func credentials(from registration: PsrpRegistration, address: String, ps5: Bool,
                            accountId: String) -> ConsoleCredentials {
        var out = registration
        let registKey = withUnsafeBytes(of: out.regist_key) { Data($0) }
        let rpKey = withUnsafeBytes(of: out.rp_key) { Data($0) }
        let mac = withUnsafeBytes(of: out.mac) { $0.map { String(format: "%02x", $0) }.joined(separator: ":") }
        return ConsoleCredentials(address: address, ps5: ps5, nickname: string(&out.nickname), mac: mac,
                                  registKey: registKey.base64EncodedString(), rpKey: rpKey.base64EncodedString(),
                                  accountId: accountId)
    }

    /// Wakes a console from rest mode.
    @discardableResult
    public static func wakeup(_ credentials: ConsoleCredentials) -> Bool {
        guard let key = Data(base64Encoded: credentials.registKey), key.count == Int(PSRP_REGIST_KEY_SIZE) else {
            Log.warning(.console, "Can't wake \(credentials.nickname): invalid pairing data")
            return false
        }
        let sent = key.withUnsafeBytes { psrp_wakeup(credentials.address, $0.bindMemory(to: CChar.self).baseAddress, credentials.ps5) }
        Log.info(.console, sent ? "Wake-up sent to \(credentials.nickname) at \(credentials.address)"
                                : "Wake-up to \(credentials.nickname) at \(credentials.address) failed")
        return sent
    }

    /// Reads a fixed-size C char array (imported as a tuple) as a String.
    static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
