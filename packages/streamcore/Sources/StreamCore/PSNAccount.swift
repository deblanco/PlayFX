import os
import Foundation
import PlayFXProtocol
import Security

/// PSN OAuth tokens, needed to reach the console over the internet (PSN hole punching).
public struct PSNTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// Refresh a minute before expiry.
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

    public init(service: String = "PlayFX — PSN") { self.service = service }

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
        guard status == errSecSuccess else { throw Self.saveFailed(status) }
    }

    /// Also a sign-in's reason, which the app puts after "PSN sign-in failed:".
    static func saveFailed(_ status: OSStatus) -> ConsoleError {
        .message("The Keychain couldn't save the PSN tokens (error \(status))")
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// A JSON file only the user can read (0600), for development builds: the Keychain ties its items to a
/// build's signature, so unsigned dev builds would ask for access after every rebuild — a prompt nobody
/// can answer when developing remotely. Outside the repo by default, so it can't be committed.
public final class FileTokenStore: PSNTokenStore {
    public let url: URL

    /// `$PSRP_TOKEN_FILE`, else ~/.config/psrp/psn-tokens.json (next to psrp's pairing keys).
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["PSRP_TOKEN_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/psrp/psn-tokens.json")
    }

    public init(url: URL = FileTokenStore.defaultURL) { self.url = url }

    public func load() -> PSNTokens? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PSNTokens.self, from: $0) }
    }

    public func save(_ tokens: PSNTokens) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(tokens).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
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
    /// Release builds keep the tokens in the Keychain; development builds in a 0600 file (see FileTokenStore).
    /// Replaceable so tests never touch the user's real sign-in.
    nonisolated(unsafe) public static var shared: PSNAccount = {
        #if DEBUG
        let store = FileTokenStore()
        Log.info(.psn, "Development build: PSN sign-in kept in \(store.url.path)")
        return PSNAccount(store: store)
        #else
        return PSNAccount(store: KeychainTokenStore())
        #endif
    }()

    let store: PSNTokenStore
    var now: () -> Date = Date.init

    init(store: PSNTokenStore) { self.store = store }

    /// Whether there are tokens to reach consoles over the internet with.
    public var signedIn: Bool { store.load() != nil }

    /// When the stored access token expires (diagnostics; never the token itself).
    public var tokenExpiry: Date? { store.load()?.expiresAt }

    /// Exchanges the sign-in code: keeps the tokens and returns the account ID (for pairing).
    public func signIn(code: String) async throws -> String {
        let reply = try await PSNAuth.json(PSNAuth.tokenRequest(code: code))
        guard let tokens = PSNTokens(reply: reply, now: now()) else {
            Log.error(.psn, "Sign-in refused by PSN: \(PSNAuth.describe(reply))")
            throw PSNAuth.failure(reply)
        }
        let id = try await PSNAuth.accountId(accessToken: tokens.accessToken)
        try Task.checkCancellation() // the caller gave up: don't sign in behind its back
        try store.save(tokens)
        Log.info(.psn, "Signed in; access token valid until \(tokens.expiresAt)")
        return id
    }

    /// An access token valid for at least a minute, refreshing (and saving) it when needed. Throws
    /// `.signInExpired` — and forgets the tokens — only when Sony says the refresh token is no good
    /// (`invalid_grant`); any other failure (a server error, rate limiting) keeps them for the next try.
    /// `forceRefresh`: get a new one even if this one hasn't expired (PSN can revoke tokens early).
    /// One refresh at a time: a caller arriving during one waits for it (Sony may rotate the refresh
    /// token, so a second refresh with the old one would fail and sign the user out).
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = store.load() else { throw PSNError.notSignedIn }
        guard forceRefresh || tokens.needsRefresh(at: now()) else { return tokens.accessToken }
        let refresh = refreshing.withLock { current -> Task<String, Error> in
            if let current { return current }
            let task = Task { try await self.refresh(tokens, forced: forceRefresh) }
            current = task
            return task
        }
        defer { refreshing.withLock { if $0 == refresh { $0 = nil } } }
        return try await refresh.value
    }

    private let refreshing = OSAllocatedUnfairLock<Task<String, Error>?>(initialState: nil)

    private func refresh(_ tokens: PSNTokens, forced: Bool) async throws -> String {
        Log.info(.psn, forced ? "Refreshing the PSN token (PSN rejected the current one)"
                              : "Refreshing the PSN token (expires \(tokens.expiresAt))")
        let reply = try await PSNAuth.json(PSNAuth.refreshRequest(refreshToken: tokens.refreshToken))
        guard let fresh = PSNTokens(reply: reply, now: now()) else {
            guard reply["error"] as? String == "invalid_grant" else {
                Log.warning(.psn, "PSN couldn't refresh the token right now: \(PSNAuth.describe(reply))")
                throw ConsoleError.message("PlayStation Network didn't answer properly. Try again in a moment.")
            }
            Log.error(.psn, "PSN refused the token refresh, signing out: \(PSNAuth.describe(reply))")
            store.clear()
            throw PSNError.signInExpired
        }
        try store.save(fresh)
        Log.info(.psn, "PSN token refreshed; valid until \(fresh.expiresAt)")
        return fresh.accessToken
    }

    public func signOut() {
        store.clear()
        Log.info(.psn, "Signed out of PSN")
    }

    /// The PS5s on this PSN account (a network call of up to ~5 s; run off the main thread).
    /// PSN can revoke an access token before it expires; then this refreshes it once and retries.
    public func consoles() async throws -> [PSNConsole] {
        let consoles: [PSNConsole]
        let token = try await validAccessToken()
        do {
            consoles = try await listConsoles(token)
        } catch let error as PlayFXProtocol.PSNError where Self.isUnauthorized(error) {
            Log.warning(.psn, "PSN refused the token for the console list (\(error)); retrying with a refreshed token")
            let fresh = try await validAccessToken(forceRefresh: true)
            do { consoles = try await listConsoles(fresh) } catch { throw Self.listFailure(error) }
        } catch {
            throw Self.listFailure(error)
        }
        Log.info(.psn, "PSN lists \(consoles.count) PS5(s): "
            + consoles.map { "\($0.name)\($0.remotePlay ? "" : " (Remote Play off)")" }.joined(separator: ", "))
        return consoles
    }

    /// How PSN is reached: tests put a fake here.
    var transport: any PSNTransport = URLSessionPSNTransport()

    /// The account's device list from PlayFXProtocol (psn.md section 4), with `token`.
    func listConsoles(_ token: String) async throws -> [PSNConsole] {
        try await PSNClient(accessToken: token, transport: transport).consoles().map(PSNConsole.init)
    }

    static func isUnauthorized(_ error: PlayFXProtocol.PSNError) -> Bool {
        if case .unauthorized = error { return true }
        return false
    }

    /// A failed list as the app shows it: what happened and what to do, after "Couldn't list your PSN consoles:".
    /// A cancelled call stays cancelled.
    static func listFailure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let reason: String
        switch error as? PlayFXProtocol.PSNError {
        case .unauthorized?:
            reason = "PlayStation Network refused the sign-in. Sign in with your PlayStation account again."
        case .timedOut?, .transport?:
            reason = "PlayStation Network didn't answer. Check the internet connection and try again."
        case .httpStatus(_, let status)?:
            reason = "PlayStation Network answered with an error (HTTP \(status)). Try again in a moment."
        case .some:
            reason = "PlayStation Network sent an answer PlayFX couldn't use. Try again; if it keeps happening, sign in again."
        case nil:
            reason = error.localizedDescription
        }
        return ConsoleError.message("Couldn't list your PSN consoles: \(reason)")
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

    init(_ c: PlayFXProtocol.PSNConsole) {
        self.init(name: c.name, duid: c.duid, remotePlay: c.remotePlayEnabled)
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
