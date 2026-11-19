import Foundation
import Security

/// Small secrets the app keeps for the user (console pairing keys, the PSN account ID): string values by
/// key. Release builds use the Keychain; development builds a 0600 file, because an unsigned build gets a
/// Keychain prompt after every rebuild (nobody may be at the screen to answer it).
public protocol SecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String) throws
    func remove(_ key: String)
}

public enum SecretStores {
    /// The store the app uses (replaceable in tests, so they never touch real secrets).
    nonisolated(unsafe) public static var shared: SecretStore = {
        #if DEBUG
        FileSecretStore()
        #else
        KeychainSecretStore()
        #endif
    }()
}

public final class KeychainSecretStore: SecretStore {
    private let service: String
    public init(service: String = "PlayFX") { self.service = service }

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConsoleError.message("Couldn't save to the Keychain (\(status))") }
    }

    public func remove(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

/// One JSON object of key → value in a file only the user can read.
public final class FileSecretStore: SecretStore {
    private let url: URL
    private let lock = NSLock()

    /// `$PSRP_SECRET_FILE`, else ~/.config/psrp/playfx-secrets.json (next to psrp's pairing keys).
    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let path = ProcessInfo.processInfo.environment["PSRP_SECRET_FILE"], !path.isEmpty {
            self.url = URL(fileURLWithPath: path)
        } else {
            self.url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/psrp/playfx-secrets.json")
        }
    }

    /// Everything stored; empty when there's no file yet. A file that exists but can't be read or decoded
    /// throws: writing over it would silently delete every other console's pairing keys.
    private func all() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    public func get(_ key: String) -> String? { lock.withLock { (try? all())?[key] } }

    public func set(_ key: String, _ value: String) throws {
        try lock.withLock {
            var values = try all()
            values[key] = value
            try PrivateFile.write(JSONEncoder().encode(values), to: url)
        }
    }

    public func remove(_ key: String) {
        lock.withLock {
            guard var values = try? all() else {
                return Log.error(.session, "Secrets file unreadable; not removing \(key) (that would rewrite it)")
            }
            guard values.removeValue(forKey: key) != nil else { return }
            try? PrivateFile.write(JSONEncoder().encode(values), to: url)
        }
    }
}

/// For tests.
final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) throws { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}
