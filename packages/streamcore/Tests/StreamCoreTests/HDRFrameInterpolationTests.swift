import CoreVideo
import Foundation
import Metal
import MetalFX
import QuartzCore
import Testing
@testable import StreamCore

// MARK: HDR frames

/// A 10-bit HDR10 frame (BT.2020 matrix and primaries, PQ, left-sited chroma, as the PS5 sends) with per-pixel luma
/// and per-chroma-texel (Cb, Cr) codes, in video range unless `fullRange`.
func makeHDRFrame(width: Int, height: Int, fullRange: Bool = false, luma: (Int, Int) -> UInt16,
                  chroma: (Int, Int) -> (UInt16, UInt16)) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
    var out: CVPixelBuffer?
    let format = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &out)
    let buffer = try #require(out)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
    for row in 0..<height { for col in 0..<width { y[row * yStride + col] = luma(col, row) << 6 } }
    let c = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
    let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for col in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
            let (cb, cr) = chroma(col, row)
            c[row * cStride + col * 2] = cb << 6
            c[row * cStride + col * 2 + 1] = cr << 6
        }
    }
    return buffer
}

/// A 10-bit frame's codes: luma at a pixel, or (Cb, Cr) at a chroma texel.
func lumaCode(_ frame: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt16.self)
    return Int(base[y * CVPixelBufferGetBytesPerRowOfPlane(frame, 0) / 2 + x] >> 6)
}

func chromaCodes(_ frame: CVPixelBuffer, _ x: Int, _ y: Int) -> (cb: Int, cr: Int) {
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt16.self)
    let i = y * CVPixelBufferGetBytesPerRowOfPlane(frame, 1) / 2 + x * 2
    return (Int(base[i] >> 6), Int(base[i + 1] >> 6))
}

/// The spike's synthetic HDR scene (docs/FRAME_INTERPOLATION.md, "HDR"), in linear light (1.0 = 203 nits, as the
/// renderer's HDR path), laid out at 1920×1080 and drawn at `scale` of it: a textured ground panning 8,3 px per frame,
/// a bright sky band (about 400 nits), a sun (a 1000-nit disc with a 2600-nit core) drifting 20,5 px per frame, and a
/// red square crossing fast, 60 px per frame. `t` in frames.
enum HDRScene {
    static func light(_ px: Float, _ py: Float, t: Float, scale s: Float) -> SIMD3<Float> {
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let k = min(max((x - a) / (b - a), 0), 1)
            return k * k * (3 - 2 * k)
        }
        let qx = px / s + 8 * t, qy = py / s + 3 * t
        let texture = 0.5 + 0.25 * sin(qx * 0.05) * sin(qy * 0.07) + 0.15 * sin((qx + qy) * 0.013)
        var c = SIMD3<Float>(0.35, 0.40, 0.50) * texture * 1.6
        c += SIMD3<Float>(2.0, 1.8, 1.5) * smoothstep(300, 0, qy + 100)
        let d = ((px / s - sun(t).x) * (px / s - sun(t).x) + (py / s - sun(t).y) * (py / s - sun(t).y)).squareRoot()
        c += SIMD3<Float>(4.9, 4.6, 4.2) * (1 - smoothstep(38, 42, d)) + SIMD3<Float>(8, 7.5, 7) * exp(-d * d / (2 * 15 * 15))
        if abs(px / s - object(t)) < 40, abs(py / s - 700) < 40 { c = SIMD3<Float>(2.5, 0.3, 0.2) }
        return c
    }

    /// Where the sun's centre and the square's are at `t` (1080p pixels; the square's row is 700).
    static func sun(_ t: Float) -> (x: Float, y: Float) { (300 + 20 * t, 250 + 5 * t) }
    static func object(_ t: Float) -> Float { 200 + 60 * t }

    static func pq(_ linear: Float) -> Float {
        let m1: Float = 0.1593017578125, m2: Float = 78.84375, c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
        let lp = powf(min(max(linear * 203 / 10000, 0), 1), m1)
        return powf((c1 + c2 * lp) / (1 + c3 * lp), m2)
    }

    /// PQ signal → nits.
    static func nits(_ e: Float) -> Float {
        let m1: Float = 0.1593017578125, m2: Float = 78.84375, c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
        let ep = powf(min(max(e, 0), 1), 1 / m2)
        return powf(max(ep - c1, 0) / (c2 - c3 * ep), 1 / m1) * 10000
    }

    /// The scene at `t` as an HDR10 frame (BT.2020, video range).
    static func frame(t: Float, width: Int = 960, height: Int = 540) throws -> CVPixelBuffer {
        var ycc = [(Float, Float, Float)](repeating: (0, 0, 0), count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let c = light(Float(x) + 0.5, Float(y) + 0.5, t: t, scale: Float(width) / 1920)
                let r = Self.pq(c.x), g = Self.pq(c.y), b = Self.pq(c.z)
                let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
                ycc[y * width + x] = (luma, (b - luma) / 1.8814, (r - luma) / 1.4746)
            }
        }
        func code(_ v: Float, _ offset: Float, _ scale: Float) -> UInt16 { UInt16(max(0, min(1023, (offset + v * scale).rounded()))) }
        return try makeHDRFrame(width: width, height: height, luma: { x, y in code(ycc[y * width + x].0, 64, 876) }) { cx, cy in
            // Left-sited: the chroma sample at the even column, averaged over its two rows.
            let a = ycc[(cy * 2) * width + cx * 2], b = ycc[(cy * 2 + 1) * width + cx * 2]
            return (code((a.1 + b.1) / 2, 512, 896), code((a.2 + b.2) / 2, 512, 896))
        }
    }
}

// MARK: Stand-ins

/// Stands in for MetalFX's interpolator where there is none (CI's virtual machines): copies the newer image (or
/// refuses to encode, or raises an exception as MetalFX might), counting the calls and fresh starts.
final class StandInMidpoint: MidpointEncoder {
    enum Behaviour { case copies, refuses, throwsException }
    let behaviour: Behaviour
    private(set) var calls = 0
    private(set) var resets = 0
    init(_ behaviour: Behaviour = .copies) { self.behaviour = behaviour }
    var colorUsage: MTLTextureUsage { .shaderRead }
    var outputUsage: MTLTextureUsage { .shaderWrite }
    func encode(_ cb: MTLCommandBuffer, previous: MTLTexture, current: MTLTexture, output: MTLTexture, reset: Bool) -> ProcessorOutcome {
        calls += 1
        if reset { resets += 1 }
        switch behaviour {
        case .refuses: return .failed("refused")
        case .throwsException: return .threw("NSInternalInconsistencyException")
        case .copies:
            guard let blit = cb.makeBlitCommandEncoder() else { return .failed("no blit") }
            blit.copy(from: current, to: output)
            blit.endEncoding()
            return .done
        }
    }
}

@Suite struct HDRFrameInterpolatorTests {
    let device = MTLCreateSystemDefaultDevice()

    func engine(_ midpoint: StandInMidpoint = StandInMidpoint(), health: VideoProcessorHealth = testHealth(),
                made: ((Int, Int) -> Void)? = nil) throws -> HDRFrameInterpolator {
        HDRFrameInterpolator(device: try #require(device), health: health, available: true) { _, w, h in
            made?(w, h)
            return midpoint
        }
    }

    func uniform(_ y: UInt16, _ cb: UInt16, _ cr: UInt16, fullRange: Bool = false, width: Int = 64, height: Int = 32) throws -> CVPixelBuffer {
        try makeHDRFrame(width: width, height: height, fullRange: fullRange, luma: { _, _ in y }) { _, _ in (cb, cr) }
    }

    /// The R'G'B' image MetalFX worked on, read back (rgba16Float).
    func readBack(_ texture: MTLTexture) throws -> [Float16] {
        let device = try #require(device)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height,
                                                         mipmapped: false)
        d.storageMode = .shared
        let shared = try #require(device.makeTexture(descriptor: d))
        let cb = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        shared.getBytes(&pixels, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }

    /// YCbCr → PQ R'G'B' (the present pass's conversion) → YCbCr lands back on the same codes: limited and full range,
    /// greys and colours, a 1000-nit grey and near peak.
    @Test(arguments: [false, true])
    func roundTripsTheCodesThroughPQRGB(fullRange: Bool) throws {
        let engine = try engine()
        let values: [(UInt16, UInt16, UInt16)] = fullRange
            ? [(0, 512, 512), (723, 512, 512), (1000, 512, 512), (400, 300, 700), (600, 650, 400)]
            : [(64, 512, 512), (723, 512, 512), (940, 512, 512), (400, 420, 600), (500, 600, 450), (300, 512, 700)]
        for (y, cb, cr) in values {
            let previous = try uniform(64, 512, 512, fullRange: fullRange), current = try uniform(y, cb, cr, fullRange: fullRange)
            let out = try #require(engine.make(previous: previous, current: current, phases: [0.5], steps: 1)?.first)
            #expect(CVPixelBufferGetPixelFormatType(out) == CVPixelBufferGetPixelFormatType(current))
            #expect(CVPixelBufferGetWidth(out) == 64 && CVPixelBufferGetHeight(out) == 32)
            for (x, row) in [(0, 0), (17, 9), (63, 31)] {
                #expect(abs(lumaCode(out, x, row) - Int(y)) <= 1, "luma \(y) → \(lumaCode(out, x, row))")
            }
            let c = chromaCodes(out, 8, 8)
            #expect(abs(c.cb - Int(cb)) <= 1 && abs(c.cr - Int(cr)) <= 1, "(\(cb), \(cr)) → \(c)")
        }
        // A 1000-nit grey is PQ 0.7518 in R'G'B' (code 723 in limited range): non-linear, not light.
        guard !fullRange else { return }
        _ = engine.make(previous: try uniform(64, 512, 512), current: try uniform(723, 512, 512), phases: [0.5], steps: 1)
        let rgb = try readBack(try #require(engine.lastMidpoint))
        #expect(abs(Float(rgb[0]) - 0.7523) < 0.002 && abs(Float(rgb[1]) - 0.7523) < 0.002 && Float(rgb[3]) == 1)
    }

    /// Luma keeps its detail pixel for pixel, and chroma comes back where its samples sit (left-sited: on the even
    /// column), not shifted half a pixel.
    @Test func keepsLumaDetailAndChromaSiting() throws {
        let engine = try engine()
        // In gamut throughout (a colour outside it comes back clipped, as the present pass would show it anyway).
        let ramp = try makeHDRFrame(width: 64, height: 32, luma: { x, y in UInt16(300 + x * 5 + y * 2) }) { x, _ in
            x < 16 ? (512, 512) : (470, 570) // a chroma edge between chroma columns 15 and 16
        }
        let out = try #require(engine.make(previous: try uniform(64, 512, 512), current: ramp, phases: [0.5], steps: 1)?.first)
        for (x, y) in [(0, 0), (31, 7), (63, 31), (40, 20)] {
            #expect(abs(lumaCode(out, x, y) - lumaCode(ramp, x, y)) <= 1, "(\(x), \(y))")
        }
        // Away from the edge chroma is exact; at it, the round trip softens it but keeps it in place.
        let still = chromaCodes(out, 4, 4), coloured = chromaCodes(out, 28, 4)
        #expect(abs(still.cb - 512) <= 1 && abs(still.cr - 512) <= 1 && abs(coloured.cb - 470) <= 1 && abs(coloured.cr - 570) <= 1,
                "\(still) \(coloured)")
        let left = chromaCodes(out, 15, 4), right = chromaCodes(out, 16, 4)
        #expect(left.cb > right.cb && abs(left.cb - 512) < abs(left.cb - 470) && abs(right.cb - 470) < abs(right.cb - 512),
                "\(left) \(right)")
    }

    @Test func copiesTheFramesColourAttachments() throws {
        let engine = try engine()
        let current = try uniform(500, 512, 512)
        let out = try #require(engine.make(previous: try uniform(400, 512, 512), current: current, phases: [0.5], steps: 1)?.first)
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferChromaLocationTopFieldKey] {
            let made = CVBufferCopyAttachment(out, key, nil).map { "\($0)" }
            #expect(made != nil && made == CVBufferCopyAttachment(current, key, nil).map { "\($0)" }, "\(key)")
        }
        #expect(FrameColor.isHDR(out) && FrameColor(out) == FrameColor(current))
    }

    /// MetalFX goes on from the pair before when this pair starts from its newer frame; anything else starts afresh.
    @Test func carriesHistoryOnlyAcrossFollowingPairs() throws {
        let midpoint = StandInMidpoint()
        let engine = try engine(midpoint)
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512), c = try uniform(500, 512, 512), d = try uniform(600, 512, 512)
        for (previous, current) in [(a, b), (b, c), (c, d)] {
            #expect(engine.make(previous: previous, current: current, phases: [0.5], steps: 1) != nil)
        }
        #expect(engine.freshStarts == 1 && midpoint.resets == 1 && midpoint.calls == 3)
        // The previous frame's image is the one converted last time: the midpoint of (c, d) still shows d.
        #expect(engine.make(previous: a, current: d, phases: [0.5], steps: 1) != nil) // a gap
        #expect(engine.freshStarts == 2)
        engine.reset() // a cut, or a switch from SDR
        let out = try #require(engine.make(previous: d, current: c, phases: [0.5], steps: 1)?.first)
        #expect(engine.freshStarts == 3 && midpoint.resets == 3 && abs(lumaCode(out, 5, 5) - 500) <= 1)
    }

    @Test func makesOnlyHalvesOfHDRFramesOfOneSize() throws {
        var sizes: [String] = []
        let engine = try engine(made: { sizes.append("\($0)x\($1)") })
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512)
        #expect(engine.make(previous: a, current: b, phases: [0.25, 0.5, 0.75], steps: 2) == nil) // no quarters
        #expect(engine.make(previous: a, current: b, phases: [0.25], steps: 1) == nil)
        let sdr = try makeNV12(width: 64, height: 32, y: 100, cb: 128, cr: 128)
        #expect(engine.make(previous: sdr, current: sdr, phases: [0.5], steps: 1) == nil)
        #expect(engine.make(previous: a, current: try makeHDRFrame(width: 64, height: 32, y: 400, pq: false), phases: [0.5], steps: 1) == nil)
        #expect(engine.make(previous: try uniform(300, 512, 512, width: 32, height: 32), current: b, phases: [0.5], steps: 1) == nil)
        #expect(sizes.isEmpty) // nothing set up for any of them
        engine.prepare(width: 64, height: 32)
        #expect(sizes == ["64x32"])
        #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1)?.count == 1)
        #expect(sizes == ["64x32"]) // set up ahead, not again
        // Unavailable (an older macOS, an unsupported GPU, a virtual machine): nothing, and nothing set up.
        let off = HDRFrameInterpolator(device: try #require(device), health: testHealth(), available: false) { _, _, _ in
            Issue.record("set up while unavailable")
            return nil
        }
        off.prepare(width: 64, height: 32)
        #expect(off.make(previous: a, current: b, phases: [0.5], steps: 1) == nil)
    }

    @Test func aSizeMetalFXCannotRunAtIsNotTriedAgain() throws {
        var tries = 0
        let engine = HDRFrameInterpolator(device: try #require(device), health: testHealth(), available: true) { _, _, _ in
            tries += 1
            return nil
        }
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512)
        for _ in 0..<3 { #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) }
        #expect(tries == 1 && engine.lastMidpoint == nil)
    }

    /// GPU work that fails counts against HDR frame interpolation's own budget (VideoToolbox's on SDR streams is left
    /// alone); past it, it's off for the run.
    @Test func failuresTurnItOffForTheRun() throws {
        let health = testHealth()
        let midpoint = StandInMidpoint(.refuses)
        let engine = try engine(midpoint, health: health)
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512)
        for _ in 0..<3 { #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) == nil) }
        #expect(health.failures == 3 && health.isOff && engine.hasFailed)
        #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) == nil && midpoint.calls == 3) // not called again
        #expect(engine.lastMidpoint == nil) // its images are let go
    }

    /// An interpolator that raised an Objective-C exception may hold a lock or be half-made: it's quarantined (kept,
    /// never called again, counted as a failure) and the next pair sets up a fresh one.
    @Test func anExceptionQuarantinesTheInterpolator() throws {
        let health = testHealth()
        var made: [StandInMidpoint] = []
        let engine = HDRFrameInterpolator(device: try #require(device), health: health, available: true) { _, _, _ in
            let midpoint = StandInMidpoint(made.isEmpty ? .throwsException : .copies)
            made.append(midpoint)
            return midpoint
        }
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512)
        #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) == nil)
        #expect(health.quarantined == 1 && health.failures == 1 && !health.isOff && engine.lastMidpoint == nil)
        let out = try #require(engine.make(previous: a, current: b, phases: [0.5], steps: 1)?.first)
        #expect(made.count == 2 && made[0].calls == 1 && made[1].calls == 1 && made[1].resets == 1)
        #expect(abs(lumaCode(out, 5, 5) - 400) <= 1)
    }

    /// A command buffer that doesn't complete (a GPU error) counts against the budget, gives no image, and the next
    /// pair starts afresh.
    @Test func aGPUErrorCountsAsAFailure() throws {
        let health = testHealth(), midpoint = StandInMidpoint()
        var fails = true
        let engine = HDRFrameInterpolator(device: try #require(device), health: health, available: true,
                                          makeMidpoint: { _, _, _ in midpoint }) { cb in
            guard !fails else { return } // never committed: its status isn't `.completed`, as after an error
            cb.commit()
            cb.waitUntilCompleted()
        }
        let a = try uniform(300, 512, 512), b = try uniform(400, 512, 512), c = try uniform(500, 512, 512)
        #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) == nil)
        #expect(health.failures == 1 && health.quarantined == 0)
        fails = false
        #expect(engine.make(previous: b, current: c, phases: [0.5], steps: 1) != nil)
        #expect(engine.freshStarts == 2 && health.failures == 1) // no history from the pair that failed
    }

    /// One engine given frames of another size makes images of that size (its buffers aren't the first size's).
    @Test func makesImagesAtEachFramesOwnSize() throws {
        let engine = try engine()
        for (width, height) in [(64, 32), (32, 16), (64, 32)] {
            let a = try uniform(300, 512, 512, width: width, height: height), b = try uniform(600, 512, 512, width: width, height: height)
            let out = try #require(engine.make(previous: a, current: b, phases: [0.5], steps: 1)?.first)
            #expect(CVPixelBufferGetWidth(out) == width && CVPixelBufferGetHeight(out) == height)
            #expect(abs(lumaCode(out, width - 1, height - 1) - 600) <= 1)
        }
    }

    @Test func availabilityFollowsMetalFX() throws {
        let device = try #require(device)
        guard #available(macOS 26.0, *), !isVirtualMachine else {
            #expect(!HDRFrameInterpolator.isAvailable) // CI's virtual machines (and STREAMCORE_SIMULATE_VM=1)
            return
        }
        #expect(HDRFrameInterpolator.isAvailable == MTLFXFrameInterpolatorDescriptor.supportsDevice(device))
        if HDRFrameInterpolator.isAvailable { #expect(makeMetalFXMidpoint(device: device, width: 640, height: 360) != nil) }
    }
}

// MARK: MetalFX on this Mac (skipped where it can't run: CI's virtual machines)

extension HDRFrameInterpolatorTests {
    /// A pixel's R'G'B' (PQ) from a BT.2020 video-range frame's codes (its chroma sample's, unfiltered).
    func rgb(_ frame: CVPixelBuffer, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let l = (Float(lumaCode(frame, x, y)) - 64) / 876
        let c = chromaCodes(frame, x / 2, y / 2)
        let cb = (Float(c.cb) - 512) / 896, cr = (Float(c.cr) - 512) / 896
        return SIMD3(l + 1.4746 * cr, l - 0.16455 * cb - 0.57135 * cr, l + 1.8814 * cb)
    }

    /// PSNR (dB) of `a` against `truth` in R'G'B' (PQ, 0–1) over a region.
    func psnr(_ a: CVPixelBuffer, _ truth: CVPixelBuffer, x: Range<Int>, y: Range<Int>) -> Double {
        var total = 0.0
        for row in y { for col in x { let d = rgb(a, col, row) - rgb(truth, col, row); total += Double((d * d).sum()) } }
        let mse = total / Double(x.count * y.count * 3)
        return mse <= 0 ? 99 : 10 * log10(1 / mse)
    }

    /// The real thing on the spike's clip at 960×540: around the fast square, the image MetalFX makes halfway is closer
    /// to the true in-between picture than a cross-fade (measured: about 3 dB); the sun's core stays far above 1000
    /// nits; nothing is NaN or infinite.
    @Test func metalFXMakesTheHDRMidpoint() throws {
        guard HDRFrameInterpolator.isAvailable else { return }
        let health = testHealth()
        let engine = HDRFrameInterpolator(device: try #require(device), health: health)
        let (width, height, scale) = (960, 540, Float(0.5))
        var frames: [CVPixelBuffer] = []
        for t in 0..<5 { frames.append(try HDRScene.frame(t: Float(t), width: width, height: height)) }
        var out: CVPixelBuffer?
        for k in 1..<frames.count {
            out = try #require(engine.make(previous: frames[k - 1], current: frames[k], phases: [0.5], steps: 1)?.first)
        }
        let middle = try #require(out)
        #expect(engine.freshStarts == 1 && health.failures == 0)
        let truth = try HDRScene.frame(t: 3.5, width: width, height: height)
        let fade = try makeHDRFrame(width: width, height: height, luma: { x, y in
            UInt16((lumaCode(frames[3], x, y) + lumaCode(frames[4], x, y) + 1) / 2)
        }) { x, y in
            let a = chromaCodes(frames[3], x, y), b = chromaCodes(frames[4], x, y)
            return (UInt16((a.cb + b.cb + 1) / 2), UInt16((a.cr + b.cr + 1) / 2))
        }
        // Where the square was and is (frames 3 and 4), with a margin.
        let xs = Int((HDRScene.object(3) - 50) * scale)..<Int((HDRScene.object(4) + 50) * scale)
        let ys = Int(650 * scale)..<Int(750 * scale)
        let generated = psnr(middle, truth, x: xs, y: ys), faded = psnr(fade, truth, x: xs, y: ys)
        #expect(generated > faded + 1, "MetalFX \(generated) dB, cross-fade \(faded) dB")
        let sun = HDRScene.sun(3.5)
        let core = HDRScene.nits((Float(lumaCode(middle, Int(sun.x * scale), Int(sun.y * scale))) - 64) / 876)
        #expect(core > 1000, "sun core \(core) nits")
        let rgb = try readBack(try #require(engine.lastMidpoint))
        #expect(rgb.allSatisfy { $0.isFinite })
        print("HDR midpoint around the moving square: MetalFX \(String(format: "%.1f", generated)) dB, cross-fade "
              + "\(String(format: "%.1f", faded)) dB; sun core \(Int(core)) nits")
    }

    /// The quality table in docs/FRAME_INTERPOLATION.md ("HDR", "Measured through the app's code"): the spike's scene
    /// at 1080p, 720p and 540p through the app's engine, each pair's midpoint scored against the true in-between
    /// picture in R'G'B' (PQ) from the output codes, next to a cross-fade of the frames: mean PSNR over the pairs ·
    /// worst 32 px tile, and the mean around the fast square; plus the YCbCr round trip alone. Slow (a minute in a
    /// debug build), so only on request: `STREAMCORE_HDR_QUALITY=1 scripts/test.sh --filter hdrQualityTable`.
    @Test func hdrQualityTable() throws {
        guard ProcessInfo.processInfo.environment["STREAMCORE_HDR_QUALITY"] != nil, HDRFrameInterpolator.isAvailable else { return }
        let device = try #require(device)
        /// A frame's R'G'B' per pixel (its chroma sample's, unfiltered), from its codes.
        func image(_ frame: CVPixelBuffer) -> [SIMD3<Float>] {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
            let y = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt16.self)
            let c = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt16.self)
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 0) / 2, cRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 1) / 2
            var out = [SIMD3<Float>](repeating: .zero, count: width * height)
            for row in 0..<height {
                for col in 0..<width {
                    let l = (Float(y[row * yRow + col] >> 6) - 64) / 876
                    let i = (row / 2) * cRow + (col / 2) * 2
                    let cb = (Float(c[i] >> 6) - 512) / 896, cr = (Float(c[i + 1] >> 6) - 512) / 896
                    out[row * width + col] = SIMD3(l + 1.4746 * cr, l - 0.16455 * cb - 0.57135 * cr, l + 1.8814 * cb)
                }
            }
            return out
        }
        func psnr(_ mse: Double) -> Double { mse <= 0 ? 99 : 10 * log10(1 / mse) }
        /// Whole-image PSNR, the worst 32 px tile's, and the region's.
        func score(_ a: [SIMD3<Float>], _ truth: [SIMD3<Float>], width: Int, height: Int,
                   region: (x: Range<Int>, y: Range<Int>)) -> (all: Double, worstTile: Double, region: Double) {
            var total = 0.0, inRegion = 0.0
            var tiles = [Double](repeating: 0, count: ((width + 31) / 32) * ((height + 31) / 32))
            let across = (width + 31) / 32
            for row in 0..<height {
                for col in 0..<width {
                    let d = a[row * width + col] - truth[row * width + col]
                    let e = Double((d * d).sum())
                    total += e
                    tiles[(row / 32) * across + col / 32] += e
                    if region.x.contains(col), region.y.contains(row) { inRegion += e }
                }
            }
            let worst = tiles.enumerated().map { k, e -> Double in
                let w = min(32, width - (k % across) * 32), h = min(32, height - (k / across) * 32)
                return e / Double(w * h * 3)
            }.max() ?? 0
            return (psnr(total / Double(width * height * 3)), psnr(worst), psnr(inRegion / Double(region.x.count * region.y.count * 3)))
        }
        print("HDR quality through the app's code (PSNR in PQ R'G'B', dB): mean · worst 32 px tile · around the square")
        for (width, height) in [(1920, 1080), (1280, 720), (960, 540)] {
            let scale = Float(width) / 1920, pairs = 8
            let engine = HDRFrameInterpolator(device: device, health: testHealth())
            let frames = try (0...pairs).map { try HDRScene.frame(t: Float($0), width: width, height: height) }
            let pictures = frames.map(image)
            var made: [(all: Double, worstTile: Double, region: Double)] = [], faded = made
            for k in 1...pairs {
                let middle = try #require(engine.make(previous: frames[k - 1], current: frames[k], phases: [0.5], steps: 1)?.first)
                let truth = image(try HDRScene.frame(t: Float(k) - 0.5, width: width, height: height))
                let region = (x: Int((HDRScene.object(Float(k - 1)) - 50) * scale)..<min(width, Int((HDRScene.object(Float(k)) + 50) * scale)),
                              y: Int(650 * scale)..<Int(750 * scale))
                made.append(score(image(middle), truth, width: width, height: height, region: region))
                let fade = zip(pictures[k - 1], pictures[k]).map { ($0 + $1) / 2 }
                faded.append(score(fade, truth, width: width, height: height, region: region))
            }
            func line(_ s: [(all: Double, worstTile: Double, region: Double)]) -> String {
                let n = Double(s.count)
                return String(format: "%.1f · %.1f · %.1f", s.map(\.all).reduce(0, +) / n, s.map(\.worstTile).min() ?? 0,
                              s.map(\.region).reduce(0, +) / n)
            }
            // The round trip alone: a stand-in that passes the newer frame's R'G'B' through.
            let trip = try #require(try self.engine().make(previous: frames[0], current: frames[1], phases: [0.5], steps: 1)?.first)
            let whole = (x: 0..<width, y: 0..<height)
            print("  \(width)x\(height): MetalFX \(line(made)) | cross-fade \(line(faded)) | round trip "
                  + String(format: "%.1f", score(image(trip), pictures[1], width: width, height: height, region: whole).all))
        }
    }

    /// What the app runs per HDR pair at 1080p (the size the PS5 sends), timed: comfortably inside a 60 fps game's
    /// 12.5 ms budget.
    @Test func metalFXCostAt1080p() throws {
        guard HDRFrameInterpolator.isAvailable else { return }
        let engine = HDRFrameInterpolator(device: try #require(device), health: testHealth())
        let a = try makeHDRFrame(width: 1920, height: 1080, luma: { x, y in UInt16(100 + (x + y) % 700) }) { _, _ in (512, 512) }
        let b = try makeHDRFrame(width: 1920, height: 1080, luma: { x, y in UInt16(100 + (x + y + 8) % 700) }) { _, _ in (512, 512) }
        var times: [Double] = []
        for k in 0..<24 {
            let started = CACurrentMediaTime()
            #expect(engine.make(previous: k % 2 == 0 ? a : b, current: k % 2 == 0 ? b : a, phases: [0.5], steps: 1) != nil)
            if k >= 4 { times.append((CACurrentMediaTime() - started) * 1000) }
        }
        let median = times.sorted()[times.count / 2]
        #expect(median < 12.5, "\(median) ms")
        print("HDR frame interpolation at 1080p: \(String(format: "%.1f", median)) ms per pair (median, wall clock)")
    }
}

extension SharedEventTests {
    /// MetalFX's frame interpolator, unlike VideoToolbox's Metal call, makes no Metal shared event per call.
    @Test func hdrInterpolationMakesNoSharedEventPerCall() throws {
        guard HDRFrameInterpolator.isAvailable, let device = MTLCreateSystemDefaultDevice() else { return }
        // The hook sees a shared event being made (so the check below can't pass for not looking).
        let start = try #require(SharedEvents.made)
        let event = device.makeSharedEvent()
        let after = try #require(SharedEvents.made)
        #expect(event != nil && after - start >= 1)
        let health = testHealth()
        let engine = HDRFrameInterpolator(device: device, health: health)
        let a = try makeHDRFrame(width: 640, height: 360, y: 300), b = try makeHDRFrame(width: 640, height: 360, y: 500)
        #expect(engine.make(previous: a, current: b, phases: [0.5], steps: 1) != nil) // past the first call (setting up)
        let calls = 200
        let before = try #require(SharedEvents.made)
        var made = 0
        for k in 0..<calls where engine.make(previous: k % 2 == 0 ? b : a, current: k % 2 == 0 ? a : b, phases: [0.5], steps: 1) != nil {
            made += 1
        }
        #expect(made == calls && health.failures == 0)
        #expect(try #require(SharedEvents.made) - before < calls / 10) // none of its own; room for other tests alongside
    }
}

// MARK: The lane and the renderer with HDR frames

/// Stands in for an engine, counting what it was asked and how often it was reset.
final class CountingMaker: MiddleFrameMaker {
    private(set) var pairs = 0
    private(set) var resets = 0
    func make(previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        pairs += 1
        return phases.map { _ in current }
    }
    func reset() { resets += 1 }
}

/// Stands in for the HDR engine with an image unlike either frame (or nothing): a flat HDR frame of the pair's size and
/// format, these codes.
final class FlatHDRMaker: MiddleFrameMaker {
    let codes: (y: UInt16, cb: UInt16, cr: UInt16)?
    init(_ codes: (y: UInt16, cb: UInt16, cr: UInt16)?) { self.codes = codes }
    func make(previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        guard let codes else { return nil }
        let full = CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let image = try? makeHDRFrame(width: CVPixelBufferGetWidth(current), height: CVPixelBufferGetHeight(current), fullRange: full,
                                      luma: { _, _ in codes.y }) { _, _ in (codes.cb, codes.cr) }
        return image.map { image in phases.map { _ in image } }
    }
}

extension InterpolationLaneTests {
    func metal() throws -> MTLDevice { try #require(device) }

    /// A 640×360 HDR frame like `frame(bar:)`: a "HUD" patch that never moves, a bright bar from x on a dark ground.
    func hdrFrame(bar x: Int, background: UInt16 = 200) throws -> CVPixelBuffer {
        try makeHDRFrame(width: 640, height: 360, luma: { px, py in
            if px < 100 && py < 60 { return UInt16(240 + (px * 7 + py * 13) % 480) }
            return px >= x && px < x + 60 ? 800 : background
        }) { _, _ in (512, 512) }
    }

    @Test func sendsHDRPairsToTheHDREngineAndSDRPairsToVideoToolbox() throws {
        let sdr = CountingMaker(), hdr = CountingMaker()
        let lane = try #require(InterpolationLane(device: try metal(), health: testHealth(), hdrHealth: testHealth(),
                                                  engine: { sdr }, hdrEngine: { hdr }))
        var made: [CVPixelBuffer] = []
        lane.onImage = { made.append($0.buffer) }
        let half = [InBetween.Image(phase: 0.5, time: 1)]
        lane.submit(previous: try hdrFrame(bar: 200), current: try hdrFrame(bar: 300), between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(hdr.pairs == 1 && sdr.pairs == 0 && made.count == 1)
        #expect(made.first.map { CVPixelBufferGetPixelFormatType($0) } == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        lane.submit(previous: try frame(bar: 200), current: try frame(bar: 300), between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(hdr.pairs == 1 && sdr.pairs == 1 && made.count == 2)
        // The switch between SDR and HDR, both ways: no images, like a cut, and MetalFX starts afresh after it.
        for (previous, current) in [(try frame(bar: 300), try hdrFrame(bar: 300)), (try hdrFrame(bar: 300), try frame(bar: 300))] {
            lane.submit(previous: previous, current: current, between: half, steps: 1, size: (640, 360))
            lane.waitUntilIdle()
        }
        #expect(hdr.pairs == 1 && sdr.pairs == 1 && made.count == 2 && hdr.resets == 2 && sdr.resets == 0)
        #expect(lane.cutPairs == 2 && lane.failedPairs == 0 && lane.busyPairs == 0)
        // A cut between HDR frames resets it too.
        lane.submit(previous: try hdrFrame(bar: 200), current: try hdrFrame(bar: 300), between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        lane.submit(previous: try hdrFrame(bar: 300, background: 100), current: try hdrFrame(bar: 300, background: 900),
                    between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(hdr.resets == 3 && lane.cutPairs == 3 && hdr.pairs == 2)
    }

    /// The still-area blend on 10-bit planes, against an engine image unlike either frame (flat luma 500, a colour):
    /// the HUD comes back exactly from the frames; an area 4 codes apart (under 2/255 of the range) is the frames'
    /// average; one 40 codes apart (over 8/255) and the moving bar are the engine's, luma and chroma.
    @Test func blendsStillAreasOfHDRFrames() throws {
        let lane = try #require(InterpolationLane(device: try metal(), hdrHealth: testHealth(), engine: { StandInMaker() },
                                                  hdrEngine: { FlatHDRMaker((500, 600, 450)) }))
        var made: [InterpolationLane.Image] = []
        lane.onImage = { made.append($0) }
        func frame(bar x: Int, apart d: UInt16) throws -> CVPixelBuffer {
            try makeHDRFrame(width: 640, height: 360, luma: { px, py in
                if px < 100 && py < 60 { return UInt16(240 + (px * 7 + py * 13) % 480) }
                if px >= 400 && px < 460 && py >= 100 && py < 160 { return 300 + d / 10 } // nearly still
                if px >= 400 && px < 460 && py >= 200 && py < 260 { return 300 + d } // changed
                return px >= x && px < x + 60 ? 800 : 200
            }) { _, _ in (512, 512) }
        }
        let a = try frame(bar: 200, apart: 0), b = try frame(bar: 300, apart: 40)
        lane.submit(previous: a, current: b, between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        let image = try #require(made.first).buffer
        for (x, y) in [(10, 10), (55, 31), (90, 50)] { #expect(abs(lumaCode(image, x, y) - lumaCode(a, x, y)) <= 1, "(\(x), \(y))") }
        #expect(abs(lumaCode(image, 430, 130) - 302) <= 1, "\(lumaCode(image, 430, 130))") // (300 + 304) / 2
        #expect(abs(lumaCode(image, 430, 230) - 500) <= 1 && abs(lumaCode(image, 230, 200) - 500) <= 1
                && abs(lumaCode(image, 320, 200) - 500) <= 1)
        let still = chromaCodes(image, 10, 10), moved = chromaCodes(image, 215, 115)
        #expect(still.cb == 512 && still.cr == 512 && abs(moved.cb - 600) <= 1 && abs(moved.cr - 450) <= 1, "\(still) \(moved)")
        #expect(FrameColor.isHDR(image))
    }

    /// The empty-image check is for VideoToolbox's silent failures: an HDR image is never taken for one, so a dark
    /// full-range pair (black is code 0 there; a fade to black isn't a cut) gets its image and keeps its size.
    @Test func doesNotTakeADarkHDRImageForAnEmptyOne() throws {
        let lane = try #require(InterpolationLane(device: try metal(), health: testHealth(), hdrHealth: testHealth(),
                                                  engine: { StandInMaker() }, hdrEngine: { FlatHDRMaker((0, 512, 512)) }))
        var made = 0
        lane.onImage = { _ in made += 1 }
        let a = try makeHDRFrame(width: 64, height: 64, fullRange: true, luma: { _, _ in 20 }) { _, _ in (512, 512) }
        let b = try makeHDRFrame(width: 64, height: 64, fullRange: true, luma: { _, _ in 0 }) { _, _ in (512, 512) }
        #expect(InterpolationLane.isEmpty(b) && !InterpolationLane.isCut(a, b))
        lane.submit(previous: a, current: b, between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (64, 64))
        lane.waitUntilIdle()
        #expect(made == 1 && !lane.isBroken((64, 64), hdr: true) && lane.failedPairs == 0)
    }

    /// HDR engines (MetalFX, its images, the last frame it holds) are let go when the stream turns SDR and when a new
    /// stream starts; the next HDR pair sets one up again.
    @Test func letsGoOfHDREnginesWhenTheStreamTurnsSDROrANewOneStarts() throws {
        var built = 0
        weak var last: CountingMaker?
        let lane = try #require(InterpolationLane(device: try metal(), health: testHealth(), hdrHealth: testHealth(),
                                                  engine: { StandInMaker() }, hdrEngine: {
                                                      built += 1
                                                      let made = CountingMaker()
                                                      last = made
                                                      return made
                                                  }))
        let half = [InBetween.Image(phase: 0.5, time: 1)]
        func hdrPair() throws {
            lane.submit(previous: try hdrFrame(bar: 200), current: try hdrFrame(bar: 220), between: half, steps: 1, size: (640, 360))
            lane.waitUntilIdle()
        }
        try hdrPair()
        #expect(built == 1 && last != nil)
        // To SDR: let go. (SDR to HDR only starts it afresh.)
        lane.submit(previous: try hdrFrame(bar: 220), current: try frame(bar: 220), between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(last == nil)
        try hdrPair()
        #expect(built == 2 && last != nil)
        lane.submit(previous: try frame(bar: 220), current: try hdrFrame(bar: 220), between: half, steps: 1, size: (640, 360))
        lane.waitUntilIdle()
        #expect(last?.resets == 1)
        lane.releaseHDREngines() // a new stream
        lane.waitUntilIdle()
        #expect(last == nil)
        try hdrPair()
        #expect(built == 3)
    }

    /// The CPU checks read 10-bit luma by its high byte: the same thresholds as 8-bit frames.
    @Test func readsTenBitLumaForCutsRepeatsAndEmptyImages() throws {
        let dark = try makeHDRFrame(width: 64, height: 64, y: 100), bright = try makeHDRFrame(width: 64, height: 64, y: 900)
        let darker = try makeHDRFrame(width: 64, height: 64, y: 120)
        #expect(InterpolationLane.isCut(dark, bright) && !InterpolationLane.isCut(dark, darker))
        // 20 codes in 10 bits: 5 in 8.
        #expect(InterpolationLane.difference(dark, darker) == 5)
        #expect(InterpolationLane.difference(dark, try makeNV12(width: 64, height: 64, y: 25, cb: 128, cr: 128)) == nil) // 10 vs 8 bits
        #expect(InterpolationLane.isEmpty(try makeHDRFrame(width: 64, height: 64, y: 0)))
        #expect(!InterpolationLane.isEmpty(try makeHDRFrame(width: 64, height: 64, y: 64))) // 10-bit video-range black
    }

    @Test func keepsSDRAndHDRSizesApart() throws {
        let lane = try #require(InterpolationLane(device: try metal(), health: testHealth(), hdrHealth: testHealth(),
                                                  engine: { StandInMaker() }, hdrEngine: { FlatHDRMaker(nil) }))
        for _ in 0..<5 { // a size that keeps giving nothing is dropped
            lane.submit(previous: try hdrFrame(bar: 200, background: 100), current: try hdrFrame(bar: 220, background: 100),
                        between: [InBetween.Image(phase: 0.5, time: 1)], steps: 1, size: (640, 360))
            lane.waitUntilIdle()
        }
        #expect(lane.isBroken((640, 360), hdr: true) && !lane.isBroken((640, 360)))
    }

    @Test func saysWhenHDRFrameInterpolationTurnedItselfOff() throws {
        let health = testHealth(), hdrHealth = testHealth()
        let lane = try #require(InterpolationLane(device: try metal(), health: health, hdrHealth: hdrHealth,
                                                  engine: { StandInMaker() }, hdrEngine: { StandInMaker() }))
        for _ in 0..<3 { hdrHealth.failed("test") }
        #expect(lane.hdrHasFailed && !lane.hasFailed)
        // Without an HDR engine given, it makes MetalFX's (here off: its health is), reporting to that health.
        let real = try #require(InterpolationLane(device: try metal(), health: health, hdrHealth: hdrHealth))
        var made = 0
        real.onImage = { _ in made += 1 }
        real.prepare(size: (640, 360), hdr: true)
        real.submit(previous: try hdrFrame(bar: 200), current: try hdrFrame(bar: 300), between: [InBetween.Image(phase: 0.5, time: 1)],
                    steps: 1, size: (640, 360))
        real.waitUntilIdle()
        #expect(made == 0 && real.failedPairs == 1)
    }
}

@Suite struct HDRPacingTests {
    @Test func hdrPairsGetHalvesOnly() {
        // A 30 fps game on a 120 Hz screen: quarters for SDR, halves for HDR (MetalFX makes the midpoint only).
        #expect(InBetween.steps(interval: 1.0 / 30, refreshInterval: 1.0 / 120) == 2)
        #expect(InBetween.steps(interval: 1.0 / 30, refreshInterval: 1.0 / 120, most: HDRFrameInterpolator.maxSteps) == 1)
        #expect(InBetween.steps(interval: 0, refreshInterval: 1.0 / 120, current: 2, most: 1) == 1)
    }

    @Test func hdrPairsStayAtTheirOwnSize() {
        var rungs = RungSelector(width: 1920, height: 1080, scales: false)
        #expect(rungs.rungs.count == 1 && rungs.size == (1920, 1080) && !rungs.scales)
        // Over budget: there's nowhere smaller to go (MetalFX's cost at 1080p is a few ms).
        rungs.observe(cost: 0.02, budget: 0.0125, now: 1)
        #expect(rungs.size == (1920, 1080))
        #expect(!rungs.exhausted)
        let another = rungs.markBroken()
        #expect(!another && rungs.exhausted)
        // An odd size isn't rounded (that's VideoToolbox's fast path, which HDR pairs don't take).
        #expect(RungSelector(width: 1000, height: 562, scales: false).size == (1000, 562))
        #expect(RungSelector(width: 1920, height: 1080).rungs.count == 3)
    }
}

extension StreamRendererTests {
    /// Renders HDR into a float target (as the drawable is in HDR) and returns its RGBA, linear light (1.0 = 203 nits).
    func renderHDR(_ r: StreamRenderer, size: (Int, Int), now: Double) throws -> [Float16] {
        let device = r.commandQueue.device
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.0, height: size.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        let cb = try #require(r.commandQueue.makeCommandBuffer())
        r.encode(cb, pass: pass, drawableSize: CGSize(width: size.0, height: size.1), now: now)
        cb.commit()
        cb.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: size.0 * size.1 * 4)
        target.getBytes(&pixels, bytesPerRow: size.0 * 8, from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0)
        return pixels
    }

    /// What the stats say for HDR streams follows MetalFX's engine, for SDR ones VideoToolbox's.
    @Test(arguments: [(true, false), (false, true), (true, true)])
    func reportsInterpolationForTheStreamAsItIs(sdr: Bool, hdr: Bool) throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: nil, interpolation: (sdr, hdr)))
        r.params.upscaler = .bilinear
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        #expect(r.interpolationSupported && r.hdrInterpolationSupported == hdr)
        let frame = 1.0 / 30, refresh = 1.0 / 60
        for k in 0..<4 {
            r.display(try makeNV12(width: 64, height: 64, y: UInt8(40 + 30 * k), cb: 128, cr: 128), index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try render(r, size: (64, 64), now: Double(k) * frame)
            _ = try render(r, size: (64, 64), now: Double(k) * frame + refresh)
        }
        #expect(r.pipeline.interpolation == (sdr ? .on : .unsupported))
        r.setHDR(true)
        for k in 4..<8 {
            r.display(try makeHDRFrame(width: 64, height: 64, y: UInt16(300 + 60 * k)), index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try renderHDR(r, size: (64, 64), now: Double(k) * frame)
            _ = try renderHDR(r, size: (64, 64), now: Double(k) * frame + refresh)
        }
        #expect(r.pipeline.interpolation == (hdr ? .on : .unsupported))
        #expect(r.pipeline.ml == .off) // ML upscaling still sits out in HDR (and is off here)
    }

    /// On a 120 Hz screen a 30 fps game gets quarters in SDR, and halves in HDR (MetalFX makes the midpoint only):
    /// what the renderer asks each engine for.
    @Test func asksTheHDREngineForHalvesOnlyAt120Hz() throws {
        let sdr = StandInMaker(), hdr = StandInMaker()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: nil, interpolation: (true, true),
                                            engines: ({ sdr }, { hdr })))
        r.params.upscaler = .bilinear
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        let frame = 1.0 / 30, refresh = 1.0 / 120
        for k in 0..<12 {
            let hdrFrame = k >= 6
            if k == 6 { r.setHDR(true) }
            r.display(hdrFrame ? try makeHDRFrame(width: 64, height: 64, y: UInt16(300 + 12 * k))
                               : try makeNV12(width: 64, height: 64, y: UInt8(40 + 3 * k), cb: 128, cr: 128),
                      index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            for step in 0..<4 {
                let now = Double(k) * frame + Double(step) * refresh
                _ = hdrFrame ? try renderHDR(r, size: (64, 64), now: now).count : try render(r, size: (64, 64), now: now).count
            }
        }
        #expect(!sdr.asked.isEmpty && sdr.asked.allSatisfy { $0.steps == 2 && $0.phases == [0.25, 0.5, 0.75] }, "\(sdr.asked)")
        #expect(!hdr.asked.isEmpty && hdr.asked.allSatisfy { $0.steps == 1 && $0.phases == [0.5] }, "\(hdr.asked)")
        #expect(r.pipeline.interpolation == .on && r.missedInterpolations == 0)
    }

    /// HDR streams have one size: when the lane drops it (MetalFX can't be set up there, or keeps giving nothing),
    /// interpolation says `failed` for the stream instead of `on` with nothing made, and stops waiting for images.
    @Test func saysFailedWhenNoSizeWorksForTheStream() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: nil, interpolation: (true, true),
                                            engines: ({ StandInMaker() }, { StandInMaker(.none) })))
        r.params.upscaler = .bilinear
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        r.setHDR(true)
        let frame = 1.0 / 30, refresh = 1.0 / 60
        var states: [PipelineState.Interpolation] = []
        for k in 0..<10 {
            r.display(try makeHDRFrame(width: 64, height: 64, y: UInt16(300 + 12 * k)), index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try renderHDR(r, size: (64, 64), now: Double(k) * frame)
            _ = try renderHDR(r, size: (64, 64), now: Double(k) * frame + refresh)
            states.append(r.pipeline.interpolation)
        }
        #expect(states.contains(.on) && states.last == .failed, "\(states)")
        let missed = r.missedInterpolations
        #expect(missed == 5) // the five that dropped the size; none asked for after it
        // A new stream starts over (it may come at another size).
        r.streamFrameRate = 30
        _ = try renderHDR(r, size: (64, 64), now: 10 * frame)
        #expect(r.pipeline.interpolation == .still) // on, with no picture of the new stream yet
    }

    /// With the HDR setting on, an SDR game's frames are 10-bit but not PQ: neither engine takes them, so
    /// interpolation says `unsupported` (not `on` with nothing made), and repeats show as they come instead of being
    /// left out for images that never come.
    @Test func tenBitSDRFramesAreUnsupportedAndKeepTheirRepeats() throws {
        let sdr = StandInMaker(), hdr = StandInMaker()
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64, upscaler: nil, interpolation: (true, true),
                                            engines: ({ sdr }, { hdr })))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        let frame = 1.0 / 30, refresh = 1.0 / 60
        // The same luma throughout (each frame a repeat to the detector), the colour changing.
        var shown: [Int] = []
        for k in 0..<6 {
            r.display(try makeHDRFrame(width: 64, height: 64, y: 500, cb: UInt16(400 + 40 * k), pq: false), index: UInt64(k),
                      arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try render(r, size: (64, 64), now: Double(k) * frame)
            shown.append(pixel(try render(r, size: (64, 64), now: Double(k) * frame + refresh), width: 64, x: 32, y: 32).b)
        }
        #expect(r.pipeline.interpolation == .unsupported && r.repeatedFrames > 0)
        #expect(sdr.asked.isEmpty && hdr.asked.isEmpty)
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $1 > $0 }, "\(shown)") // every frame shown, bluer each time
    }

    /// The HDR stream end to end with MetalFX: a 30 fps stream on a 60 Hz screen, a bright bar moving; an in-between
    /// image shows the bar about halfway before the new frame, as an HDR image (EDR, far above SDR white).
    @Test func showsHDRInBetweenImagesBeforeTheNewFrame() throws {
        guard HDRFrameInterpolator.isAvailable else { return }
        let r = try #require(StreamRenderer(inputWidth: 640, inputHeight: 360))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.frameInterpolation = true
        r.streamFrameRate = 30
        r.setHDR(true)
        /// A dark HDR frame (about 5 nits) with a 1000-nit vertical bar starting at x.
        func bar(at x: Int) throws -> CVPixelBuffer {
            try makeHDRFrame(width: 640, height: 360, luma: { px, _ in px >= x && px < x + 60 ? 723 : 200 }) { _, _ in (512, 512) }
        }
        /// Where the bar is in a rendered 64-pixel row (brightness-weighted centre), and its peak level.
        func centre(_ pixels: [Float16]) -> (x: Double, peak: Float) {
            var sum = 0.0, weight = 0.0, peak: Float = 0
            for x in 0..<64 {
                let level = Float(pixels[(18 * 64 + x) * 4 + 1])
                peak = max(peak, level)
                let w = Double(max(0, level - 1))
                sum += w * Double(x)
                weight += w
            }
            return (weight > 0 ? sum / weight : -1, peak)
        }
        let frame = 1.0 / 30, refresh = 1.0 / 60
        for k in 0..<8 {
            r.display(k == 7 ? try bar(at: 200) : try bar(at: 186 + 2 * k), index: UInt64(k), arrival: Double(k) * frame)
            r.waitForInterpolation()
            _ = try renderHDR(r, size: (64, 36), now: Double(k) * frame)
            _ = try renderHDR(r, size: (64, 36), now: Double(k) * frame + refresh)
        }
        r.display(try bar(at: 300), index: 8, arrival: 8 * frame)
        r.waitForInterpolation()
        var seen: [(x: Double, peak: Float)] = []
        for step in 0..<12 {
            seen.append(centre(try renderHDR(r, size: (64, 36), now: 8 * frame + Double(step) * refresh)))
            if step == 0 { #expect(r.pipeline.interpolation == .on && r.hdrActive && r.missedInterpolations == 0) }
        }
        #expect(abs((seen.last?.x ?? 0) - 33) < 1.5, "\(seen)")
        let arrived = try #require(seen.firstIndex { abs($0.x - 33) < 1.5 }, "\(seen)")
        #expect(seen[..<arrived].contains { abs($0.x - 28) < 3 }, "no in-between image before the new frame: \(seen)")
        #expect(seen.allSatisfy { $0.peak > 3 }, "highlights clipped: \(seen)") // 1000 nits ≈ 4.9× SDR white
    }
}
