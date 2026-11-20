import CChiaki
import Foundation
import os

/// StreamCore's log: levels and areas, secrets scrubbed before anything leaves this file. Every entry
/// goes to the system log (Console.app, subsystem "playfx") and to the configured sink — the
/// terminal for psrp, the host app (its log file) for the desktop. libchiaki's messages come through
/// here too, under the `chiaki` area.
public enum Log {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warning, error

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var name: String { ["debug", "info", "warning", "error"][rawValue] }
    }

    public enum Area: String, Sendable {
        case session, psn, console, renderer, input, chiaki
    }

    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let level: Level
        public let area: Area
        /// Already scrubbed.
        public let message: String
    }

    public typealias Sink = @Sendable (Entry) -> Void

    private struct Config {
        var minimum: Level = .info
        var sink: Sink?
    }

    private static let config = OSAllocatedUnfairLock(initialState: Config())
    private static let system = os.Logger(subsystem: "playfx", category: "streamcore")

    /// `detailed` adds debug entries, including libchiaki's verbose ones. `sink` gets every kept entry.
    public static func configure(detailed: Bool, sink: Sink?) {
        config.withLock { $0 = Config(minimum: detailed ? .debug : .info, sink: sink) }
        let mask = detailed ? UInt32(0x1f)
            : UInt32(PSRP_LOG_INFO.rawValue) | UInt32(PSRP_LOG_WARNING.rawValue) | UInt32(PSRP_LOG_ERROR.rawValue)
        psrp_init({ level, message, _ in
            let text = message.map { String(cString: $0) } ?? ""
            guard Log.keeps(chiaki: text) else { return }
            Log.write(Log.level(chiaki: level, text), .chiaki, text)
        }, nil, mask)
    }

    public static func debug(_ area: Area, _ message: @autoclosure () -> String) { write(.debug, area, message()) }
    public static func info(_ area: Area, _ message: @autoclosure () -> String) { write(.info, area, message()) }
    public static func warning(_ area: Area, _ message: @autoclosure () -> String) { write(.warning, area, message()) }
    public static func error(_ area: Area, _ message: @autoclosure () -> String) { write(.error, area, message()) }

    static func write(_ level: Level, _ area: Area, _ message: @autoclosure () -> String) {
        let (minimum, sink) = config.withLock { ($0.minimum, $0.sink) }
        guard level >= minimum else { return }
        let entry = Entry(date: Date(), level: level, area: area, message: redact(message()))
        switch level {
        case .debug: system.debug("[\(area.rawValue, privacy: .public)] \(entry.message, privacy: .public)")
        case .info: system.info("[\(area.rawValue, privacy: .public)] \(entry.message, privacy: .public)")
        case .warning: system.warning("[\(area.rawValue, privacy: .public)] \(entry.message, privacy: .public)")
        case .error: system.error("[\(area.rawValue, privacy: .public)] \(entry.message, privacy: .public)")
        }
        sink?(entry)
    }

    /// libchiaki's level (PsrpLogLevel bits) → ours. Discovery pings every IPv4 broadcast address every
    /// few seconds, and libchiaki reports each one it can't reach (VM/container bridges, VPNs) as an
    /// error; those are expected, so they're debug entries rather than burying real errors.
    static func level(chiaki: Int32, _ message: String) -> Level {
        if message.hasPrefix("Discovery failed to send") || message.hasPrefix("Discovery Service failed to send ping") {
            return .debug
        }
        return level(chiaki: chiaki)
    }

    /// libchiaki's per-frame and per-packet chatter, dropped even from detailed logs: at 60 fps it's
    /// thousands of lines a minute, which rotated a whole session out of the log file within half an
    /// hour and left nothing but these lines. What's useful about it is in the stats.
    private static let chatter = [
        "Added reference ", "StreamConnection received data with msg.type", "Sending Congestion Control Packet",
        "StreamConnection sent heartbeat", "Takion received data ack", "Pushed seq num ", "Acked seq num ",
        "Ctrl received message of type", "Ctrl sending message type", "websocket_thread_func:",
    ]

    /// Hexdumps of protocol messages ("Sending Message:" then "offset 0 1 2 …" and rows of hex bytes):
    /// they can carry session material that `redact` can't recognise, so they never leave this file.
    private static let hexdump = try! NSRegularExpression(pattern: #"^(Sending Message:|Receiving message:|offset 0 +1 +2 |\s*[0-9a-f]+( [0-9a-f]{2})+\s|[0-9a-f]{2}( [0-9a-f]{2})*$)"#)

    /// Whether a libchiaki message goes to the log at all.
    static func keeps(chiaki message: String) -> Bool {
        if chatter.contains(where: { message.hasPrefix($0) }) { return false }
        return hexdump.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) == nil
    }

    static func level(chiaki: Int32) -> Level {
        switch UInt32(chiaki) {
        case PSRP_LOG_ERROR.rawValue: .error
        case PSRP_LOG_WARNING.rawValue: .warning
        case PSRP_LOG_INFO.rawValue: .info
        default: .debug
        }
    }

    /// Patterns for secrets that can show up in messages (libchiaki logs HTTP headers when verbose).
    private static let secrets: [(NSRegularExpression, String)] = [
        (#"(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#, "$1 <redacted>"),
        (#""(access_token|refresh_token|id_token|token|npsso)"\s*:\s*"[^"]*""#, #""$1":"<redacted>""#),
        (#"\b(access_token|refresh_token|token|code)=[^&\s"']+"#, "$1=<redacted>"),
        (#"(oauth/token/)[^\s/?"']+"#, "$1<redacted>"),
        (#"(?i)\b(regist[_ ]?key|rp[_ ]?key|morning|account[_ ]?id|psn[_ ]?account[_ ]?id)(["']?\s*[:=]\s*["']?)[A-Za-z0-9+/=_-]{6,}"#, "$1$2<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The message with credentials replaced by `<redacted>`.
    public static func redact(_ text: String) -> String {
        secrets.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }
}
