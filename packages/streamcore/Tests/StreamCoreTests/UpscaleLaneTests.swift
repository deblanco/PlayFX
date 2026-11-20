import CoreGraphics
import CoreVideo
import Foundation
import Metal
import os
import QuartzCore
import Testing
@testable import StreamCore

/// Stands in for Apple's model: a uniform 1.5× frame (luma `luma`), after `delay` seconds. Plain CoreVideo, so
/// the lane and the renderer around it are tested where the model isn't (CI's virtual machines).
final class FakeUpscaler: FrameUpscaler, @unchecked Sendable {
    let luma: UInt8
    let delay: Double
    let hasFailed: Bool
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { count.withLock { $0 } }

    init(luma: UInt8 = 200, delay: Double = 0, failed: Bool = false) {
        self.luma = luma
        self.delay = delay
        hasFailed = failed
    }

    func upscale(_ frame: CVPixelBuffer, target: CGSize) -> CVPixelBuffer? {
        count.withLock { $0 += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        guard target.width > Double(w) else { return nil } // no upscale needed
        return try? makeNV12(width: w * 3 / 2, height: h * 3 / 2, y: luma, cb: 128, cr: 128)
    }

    func refuses(width: Int, height: Int) -> Bool { width > 2000 }
}

@Suite struct UpscaleLaneTests {
    func makeLane(_ engine: FakeUpscaler) -> UpscaleLane { UpscaleLane(engine: engine) }

    @Test func keepsOrderAndDropsAWaitingFrameWhenANewerOneArrives() throws {
        let engine = FakeUpscaler(delay: 0.3)
        let lane = makeLane(engine)
        let done = OSAllocatedUnfairLock(initialState: [Int]())
        let frames = try (0..<3).map { i in try makeNV12(width: 64, height: 64, y: UInt8(i * 10 + 16), cb: 128, cr: 128) }
        for (i, frame) in frames.enumerated() {
            lane.submit(frame, target: CGSize(width: 200, height: 200)) { upscaled in
                done.withLock { $0.append(i) }
                #expect(upscaled.map(CVPixelBufferGetWidth) == 96)
            }
        }
        lane.waitUntilIdle()
        // The first is upscaled; the second waits and is replaced by the third, which goes next.
        #expect(done.withLock { $0 } == [0, 2])
        #expect(lane.dropped == 1 && engine.calls == 2)
        lane.reset()
        #expect(lane.dropped == 0)
    }

    @Test func aRepeatNeverTakesTheWaitingPicturesPlace() throws {
        let engine = FakeUpscaler(delay: 0.2)
        let lane = makeLane(engine)
        let target = CGSize(width: 200, height: 200)
        let done = OSAllocatedUnfairLock(initialState: [(Int, CVPixelBuffer?)]())
        func submit(_ i: Int, upscale: Bool) throws {
            let frame = try makeNV12(width: 64, height: 64, y: UInt8(i * 10 + 16), cb: 128, cr: 128)
            lane.submit(frame, target: target, upscale: upscale, reuse: !upscale) { upscaled in
                done.withLock { $0.append((i, upscaled)) }
            }
        }
        // A new picture waits behind the one in the model; its repeat is dropped, not the picture.
        try submit(0, upscale: true)
        try submit(1, upscale: true)
        try submit(2, upscale: false)
        lane.waitUntilIdle()
        #expect(done.withLock { $0.map(\.0) } == [0, 1])
        #expect(lane.dropped == 0 && engine.calls == 2)
        // A repeat waiting behind the model gives way to a newer repeat, uncounted, and gets that upscale.
        try submit(3, upscale: true)
        try submit(4, upscale: false)
        try submit(5, upscale: false)
        lane.waitUntilIdle()
        let results = done.withLock { $0 }
        #expect(results.map(\.0) == [0, 1, 3, 5])
        #expect(lane.dropped == 0 && engine.calls == 3)
        let upscaled = try #require(results[2].1)
        #expect(results[3].1 === upscaled)
    }

    @Test func keepsTheDecodedFrameWithTheUpscaledOne() throws {
        let lane = makeLane(FakeUpscaler())
        let frame = try makeNV12(width: 64, height: 64, y: 50, cb: 128, cr: 128)
        let result = OSAllocatedUnfairLock<CVPixelBuffer?>(initialState: nil)
        lane.submit(frame, target: CGSize(width: 200, height: 200)) { upscaled in result.withLock { $0 = upscaled } }
        lane.waitUntilIdle()
        let upscaled = try #require(result.withLock { $0 })
        #expect(UpscaleLane.decodedFrame(of: upscaled) === frame)
        #expect(UpscaleLane.decodedFrame(of: frame) == nil)
        #expect(lane.status.ran && !lane.status.refused)
    }

    @Test func reportsWhatItDidntUpscale() throws {
        let lane = makeLane(FakeUpscaler())
        let result = OSAllocatedUnfairLock(initialState: false)
        // The screen isn't larger than the frame: nothing to do, and the frame goes on as it is.
        lane.submit(try makeNV12(width: 64, height: 64, y: 50, cb: 128, cr: 128), target: CGSize(width: 64, height: 64)) {
            upscaled in result.withLock { $0 = upscaled == nil }
        }
        lane.waitUntilIdle()
        #expect(result.withLock { $0 } && !lane.status.ran && !lane.status.refused)
        lane.submit(try makeNV12(width: 2560, height: 64, y: 50, cb: 128, cr: 128), target: CGSize(width: 64, height: 64)) { _ in }
        lane.waitUntilIdle()
        #expect(lane.status.refused)
    }
}

extension StreamRendererTests {
    @Test func upscalesOnItsLaneNotOnEveryDraw() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.params.upscaler = .bilinear
        let out = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        #expect(r.mlSupported && r.mlActive)
        #expect(r.inputSize == (1920, 1080)) // the upscaled frame is what the pipeline gets
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 210) <= 8, "\(pixel(out, width: 2560, x: 300, y: 700))")
        // More refreshes with no new frame: the engine isn't run again.
        _ = try render(r, size: (2560, 1440))
        _ = try render(r, size: (2560, 1440))
        #expect(engine.calls == 1)
        #expect(r.pipeline.ml == .on)
    }

    @Test func comparesAgainstTheDecodedFrame() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: FakeUpscaler()))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.compare = true
        r.params.sharpness = 0
        r.params.upscaler = .bilinear
        let out = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        // Left: the decoded frame (its dark half); right: the upscaled one (uniformly light).
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 86) <= 6, "\(pixel(out, width: 2560, x: 300, y: 700))")
        #expect(abs(pixel(out, width: 2560, x: 2200, y: 700).g - 210) <= 8, "\(pixel(out, width: 2560, x: 2200, y: 700))")
    }

    @Test func framesSkipTheLaneWithMLOff() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        #expect(engine.calls == 0 && !r.mlActive && r.inputSize == (1280, 720))
        #expect(r.pipeline.ml == .off)
    }

    @Test func framesThatNeedNoUpscaleSkipTheLane() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        // The window is the stream's size: nothing to upscale, so the frame doesn't wait on the lane.
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (1280, 720))
        #expect(engine.calls == 0 && !r.mlActive && r.inputSize == (1280, 720))
        #expect(r.pipeline.ml == .notLarger)
    }

    @Test func framesSkippingTheLaneQueueBehindOneStillInIt() throws {
        let engine = FakeUpscaler(delay: 0.3)
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let frames = try (0..<3).map { _ in try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128) }
        r.display(frames[0], index: 0) // in the lane
        r.params.mlUpscale = false
        // These two need no upscale, but the lane is busy: they queue behind the first (the second is
        // replaced by the third while it waits), instead of reaching the clock before it.
        r.display(frames[1], index: 1)
        r.display(frames[2], index: 2)
        r.waitForUpscaling()
        #expect(engine.calls == 1 && r.skippedFrames == 1)
    }

    @Test func aFrameFromTheStreamBeforeIsLeftOut() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: FakeUpscaler(delay: 0.3)))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        // Still in the lane when a new stream starts: its high index would hold the new stream's clock.
        r.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 50_000)
        r.streamFrameRate = 60
        _ = try show(r, try makeNV12(width: 128, height: 128, y: 90, cb: 128, cr: 128), size: (2560, 1440), index: 0)
        #expect(r.inputSize == (192, 192)) // the new stream's first frame, upscaled, is on screen
    }

    @Test func aRepeatedPictureIsNotUpscaledAgain() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.params.upscaler = .bilinear
        r.setFrameInterpolationActive(true)
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let frames = try (0..<6).map { _ in try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128) }
        r.display(frames[0], index: 0)
        r.waitForUpscaling()
        let start = CACurrentMediaTime()
        for i in 1..<frames.count {
            r.display(frames[i], index: UInt64(i), arrival: start + Double(i) / 60)
        }
        #expect(engine.calls == 1)
        #expect(r.repeatedFrames == 5)
    }

    @Test func aRepeatedPictureKeepsTheUpscaledFrame() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.params.upscaler = .bilinear
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let frames = try (0..<4).map { _ in try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128) }
        r.display(frames[0], index: 0)
        r.waitForUpscaling()
        let start = CACurrentMediaTime()
        for i in 1..<frames.count {
            r.display(frames[i], index: UInt64(i), arrival: start + Double(i) / 60)
        }
        _ = try render(r, size: (2560, 1440))
        #expect(engine.calls == 1 && r.repeatedFrames == 3)
        #expect(r.inputSize == (96, 96)) // the last upscaled frame, not the decoded 64×64
        #expect(r.mlActive)
    }

    @Test func aRepeatArrivingWhileTheModelRunsIsNotUpscaled() throws {
        let engine = FakeUpscaler(delay: 0.2)
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setFrameInterpolationActive(true)
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let start = CACurrentMediaTime()
        let first = try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128)
        r.display(first, index: 0, arrival: start)
        r.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 1, arrival: start + 1 / 60)
        r.waitForUpscaling()
        #expect(engine.calls == 1 && r.repeatedFrames == 1)

        // Interpolation off: the repeat waits behind the model, then shows that upscaled frame.
        let engine2 = FakeUpscaler(delay: 0.2)
        let r2 = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine2))
        r2.showsTestPattern = false
        r2.params.mlUpscale = true
        r2.params.sharpness = 0
        r2.params.upscaler = .bilinear
        r2.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let start2 = CACurrentMediaTime()
        r2.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 0, arrival: start2)
        r2.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 1, arrival: start2 + 1 / 60)
        r2.waitForUpscaling()
        _ = try render(r2, size: (2560, 1440))
        #expect(engine2.calls == 1 && r2.repeatedFrames == 1)
        #expect(r2.inputSize == (96, 96))
    }

    @Test func aNewPictureIsUpscaledAndAGapUpscalesAgain() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setFrameInterpolationActive(true)
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        r.display(try makeNV12(width: 64, height: 64, y: 40, cb: 128, cr: 128), index: 0)
        r.waitForUpscaling()
        let start = CACurrentMediaTime()
        r.display(try makeNV12(width: 64, height: 64, y: 200, cb: 128, cr: 128), index: 1, arrival: start + 1 / 60)
        r.waitForUpscaling()
        #expect(engine.calls == 2 && r.repeatedFrames == 0)
        // The same picture again, after a gap the clock starts over for: upscale it, don't reuse across the break.
        r.display(try makeNV12(width: 64, height: 64, y: 200, cb: 128, cr: 128), index: 2, arrival: start + 0.5)
        r.waitForUpscaling()
        #expect(engine.calls == 3)
    }

    @Test func aRepeatTheClockStartsOverAtIsANewPicture() throws {
        let engine = FakeUpscaler(delay: 0.2)
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.params.upscaler = .bilinear
        r.setFrameInterpolationActive(true)
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let start = CACurrentMediaTime()
        r.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 0, arrival: start)
        // The same picture while the model runs, but frames were lost: the clock starts over at it, so it's
        // the new start (on the timeline, at the upscaled size), not a repeat left out.
        r.display(try makeNV12(width: 64, height: 64, y: 90, cb: 128, cr: 128), index: 100, arrival: start + 1 / 60)
        r.waitForUpscaling()
        _ = try render(r, size: (2560, 1440))
        #expect(engine.calls == 1 && r.repeatedFrames == 0)
        #expect(r.pacingParts.restarts == 2)
        #expect(r.inputSize == (96, 96))
    }

    @Test func aPictureAfterMLWasOffIsUpscaled() throws {
        let engine = FakeUpscaler()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: engine))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setFrameInterpolationActive(true)
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        let start = CACurrentMediaTime()
        r.display(try makeNV12(width: 64, height: 64, y: 40, cb: 128, cr: 128), index: 0, arrival: start)
        r.waitForUpscaling()
        r.params.mlUpscale = false
        r.display(try makeNV12(width: 64, height: 64, y: 200, cb: 128, cr: 128), index: 1, arrival: start + 1 / 60)
        // Back on with the first picture again: new against the last frame shown, so it's upscaled, not
        // taken for a repeat of the frame upscaled before ML went off.
        r.params.mlUpscale = true
        r.display(try makeNV12(width: 64, height: 64, y: 40, cb: 128, cr: 128), index: 2, arrival: start + 2 / 60)
        r.waitForUpscaling()
        #expect(engine.calls == 2 && r.repeatedFrames == 0)
    }

    @Test func aDroppedFrameCountsAsSkipped() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: FakeUpscaler(delay: 0.3)))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.setUpscaleTarget(drawableSize: CGSize(width: 2560, height: 1440))
        // Made first, so the three arrive while the first is still being upscaled. Three different pictures:
        // a dropped repeat isn't a lost frame.
        let frames = try (0..<3).map { i in try makeNV12(width: 64, height: 64, y: UInt8(40 + i * 80), cb: 128, cr: 128) }
        for (i, frame) in frames.enumerated() { r.display(frame, index: UInt64(i)) }
        r.waitForUpscaling()
        #expect(r.skippedFrames >= 1)
        r.streamFrameRate = 60 // a new stream starts the count over
        #expect(r.skippedFrames == 0)
    }
}
