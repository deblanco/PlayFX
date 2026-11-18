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
    public static func configureLogging(verbose: Bool, handler: (@Sendable (Int32, String) -> Void)? = nil) {
        logHandler = handler
        let mask: UInt32 = verbose ? 0x1f : (UInt32(PSRP_LOG_INFO.rawValue) | UInt32(PSRP_LOG_WARNING.rawValue) | UInt32(PSRP_LOG_ERROR.rawValue))
        psrp_init({ level, msg, _ in
            let text = msg.map { String(cString: $0) } ?? ""
            if let h = Console.logHandler { h(level, text) } else {
                FileHandle.standardError.write(Data("[chiaki] \(text)\n".utf8))
            }
        }, nil, mask)
    }
    static var logHandler: (@Sendable (Int32, String) -> Void)?

    /// Blocking; pings `host` or the whole LAN for `timeout` seconds.
    public static func discover(host: String? = nil, timeout: TimeInterval = 2) -> [DiscoveredConsole] {
        var hosts = [PsrpHost](repeating: PsrpHost(), count: 16)
        let n = hosts.withUnsafeMutableBufferPointer { buf in
            psrp_discover(host, Int32(timeout * 1000), buf.baseAddress, Int32(buf.count))
        }
        guard n > 0 else { return [] }
        return hosts[0..<Int(n)].map { h in
            var h = h
            let app = string(&h.running_app_name)
            return DiscoveredConsole(
                address: string(&h.address), name: string(&h.name), hostId: string(&h.host_id),
                systemVersion: string(&h.system_version), runningApp: app.isEmpty ? nil : app, ps5: h.ps5,
                state: h.state == Int32(PSRP_HOST_READY.rawValue) ? .ready
                    : h.state == Int32(PSRP_HOST_STANDBY.rawValue) ? .standby : .unknown)
        }
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
        guard ok else { throw ConsoleError.message(String(cString: error)) }
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
        guard let key = Data(base64Encoded: credentials.registKey), key.count == Int(PSRP_REGIST_KEY_SIZE) else { return false }
        return key.withUnsafeBytes { psrp_wakeup(credentials.address, $0.bindMemory(to: CChar.self).baseAddress, credentials.ps5) }
    }

    /// Reads a fixed-size C char array (imported as a tuple) as a String.
    static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
