import CChiaki
import Foundation
import Security

/// PSN OAuth tokens, needed to reach the console over the internet (PSN hole punching).
public struct PSNTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// Refresh a minute before expiry, like chiaki-ng.
    func needsRefresh(at now: Date) -> Bool { now.addingTimeInterval(60) >= expiresAt }

    /// From a token endpoint reply (`access_token`, `refresh_token`, `expires_in` seconds).
    init?(reply: [String: Any], now: Date) {
        guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String,
              let expiresIn = (reply["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        self.init(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn))
    }

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Where the tokens live between launches.
public protocol PSNTokenStore: AnyObject {
    func load() -> PSNTokens?
    func save(_ tokens: PSNTokens) throws
    func clear()
}

/// The macOS/iOS Keychain (the tokens are credentials; they never reach the web UI).
public final class KeychainTokenStore: PSNTokenStore {
    let service: String
    let account = "psn-tokens"

    public init(service: String = "PS Remote Play — PSN") { self.service = service }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func load() -> PSNTokens? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PSNTokens.self, from: data)
    }

    public func save(_ tokens: PSNTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConsoleError.message("Couldn't save the PSN sign-in (Keychain error \(status))") }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// Tokens in memory only (tests).
final class MemoryTokenStore: PSNTokenStore {
    var tokens: PSNTokens?
    func load() -> PSNTokens? { tokens }
    func save(_ tokens: PSNTokens) throws { self.tokens = tokens }
    func clear() { tokens = nil }
}

/// The signed-in PSN account: signs in, keeps the tokens fresh, signs out.
public final class PSNAccount {
    public static let shared = PSNAccount(store: KeychainTokenStore())

    let store: PSNTokenStore
    var now: () -> Date = Date.init

    init(store: PSNTokenStore) { self.store = store }

    /// Whether there are tokens to reach consoles over the internet with.
    public var signedIn: Bool { store.load() != nil }

    /// Exchanges the sign-in code: keeps the tokens and returns the account ID (for pairing).
    public func signIn(code: String) async throws -> String {
        let reply = try await PSNAuth.json(PSNAuth.tokenRequest(code: code))
        guard let tokens = PSNTokens(reply: reply, now: now()) else { throw PSNAuth.failure(reply) }
        let id = try await PSNAuth.accountId(accessToken: tokens.accessToken)
        try store.save(tokens)
        return id
    }

    /// An access token valid for at least a minute, refreshing (and saving) it when needed. Throws
    /// `.signInExpired` — and forgets the tokens — when Sony no longer accepts the refresh token.
    public func validAccessToken() async throws -> String {
        guard let tokens = store.load() else { throw PSNError.notSignedIn }
        guard tokens.needsRefresh(at: now()) else { return tokens.accessToken }
        let reply = try await PSNAuth.json(PSNAuth.refreshRequest(refreshToken: tokens.refreshToken))
        guard let fresh = PSNTokens(reply: reply, now: now()) else {
            store.clear()
            throw PSNError.signInExpired
        }
        try store.save(fresh)
        return fresh.accessToken
    }

    public func signOut() { store.clear() }

    /// The PS5s on this PSN account (blocking network call, up to ~5 s; run off the main thread).
    public func consoles() async throws -> [PSNConsole] {
        let token = try await validAccessToken()
        return try listConsoles(token)
    }

    /// The shim's device list (tests replace it).
    var listConsoles: (String) throws -> [PSNConsole] = { token in
        var out = [PsrpPsnConsole](repeating: PsrpPsnConsole(), count: 16)
        var error = [CChar](repeating: 0, count: 256)
        let n = psrp_psn_list_consoles(token, &out, Int32(out.count), &error, error.count)
        guard n >= 0 else { throw ConsoleError.message("Couldn't list your PSN consoles: \(String(cString: error))") }
        return out.prefix(Int(n)).map(PSNConsole.init)
    }
}

/// A console on the PSN account, as PSN knows it.
public struct PSNConsole: Codable, Equatable, Sendable {
    public var name: String
    /// The console's PSN device ID (hex), used to reach it over the internet.
    public var duid: String
    public var remotePlay: Bool

    public init(name: String, duid: String, remotePlay: Bool) {
        self.name = name
        self.duid = duid
        self.remotePlay = remotePlay
    }

    init(_ c: PsrpPsnConsole) {
        var c = c
        name = withUnsafeBytes(of: &c.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        duid = withUnsafeBytes(of: &c.duid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        remotePlay = c.remote_play
    }
}

public enum PSNError: Error, Equatable, LocalizedError {
    case notSignedIn, signInExpired

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to PlayStation Network to play over the internet."
        case .signInExpired: "Your PlayStation Network sign-in expired. Sign in again to play over the internet."
        }
    }
}
