import Foundation
import os
import Testing
import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// The account's console list through PlayFXProtocol's PSN client, against a stand-in transport: nothing here reaches PSN.
/// (Both modules have a `PSNConsole` and a `PSNError`: StreamCore's are the ones the app sees.)
extension Serial {
    @Suite struct PSNConsoleListTests {
        let start = Date(timeIntervalSince1970: 1_000_000)

        /// A PSN that answers each device-list call from the token it carries, and keeps what it was asked.
        final class ListPSN: PSNTransport, @unchecked Sendable {
            let requests = OSAllocatedUnfairLock(initialState: [PSNHTTPRequest]())
            let answer: @Sendable (String) throws -> PSNHTTPResponse
            init(_ answer: @escaping @Sendable (String) throws -> PSNHTTPResponse) { self.answer = answer }

            func send(_ request: PSNHTTPRequest) async throws -> PSNHTTPResponse {
                requests.withLock { $0.append(request) }
                let token = (request.headers["Authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
                return try answer(token)
            }
            var tokens: [String] {
                requests.withLock { $0 }.map { ($0.headers["Authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "") }
            }
        }

        static func list(_ names: [(String, Bool)]) -> PSNHTTPResponse {
            let entries = names.map { name, remotePlay in
                #"{"duid":"\#(PSNVector.duid)","device":{"name":"\#(name)","enabledFeatures":[\#(remotePlay ? #""remotePlay""# : "")]}}"#
            }
            return PSNHTTPResponse(status: 200, body: Data(#"{"clients":[\#(entries.joined(separator: ","))]}"#.utf8))
        }

        /// An account that signs in with `access`, and whose PSN is `psn`; refreshing gives `refreshed`.
        func makeAccount(access: String = "a", psn: ListPSN) -> (PSNAccount, MemoryTokenStore) {
            let store = MemoryTokenStore()
            store.tokens = PSNTokens(accessToken: access, refreshToken: "r", expiresAt: start.addingTimeInterval(600))
            let account = PSNAccount(store: store)
            account.now = { [start] in start }
            account.transport = psn
            return (account, store)
        }

        func refreshing<T>(to token: String, _ body: () async throws -> T) async rethrows -> T {
            StubURLProtocol.handler = { _ in
                (200, Data(#"{"access_token":"\#(token)","refresh_token":"r2","expires_in":3600}"#.utf8))
            }
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            return try await body()
        }

        @Test func listsTheAccountsConsolesInTheShapeTheAppReads() async throws {
            let psn = ListPSN { _ in Self.list([("PS5-454", true), ("Den", false)]) }
            let (account, _) = makeAccount(psn: psn)
            let consoles = try await account.consoles()
            #expect(consoles == [
                StreamCore.PSNConsole(name: "PS5-454", duid: PSNVector.duid, remotePlay: true),
                StreamCore.PSNConsole(name: "Den", duid: PSNVector.duid, remotePlay: false),
            ])
            #expect(psn.tokens == ["a"])
            // The JSON the desktop app decodes: name, duid, remotePlay.
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(consoles[0])) as? [String: Any]
            #expect(Set(json.map { Array($0.keys) } ?? []) == ["name", "duid", "remotePlay"])
            // Only the device list was asked for, from PSN's web host.
            let urls = psn.requests.withLock { $0 }.compactMap(\.url.host)
            #expect(urls == ["web.np.playstation.com"])
        }

        @Test func anAccountWithoutConsolesGetsAnEmptyList() async throws {
            let (account, _) = makeAccount(psn: ListPSN { _ in Self.list([]) })
            #expect(try await account.consoles().isEmpty)
        }

        @Test func aRevokedTokenIsRefreshedOnceAndRetried() async throws {
            let psn = ListPSN { token in
                token == "fresh" ? Self.list([("PS5-454", true)]) : PSNHTTPResponse(status: 401)
            }
            let (account, store) = makeAccount(access: "revoked", psn: psn)
            let consoles = try await refreshing(to: "fresh") { try await account.consoles() }
            #expect(consoles.map(\.name) == ["PS5-454"] && psn.tokens == ["revoked", "fresh"])
            #expect(store.tokens?.accessToken == "fresh")
        }

        @Test func aTokenPSNKeepsRefusingIsReportedWithoutLoopingAndOtherFailuresAreNotRetried() async throws {
            let refused = ListPSN { _ in PSNHTTPResponse(status: 403) }
            let (account, _) = makeAccount(psn: refused)
            let reason = "PlayStation Network refused the sign-in. Sign in with your PlayStation account again."
            await #expect(throws: ConsoleError.message("Couldn't list your PSN consoles: \(reason)")) {
                _ = try await refreshing(to: "again") { try await account.consoles() }
            }
            #expect(refused.tokens == ["a", "again"]) // once refreshed, then given up

            for (status, text) in [(500, "PlayStation Network answered with an error (HTTP 500). Try again in a moment."),
                                   (200, "PlayStation Network sent an answer PlayFX couldn't use. Try again; if it keeps happening, sign in again.")] {
                let psn = ListPSN { _ in PSNHTTPResponse(status: status, body: Data("{}".utf8)) }
                let (account, _) = makeAccount(psn: psn)
                await #expect(throws: ConsoleError.message("Couldn't list your PSN consoles: \(text)")) { _ = try await account.consoles() }
                #expect(psn.tokens == ["a"]) // not a token problem: no refresh, no second call
            }
        }

        @Test func aFailureOfThePSNCallIsExplained() async {
            let down = ListPSN { _ in throw URLError(.notConnectedToInternet) }
            let (account, _) = makeAccount(psn: down)
            await #expect(throws: ConsoleError.message(
                "Couldn't list your PSN consoles: PlayStation Network didn't answer. Check the internet connection and try again.")) {
                _ = try await account.consoles()
            }
        }

        @Test func failuresReadAsTheAppShowsThem() {
            func text(_ error: Error) -> String { PSNAccount.listFailure(error).localizedDescription }
            #expect(text(PlayFXProtocol.PSNError.timedOut(step: .consoleList)).contains("didn't answer"))
            #expect(text(PlayFXProtocol.PSNError.unauthorized(step: .consoleList, status: 401)).contains("Sign in"))
            #expect(text(PlayFXProtocol.PSNError.invalidResponse(step: .consoleList, reason: "x")).contains("couldn't use"))
            #expect(text(ConsoleError.message("odd")) == "Couldn't list your PSN consoles: odd")
            #expect(PSNAccount.listFailure(CancellationError()) is CancellationError)
        }

        @Test func aSignedOutAccountNeverCallsPSN() async {
            let psn = ListPSN { _ in Self.list([]) }
            let (account, store) = makeAccount(psn: psn)
            store.tokens = nil
            await #expect(throws: StreamCore.PSNError.notSignedIn) { _ = try await account.consoles() }
            #expect(psn.requests.withLock { $0 }.isEmpty)
        }

        @Test func aSignInThatCannotBeRefreshedStaysSignedOut() async {
            let psn = ListPSN { _ in PSNHTTPResponse(status: 401) }
            let (account, store) = makeAccount(psn: psn)
            StubURLProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            await #expect(throws: StreamCore.PSNError.signInExpired) { _ = try await account.consoles() }
            #expect(store.tokens == nil)
        }

        @Test func theLibrarysConsoleBecomesTheAppsConsole() {
            let library = PlayFXProtocol.PSNConsole(name: "PS5-454", duid: PSNVector.duid, enabledFeatures: ["remotePlay", "other"])
            #expect(StreamCore.PSNConsole(library) == StreamCore.PSNConsole(name: "PS5-454", duid: PSNVector.duid, remotePlay: true))
            let off = PlayFXProtocol.PSNConsole(name: "x", duid: PSNVector.duid, enabledFeatures: [])
            #expect(!StreamCore.PSNConsole(off).remotePlay)
        }

        /// The default transport is the real one; no test may leave it in place, or a list would reach PSN.
        @Test func theDefaultTransportIsTheURLSessionOne() {
            #expect(PSNAccount(store: MemoryTokenStore()).transport is URLSessionPSNTransport)
        }
    }
}
