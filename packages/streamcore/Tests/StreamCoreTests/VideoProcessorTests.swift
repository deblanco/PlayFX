import CoreGraphics
import CoreVideo
import Foundation
import Metal
import ObjectiveC
import os
import QuartzCore
import Testing
import VideoToolbox
@testable import StreamCore

/// Stands in for VideoToolbox's frame processor: records every call, and each kind of call can succeed, return an
/// error, or raise an Objective-C exception (as VideoToolbox did once it ran out of Metal shared events). `process`
/// takes its acts in turn, the last one for good.
final class FakeProcessor: VideoProcessing, @unchecked Sendable {
    enum Act { case ok, error, exception }
    private struct State {
        var start = Act.ok, process = [Act.ok], end = Act.ok
        var calls: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// While set, `process` waits for it (a call still running); `holdStart` the same for `startSession`.
    var hold: DispatchSemaphore?
    var holdStart: DispatchSemaphore?

    init(start: Act = .ok, process: [Act] = [.ok], end: Act = .ok) {
        state.withLock { $0.start = start; $0.process = process; $0.end = end }
    }

    var calls: [String] { state.withLock { $0.calls } }
    func set(process: Act) { state.withLock { $0.process = [process] } }

    func startSession(configuration: AnyObject) throws {
        let act = state.withLock { s -> Act in s.calls.append("start"); return s.start }
        holdStart?.wait()
        try perform(act)
    }
    func process(parameters: AnyObject) throws {
        let act = state.withLock { s -> Act in
            s.calls.append("process")
            return s.process.count > 1 ? s.process.removeFirst() : s.process[0]
        }
        hold?.wait()
        try perform(act)
    }
    func endSession() { try? perform(state.withLock { s -> Act in s.calls.append("end"); return s.end }) }

    private func perform(_ act: Act) throws {
        switch act {
        case .ok: return
        case .error: throw NSError(domain: "VTFrameProcessorErrorDomain", code: -19730)
        case .exception:
            NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil").raise()
        }
    }
}

/// Makes `FakeProcessor`s, each as `next` says, and keeps them to look at.
final class FakeProcessors: @unchecked Sendable {
    private let made = OSAllocatedUnfairLock(initialState: [FakeProcessor]())
    var next: () -> FakeProcessor = { FakeProcessor() }
    var all: [FakeProcessor] { made.withLock { $0 } }
    /// The processors' `process` acts in the order they're made; any made after these always work.
    func plan(_ processes: [[FakeProcessor.Act]]) {
        next = { [unowned self] in FakeProcessor(process: all.count < processes.count ? processes[all.count] : [.ok]) }
    }
    func make() -> VideoProcessing? {
        let p = next()
        made.withLock { $0.append(p) }
        return p
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let t = OSAllocatedUnfairLock(initialState: 1000.0)
    var now: Double { t.withLock { $0 } }
    func advance(_ seconds: Double) { t.withLock { $0 += seconds } }
}

func testHealth(grace: Double = 0.02, clock: TestClock = TestClock()) -> VideoProcessorHealth {
    VideoProcessorHealth(feature: "Test", grace: grace, now: { clock.now })
}

@Suite struct VideoProcessorTests {
    @Test func outcomesTellErrorsFromExceptions() {
        #expect(ProcessorOutcome.of {} == .done)
        #expect(ProcessorOutcome.of { throw VideoProcessorError.failed } == .failed("failed"))
        #expect(ProcessorOutcome.of { NSException(name: .genericException, reason: "boom").raise() } == .threw("boom"))
    }

    @Test func anExceptionQuarantinesTheProcessorForGood() {
        let health = testHealth()
        let fake = FakeProcessor(process: [.exception])
        var processor: GuardedProcessor? = GuardedProcessor(fake, health: health)
        #expect(processor?.start(NSObject()) == .done)
        #expect(processor?.process(NSObject()) == .failed)
        #expect(processor?.isPoisoned == true && health.quarantined == 1 && health.failures == 1)
        // Nothing is called on it again: not another frame, not the end of its session, not when it's dropped.
        fake.set(process: .ok)
        #expect(processor?.process(NSObject()) == .failed)
        processor?.retire()
        processor = nil
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "process"])
    }

    @Test func anErrorCountsAndTheProcessorIsEndedAfterAGrace() {
        let health = testHealth(grace: 0.2)
        let fake = FakeProcessor(process: [.ok, .error])
        let processor = GuardedProcessor(fake, health: health)
        #expect(processor.start(NSObject()) == .done)
        #expect(processor.process(NSObject()) == .done)
        #expect(processor.process(NSObject()) == .failed)
        #expect(!processor.isPoisoned && health.failures == 1 && health.quarantined == 0 && !health.isOff)
        processor.retire()
        // Not at once: VideoToolbox may still be finishing the last call on its own queue.
        #expect(fake.calls == ["start", "process", "process"])
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "process", "process", "end"])
        // Retired: no more calls, and retiring again does nothing.
        #expect(processor.process(NSObject()) == .failed)
        processor.retire()
        #expect(health.waitForRetirements(timeout: 2) && fake.calls == ["start", "process", "process", "end"])
    }

    @Test func anErrorBeforeItEverWorkedIsARefusalNotAFailure() {
        // VideoToolbox's low-latency interpolation returns an error for every pair at 960×540: that size can't
        // be made, which says nothing about the processor (and mustn't turn the feature off).
        let health = testHealth()
        let fake = FakeProcessor(process: [.error])
        let processor = GuardedProcessor(fake, health: health)
        #expect(processor.start(NSObject()) == .done)
        #expect(processor.process(NSObject()) == .refused)
        #expect(health.failures == 0 && !processor.isPoisoned)
    }

    @Test func aFreshProcessorsFirstErrorIsAFailureWhereThatConfigurationWorkedBefore() {
        // Another processor made images at this size in this run: an error now is a fault (a GPU reset on wake),
        // not a size VideoToolbox refuses.
        let health = testHealth()
        let fake = FakeProcessor(process: [.error, .ok])
        let processor = GuardedProcessor(fake, health: health, proven: true)
        #expect(processor.start(NSObject()) == .done)
        #expect(processor.process(NSObject()) == .failed)
        #expect(health.failures == 1 && !processor.isPoisoned)
    }

    @Test func retirementEndsASessionStillStarting() {
        // Retired from another thread (the feature turning off) while `startSession` runs: ended once it's started.
        let health = testHealth(grace: 0.02)
        let fake = FakeProcessor()
        let hold = DispatchSemaphore(value: 0)
        fake.holdStart = hold
        let processor = GuardedProcessor(fake, health: health)
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = processor.start(NSObject())
            returned.signal()
        }
        while fake.calls.isEmpty { Thread.sleep(forTimeInterval: 0.005) }
        processor.retire()
        hold.signal()
        returned.wait()
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "end"])
    }

    @Test func turningOffRetiresEveryProcessorStillRunning() {
        // Nobody calls the owners again once the feature is off (the renderer stops asking), so the health ends
        // the sessions itself: here two that are idle and one in the middle of a call.
        let health = testHealth(grace: 0.02)
        let idle = (0..<2).map { _ in FakeProcessor() }
        let busy = FakeProcessor()
        let guarded = (idle + [busy]).map { GuardedProcessor($0, health: health) }
        #expect(guarded.allSatisfy { $0.start(NSObject()) == .done })
        let hold = DispatchSemaphore(value: 0)
        busy.hold = hold
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = guarded[2].process(NSObject())
            returned.signal()
        }
        while busy.calls.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        for _ in 0..<3 { health.failed("elsewhere") }
        #expect(health.isOff)
        #expect(!health.waitForRetirements(timeout: 0.2)) // not under the running call
        hold.signal()
        returned.wait()
        #expect(health.waitForRetirements(timeout: 2))
        #expect(idle.allSatisfy { $0.calls == ["start", "end"] } && busy.calls == ["start", "process", "end"])
        // Off: a processor made from now on is never started.
        let late = FakeProcessor()
        #expect(GuardedProcessor(late, health: health).start(NSObject()) == .notCalled && late.calls.isEmpty)
        withExtendedLifetime(guarded) {}
    }

    @Test func retirementWaitsForACallStillRunning() {
        let health = testHealth(grace: 0.02)
        let fake = FakeProcessor()
        let processor = GuardedProcessor(fake, health: health)
        #expect(processor.start(NSObject()) == .done)
        let hold = DispatchSemaphore(value: 0)
        fake.hold = hold
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = processor.process(NSObject())
            returned.signal()
        }
        while fake.calls.count < 2 { Thread.sleep(forTimeInterval: 0.005) } // in the call
        processor.retire() // from another thread while the call runs (a renderer torn down mid-pair)
        #expect(!health.waitForRetirements(timeout: 0.3))
        #expect(fake.calls == ["start", "process"]) // never ended under a running call
        hold.signal()
        returned.wait()
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "process", "end"])
    }

    @Test func aCallThatThrowsAfterRetiringIsNeverEnded() {
        let health = testHealth(grace: 0.02)
        let fake = FakeProcessor(process: [.exception])
        let processor = GuardedProcessor(fake, health: health)
        #expect(processor.start(NSObject()) == .done)
        let hold = DispatchSemaphore(value: 0)
        fake.hold = hold
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = processor.process(NSObject())
            returned.signal()
        }
        while fake.calls.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        processor.retire()
        hold.signal()
        returned.wait()
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "process"] && health.quarantined == 1)
    }

    @Test func startingCanFailOrThrow() {
        let health = testHealth()
        // It can't run this configuration: not poisoned, and never ended (it never started).
        let refused = FakeProcessor(start: .error)
        var a: GuardedProcessor? = GuardedProcessor(refused, health: health)
        if case .failed = a?.start(NSObject()) {} else { Issue.record("expected a failure") }
        #expect(a?.process(NSObject()) == .failed) // not started: not called, not counted
        a = nil
        // An exception: quarantined.
        let threw = FakeProcessor(start: .exception)
        let b = GuardedProcessor(threw, health: health)
        if case .threw = b.start(NSObject()) {} else { Issue.record("expected an exception") }
        #expect(b.isPoisoned && b.start(NSObject()) == .notCalled)
        #expect(health.waitForRetirements(timeout: 2))
        #expect(refused.calls == ["start"] && threw.calls == ["start"] && health.quarantined == 1 && health.failures == 1)
    }

    @Test func anExceptionWhileEndingQuarantinesToo() {
        let health = testHealth()
        let fake = FakeProcessor(end: .exception)
        let processor = GuardedProcessor(fake, health: health)
        #expect(processor.start(NSObject()) == .done && processor.process(NSObject()) == .done)
        processor.retire()
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fake.calls == ["start", "process", "end"] && health.quarantined == 1)
    }

    @Test func failuresPastTheBudgetTurnTheFeatureOff() {
        let clock = TestClock()
        let health = testHealth(clock: clock)
        health.failed("one")
        clock.advance(30)
        health.failed("two")
        #expect(!health.isOff)
        clock.advance(31) // the first is over a minute ago
        health.failed("three")
        #expect(!health.isOff)
        health.failed("four") // three within a minute
        #expect(health.isOff && health.failures == 4)
        // Spread out, they still turn it off at the run's limit.
        let spread = testHealth(clock: clock)
        for _ in 0..<9 {
            spread.failed("now and then")
            clock.advance(61)
        }
        #expect(!spread.isOff)
        spread.failed("tenth")
        #expect(spread.isOff)
    }
}

/// `FrameInterpolator` with stand-in processors: VideoToolbox's configuration and frame objects are real (macOS 26),
/// the processor isn't, so this runs where VideoToolbox can't (a VM).
@Suite struct FrameInterpolatorDefenceTests {
    func frames() throws -> (CVPixelBuffer, CVPixelBuffer) {
        (try makeNV12(width: 640, height: 352, y: 40, cb: 128, cr: 128), try makeNV12(width: 640, height: 352, y: 200, cb: 128, cr: 128))
    }

    @Test func restartsTheVideoProcessorAfterAnException() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: fakes.all.isEmpty ? [.exception] : [.ok]) }
        var interpolator: FrameInterpolator? = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        #expect(interpolator?.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) // this pair gets nothing
        let images = try #require(interpolator?.make(previous: a, current: b, phases: [0.5], steps: 1)) // a fresh processor
        #expect(images.count == 1 && CVPixelBufferGetWidth(images[0]) == 640)
        #expect(fakes.all.count == 2 && interpolator?.sessionsStarted == 2 && health.quarantined == 1 && interpolator?.hasFailed == false)
        // Torn down: the healthy one is ended (later), the poisoned one never.
        interpolator = nil
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all[0].calls == ["start", "process"])
        #expect(fakes.all[1].calls == ["start", "process", "end"])
    }

    @Test func anErrorGivesThatPairNothingAndRestartsTheProcessor() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: fakes.all.isEmpty ? [.ok, .error] : [.ok]) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        #expect(interpolator.make(previous: a, current: b, phases: [0.25, 0.5, 0.75], steps: 2)?.count == 3)
        #expect(interpolator.make(previous: a, current: b, phases: [0.25, 0.5, 0.75], steps: 2) == nil)
        #expect(interpolator.make(previous: a, current: b, phases: [0.25, 0.5, 0.75], steps: 2)?.count == 3)
        #expect(health.waitForRetirements(timeout: 2))
        // The one that failed is ended normally, after its grace.
        #expect(fakes.all[0].calls == ["start", "process", "process", "end"] && health.failures == 1 && health.quarantined == 0)
    }

    @Test func aSizeThatNeverWorksIsNotAskedForAgain() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: [.error]) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        for _ in 0..<4 { #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) }
        // Two fresh processors in a row erred at once; the size isn't asked for again, and the feature stays on.
        #expect(fakes.all.count == 2 && health.failures == 0 && !interpolator.hasFailed)
        #expect(health.waitForRetirements(timeout: 2) && fakes.all.allSatisfy { $0.calls == ["start", "process", "end"] })
    }

    @Test func turnsItselfOffWhenFreshProcessorsKeepFailing() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: [.exception]) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        for _ in 0..<3 { #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) }
        #expect(interpolator.hasFailed && health.quarantined == 3)
        // Off: no more processors, and nothing more called on the poisoned ones.
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil)
        interpolator.prepare(width: 640, height: 352)
        #expect(fakes.all.count == 3 && fakes.all.allSatisfy { $0.calls == ["start", "process"] })
    }

    @Test func turningOffEndsTheSessionsStillRunning() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        interpolator.prepare(width: 640, height: 352) // halves and quarters
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil)
        // Off from elsewhere, and the interpolator never called again (the renderer stops asking once it's off).
        for _ in 0..<3 { health.failed("elsewhere") }
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all.map(\.calls) == [["start", "process", "end"], ["start", "end"]])
        withExtendedLifetime(interpolator) {}
    }

    @Test func aFaultOverTwoProcessorsIsCountedNotTakenAsARefusal() throws {
        // A fault lasting two calls (a GPU reset on wake): the processor that worked errs, and so does the fresh
        // one's first call. Both count; the size isn't dropped, and the next fresh one makes images again.
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.plan([[.ok, .error], [.error, .ok]])
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        let made = (0..<6).map { _ in interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil }
        #expect(made == [true, false, false, true, true, true])
        #expect(health.failures == 2 && !health.isOff && fakes.all.count == 3)
    }

    @Test func aStartErrorAtASizeThatWorkedIsCountedNotTakenAsARefusal() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { fakes.all.count == 1 ? FakeProcessor(start: .error) : FakeProcessor(process: fakes.all.isEmpty ? [.ok, .error] : [.ok]) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        let made = (0..<4).map { _ in interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil }
        #expect(made == [true, false, false, true])
        #expect(health.failures == 2 && fakes.all.count == 3)
    }

    @Test func oneFreshProcessorsErrorIsntYetARefusal() throws {
        // The first processor at a size errs at once, a fresh one works: a fault that passed, the size is kept.
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: fakes.all.isEmpty ? [.error] : [.ok]) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        let made = (0..<3).map { _ in interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil }
        #expect(made == [false, true, true] && health.failures == 0 && fakes.all.count == 2)
    }

    @Test func aStartThatThrowsIsTriedAgainOneThatFailsIsNot() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(start: fakes.all.isEmpty ? .exception : .error) }
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) // threw: quarantined
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) // a fresh one can't run it
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) // so that size isn't tried again
        #expect(fakes.all.count == 2 && health.quarantined == 1 && health.failures == 1)
    }

    @Test func aNewSizeRetiresTheOldSessions() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        let interpolator = FrameInterpolator(health: health, available: true, makeProcessor: fakes.make)
        let (a, b) = try frames()
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil)
        #expect(interpolator.make(previous: a, current: b, phases: [0.25, 0.5, 0.75], steps: 2) != nil)
        let other = try makeNV12(width: 1280, height: 720, y: 40, cb: 128, cr: 128)
        #expect(interpolator.make(previous: other, current: other, phases: [0.5], steps: 1) != nil)
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all.map(\.calls) == [["start", "process", "end"], ["start", "process", "end"], ["start", "process"]])
    }
}

/// `MLSuperResolution` with stand-in processors: whole frames, and 1080p in two tiles (the cut and join are real Metal).
@Suite struct MLSuperResolutionDefenceTests {
    let screen = CGSize(width: 3840, height: 2160)

    @Test func restartsTheVideoProcessorAfterAnException() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: fakes.all.isEmpty ? [.exception] : [.ok]) }
        var ml: MLSuperResolution? = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        #expect(ml?.upscale(frame, target: screen) == nil)
        let out = try #require(ml?.upscale(frame, target: screen))
        #expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080)
        #expect(fakes.all.count == 2 && health.quarantined == 1 && ml?.hasFailed == false && ml?.refuses(width: 1280, height: 720) == false)
        ml = nil
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all[0].calls == ["start", "process"] && fakes.all[1].calls == ["start", "process", "end"])
    }

    @Test func aTileThatFailsRestartsEveryTile() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        // The second tile's first processor raises an exception.
        fakes.next = { FakeProcessor(process: fakes.all.count == 1 ? [.exception] : [.ok]) }
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1920, height: 1080, y: 90, cb: 128, cr: 128)
        #expect(ml.upscale(frame, target: screen) == nil)
        let out = try #require(ml.upscale(frame, target: screen))
        #expect(CVPixelBufferGetWidth(out) == 2880 && CVPixelBufferGetHeight(out) == 1620)
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all.map(\.calls) == [["start", "process", "end"], ["start", "process"], ["start", "process"], ["start", "process"]])
    }

    @Test func anErrorRestartsAndCounts() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: [.ok, .error]) }
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        for _ in 0..<3 {
            #expect(ml.upscale(frame, target: screen) != nil)
            #expect(ml.upscale(frame, target: screen) == nil)
        }
        #expect(ml.hasFailed && health.quarantined == 0 && fakes.all.count == 3)
        #expect(ml.upscale(frame, target: screen) == nil && fakes.all.count == 3) // off: nothing more started
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all.allSatisfy { $0.calls == ["start", "process", "process", "end"] })
    }

    @Test func aSizeTheModelNeverTakesIsNotAskedForAgain() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(process: [.error]) }
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        #expect(ml.upscale(frame, target: screen) == nil)
        #expect(!ml.refuses(width: 1280, height: 720)) // one fresh processor erring isn't yet a refusal
        #expect(ml.upscale(frame, target: screen) == nil)
        #expect(ml.upscale(frame, target: screen) == nil)
        #expect(ml.refuses(width: 1280, height: 720) && fakes.all.count == 2 && health.failures == 0 && !ml.hasFailed)
    }

    @Test func aFaultOverTwoProcessorsIsCountedNotTakenAsARefusal() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.plan([[.ok, .error], [.error, .ok]])
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        let upscaled = (0..<6).map { _ in ml.upscale(frame, target: screen) != nil }
        #expect(upscaled == [true, false, false, true, true, true])
        #expect(!ml.refuses(width: 1280, height: 720) && health.failures == 2 && !health.isOff)
    }

    @Test func aStartErrorAtASizeThatWorkedIsCountedNotTakenAsARefusal() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { fakes.all.count == 1 ? FakeProcessor(start: .error) : FakeProcessor(process: fakes.all.isEmpty ? [.ok, .error] : [.ok]) }
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        let upscaled = (0..<4).map { _ in ml.upscale(frame, target: screen) != nil }
        #expect(upscaled == [true, false, false, true])
        #expect(!ml.refuses(width: 1280, height: 720) && health.failures == 2)
    }

    @Test func turningOffEndsEveryTilesSession() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        #expect(ml.upscale(try makeNV12(width: 1920, height: 1080, y: 90, cb: 128, cr: 128), target: screen) != nil)
        for _ in 0..<3 { health.failed("elsewhere") } // and never called again: the lane stops once it's off
        #expect(health.waitForRetirements(timeout: 2))
        #expect(fakes.all.map(\.calls) == [["start", "process", "end"], ["start", "process", "end"]])
        withExtendedLifetime(ml) {}
    }

    @Test func aStartThatThrowsIsTriedAgainOneThatFailsIsNot() throws {
        guard #available(macOS 26.0, *) else { return }
        let health = testHealth()
        let fakes = FakeProcessors()
        fakes.next = { FakeProcessor(start: fakes.all.isEmpty ? .exception : .error) }
        let ml = MLSuperResolution(health: health, available: true, makeProcessor: fakes.make)
        let frame = try makeNV12(width: 1280, height: 720, y: 90, cb: 128, cr: 128)
        #expect(ml.upscale(frame, target: screen) == nil)
        #expect(!ml.refuses(width: 1280, height: 720))
        #expect(ml.upscale(frame, target: screen) == nil)
        #expect(ml.refuses(width: 1280, height: 720) && fakes.all.count == 2)
    }
}

extension StreamRendererTests {
    @Test func framesSkipAnUpscalerThatFailed() throws {
        let engine = FakeUpscaler(failed: true)
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        #expect(engine.calls == 0 && !r.mlActive && r.inputSize == (1280, 720))
        #expect(r.pipeline.ml == .failed)
    }

    @Test func framesGoAroundAStuckUpscaler() throws {
        let engine = FakeUpscaler(delay: 3)
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine, stallLimit: 0.2))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        r.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 0) // stuck in the lane
        while engine.calls == 0 { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.3)
        // Not held up behind it: shown as it is, and the stuck one is left out when it finally comes.
        r.display(try makeNV12(width: 128, height: 128, y: 90, cb: 128, cr: 128), index: 1)
        _ = try render(r, size: (2560, 1440))
        // Waiting on the model (a first build can take this long), not failed: that's off until a restart.
        #expect(r.inputSize == (128, 128) && r.pipeline.ml == .stalled)
        r.waitForUpscaling()
        _ = try render(r, size: (2560, 1440))
        #expect(r.inputSize == (128, 128) && engine.calls == 1)
    }
}

extension UpscaleLaneTests {
    @Test func saysWhenAFrameIsStuck() throws {
        let engine = FakeUpscaler(delay: 0.3)
        let lane = UpscaleLane(engine: engine, stallLimit: 5)
        #expect(!lane.isStalled() && !lane.hasFailed)
        lane.submit(try makeNV12(width: 64, height: 64, y: 50, cb: 128, cr: 128), target: CGSize(width: 200, height: 200)) { _ in }
        while engine.calls == 0 { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!lane.isStalled() && lane.isStalled(now: CACurrentMediaTime() + 10))
        lane.waitUntilIdle()
        #expect(!lane.isStalled(now: CACurrentMediaTime() + 10))
        #expect(UpscaleLane(engine: FakeUpscaler(failed: true)).hasFailed)
    }
}

extension InterpolationLaneTests {
    @Test func saysWhenFrameInterpolationTurnedItselfOff() throws {
        let health = testHealth()
        let device = try #require(device)
        let lane = try #require(InterpolationLane(device: device, health: health, engine: { StandInMaker() }))
        #expect(!lane.hasFailed)
        for _ in 0..<3 { health.failed("test") }
        #expect(lane.hasFailed)
        // Without an engine given, it makes VideoToolbox's (here unavailable, or a real one) reporting to that health.
        let real = try #require(InterpolationLane(device: device, health: health))
        var made = 0
        real.onImage = { _ in made += 1 }
        real.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: [InBetween.Image(phase: 0.5, time: 1)],
                    steps: 1, size: (640, 360))
        real.waitUntilIdle()
        #expect(made == 0 && real.failedPairs == 1) // off: no images
    }
}

/// Counts the `_MTLSharedEvent` objects made in this process (on any thread), by a hook on their class's allocation:
/// installed on first use and kept, counting only, so nothing system-wide is used up by looking.
enum SharedEvents {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    private static let installed: Bool = {
        guard let cls = NSClassFromString("_MTLSharedEvent"), let meta = object_getClass(cls) else { return false }
        let sel = NSSelectorFromString("allocWithZone:")
        guard let method = class_getClassMethod(cls, sel) else { return false }
        typealias Alloc = @convention(c) (UnsafeRawPointer, Selector, OpaquePointer?) -> UnsafeMutableRawPointer?
        let original = unsafeBitCast(method_getImplementation(method), to: Alloc.self)
        let hook: @convention(block) (UnsafeRawPointer, OpaquePointer?) -> UnsafeMutableRawPointer? = { cls, zone in
            count.withLock { $0 += 1 }
            return original(cls, sel, zone)
        }
        // On `_MTLSharedEvent`'s own metaclass (it inherits NSObject's), so no other class changes.
        let imp = imp_implementationWithBlock(hook)
        if !class_addMethod(meta, sel, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
        return true
    }()
    /// Made so far; nil when the hook couldn't be installed.
    static var made: Int? { installed ? count.withLock { $0 } : nil }
}

/// What crashed long sessions: VideoToolbox's Metal call makes a Metal shared event per call and never frees it,
/// until the system has none left. The app's calls must make none. Needs VideoToolbox's processors (not in a VM).
@Suite struct SharedEventTests {
    @Test func interpolationAndMLUpscalingMakeNoSharedEventPerCall() throws {
        guard #available(macOS 26.0, *), FrameInterpolator.isAvailable, MLSuperResolution.isAvailable,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let a = try makeNV12(width: 1280, height: 720, y: 40, cb: 128, cr: 128)
        let b = try makeNV12(width: 1280, height: 720, y: 200, cb: 128, cr: 128)
        // The hook sees the Metal call make one per call (so the check below can't pass for not looking).
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: 1280, frameHeight: 720, scaleFactor: 1.5)
        let metal = VTFrameProcessor()
        try metal.startSession(configuration: config)
        var attrs = config.destinationPixelBufferAttributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        let pool = try #require(MLSuperResolution.makePool(attrs))
        let start = try #require(SharedEvents.made)
        for i in 0..<10 {
            let out = try #require(MLSuperResolution.buffer(from: pool))
            let pts = CMTime(value: Int64(i), timescale: 60)
            let parameters = try #require(VTLowLatencySuperResolutionScalerParameters(
                sourceFrame: try #require(VTFrameProcessorFrame(buffer: a, presentationTimeStamp: pts)),
                destinationFrame: try #require(VTFrameProcessorFrame(buffer: out, presentationTimeStamp: pts))))
            let cb = try #require(queue.makeCommandBuffer())
            metal.process(with: cb, parameters: parameters)
            cb.commit()
            cb.waitUntilCompleted()
        }
        metal.endSession()
        #expect(try #require(SharedEvents.made) - start >= 10)
        // The app's path: interpolation and ML upscaling, past their first call (building the model).
        let health = testHealth()
        let interpolator = FrameInterpolator(health: health)
        let ml = MLSuperResolution(health: health)
        let screen = CGSize(width: 3840, height: 2160)
        #expect(interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil && ml.upscale(a, target: screen) != nil)
        let calls = 200
        let before = try #require(SharedEvents.made)
        var made = 0
        for _ in 0..<calls {
            if interpolator.make(previous: a, current: b, phases: [0.5], steps: 1) != nil { made += 1 }
            if ml.upscale(a, target: screen) != nil { made += 1 }
        }
        // None of theirs; a little room for other tests running alongside.
        #expect(made == 2 * calls)
        #expect(try #require(SharedEvents.made) - before < calls / 10)
        #expect(health.failures == 0)
    }
}
