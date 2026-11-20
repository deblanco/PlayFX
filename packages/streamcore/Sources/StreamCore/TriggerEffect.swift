import Foundation
import GameController

/// A DualSense adaptive-trigger effect, decoded from the controller's own format (what the console
/// sends: a mode byte and 10 parameter bytes) into what GameController can play. Positions use the
/// trigger's 10 zones, from released (0) to fully pressed (9), as 0–1.
public enum TriggerEffect: Equatable, Sendable {
    case off
    /// Resistance per zone, 0–1.
    case feedback([Float])
    /// A trigger "pull": resistance from `start` to `end`, then it gives way.
    case weapon(start: Float, end: Float, strength: Float)
    /// Vibration amplitude per zone, 0–1, at `frequency` 0–1.
    case vibration([Float], frequency: Float)

    static let zones = 10

    public init(mode: UInt8, parameters p: [UInt8]) {
        func byte(_ i: Int) -> Int { i < p.count ? Int(p[i]) : 0 }
        func u16(_ i: Int) -> Int { byte(i) | byte(i + 1) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        /// Zone bitmask → first and last set zone.
        func span(_ mask: Int) -> (Int, Int)? {
            let set = (0..<Self.zones).filter { mask & (1 << $0) != 0 }
            return set.first.flatMap { first in set.last.map { (first, $0) } }
        }
        /// Per-zone levels from an active-zone mask and 3-bit packed levels (stored as level - 1).
        func packed(_ active: Int, _ levels: Int) -> [Float] {
            (0..<Self.zones).map { z in active & (1 << z) != 0 ? Float(((levels >> (3 * z)) & 7) + 1) / 8 : 0 }
        }
        /// Zones from a 0–255 position to the end, at `level`.
        func from(_ position: Int, _ level: Float) -> [Float] {
            let start = Int((Float(position) / 255 * 9).rounded())
            return (0..<Self.zones).map { $0 >= start ? level : 0 }
        }
        func zone(_ z: Int) -> Float { Float(z) / 9 }

        switch mode {
        case 0x21: // feedback: active zones (u16) + 3-bit strength per zone (u32)
            let strengths = packed(u16(0), u32(2))
            self = strengths.contains { $0 > 0 } ? .feedback(strengths) : .off
        case 0x25, 0x22: // weapon / bow: start and end zones (u16) + strength
            guard let (start, end) = span(u16(0)) else { self = .off; return }
            let strength = mode == 0x25 ? byte(2) : byte(2) & 7
            self = .weapon(start: zone(start), end: zone(end), strength: Float(strength + 1) / 8)
        case 0x26: // vibration: active zones + 3-bit amplitude per zone + frequency (Hz)
            let amplitudes = packed(u16(0), u32(2))
            self = amplitudes.contains { $0 > 0 } ? .vibration(amplitudes, frequency: Float(byte(8)) / 255) : .off
        case 0x23, 0x27: // galloping / machine: a vibration between two zones
            guard let (start, end) = span(u16(0)) else { self = .off; return }
            let level: Float = mode == 0x27 ? Float(max(byte(2) & 7, (byte(2) >> 3) & 7) + 1) / 8 : 0.75
            self = .vibration((0..<Self.zones).map { $0 >= start && $0 <= end ? level : 0 },
                              frequency: Float(byte(3)) / 255)
        case 0x01: // simple feedback: position, strength
            self = byte(1) > 0 ? .feedback(from(byte(0), Float(byte(1)) / 255)) : .off
        case 0x02: // simple weapon: start, end, strength
            self = byte(2) > 0
                ? .weapon(start: Float(byte(0)) / 255, end: Float(byte(1)) / 255, strength: Float(byte(2)) / 255)
                : .off
        case 0x06: // simple vibration: frequency, amplitude, position
            self = byte(1) > 0 ? .vibration(from(byte(2), Float(byte(1)) / 255), frequency: Float(byte(0)) / 255) : .off
        default: // 0x05 and anything unknown
            self = .off
        }
    }
}

/// Applies trigger effects to connected DualSense controllers (other pads have no adaptive triggers).
public final class AdaptiveTriggers {
    public init() {}

    /// Thread-safe; GameController is driven on the main queue.
    public func apply(left: TriggerEffect, right: TriggerEffect) {
        DispatchQueue.main.async {
            for pad in PadHardware.controllers().compactMap({ $0.extendedGamepad as? GCDualSenseGamepad }) {
                Self.set(pad.leftTrigger, left)
                Self.set(pad.rightTrigger, right)
            }
        }
    }

    /// Releases the triggers (e.g. when the session ends).
    public func reset() { apply(left: .off, right: .off) }

    static func set(_ trigger: GCDualSenseAdaptiveTrigger, _ effect: TriggerEffect) {
        switch effect {
        case .off:
            trigger.setModeOff()
        case .feedback(let strengths):
            var values = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            fill(&values.values, strengths)
            trigger.setModeFeedback(resistiveStrengths: values)
        case .weapon(let start, let end, let strength):
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .vibration(let amplitudes, let frequency):
            var values = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            fill(&values.values, amplitudes)
            trigger.setModeVibration(amplitudes: values, frequency: frequency)
        }
    }

    /// Copies up to 10 levels into GameController's fixed-size C array.
    static func fill<T>(_ tuple: inout T, _ levels: [Float]) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<min(floats.count, levels.count) { floats[i] = levels[i] }
        }
    }
}
