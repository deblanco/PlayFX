import CChiaki
import Foundation
import Testing
@testable import StreamCore

@Suite struct LatencyTestTests {
    @Test func tellsAnAnswerFromMotion() {
        var detector = LatencyDetector()
        let still = [UInt8](repeating: 50, count: 100)
        #expect(!detector.ready && !detector.answered(still))
        // A still menu: one picture is enough to judge against.
        detector.before(still)
        #expect(detector.ready && detector.threshold == LatencyDetector.floor)
        #expect(!detector.answered(still))
        // The highlight moving: a few samples change a lot.
        #expect(detector.answered(still.enumerated().map { $0.offset < 5 ? 150 : $0.element }))
        // The picture moving on its own raises the bar.
        detector.before(still.map { $0 + 2 })
        #expect(detector.threshold == 6 && !detector.answered(still.map { $0 + 6 }))
        #expect(detector.answered(still.map { $0 + 40 }))
        #expect(LatencyDetector.difference([1, 2], [1]) == 0)
    }

    @Test func samplesTheBottomOfThePicture() {
        // A frame dark on top, bright at the bottom: only the bottom is sampled.
        let region = LatencyDetector.region(width: 640, height: 360) { _, y in y >= 198 ? 200 : 10 }
        #expect(region.count == LatencyDetector.columns * LatencyDetector.rows && region.allSatisfy { $0 == 200 })
    }

    @Test func samplesADecodedFrame() throws {
        let frame = try makeNV12(width: 320, height: 180, y: 90, cb: 128, cr: 128)
        #expect(LatencyDetector.region(frame).allSatisfy { $0 == 90 })
    }

    /// A console on a fake clock: the control centre opens on PS and closes on Circle; while it's open, a
    /// Right or Left press moves its highlight 45 ms later. A still menu sends no new frames.
    final class StandInConsole {
        var time = 0.0
        var open = false
        var movedAt: Double?
        var highlight = 0
        var frame = 0
        var presses: [UInt32] = []
        let answers: Bool

        init(answers: Bool = true) { self.answers = answers }

        var probe: LatencyProbe {
            LatencyProbe(
                latest: { [self] in
                    if answers, let movedAt, time - movedAt >= 0.045 {
                        highlight += 1
                        frame += 1 // a new picture
                        self.movedAt = nil
                    }
                    var region = [UInt8](repeating: open ? 40 : 10, count: 64)
                    region[highlight % 8] = 200
                    return (frame, region)
                },
                press: { [self] buttons in
                    presses.append(buttons)
                    if buttons & UInt32(PSRP_BTN_PS.rawValue) != 0 { open = true; frame += 1 }
                    if buttons & UInt32(PSRP_BTN_CIRCLE.rawValue) != 0 {
                        // Off the first card, Circle only brings the highlight back to it.
                        if highlight % 2 == 0 { open = false } else { highlight = 0 }
                        frame += 1
                    }
                    let arrows = UInt32(PSRP_BTN_DPAD_RIGHT.rawValue | PSRP_BTN_DPAD_LEFT.rawValue)
                    if open, buttons & arrows != 0 { movedAt = time }
                },
                now: { [self] in time },
                sleep: { [self] in time += $0 })
        }
    }

    @Test func timesThePressToTheAnswer() {
        let console = StandInConsole()
        let summary = console.probe.run(trials: 3)
        #expect(summary.trials == 3 && summary.answered == 3)
        // 45 ms, up to the poll step.
        #expect(summary.minMs >= 45 && summary.maxMs <= 47, "\(summary)")
        #expect(summary.medianMs >= summary.minMs && summary.medianMs <= summary.maxMs)
        // PS once to open, Right / Left / Right, Circle to close; each released.
        let ps = UInt32(PSRP_BTN_PS.rawValue), circle = UInt32(PSRP_BTN_CIRCLE.rawValue)
        let right = UInt32(PSRP_BTN_DPAD_RIGHT.rawValue), left = UInt32(PSRP_BTN_DPAD_LEFT.rawValue)
        #expect(console.presses.filter { $0 != 0 }.prefix(5) == [ps, right, left, right, circle])
        #expect(console.presses.last == 0 && !console.open)
    }

    @Test func closesTheControlCentreEvenOffTheFirstCard() {
        // Three moves end off the first card: the first Circle brings the highlight back, the second closes.
        let console = StandInConsole()
        _ = console.probe.run(trials: 3)
        let circle = UInt32(PSRP_BTN_CIRCLE.rawValue)
        #expect(!console.open && console.presses.filter { $0 == circle }.count == 2)
    }

    @Test func countsTrialsWithoutAnAnswer() {
        let summary = StandInConsole(answers: false).probe.run(trials: 2)
        #expect(summary == LatencyProbe.Summary(trials: 2, answered: 0))
    }

    @Test func noPictureNoTrial() {
        final class Clock { var time = 0.0 }
        let clock = Clock()
        let probe = LatencyProbe(latest: { nil }, press: { _ in }, now: { clock.time }, sleep: { clock.time += $0 })
        #expect(probe.run(trials: 2) == LatencyProbe.Summary(trials: 2, answered: 0))
    }

    @Test func summarizes() {
        let s = LatencyProbe.summarize([40, 60, 50, 70], trials: 5)
        #expect(s.trials == 5 && s.answered == 4 && s.medianMs == 55 && s.meanMs == 55 && s.minMs == 40 && s.maxMs == 70)
        #expect(LatencyProbe.summarize([30, 10, 20], trials: 3).medianMs == 20)
    }
}
