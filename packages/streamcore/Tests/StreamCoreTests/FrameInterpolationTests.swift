import CoreVideo
import Foundation
import Testing
@testable import StreamCore

@Suite struct FrameInterpolationTests {
    @Test func helpsOnlyWhenTheScreenRefreshesClearlyMoreOftenThanFrames() {
        #expect(FrameInterpolator.helps(streamInterval: 1.0 / 30, displayInterval: 1.0 / 60))
        #expect(FrameInterpolator.helps(streamInterval: 1.0 / 60, displayInterval: 1.0 / 120))
        #expect(!FrameInterpolator.helps(streamInterval: 1.0 / 60, displayInterval: 1.0 / 60))
        #expect(!FrameInterpolator.helps(streamInterval: 0, displayInterval: 1.0 / 60)) // not measured yet
        #expect(!FrameInterpolator.helps(streamInterval: 1.0 / 30, displayInterval: 0))
    }

    @Test func averagesIntervalsIgnoringPauses() {
        #expect(StreamRenderer.smoothedInterval(0, 0.02) == 0.02)
        #expect(abs(StreamRenderer.smoothedInterval(0.02, 0.03) - 0.021) < 1e-9)
        #expect(StreamRenderer.smoothedInterval(0.02, 1.5) == 0.02) // a pause
        #expect(StreamRenderer.smoothedInterval(0.02, 0) == 0.02)
    }

    @Test func makesTheInBetweenFrame() throws {
        guard FrameInterpolator.isAvailable, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return } // needs macOS 26 on a supported Mac
        let interpolator = FrameInterpolator()
        let dark = try makeNV12(width: 640, height: 360, y: 40, cb: 128, cr: 128)
        let bright = try makeNV12(width: 640, height: 360, y: 200, cb: 128, cr: 128)
        let cb = try #require(queue.makeCommandBuffer())
        let middle = try #require(interpolator.encode(cb, previous: dark, current: bright, phases: [0.5], steps: 1)?.first)
        cb.commit()
        cb.waitUntilCompleted()
        #expect(CVPixelBufferGetWidth(middle) == 640 && CVPixelBufferGetHeight(middle) == 360)
        // Quarters: three images in one pass, darkest first.
        let cb3 = try #require(queue.makeCommandBuffer())
        let quarters = try #require(interpolator.encode(cb3, previous: dark, current: bright, phases: [0.25, 0.5, 0.75], steps: 2))
        cb3.commit()
        cb3.waitUntilCompleted()
        #expect(quarters.count == 3)
        // A phase that isn't one of the processor's points isn't asked for.
        let cb4 = try #require(queue.makeCommandBuffer())
        #expect(interpolator.encode(cb4, previous: dark, current: bright, phases: [0.3], steps: 2) == nil)
        cb4.commit()
        // Frames of different sizes (a resolution change) can't be blended.
        let small = try makeNV12(width: 320, height: 180, y: 40, cb: 128, cr: 128)
        let cb2 = try #require(queue.makeCommandBuffer())
        #expect(interpolator.encode(cb2, previous: small, current: bright, phases: [0.5], steps: 1) == nil)
        cb2.commit()
    }
}

extension StreamRendererTests {
    @Test func frameInterpolationParamDecodes() throws {
        let p = try JSONDecoder().decode(RenderParams.self, from: Data(#"{"frameInterpolation":true}"#.utf8))
        #expect(p.frameInterpolation && !RenderParams().frameInterpolation)
    }

    /// A 30 fps stream on a 60 Hz screen: when a bar moves between two frames, the in-between image (made
    /// on the interpolation lane, away from the draws) shows the bar about halfway, before the new frame.
    @Test func showsTheInBetweenImageBeforeTheNewFrame() throws {
        guard FrameInterpolator.isAvailable else { return }
        let r = try #require(StreamRenderer(inputWidth: 640, inputHeight: 360))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        /// A dark frame with a bright vertical bar starting at x.
        func bar(at x: Int) throws -> CVPixelBuffer {
            try makeNV12(width: 640, height: 360, cb: 128, cr: 128) { px, _ in px >= x && px < x + 60 ? 220 : 40 }
        }
        /// Where the bar is in a rendered 64-pixel row: its brightness-weighted centre.
        func centre(_ pixels: [UInt8]) -> Double {
            var sum = 0.0, weight = 0.0
            for x in 0..<64 {
                let w = max(0, Double(pixel(pixels, width: 64, x: x, y: 18).g) - 60)
                sum += w * Double(x)
                weight += w
            }
            return weight > 0 ? sum / weight : -1
        }
        let frame = 1.0 / 30, refresh = 1.0 / 60
        let before = try bar(at: 200), after = try bar(at: 300)
        for k in 0..<8 { // the bar moving slowly, two refreshes per frame
            r.display(k == 7 ? before : try bar(at: 186 + 2 * k), index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try render(r, size: (64, 36), now: Double(k) * frame)
            _ = try render(r, size: (64, 36), now: Double(k) * frame + refresh)
        }
        r.display(after, index: 8, arrival: 8 * frame)
        r.waitForInterpolation()
        var seen: [Double] = []
        for step in 0..<12 { seen.append(centre(try render(r, size: (64, 36), now: 8 * frame + Double(step) * refresh))) }
        // The bar is at 23 before (pixels 200–260 of 640), 33 after (300–360); halfway is 28.
        #expect(abs((seen.last ?? 0) - 33) < 1.5, "\(seen)")
        let arrived = try #require(seen.firstIndex { abs($0 - 33) < 1.5 }, "\(seen)")
        #expect(seen[..<arrived].contains { abs($0 - 28) < 2.5 }, "no in-between image before the new frame: \(seen)")
        #expect(r.pacingDelayMilliseconds > 0)
        #expect(r.skippedInterpolations >= 0 && r.skippedFrames >= 0)
        #expect(r.generatedFramesPerSecond == 0 && !r.interpolationActive) // nothing presented on a real screen here
    }
}

@Suite struct ShownRateTests {
    /// Images at `fps` for `seconds`, starting at `start`.
    func shown(_ rate: inout ShownRate, fps: Double, seconds: Double, from start: Double = 100) -> Double {
        let n = Int(fps * seconds)
        for i in 0...n { rate.count(at: start + Double(i) / fps) }
        return start + Double(n) / fps
    }

    @Test func countsImagesPerSecond() {
        var rate = ShownRate()
        #expect(rate.perSecond(now: 100) == 0) // nothing yet
        var end = shown(&rate, fps: 60, seconds: 1.5)
        #expect(abs(rate.perSecond(now: end) - 60) < 1)
        // Frame interpolation doubles what reaches the screen.
        end = shown(&rate, fps: 120, seconds: 2.5, from: end + 1.0 / 120)
        #expect(abs(rate.perSecond(now: end) - 120) < 2)
    }

    @Test func aPauseReadsZeroAndStartsAFreshWindow() {
        var rate = ShownRate()
        let end = shown(&rate, fps: 60, seconds: 1.5)
        #expect(rate.perSecond(now: end + 2) == 0) // nothing new for 2 s
        // After the pause the old window doesn't count: no rate until a full second of new images.
        rate.count(at: end + 2)
        rate.count(at: end + 2.5)
        #expect(rate.perSecond(now: end + 2.5) == 0)
        // The first window still holds the gap; the next one reads the steady 30 fps.
        let resumed = shown(&rate, fps: 30, seconds: 2.2, from: end + 2.5 + 1.0 / 30)
        #expect(abs(rate.perSecond(now: resumed) - 30) < 2)
    }
}

/// Stands in for VideoToolbox in the lane's tests: the newer frame as the middle one (or an all-zero image,
/// or nothing), optionally taking a while.
final class StandInMaker: MiddleFrameMaker {
    enum Output { case newer, zeros, none }
    let output: Output
    let delay: TimeInterval
    private(set) var prepared: [String] = []
    func prepare(width: Int, height: Int) { prepared.append("\(width)x\(height)") }
    init(_ output: Output = .newer, delay: TimeInterval = 0) {
        self.output = output
        self.delay = delay
    }
    /// The phases and points asked for, per pair.
    private(set) var asked: [(phases: [Float], steps: Int)] = []
    func encode(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        asked.append((phases, steps))
        switch output {
        case .newer: return phases.map { _ in current }
        case .zeros:
            let zeros = try? makeNV12(width: CVPixelBufferGetWidth(current), height: CVPixelBufferGetHeight(current), y: 0, cb: 0, cr: 0)
            return zeros.map { image in phases.map { _ in image } }
        case .none: return nil
        }
    }
}

@Suite struct InterpolationLaneTests {
    let device = MTLCreateSystemDefaultDevice()

    func lane(_ maker: StandInMaker = StandInMaker()) throws -> InterpolationLane {
        let device = try #require(device)
        return try #require(InterpolationLane(device: device, engine: { maker }))
    }

    /// A dark 640×360 frame with a bright bar from x (and a fixed textured patch top-left, which never moves).
    func frame(bar x: Int, background: UInt8 = 40) throws -> CVPixelBuffer {
        try makeNV12(width: 640, height: 360, cb: 128, cr: 128) { px, py in
            if px < 100 && py < 60 { return UInt8(60 + (px * 7 + py * 13) % 120) } // a "HUD"
            return px >= x && px < x + 60 ? 220 : background
        }
    }

    func luma(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]
    }

    @Test func makesImagesAwayFromTheCallerKeepingStillAreas() throws {
        let lane = try lane()
        var made: [InterpolationLane.Image] = []
        lane.onImage = { made.append($0) }
        let a = try frame(bar: 200), b = try frame(bar: 300)
        #expect(lane.submit(previous: a, current: b, between: [InBetween.Image(phase: 0.5, time: 1.5)], steps: 1, size: (640, 360)))
        lane.waitUntilIdle()
        let image = try #require(made.first)
        #expect(image.time == 1.5 && image.cost > 0 && image.size == (640, 360) && image.warmingUp && image.last)
        #expect(CVPixelBufferGetWidth(image.buffer) == 640)
        // The "HUD" didn't change between the frames, so it comes back exactly (not the model's version).
        for (x, y) in [(10, 10), (55, 31), (90, 50)] {
            #expect(abs(Int(luma(image.buffer, x, y)) - Int(luma(a, x, y))) <= 1, "(\(x), \(y))")
        }
    }

    @Test func makesAnImageForEachRefreshBetweenThePair() throws {
        let maker = StandInMaker()
        let lane = try lane(maker)
        var made: [InterpolationLane.Image] = []
        lane.onImage = { made.append($0) }
        let between = [InBetween.Image(phase: 0.25, time: 1.01), InBetween.Image(phase: 0.5, time: 1.02),
                       InBetween.Image(phase: 0.75, time: 1.03)]
        #expect(lane.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: between, steps: 2, size: (640, 360)))
        lane.waitUntilIdle()
        #expect(made.map(\.time) == [1.01, 1.02, 1.03])
        // One pass, one cost: only the last image carries it to the renderer.
        #expect(made.map(\.last) == [false, false, true] && Set(made.map(\.cost)).count == 1)
        #expect(maker.asked.first?.phases == [0.25, 0.5, 0.75] && maker.asked.first?.steps == 2)
    }

    @Test func makesSmallerImagesWhenAskedAndScalesThemBack() throws {
        let lane = try lane()
        var made: [InterpolationLane.Image] = []
        lane.onImage = { made.append($0) }
        lane.prepare(size: (320, 180))
        lane.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: [InBetween.Image(phase: 0.5, time: 2)], steps: 1, size: (320, 180))
        lane.waitUntilIdle()
        let image = try #require(made.first)
        #expect(image.size == (320, 180) && CVPixelBufferGetWidth(image.buffer) == 640)
    }

    @Test func recognisesAnEmptyImage() throws {
        // What VideoToolbox writes when it can't take a size: all zeros (video-range black is 16).
        #expect(InterpolationLane.isEmpty(try makeNV12(width: 320, height: 180, y: 0, cb: 0, cr: 0)))
        #expect(!InterpolationLane.isEmpty(try makeNV12(width: 320, height: 180, y: 16, cb: 128, cr: 128)))
        #expect(!InterpolationLane.isEmpty(try frame(bar: 200)))
    }

    @Test func skipsCutsAndPairsWhileBusy() throws {
        let lane = try lane(StandInMaker(delay: 0.05)) // slow enough that pairs arrive while busy
        var made = 0
        lane.onImage = { _ in made += 1 }
        lane.submit(previous: try frame(bar: 200, background: 20), current: try frame(bar: 200, background: 230),
                    between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(made == 0 && lane.cutPairs == 1)
        // Two pairs at once: the second goes without its image.
        let a = try frame(bar: 200), b = try frame(bar: 300)
        var accepted = 0
        for i in 0..<3 where lane.submit(previous: a, current: b, between: [InBetween.Image(phase: 0.5, time: Double(i))], steps: 1, size: (640, 360)) { accepted += 1 }
        lane.waitUntilIdle()
        #expect(accepted < 3 && lane.busyPairs == 3 - accepted)
        lane.resetCounts()
        #expect(lane.busyPairs == 0 && lane.cutPairs == 0)
    }

    @Test func dropsASizeThatComesOutEmpty() throws {
        // VideoToolbox can report success and write nothing (at 960×540, say): never shown, size dropped.
        let lane = try lane(StandInMaker(.zeros))
        var made = 0
        lane.onImage = { _ in made += 1 }
        let a = try frame(bar: 200, background: 0), b = try frame(bar: 220, background: 0) // not a cut
        #expect(!lane.isBroken((640, 360)))
        lane.submit(previous: a, current: b, between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(made == 0 && lane.isBroken((640, 360)))
    }

    @Test func dropsASizeThatKeepsFailing() throws {
        // VideoToolbox couldn't start at a size: every pair comes back empty-handed. After a few, the size is
        // dropped so the renderer moves on instead of waiting on it.
        let lane = try lane(StandInMaker(.none))
        for i in 0..<5 {
            lane.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: [InBetween.Image(phase: 0.5, time: Double(i))], steps: 1, size: (640, 360))
            lane.waitUntilIdle()
        }
        #expect(lane.isBroken((640, 360)))
    }

    @Test func getsTheEngineReadyAhead() throws {
        let maker = StandInMaker()
        let lane = try lane(maker)
        lane.prepare(size: (1280, 720))
        lane.waitUntilIdle()
        #expect(maker.prepared == ["1280x720"])
    }

    @Test func onlyEightBitFramesGoToTheLane() throws {
        // VideoToolbox's frame interpolation takes 8-bit 4:2:0 only: HDR frames aren't sent, so no time is
        // spent on them and no delay is added for images that will never come.
        #expect(StreamRenderer.interpolates(try frame(bar: 200)))
        #expect(!StreamRenderer.interpolates(try makeHDRFrame(width: 64, height: 64, y: 500)))
    }

    @Test func anEngineThatGivesNothingGivesNoImage() throws {
        let lane = try lane(StandInMaker(.none))
        var made = 0
        lane.onImage = { _ in made += 1 }
        lane.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(made == 0 && !lane.isBroken((640, 360)))
    }
}
