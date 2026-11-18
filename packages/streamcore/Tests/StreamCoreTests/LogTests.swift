import CChiaki
import Foundation
import Testing
@testable import StreamCore

@Suite struct LogRedactionTests {
    @Test(arguments: [
        ("Authorization: Bearer eyJhbGciOi.abc-DEF_123", "Authorization: Bearer <redacted>"),
        ("Authorization: Basic YmE0OTVhMjQ6bXZhaQ==", "Authorization: Basic <redacted>"),
        (#"{"access_token":"tok123","expires_in":3600}"#, #"{"access_token":"<redacted>","expires_in":3600}"#),
        (#"{"refresh_token" : "r-9"}"#, #"{"refresh_token":"<redacted>"}"#),
        ("grant_type=refresh_token&refresh_token=abc%2B1&scope=x", "grant_type=refresh_token&refresh_token=<redacted>&scope=x"),
        ("redirect?code=v3.ABC&cid=1", "redirect?code=<redacted>&cid=1"),
        ("GET auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/tok123", "GET auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/<redacted>"),
        ("regist_key: 0123abcdef", "regist_key: <redacted>"),
        ("account id=AQEBAQEBAQE=", "account id=<redacted>"),
        ("Connected to 192.168.0.40:9295 (PS5-454)", "Connected to 192.168.0.40:9295 (PS5-454)"), // nothing secret
    ])
    func scrubsSecrets(input: String, expected: String) {
        #expect(Log.redact(input) == expected)
    }

    @Test func mapsLibchiakiLevels() {
        #expect(Log.level(chiaki: Int32(PSRP_LOG_ERROR.rawValue)) == .error)
        #expect(Log.level(chiaki: Int32(PSRP_LOG_WARNING.rawValue)) == .warning)
        #expect(Log.level(chiaki: Int32(PSRP_LOG_INFO.rawValue)) == .info)
        #expect(Log.level(chiaki: Int32(PSRP_LOG_VERBOSE.rawValue)) == .debug)
        #expect(Log.level(chiaki: Int32(PSRP_LOG_DEBUG.rawValue)) == .debug)
        #expect(Log.Level.debug < .error && Log.Level.warning.name == "warning")
    }
}

extension Serial {
    @Suite struct LogTests {
        @Test func keepsEntriesAtOrAboveTheLevelAndScrubsThem() {
            let seen = LockedLines()
            Log.configure(detailed: false) { seen.append("\($0.level.name) \($0.area.rawValue) \($0.message)") }
            defer { Log.configure(detailed: false, sink: nil) }
            Log.debug(.session, "hidden unless detailed")
            Log.info(.psn, "token refresh: refresh_token=secret")
            Log.warning(.renderer, "slow")
            Log.error(.input, "gone")
            #expect(seen.lines == ["info psn token refresh: refresh_token=<redacted>", "warning renderer slow", "error input gone"])

            Log.configure(detailed: true) { seen.append("\($0.level.name) \($0.message)") }
            Log.debug(.session, "now visible")
            #expect(seen.lines.last == "debug now visible")
        }
    }
}
