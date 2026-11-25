import Foundation
import PlayFXProtocol

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
    /// What Console calls on PlayFXProtocol; tests replace it to talk to fakes on loopback.
    struct Backend: Sendable {
        var discover: @Sendable (_ host: String?, _ timeout: Double) throws -> [PlayFXProtocol.DiscoveredConsole]
        var wake: @Sendable (_ address: String, _ registKey: [UInt8], _ ps5: Bool) -> Bool
        var register: @Sendable (_ address: String, _ ps5: Bool, _ accountId: [UInt8], _ pin: UInt32) throws -> PairingResult

        static let live = Backend(
            discover: { try Discovery.discoverThrowing(host: $0, timeout: $1) },
            wake: { Discovery.wake(address: $0, registKey: $1, ps5: $2) },
            register: { try Registration.register(address: $0, ps5: $1, accountId: $2, pin: $3) })
    }

    private final class BackendBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Backend.live
        var backend: Backend {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
    private static let box = BackendBox()
    static var backend: Backend {
        get { box.backend }
        set { box.backend = newValue }
    }

    private static let maximumConsoles = 16
    private static let accountIdSize = 8
    private static let registKeySize = 16
    private static let pinDigits = 8

    /// Blocking; pings `host` or the whole LAN for `timeout` seconds.
    public static func discover(host: String? = nil, timeout: TimeInterval = 2) -> [DiscoveredConsole] {
        let answers: [PlayFXProtocol.DiscoveredConsole]
        do {
            answers = try backend.discover(host, timeout)
        } catch {
            Log.warning(.console, "Discovery failed: \(error)")
            return []
        }
        guard !answers.isEmpty else {
            Log.debug(.console, "Discovery found no consoles")
            return []
        }
        let found = answers.prefix(maximumConsoles).map(console(from:))
        Log.debug(.console, "Discovery: " + found.map { "\($0.name) \($0.state.rawValue) at \($0.address)" }.joined(separator: ", "))
        return found
    }

    static func console(from answer: PlayFXProtocol.DiscoveredConsole) -> DiscoveredConsole {
        DiscoveredConsole(
            address: answer.address, name: answer.name ?? "", hostId: answer.hostID,
            systemVersion: answer.systemVersion ?? "",
            runningApp: answer.runningAppName.flatMap { $0.isEmpty ? nil : $0 }, ps5: answer.kind == .ps5,
            state: answer.state == .ready ? .ready : answer.state == .standby ? .standby : .unknown)
    }

    /// Blocking pairing with the 8-digit PIN shown on the console.
    public static func register(address: String, ps5: Bool, accountId: String, pin: String) throws -> ConsoleCredentials {
        guard let account = Data(base64Encoded: accountId), account.count == accountIdSize else {
            throw ConsoleError.message("The PSN account ID must be 8 bytes encoded as base64")
        }
        let digits = pin.filter(\.isNumber)
        guard digits.count == pinDigits, let pinValue = UInt32(digits) else {
            throw ConsoleError.message("The PIN must have 8 digits")
        }
        let result: PairingResult
        do {
            result = try backend.register(address, ps5, Array(account), pinValue)
        } catch {
            let message = (error as? RegistrationError)?.userMessage(ps5: ps5) ?? error.localizedDescription
            Log.error(.console, "Pairing with \(address) failed: \(message) (\(error))")
            throw ConsoleError.message(message)
        }
        let paired = credentials(from: result, address: address, ps5: ps5, accountId: accountId)
        Log.info(.console, "Paired with \(paired.nickname) at \(address)")
        return paired
    }

    static func credentials(from result: PairingResult, address: String, ps5: Bool,
                            accountId: String) -> ConsoleCredentials {
        ConsoleCredentials(
            address: address, ps5: ps5, nickname: result.nickname,
            mac: result.mac.map { String(format: "%02x", $0) }.joined(separator: ":"),
            registKey: Data(result.registKey).base64EncodedString(), rpKey: Data(result.rpKey).base64EncodedString(),
            accountId: accountId)
    }

    /// Wakes a console from rest mode.
    @discardableResult
    public static func wakeup(_ credentials: ConsoleCredentials) -> Bool {
        guard let key = Data(base64Encoded: credentials.registKey), key.count == registKeySize else {
            Log.warning(.console, "Can't wake \(credentials.nickname): invalid pairing data")
            return false
        }
        let sent = backend.wake(credentials.address, Array(key), credentials.ps5)
        Log.info(.console, sent ? "Wake-up sent to \(credentials.nickname) at \(credentials.address)"
                                : "Wake-up to \(credentials.nickname) at \(credentials.address) failed")
        return sent
    }
}
