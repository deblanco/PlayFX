import CoreVideo
import Foundation
import Testing
@testable import StreamCore

@Suite struct FrameInterpolationTests {
    @Test func helpsOnlyWhenTheScreenRefreshesAtLeastTwicePerFrame() {
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
        let middle = try #require(interpolator.encode(cb, previous: dark, current: bright))
        cb.commit()
        cb.waitUntilCompleted()
        #expect(CVPixelBufferGetWidth(middle) == 640 && CVPixelBufferGetHeight(middle) == 360)
        // Frames of different sizes (a resolution change) can't be blended.
        let small = try makeNV12(width: 320, height: 180, y: 40, cb: 128, cr: 128)
        let cb2 = try #require(queue.makeCommandBuffer())
        #expect(interpolator.encode(cb2, previous: small, current: bright) == nil)
        cb2.commit()
    }
}

extension StreamRendererTests {
    @Test func smoothMotionParamDecodes() throws {
        let p = try JSONDecoder().decode(RenderParams.self, from: Data(#"{"smoothMotion":true}"#.utf8))
        #expect(p.smoothMotion && !RenderParams().smoothMotion)
    }

    /// 30 fps on a 60 Hz screen: the in-between frame shows when a new frame arrives, the new frame on
    /// the next refresh.
    @Test func showsTheInBetweenFrameThenTheNewOne() throws {
        guard FrameInterpolator.isAvailable else { return }
        let r = try #require(StreamRenderer(inputWidth: 640, inputHeight: 360))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.smoothMotion = true
        let refresh = 1.0 / 60
        let dark = try makeNV12(width: 640, height: 360, y: 40, cb: 128, cr: 128)
        let bright = try makeNV12(width: 640, height: 360, y: 200, cb: 128, cr: 128)
        func luma(_ pixels: [UInt8]) -> Int { pixel(pixels, width: 64, x: 32, y: 18).g }
        // Settle on dark frames at 30 fps so both intervals are measured.
        var now = 0.0
        for _ in 0..<4 {
            r.display(dark)
            _ = try render(r, size: (64, 36), now: now)
            now += refresh
            _ = try render(r, size: (64, 36), now: now)
            now += refresh
        }
        r.display(bright)
        let between = luma(try render(r, size: (64, 36), now: now))
        #expect(r.smoothActive)
        now += refresh
        let after = luma(try render(r, size: (64, 36), now: now)) // the held real frame
        #expect(after > between)
        #expect(r.shownFramesPerSecond >= 0) // counted through the real draw path

        // Off: the new frame shows at once.
        r.params.smoothMotion = false
        r.display(dark)
        now += refresh
        _ = try render(r, size: (64, 36), now: now)
        #expect(!r.smoothActive)
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
        // Smooth motion doubles what reaches the screen.
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
