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

    /// One actuator: a looping continuous haptic whose intensity follows the console.
    private final class Actuator {
        let engine: CHHapticEngine
        let player: CHHapticAdvancedPatternPlayer
        var playing = false

        init?(_ haptics: GCDeviceHaptics, _ locality: GCHapticsLocality, sharpness: Float) {
            guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: 1)
            guard (try? engine.start()) != nil,
                  let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let player = try? engine.makeAdvancedPlayer(with: pattern) else { return nil }
            player.loopEnabled = true
            self.engine = engine
            self.player = player
        }

        func set(_ intensity: Float) {
            if intensity > 0 {
                try? player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                     value: intensity, relativeTime: 0)],
                                           atTime: CHHapticTimeImmediate)
                if !playing { playing = (try? player.start(atTime: CHHapticTimeImmediate)) != nil }
            } else if playing {
                try? player.stop(atTime: CHHapticTimeImmediate)
                playing = false
            }
        }

        deinit { engine.stop() }
    }

    private let queue = DispatchQueue(label: "streamcore.rumble")
    private var actuators: [ObjectIdentifier: [GCHapticsLocality: Actuator]] = [:]

    public init() {}

    /// Applies the console's motor levels to every connected controller. Thread-safe.
    public func apply(left: UInt8, right: UInt8) {
        let levels = Levels(left: left, right: right)
        queue.async { [self] in
            for controller in GCController.controllers() { drive(controller, levels) }
        }
    }

    /// Stops all rumble (e.g. when the session ends).
    public func stop() {
        queue.sync {
            actuators.values.forEach { $0.values.forEach { $0.set(0) } }
            actuators = [:]
        }
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
