import Foundation

/// PSN sign-in: gives the account ID (to pair with a console) and the tokens that reach it over the
/// internet (see PSNAccount). Same OAuth client the official Remote Play app (and chiaki-ng) uses: the
/// user signs in on Sony's page, which redirects to `redirectURL?code=...`; the host app intercepts that.
public enum PSNAuth {
    static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    public static let redirectURL = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    /// A sign-in URL with a new client device ID; PSN only lets tokens created with one set up
    /// internet sessions.
    public static var loginURL: URL { loginURL(duid: newDeviceUID()) }

    /// A client device ID as PSN expects it: a fixed prefix and 16 random bytes in hex (48 chars).
    static func newDeviceUID() -> String {
        "0000000700410080" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func loginURL(duid: String) -> URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURL),
            .init(name: "scope", value: scope),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
            .init(name: "duid", value: duid),
        ]
        return c.url!
    }

    /// Extracts `code` from the redirect URL (or accepts a bare code).
    public static func code(fromRedirect input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let items = URLComponents(string: trimmed)?.queryItems, let code = items.first(where: { $0.name == "code" })?.value {
            return code
        }
        return trimmed.isEmpty || trimmed.contains("/") ? nil : trimmed
    }

    /// Session used for the token exchange (tests inject a stubbed one).
    static var urlSession = URLSession.shared
    static var basicAuth: String { "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString() }

    /// Exchanges the authorization code for the PSN account ID (8 bytes little-endian, base64).
    public static func accountId(code: String) async throws -> String {
        let token = try await json(tokenRequest(code: code))
        guard let accessToken = token["access_token"] as? String else { throw failure(token) }
        return try await accountId(accessToken: accessToken)
    }

    /// The account ID behind an access token.
    static func accountId(accessToken: String) async throws -> String {
        var info = URLRequest(url: tokenURL.appendingPathComponent(accessToken))
        info.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let user = try await json(info)
        guard let userId = (user["user_id"] as? String).flatMap(UInt64.init) else {
            throw ConsoleError.message("PSN sign-in failed: no user_id in token info")
        }
        return accountId(userId: userId)
    }

    static func failure(_ reply: [String: Any]) -> Error {
        ConsoleError.message("PSN sign-in failed: \(reply["error_description"] ?? reply["error"] ?? "no access token")")
    }

    /// The account ID as the console expects it: 8 bytes little-endian, base64.
    static func accountId(userId: UInt64) -> String {
        withUnsafeBytes(of: userId.littleEndian) { Data($0) }.base64EncodedString()
    }

    /// POST that trades the authorization code for tokens.
    static func tokenRequest(code: String) -> URLRequest {
        form([.init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code)])
    }

    /// POST that trades the refresh token for new tokens.
    static func refreshRequest(refreshToken: String) -> URLRequest {
        form([.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refreshToken)])
    }

    private static func form(_ items: [URLQueryItem]) -> URLRequest {
        var form = URLComponents()
        form.queryItems = items + [.init(name: "scope", value: scope), .init(name: "redirect_uri", value: redirectURL)]
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves '+' unescaped, which form decoding would read as a space.
        req.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return req
    }

    static func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await urlSession.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConsoleError.message("Unexpected PSN response: \(String(decoding: data, as: UTF8.self))")
        }
        return obj
    }
}
