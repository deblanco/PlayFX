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
        // Expected discovery failures (unreachable broadcast addresses) don't count as errors.
        let error = Int32(PSRP_LOG_ERROR.rawValue)
        #expect(Log.level(chiaki: error, "Discovery failed to send: No route to host") == .debug)
        #expect(Log.level(chiaki: error, "Discovery Service failed to send ping for PS5") == .debug)
        #expect(Log.level(chiaki: error, "Session request connect failed") == .error)
    }

    /// Lines copied from a detailed log of a real session (2026-11-20).
    @Test(arguments: [
        "Added reference P frame 4711",
        "StreamConnection received data with msg.type == 16",
        "Sending Congestion Control Packet, received: 106, lost: 0",
        "StreamConnection sent heartbeat",
        "Takion received data ack with cumulative_seq_num = 0x2fa1, a_rwnd = 0x19000, gap_ack_blocks_count = 0, dup_tsns_count = 0",
        "Pushed seq num 0x2fa1 into Takion Send Buffer",
        "Acked seq num 0x2fa1 from Takion Send Buffer",
        "Ctrl received message of type 0xfe, size 0",
        "Ctrl sending message type 0xfe, size 0",
        "websocket_thread_func: Received PONG.",
        // A protocol hexdump: the header, its column line, and its rows.
        "Sending Message:",
        "Receiving message:",
        "offset 0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f  0123456789abcdef",
        "     0 c0 12 24 4f 24 4f 02 30 1c 91 00 00 00 00 01 fe ..$O$O.0........",
        "    10 00 00                                           ..              ",
        "c0 12 24 4f",
    ])
    func dropsLibchiakiChatterAndHexdumps(line: String) {
        #expect(!Log.keeps(chiaki: line))
    }

    @Test(arguments: [
        "StreamConnection received connection quality: target_bitrate=19417000, upstream_bitrate=0, upstream_loss=0.0000, disable_upstream_audio=0, rtt=103.5, loss=0",
        "StreamConnection measured bitrate: 7.4646 MBit/s",
        "Frame Processor received 2+1 / 3+1 units, attempting FEC",
        "FEC successful",
        "Ctrl received Heartbeat, sending reply",
        "Session request connect failed",
    ])
    func keepsWhatSaysSomething(line: String) {
        #expect(Log.keeps(chiaki: line))
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
