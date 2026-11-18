import GameController
import Testing
@testable import StreamCore

@Suite struct TriggerEffectTests {
    func decode(_ mode: UInt8, _ bytes: [UInt8]) -> TriggerEffect {
        TriggerEffect(mode: mode, parameters: bytes + [UInt8](repeating: 0, count: max(0, 10 - bytes.count)))
    }

    @Test func offAndUnknownModes() {
        #expect(decode(0x05, []) == .off)
        #expect(decode(0x00, []) == .off)
        #expect(decode(0x99, [1, 2, 3]) == .off)
        #expect(TriggerEffect(mode: 0x25, parameters: []) == .off) // short payload: no zones
    }

    @Test func feedbackDecodesPerZoneStrengths() {
        // Zones 3–9 at strength 5 of 8 (stored as 4, 3 bits per zone).
        let effect = decode(0x21, [248, 3, 0, 72, 146, 36])
        #expect(effect == TriggerEffect.feedback([0, 0, 0] + [Float](repeating: 5.0 / 8, count: 7)))
        #expect(decode(0x21, [0, 0, 0xFF, 0xFF]) == .off) // no active zones
    }

    @Test func weaponDecodesItsSpanAndStrength() {
        // Start zone 2, end zone 7, strength 6 of 8 (stored as 5).
        #expect(decode(0x25, [132, 0, 5]) == TriggerEffect.weapon(start: 2.0 / 9, end: 7.0 / 9, strength: 6.0 / 8))
        #expect(decode(0x25, [0, 0, 5]) == .off)
        // Bow: same span, strength in the low 3 bits.
        #expect(decode(0x22, [132, 0, 0b0011_1010]) == TriggerEffect.weapon(start: 2.0 / 9, end: 7.0 / 9, strength: 3.0 / 8))
    }

    @Test func vibrationDecodesAmplitudesAndFrequency() {
        // Zones 0 and 1 at amplitude 8/8 and 4/8, 40 Hz.
        let effect = decode(0x26, [3, 0, 31, 0, 0, 0, 0, 0, 40])
        #expect(effect == TriggerEffect.vibration([1, 0.5] + [Float](repeating: 0, count: 8), frequency: 40.0 / 255))
        #expect(decode(0x26, [0, 0, 31]) == .off)
        // Galloping and machine vibrate between two zones.
        guard case .vibration(let gallop, _) = decode(0x23, [132, 0, 0, 30]) else { Issue.record("galloping"); return }
        #expect(gallop[1] == 0 && gallop[2] == 0.75 && gallop[7] == 0.75 && gallop[8] == 0)
        guard case .vibration(let machine, let hz) = decode(0x27, [132, 0, 0b0010_0011, 60]) else { Issue.record("machine"); return }
        #expect(machine[4] == 5.0 / 8 && abs(hz - 60.0 / 255) < 1e-6)
        #expect(decode(0x27, [0, 0, 7, 60]) == .off)
    }

    @Test func olderSimpleModes() {
        // Feedback from the middle of the travel, full strength.
        guard case .feedback(let zones) = decode(0x01, [128, 255]) else { Issue.record("simple feedback"); return }
        #expect(zones[3] == 0 && zones[5] == 1 && zones[9] == 1)
        #expect(decode(0x01, [128, 0]) == .off)
        #expect(decode(0x02, [51, 204, 255]) == TriggerEffect.weapon(start: 0.2, end: 0.8, strength: 1))
        #expect(decode(0x02, [51, 204, 0]) == .off)
        guard case .vibration(let amps, let hz) = decode(0x06, [100, 255, 0]) else { Issue.record("simple vibration"); return }
        #expect(amps.allSatisfy { $0 == 1 } && abs(hz - 100.0 / 255) < 1e-6)
        #expect(decode(0x06, [100, 0, 0]) == .off)
    }

    @Test func fillsGameControllersFixedArrays() {
        var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
        AdaptiveTriggers.fill(&strengths.values, [0.1, 0.2, 0.3])
        #expect(strengths.values.0 == 0.1 && strengths.values.2 == 0.3 && strengths.values.3 == 0)
        var amplitudes = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
        AdaptiveTriggers.fill(&amplitudes.values, [Float](repeating: 1, count: 12)) // extra levels ignored
        #expect(amplitudes.values.9 == 1)
    }

    @Test func noDualSenseIsANoOp() async {
        let triggers = AdaptiveTriggers()
        triggers.apply(left: .weapon(start: 0.2, end: 0.6, strength: 1), right: .feedback([1]))
        triggers.reset()
        await MainActor.run {} // let the queued work run
    }
}

extension Serial.StreamSessionTests {
    @Test func triggerEffectsBecomeEvents() throws {
        let session = try StreamSession(credentials: fakeCredentials(), options: StreamSession.Options())
        defer { session.stop() }
        var received: [(TriggerEffect, TriggerEffect)] = []
        session.onEvent = { if case .triggerEffects(let l, let r) = $0 { received.append((l, r)) } }
        session.handleTriggerEffects(0x25, [132, 0, 5, 0, 0, 0, 0, 0, 0, 0], 0x05, [UInt8](repeating: 0, count: 10))
        #expect(received.count == 1)
        #expect(received.first?.0 == TriggerEffect.weapon(start: 2.0 / 9, end: 7.0 / 9, strength: 6.0 / 8))
        #expect(received.first?.1 == TriggerEffect.off)
        #expect(eventPayload(.triggerEffects(left: .off, right: .off)) == nil) // not sent to the host
    }
}
