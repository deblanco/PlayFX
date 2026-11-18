import CChiaki
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

        @Test func listsConsolesWithAValidToken() async throws {
            let (account, _) = account(PSNTokens(accessToken: "a", refreshToken: "r", expiresAt: start.addingTimeInterval(600)))
            var usedToken: String?
            account.listConsoles = { token in
                usedToken = token
                return [PSNConsole(name: "PS5-454", duid: String(repeating: "ab", count: 32), remotePlay: true)]
            }
            let consoles = try await account.consoles()
            #expect(usedToken == "a" && consoles.map(\.name) == ["PS5-454"])
            account.listConsoles = { _ in throw ConsoleError.message("Couldn't list your PSN consoles: Unknown") }
            await #expect(throws: ConsoleError.message("Couldn't list your PSN consoles: Unknown")) { try await account.consoles() }
            let (signedOut, _) = self.account()
            await #expect(throws: PSNError.notSignedIn) { try await signedOut.consoles() }
        }

        @Test func readsTheShimsConsoleRecord() {
            var c = PsrpPsnConsole()
            func write(_ text: String, into field: inout some Any) {
                withUnsafeMutableBytes(of: &field) { dst in
                    text.utf8CString.withUnsafeBytes { src in dst.copyMemory(from: src) }
                }
            }
            write("PS5-454", into: &c.name)
            write("ab12", into: &c.duid)
            c.remote_play = true
            #expect(PSNConsole(c) == PSNConsole(name: "PS5-454", duid: "ab12", remotePlay: true))
        }

        @Test func keychainRoundTrip() throws {
            let store = KeychainTokenStore(service: "PS Remote Play tests \(UUID())")
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
    }
}
