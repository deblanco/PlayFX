import CoreHaptics
import Foundation
import GameController

/// Plays the console's rumble on connected controllers through GameController haptics. The PS5 sends
/// two motor levels: left = the heavy low-frequency motor, right = the light high-frequency one.
public final class Rumble {
    /// Motor levels as haptic intensities, 0–1.
    struct Levels: Equatable {
        var low: Float
        var high: Float

        init(left: UInt8, right: UInt8) {
            low = Float(left) / 255
            high = Float(right) / 255
        }
    }

    /// Which actuator plays which motor: a handle each when the pad has both (DualSense, DualShock,
    /// Xbox), else the one default actuator plays the stronger of the two.
    enum Layout: Equatable {
        case handles
        case single

        init(supported: Set<GCHapticsLocality>) {
            self = supported.contains(.leftHandle) && supported.contains(.rightHandle) ? .handles : .single
        }

        /// (locality, intensity, sharpness) for each actuator to drive.
        func targets(_ levels: Levels) -> [(GCHapticsLocality, Float, Float)] {
            switch self {
            case .handles: [(.leftHandle, levels.low, 0.1), (.rightHandle, levels.high, 0.8)]
            case .single: [(.default, max(levels.low, levels.high), levels.high > levels.low ? 0.8 : 0.1)]
            }
        }
    }

    /// How long one continuous haptic runs, and when a playing one is replaced by a fresh one so the
    /// rumble never runs out mid-game.
    static let eventDuration: TimeInterval = 30
    static let renewAfter: TimeInterval = 25

    /// Whether to start a fresh player: none is playing, or the playing one is near its end.
    static func needsNewPlayer(playingSince: TimeInterval?, now: TimeInterval) -> Bool {
        playingSince.map { now - $0 >= renewAfter } ?? true
    }

    /// One actuator: a long continuous haptic whose intensity follows the console. A plain pattern player,
    /// not a looping advanced one: on macOS 27 gamecontrollerd rejects advanced-player patterns (it doesn't
    /// allow AVHapticEvent over XPC) and drops the connection, so nothing plays.
    private final class Actuator {
        let engine: CHHapticEngine
        let pattern: CHHapticPattern
        var player: CHHapticPatternPlayer?
        var playingSince: TimeInterval?

        init?(_ haptics: GCDeviceHaptics, _ locality: GCHapticsLocality, sharpness: Float) {
            guard let engine = haptics.createEngine(withLocality: locality) else {
                Log.warning(.input, "Rumble: no haptic engine for \(locality.rawValue)")
                return nil
            }
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: Rumble.eventDuration)
            do {
                try engine.start()
                pattern = try CHHapticPattern(events: [event], parameters: [])
                self.engine = engine
            } catch {
                Log.warning(.input, "Rumble: haptic engine for \(locality.rawValue) failed: \(error)")
                return nil
            }
        }

        func set(_ intensity: Float) {
            if intensity > 0 {
                do {
                    let now = ProcessInfo.processInfo.systemUptime
                    if Rumble.needsNewPlayer(playingSince: playingSince, now: now) {
                        let next = try engine.makePlayer(with: pattern)
                        try next.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                          value: intensity, relativeTime: 0)],
                                                atTime: CHHapticTimeImmediate)
                        try next.start(atTime: CHHapticTimeImmediate)
                        try? player?.stop(atTime: CHHapticTimeImmediate)
                        (player, playingSince) = (next, now)
                    } else {
                        try player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                             value: intensity, relativeTime: 0)],
                                                   atTime: CHHapticTimeImmediate)
                    }
                } catch {
                    Log.warning(.input, "Rumble: playing failed: \(error)")
                    (player, playingSince) = (nil, nil)
                }
            } else if let player {
                try? player.stop(atTime: CHHapticTimeImmediate)
                (self.player, playingSince) = (nil, nil)
            }
        }

        deinit { engine.stop() }
    }

    private let queue = DispatchQueue(label: "streamcore.rumble")
    private var actuators: [ObjectIdentifier: [GCHapticsLocality: Actuator]] = [:]

    public init() { PadQuiet.register(self) }

    /// How long haptics-made rumble lasts without a refresh. The shim repeats it every 50 ms while the
    /// console's haptics stream keeps coming; when an effect ends the console just stops sending.
    static let hapticsTimeout: TimeInterval = 0.15

    /// The connected controllers (replaced in tests; none in a test run, see `PadHardware`).
    nonisolated(unsafe) static var controllers: () -> [GCController] = PadHardware.controllers

    /// The levels last sent to the controllers. On `queue`.
    private var lastLevels = Levels(left: 0, right: 0)
    /// The levels the controllers play now, once what was asked so far is applied (tests, diagnosis).
    var levels: Levels { queue.sync { lastLevels } }
    /// Until when the haptics-made rumble playing now lasts; nil when the console's rumble is playing.
    private var hapticsUntil: TimeInterval?

    /// Whether haptics-made rumble is over: it was due a refresh by now and none came.
    static func hapticsExpired(until: TimeInterval?, now: TimeInterval) -> Bool {
        until.map { now >= $0 } ?? false
    }

    /// Applies the console's motor levels to every connected controller. Thread-safe.
    public func apply(left: UInt8, right: UInt8) {
        let levels = Levels(left: left, right: right)
        queue.async { [self] in
            hapticsUntil = nil
            send(levels)
        }
    }

    /// Applies levels made from the DualSense haptics stream; they end by themselves unless refreshed within
    /// `hapticsTimeout`. Thread-safe.
    public func applyHaptics(left: UInt8, right: UInt8) {
        let levels = Levels(left: left, right: right)
        queue.async { [self] in
            let silent = levels == Levels(left: 0, right: 0)
            hapticsUntil = silent ? nil : ProcessInfo.processInfo.systemUptime + Self.hapticsTimeout
            send(levels)
            guard !silent else { return }
            queue.asyncAfter(deadline: .now() + Self.hapticsTimeout + 0.01) { [self] in
                guard Self.hapticsExpired(until: hapticsUntil, now: ProcessInfo.processInfo.systemUptime) else { return }
                hapticsUntil = nil
                send(Levels(left: 0, right: 0))
            }
        }
    }

    /// On `queue`.
    private func send(_ levels: Levels) {
        lastLevels = levels
        guard !PadQuiet.isEnding else { return } // the process is ending with its pads quiet
        for controller in Self.controllers() { drive(controller, levels) }
        USBHapticsMode.padOutputSent() // GameController's report may end a USB pad's audio haptics
    }

    /// Stops all rumble (e.g. when the session ends).
    public func stop() { _ = stopAll() }

    /// Stops all rumble; returns the haptic engines that played it.
    private func stopAll() -> [CHHapticEngine] {
        queue.sync {
            let engines = actuators.values.flatMap(\.values).map(\.engine)
            actuators.values.forEach { $0.values.forEach { $0.set(0) } }
            actuators = [:]
            return engines
        }
    }

    /// How long the process waits, when it ends, for the haptic engines to say they stopped.
    static let quietTimeout: TimeInterval = 0.3

    /// Stops all rumble and waits (at most `quietTimeout`) for the engines to stop: the process is ending, and a
    /// player it leaves running keeps the pad rumbling.
    func quiet() {
        let stopped = DispatchGroup()
        for engine in stopAll() {
            stopped.enter()
            engine.stop { _ in stopped.leave() }
        }
        _ = stopped.wait(timeout: .now() + Self.quietTimeout)
    }

    private func drive(_ controller: GCController, _ levels: Levels) {
        guard let haptics = controller.haptics else { return }
        let id = ObjectIdentifier(controller)
        for (locality, intensity, sharpness) in Layout(supported: haptics.supportedLocalities).targets(levels) {
            if actuators[id]?[locality] == nil {
                guard intensity > 0, let actuator = Actuator(haptics, locality, sharpness: sharpness) else { continue }
                actuators[id, default: [:]][locality] = actuator
            }
            actuators[id]?[locality]?.set(intensity)
        }
    }
}

extension Rumble: PadOutput {}
