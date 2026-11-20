import Foundation
import Testing
@testable import StreamCore

extension Serial {
    @Suite struct PSNAuthTests {
        @Test func loginURLCarriesTheOAuthParameters() throws {
            let items = try #require(URLComponents(url: PSNAuth.loginURL, resolvingAgainstBaseURL: false)?.queryItems)
            let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(PSNAuth.loginURL.host == "auth.api.sonyentertainmentnetwork.com")
            #expect(q["client_id"] == PSNAuth.clientId)
            #expect(q["redirect_uri"] == PSNAuth.redirectURL)
            #expect(q["response_type"] == "code")
            #expect(q["scope"] == PSNAuth.scope)
        }

        @Test func extractsTheCode() {
            #expect(PSNAuth.code(fromRedirect: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=v3.ABC&cid=1") == "v3.ABC")
            #expect(PSNAuth.code(fromRedirect: "  v3.XYZ \n") == "v3.XYZ")
            #expect(PSNAuth.code(fromRedirect: "https://remoteplay.dl.playstation.net/remoteplay/redirect?error=denied") == nil)
            #expect(PSNAuth.code(fromRedirect: "   ") == nil)
        }

        @Test func tokenRequestIsAFormPost() throws {
            let req = PSNAuth.tokenRequest(code: "a+b c")
            #expect(req.httpMethod == "POST")
            #expect(req.url == PSNAuth.tokenURL)
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let basic = try #require(req.value(forHTTPHeaderField: "Authorization"))
            #expect(basic == "Basic " + Data("\(PSNAuth.clientId):\(PSNAuth.clientSecret)".utf8).base64EncodedString())
            let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
            #expect(body.hasPrefix("grant_type=authorization_code&code=a%2Bb%20c&scope="))
            #expect(!body.contains("+"))
            #expect(body.hasSuffix("&redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect"))
        }

        @Test func accountIdIsLittleEndianBase64() {
            #expect(PSNAuth.accountId(userId: 1) == "AQAAAAAAAAA=")
            #expect(PSNAuth.accountId(userId: 0x0102030405060708) == Data([8, 7, 6, 5, 4, 3, 2, 1]).base64EncodedString())
        }

        func withStub<T>(_ handler: @escaping (URLRequest) -> (Int, Data)?, _ body: () async throws -> T) async rethrows -> T {
            StubURLProtocol.handler = handler
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            return try await body()
        }

        @Test func exchangesTheCodeForTheAccountId() async throws {
            let id = try await withStub(psnStub(userId: "1")) { try await PSNAuth.accountId(code: "c") }
            #expect(id == "AQAAAAAAAAA=")
        }

        @Test func reportsSignInFailures() async {
            func message(_ handler: @escaping (URLRequest) -> (Int, Data)?) async -> String? {
                await withStub(handler) {
                    do { _ = try await PSNAuth.accountId(code: "c"); return nil } catch { return error.localizedDescription }
                }
            }
            #expect(await message { _ in (400, Data(#"{"error":"invalid_grant","error_description":"Bad code"}"#.utf8)) }
                    == "Bad code")
            #expect(await message { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) } == "invalid_grant")
            #expect(await message { _ in (200, Data("{}".utf8)) } == "no access token")
            #expect(await message(psnStub(userId: nil)) == "no user_id in token info")
            #expect(await message(psnStub(userId: "not a number")) == "no user_id in token info")
            #expect(await message { _ in (502, Data("<html>".utf8)) } != nil)
            #expect(await message { _ in (200, Data("[1]".utf8)) } == "Unexpected PSN response: [1]")
            #expect(await message { _ in nil } != nil) // network error
        }
    }
}
