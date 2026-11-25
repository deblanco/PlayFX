import Foundation
import Testing
@testable import StreamCore

extension Serial {
    @Suite struct PSNAccountTests {
        let start = Date(timeIntervalSince1970: 1_000_000)

        func withStub<T>(_ handler: @escaping (URLRequest) -> (Int, Data)?, _ body: () async throws -> T) async rethrows -> T {
            StubURLProtocol.handler = handler
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            return try await body()
        }

        func account(_ tokens: PSNTokens? = nil) -> (PSNAccount, MemoryTokenStore) {
            let store = MemoryTokenStore()
            store.tokens = tokens
            let account = PSNAccount(store: store)
            account.now = { [start] in start }
            return (account, store)
        }

        @Test func tokensFromAReplyAndWhenToRefresh() throws {
            let t = try #require(PSNTokens(reply: ["access_token": "a", "refresh_token": "r", "expires_in": 3600], now: start))
            #expect(t == PSNTokens(accessToken: "a", refreshToken: "r", expiresAt: start.addingTimeInterval(3600)))
            #expect(!t.needsRefresh(at: start.addingTimeInterval(3539)))
            #expect(t.needsRefresh(at: start.addingTimeInterval(3540))) // within the last minute
            #expect(PSNTokens(reply: ["access_token": "a"], now: start) == nil)
        }

        @Test func signInURLCarriesANewDeviceIDEachTime() throws {
            func duid(_ url: URL) -> String? {
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "duid" }?.value
            }
            let a = try #require(duid(PSNAuth.loginURL)), b = try #require(duid(PSNAuth.loginURL))
            #expect(a.count == 48 && a.hasPrefix("0000000700410080") && a != b)
            #expect(a.dropFirst(16).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }

        @Test func refreshRequestUsesTheRefreshToken() throws {
            let body = String(decoding: try #require(PSNAuth.refreshRequest(refreshToken: "r+1").httpBody), as: UTF8.self)
            #expect(body.hasPrefix("grant_type=refresh_token&refresh_token=r%2B1&scope="))
        }

        @Test func signInKeepsTheTokensAndReturnsTheAccountID() async throws {
            let (account, store) = account()
            #expect(!account.signedIn)
            let id = try await withStub(psnStub(userId: "1")) { try await account.signIn(code: "c") }
            #expect(id == "AQAAAAAAAAA=")
            #expect(store.tokens == PSNTokens(accessToken: "tok123", refreshToken: "ref456", expiresAt: start.addingTimeInterval(3600)))
            #expect(account.signedIn)
            await #expect(throws: (any Error).self) {
                try await withStub({ _ in (200, Data(#"{"access_token":"only"}"#.utf8)) }) { try await account.signIn(code: "c") }
            }
            account.signOut()
            #expect(!account.signedIn)
        }

        @Test func freshTokensAreUsedAsIs() async throws {
            let (account, _) = account(PSNTokens(accessToken: "a", refreshToken: "r", expiresAt: start.addingTimeInterval(600)))
            #expect(try await withStub({ _ in nil }) { try await account.validAccessToken() } == "a") // no network
        }

        @Test func expiringTokensAreRefreshedAndSaved() async throws {
            let (account, store) = account(PSNTokens(accessToken: "old", refreshToken: "r", expiresAt: start.addingTimeInterval(30)))
            var sent: String?
            let token = try await withStub({ req in
                sent = req.httpMethod // the body reaches stubs as a stream; its content is tested above
                return (200, Data(#"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#.utf8))
            }) { try await account.validAccessToken() }
            #expect(token == "new" && store.tokens?.refreshToken == "r2")
            #expect(sent == "POST")
        }

        @Test func aRejectedRefreshSignsOut() async {
            let (account, store) = account(PSNTokens(accessToken: "old", refreshToken: "r", expiresAt: start))
            await #expect(throws: PSNError.signInExpired) {
                try await withStub({ _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }) { try await account.validAccessToken() }
            }
            #expect(store.tokens == nil)
            await #expect(throws: PSNError.notSignedIn) { try await account.validAccessToken() }
            #expect(PSNError.notSignedIn.errorDescription?.contains("Sign in") == true)
            #expect(PSNError.signInExpired.errorDescription?.contains("expired") == true)
        }

        @Test func aPassingFailureKeepsTheSignIn() async {
            // A server error or rate limit says nothing about the refresh token: keep it for the next try.
            let tokens = PSNTokens(accessToken: "old", refreshToken: "r", expiresAt: start)
            let (account, store) = account(tokens)
            await #expect(throws: ConsoleError.self) {
                try await withStub({ _ in (503, Data(#"{"error":"server_error"}"#.utf8)) }) { try await account.validAccessToken() }
            }
            #expect(store.tokens == tokens)
        }

        @Test func oneRefreshAtATime() async throws {
            let (account, store) = account(PSNTokens(accessToken: "old", refreshToken: "r", expiresAt: start))
            var calls = 0
            let lock = NSLock()
            let tokens = try await withStub({ _ in
                lock.withLock { calls += 1 }
                Thread.sleep(forTimeInterval: 0.1)
                return (200, Data(#"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#.utf8))
            }) {
                async let a = account.validAccessToken()
                async let b = account.validAccessToken()
                return try await [a, b]
            }
            #expect(tokens == ["new", "new"] && calls == 1 && store.tokens?.refreshToken == "r2")
        }

        @Test func fileStoreRoundTripOnlyForTheUser() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psrp-tokens-\(UUID())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = FileTokenStore(url: dir.appendingPathComponent("nested/psn-tokens.json"))
            #expect(store.load() == nil)
            let tokens = PSNTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 42))
            try store.save(tokens)
            #expect(store.load() == tokens)
            let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            try Data("not json".utf8).write(to: store.url)
            #expect(store.load() == nil) // corrupt file: signed out, not a crash
            store.clear()
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(FileTokenStore.defaultURL.path.hasSuffix("psn-tokens.json"))
        }

        @Test func keychainRoundTrip() throws {
            let store = KeychainTokenStore(service: "PlayFX tests \(UUID())")
            defer { store.clear() }
            #expect(store.load() == nil)
            let tokens = PSNTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 42))
            try store.save(tokens)
            #expect(store.load() == tokens)
            try store.save(PSNTokens(accessToken: "b", refreshToken: "r", expiresAt: tokens.expiresAt)) // update in place
            #expect(store.load()?.accessToken == "b")
            store.clear()
            #expect(store.load() == nil)
        }

        @Test func signInReasonsDontRepeatThePrefix() {
            // The app shows "PSN sign-in failed: <reason>", so a reason mustn't say it again.
            let keychain = KeychainTokenStore.saveFailed(-25308).localizedDescription
            #expect(keychain == "The Keychain couldn't save the PSN tokens (error -25308)")
            #expect(psnSignInTimedOut == "PlayStation Network didn't answer in time")
            for reason in [keychain, psnSignInTimedOut] { #expect(!reason.localizedCaseInsensitiveContains("sign-in")) }
        }
    }
}
