import Foundation

/// A timed script of controller inputs for hardware checks (`pfxp stream --press`): button presses and stick or
/// trigger holds at given times, turned into the `ControllerState` to send at any moment.
///
/// Text form: comma-separated entries, `INPUT@SECONDS[:HOLD_MS]`.
/// - `INPUT` is buttons joined with `+` (`cross`, `circle`, `square`, `triangle`, `l1`, `r1`, `l2`, `r2` (a full
///   press), `l3`, `r3`, `options`, `share` (or `create`), `ps`, `touchpad`, `up`, `down`, `left`, `right`), or
///   `AXIS=VALUE` with `AXIS` one of `lx`, `ly`, `rx`, `ry` (VALUE -1...1; `ly=-1` is up, as on the wire, y is
///   negative up) or `l2`, `r2` (VALUE 0...1).
/// - `SECONDS` is when the input starts, from the script's own time zero, and `HOLD_MS` how long it stays
///   (default 150 ms). When the hold ends, that part returns to neutral.
///
/// Entries that overlap in time combine: buttons add up; for `lx`, `ly`, `rx` and `ry` two entries at once give the
/// one written later in the script; `l2` and `r2` (as a button or an axis) give the larger value. Two entries with a
/// button in common that touch or are closer than `minimumReleaseSeconds` (16 ms, one frame at 60 fps) are refused
/// when parsing, because the button would not be released in between. The ControllerState has no microphone button,
/// so there is none here.
public struct ControllerScript: Sendable, Equatable {
    public static let defaultHoldMilliseconds = 150
    /// The shortest release between two presses of the same button.
    public static let minimumReleaseSeconds = 0.016

    public enum Axis: String, Sendable, Equatable, CaseIterable {
        case lx, ly, rx, ry, l2, r2

        /// The range of values the script accepts.
        var range: ClosedRange<Double> { self == .l2 || self == .r2 ? 0...1 : -1...1 }
    }

    /// What an entry does while it is held.
    public enum Input: Sendable, Equatable {
        /// Button names as written (lower case).
        case buttons([String])
        case axis(Axis, Double)
    }

    public struct Entry: Sendable, Equatable {
        public var input: Input
        /// Seconds from the script's time zero.
        public var start: Double
        public var holdMilliseconds: Int

        public var end: Double { start + Double(holdMilliseconds) / 1000 }

        /// `label` with the start time, for messages: `press circle (150 ms) at 4 s`.
        func label(atTime: Bool) -> String { "\(label) at \(String(format: "%g", start)) s" }

        /// For logs: `press circle+up (300 ms)` or `hold ly=-1 (2000 ms)`.
        public var label: String {
            switch input {
            case .buttons(let names): "press \(names.joined(separator: "+")) (\(holdMilliseconds) ms)"
            case .axis(let axis, let value): "hold \(axis.rawValue)=\(String(format: "%g", value)) (\(holdMilliseconds) ms)"
            }
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Parses the text form. Throws `ControllerScriptError` on the first thing wrong.
    public init(parsing text: String) throws {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !(pieces.count == 1 && pieces[0].isEmpty) else { throw ControllerScriptError.emptyScript }
        entries = try pieces.map { try Self.parseEntry($0) }
        try checkReleases()
    }

    /// Refuses two entries that share a button and whose gap (end of one to start of the next) is under
    /// `minimumReleaseSeconds` without having started inside the other (that is an intended overlap).
    private func checkReleases() throws {
        for (i, a) in entries.enumerated() {
            guard case .buttons(let namesA) = a.input else { continue }
            for b in entries[(i + 1)...] {
                guard case .buttons(let namesB) = b.input, !Set(namesA).isDisjoint(with: namesB) else { continue }
                for (first, second) in [(a, b), (b, a)] {
                    let gap = second.start - first.end
                    if gap > -1e-9 && gap < Self.minimumReleaseSeconds - 1e-9 {
                        throw ControllerScriptError.noRelease(first: first.label(atTime: true), second: second.label(atTime: true))
                    }
                }
            }
        }
    }

    /// When the last entry ends (0 for no entries).
    public var duration: Double { entries.map(\.end).max() ?? 0 }

    /// The state to send at `time` seconds: idle with every entry that is being held applied.
    public func state(at time: Double) -> ControllerState {
        var state = ControllerState.idle
        for entry in entries where entry.start <= time && time < entry.end { Self.apply(entry.input, to: &state) }
        return state
    }

    /// The first moment after `time` at which an entry starts or ends, so the sender can wake exactly then.
    public func nextChange(after time: Double) -> Double? {
        entries.flatMap { [$0.start, $0.end] }.filter { $0 > time }.min()
    }

    // MARK: Applying

    private static let buttonNames: [String: ControllerButtons] = [
        "cross": .cross, "circle": .circle, "square": .square, "triangle": .triangle, "l1": .l1, "r1": .r1,
        "l3": .l3, "r3": .r3, "options": .options, "share": .share, "create": .share, "ps": .ps,
        "touchpad": .touchpad, "up": .dpadUp, "down": .dpadDown, "left": .dpadLeft, "right": .dpadRight,
    ]

    private static func apply(_ input: Input, to state: inout ControllerState) {
        switch input {
        case .buttons(let names):
            for name in names {
                if let bits = buttonNames[name] { state.buttons.formUnion(bits) }
                if name == "l2" { state.l2 = 255 }
                if name == "r2" { state.r2 = 255 }
            }
        case .axis(let axis, let value):
            func stick() -> Int16 { Int16((value * (value < 0 ? 32768 : 32767)).rounded()) }
            func trigger() -> UInt8 { UInt8((value * 255).rounded()) }
            switch axis {
            case .lx: state.leftStickX = stick()
            case .ly: state.leftStickY = stick()
            case .rx: state.rightStickX = stick()
            case .ry: state.rightStickY = stick()
            case .l2: state.l2 = max(state.l2, trigger())
            case .r2: state.r2 = max(state.r2, trigger())
            }
        }
    }

    // MARK: Parsing

    private static func parseEntry(_ entry: String) throws -> Entry {
        guard !entry.isEmpty else { throw ControllerScriptError.emptyEntry }
        let atParts = entry.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard atParts.count == 2, !atParts[0].isEmpty else { throw ControllerScriptError.missingTime(entry) }
        let timeParts = atParts[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard timeParts.count <= 2 else { throw ControllerScriptError.badNumber(entry: entry, text: atParts[1]) }

        guard let start = Double(timeParts[0]), start.isFinite else {
            throw ControllerScriptError.badNumber(entry: entry, text: timeParts[0])
        }
        guard start >= 0 else { throw ControllerScriptError.negativeTime(entry) }
        var hold = defaultHoldMilliseconds
        if timeParts.count == 2 {
            guard let ms = Int(timeParts[1]) else { throw ControllerScriptError.badNumber(entry: entry, text: timeParts[1]) }
            guard ms > 0 else { throw ControllerScriptError.badHold(entry) }
            hold = ms
        }

        let what = atParts[0].lowercased()
        if what.contains("=") {
            let sides = what.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
            guard sides.count == 2 else { throw ControllerScriptError.badAxisValue(entry) }
            guard let axis = Axis(rawValue: sides[0]) else {
                throw ControllerScriptError.unknownInput(entry: entry, name: sides[0])
            }
            guard let value = Double(sides[1]), value.isFinite else {
                throw ControllerScriptError.badNumber(entry: entry, text: sides[1])
            }
            guard axis.range.contains(value) else {
                throw ControllerScriptError.valueOutOfRange(entry: entry, axis: axis.rawValue, value: value)
            }
            return Entry(input: .axis(axis, value), start: start, holdMilliseconds: hold)
        }
        let names = what.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        for name in names where buttonNames[name] == nil && name != "l2" && name != "r2" {
            throw ControllerScriptError.unknownInput(entry: entry, name: name)
        }
        return Entry(input: .buttons(names), start: start, holdMilliseconds: hold)
    }
}

/// What is wrong with a `--press` script; the text names the entry.
public enum ControllerScriptError: Error, Equatable, CustomStringConvertible {
    case emptyScript
    case emptyEntry
    case missingTime(String)
    case unknownInput(entry: String, name: String)
    case badNumber(entry: String, text: String)
    case negativeTime(String)
    /// Two presses of one button with no release (or under 16 ms of it) between them.
    case noRelease(first: String, second: String)
    case badAxisValue(String)
    case badHold(String)
    case valueOutOfRange(entry: String, axis: String, value: Double)

    public var description: String {
        switch self {
        case .emptyScript: "the script is empty"
        case .emptyEntry: "an entry is empty (a doubled or trailing comma?)"
        case .missingTime(let entry): "\"\(entry)\": expected INPUT@SECONDS[:HOLD_MS]"
        case .unknownInput(let entry, let name):
            "\"\(entry)\": unknown button or axis \"\(name)\" (buttons: cross circle square triangle l1 r1 l2 r2 l3 r3 options "
                + "share create ps touchpad up down left right; axes: lx ly rx ry l2 r2)"
        case .badNumber(let entry, let text): "\"\(entry)\": \"\(text)\" is not a number"
        case .negativeTime(let entry): "\"\(entry)\": the time can't be negative"
        case .noRelease(let first, let second):
            "\(first) and \(second) touch: the button would not be released between them (leave at least 16 ms)"
        case .badAxisValue(let entry): "\"\(entry)\": expected AXIS=VALUE before the @"
        case .badHold(let entry): "\"\(entry)\": the hold must be at least 1 ms"
        case .valueOutOfRange(let entry, let axis, let value):
            "\"\(entry)\": \(String(format: "%g", value)) is out of range for \(axis) "
                + "(\(axis == "l2" || axis == "r2" ? "0 to 1" : "-1 to 1"))"
        }
    }
}

extension ControllerButtons {
    /// The script names of the buttons in the set, in a fixed order (for traces).
    public var names: [String] {
        let all: [(ControllerButtons, String)] = [
            (.cross, "cross"), (.circle, "circle"), (.square, "square"), (.triangle, "triangle"), (.l1, "l1"), (.r1, "r1"),
            (.l3, "l3"), (.r3, "r3"), (.options, "options"), (.share, "share"), (.ps, "ps"), (.touchpad, "touchpad"),
            (.dpadUp, "up"), (.dpadDown, "down"), (.dpadLeft, "left"), (.dpadRight, "right"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

extension ControllerState {
    /// One line for `pfxp --trace-input`: buttons, the four sticks and both triggers.
    public var traceDescription: String {
        "buttons [\(buttons.names.joined(separator: "+"))] lx \(leftStickX) ly \(leftStickY) rx \(rightStickX) ry \(rightStickY) l2 \(l2) r2 \(r2)"
    }
}

// MARK: Playing a script

extension ControllerScript {
    /// What `Player.step` decided for one wake-up.
    public struct Step: Sendable, Equatable {
        /// One state to send, for a start or end that fell in the interval.
        public struct Send: Sendable, Equatable {
            /// The script time of the boundary.
            public var time: Double
            public var state: ControllerState
            /// The entries that start here (announce each once `state` has been sent).
            public var announcements: [String]
        }

        /// Every boundary in `(previous time, time]` in order, so a press shorter than the wake-up interval, or a
        /// late wake-up, still sends its pressed state and then its release. Boundaries that change nothing and
        /// announce nothing are left out.
        public var sends: [Send]
        /// The state at `time` (the last send's state, or the unchanged one).
        public var current: ControllerState
        /// The next start or end after `time`, nil when the script is over.
        public var nextWake: Double?
    }

    /// Walks a script through time: `pfxp` calls `step(to:)` with the time since `connected` each time it wakes.
    public struct Player: Sendable {
        public let script: ControllerScript
        private var last = -Double.infinity
        private var previous = ControllerState.idle

        public init(_ script: ControllerScript) { self.script = script }

        public mutating func step(to time: Double) -> Step {
            let bounds = Set(script.entries.flatMap { [$0.start, $0.end] }).filter { $0 > last && $0 <= time }.sorted()
            var sends: [Step.Send] = []
            for bound in bounds {
                let state = script.state(at: bound)
                let starting = script.entries.filter { $0.start == bound }.map(\.label)
                if state != previous || !starting.isEmpty {
                    sends.append(Step.Send(time: bound, state: state, announcements: starting))
                }
                previous = state
            }
            last = max(last, time)
            return Step(sends: sends, current: previous, nextWake: script.nextChange(after: time))
        }
    }
}
