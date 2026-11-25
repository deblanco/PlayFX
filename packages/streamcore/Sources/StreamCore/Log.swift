import Foundation
import os

/// StreamCore's log: levels and areas, secrets scrubbed before anything leaves this file. Every entry
/// goes to the system log (Console.app, subsystem "playfx") and to the configured sink — the
/// terminal for psrp, the host app (its log file) for the desktop.
public enum Log {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warning, error

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var name: String { ["debug", "info", "warning", "error"][rawValue] }
    }

    public enum Area: String, Sendable {
        case session, psn, console, renderer, input
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

    /// `detailed` adds debug entries. `sink` gets every kept entry.
    public static func configure(detailed: Bool, sink: Sink?) {
        config.withLock { $0 = Config(minimum: detailed ? .debug : .info, sink: sink) }
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

    /// Patterns for secrets that can show up in messages (HTTP headers, PSN replies, pairing keys).
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
