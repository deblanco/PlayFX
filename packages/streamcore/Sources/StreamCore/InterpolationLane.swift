import CoreVideo
import Foundation
import Metal
import os
import QuartzCore
import VideoToolbox

/// Makes in-between images away from the display: its own queue and Metal command queue, one pair at a
/// time, so making one never holds up a refresh. A pair that arrives while the last is still being made
/// goes without its image (counted). Per pair: skip across a scene cut; make the image at the size the
/// renderer asks for (scaling down first and back up after when that is smaller than the frames); then
/// blend areas that didn't change between the two frames back from them, since generated images are
/// lossy there (a HUD, subtitles). See docs/frame-interpolation.md.
final class InterpolationLane {
    struct Image {
        let buffer: CVPixelBuffer
        /// The stream-clock time it shows at (halfway between the pair).
        let time: Double
        /// Seconds from submitting the pair to the image being ready.
        let cost: Double
        let size: (width: Int, height: Int)
    }

    /// Called on the lane's queue with each image made.
    var onImage: ((Image) -> Void)?
    /// Pairs gone without an image: still making the last one, or a scene cut.
    var busyPairs: Int { state.withLock { $0.busyPairs } }
    var cutPairs: Int { state.withLock { $0.cutPairs } }

    private let queue = DispatchQueue(label: "streamcore.interpolation", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blendLuma: MTLComputePipelineState
    private let blendChroma: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var transfer: VTPixelTransferSession?
    private var interpolators: [String: FrameInterpolator] = [:]
    private var pools: [String: CVPixelBufferPool] = [:]
    private let state = OSAllocatedUnfairLock(initialState: (busy: false, busyPairs: 0, cutPairs: 0))

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaders, options: nil),
              let luma = library.makeFunction(name: "blendStaticLuma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let chroma = library.makeFunction(name: "blendStaticChroma").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        self.device = device
        commandQueue = queue
        blendLuma = luma
        blendChroma = chroma
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    /// Queues the pair (previous, current); false when the lane is still busy with the last one.
    @discardableResult
    func submit(previous: CVPixelBuffer, current: CVPixelBuffer, time: Double, size: (width: Int, height: Int)) -> Bool {
        let free = state.withLock { state in
            guard !state.busy else { state.busyPairs += 1; return false }
            state.busy = true
            return true
        }
        guard free else { return false }
        let started = CACurrentMediaTime()
        queue.async { [self] in
            defer { state.withLock { $0.busy = false } }
            if Self.isCut(previous, current) { state.withLock { $0.cutPairs += 1 }; return }
            guard let made = make(previous, current, size: size) else { return }
            onImage?(Image(buffer: made, time: time, cost: CACurrentMediaTime() - started, size: size))
        }
        return true
    }

    /// Waits until the pair in hand (if any) is done; for tests and shutdown.
    func waitUntilIdle() { queue.sync {} }

    /// Builds the size's interpolation model ahead of the first pair that needs it (1–2 s the first time).
    func prepare(size: (width: Int, height: Int)) {
        queue.async { [self] in _ = interpolator(size) }
    }

    private func interpolator(_ size: (width: Int, height: Int)) -> FrameInterpolator {
        let key = "\(size.width)x\(size.height)"
        if let made = interpolators[key] { return made }
        let made = FrameInterpolator()
        interpolators[key] = made
        return made
    }

    private func make(_ previous: CVPixelBuffer, _ current: CVPixelBuffer, size: (width: Int, height: Int)) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
        let scaled = size.width < width
        var a = previous, b = current
        if scaled {
            guard let sa = scale(previous, to: size), let sb = scale(current, to: size) else { return nil }
            a = sa
            b = sb
        }
        guard let cb = commandQueue.makeCommandBuffer(),
              var middle = interpolator(size).encode(cb, previous: a, current: b) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        if scaled {
            guard let full = scale(middle, to: (width, height)) else { return nil }
            CVBufferPropagateAttachments(current, full)
            middle = full
        }
        return blendStatic(previous, current, middle) ?? middle
    }

    /// The image with areas that didn't change between `a` and `b` taken from them instead.
    private func blendStatic(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ middle: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(middle), height = CVPixelBufferGetHeight(middle)
        guard CVPixelBufferGetWidth(a) == width, CVPixelBufferGetHeight(a) == height,
              let output = buffer(width, height, CVPixelBufferGetPixelFormatType(middle)),
              let ya = plane(a, 0, .r8Unorm), let yb = plane(b, 0, .r8Unorm), let ym = plane(middle, 0, .r8Unorm),
              let ca = plane(a, 1, .rg8Unorm), let cbt = plane(b, 1, .rg8Unorm), let cm = plane(middle, 1, .rg8Unorm),
              let yo = plane(output, 0, .r8Unorm), let co = plane(output, 1, .rg8Unorm),
              let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(blendLuma)
        for (i, t) in [ya, yb, ym, yo].enumerated() { enc.setTexture(t, index: i) }
        enc.dispatchThreads(MTLSize(width: yo.width, height: yo.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.setComputePipelineState(blendChroma)
        for (i, t) in [ya, yb, ca, cbt, cm, co].enumerated() { enc.setTexture(t, index: i) }
        enc.dispatchThreads(MTLSize(width: co.width, height: co.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        CVBufferPropagateAttachments(middle, output)
        return output
    }

    private func plane(_ buffer: CVPixelBuffer, _ index: Int, _ format: MTLPixelFormat) -> MTLTexture? {
        guard let textureCache else { return nil }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, index),
                                                  CVPixelBufferGetHeightOfPlane(buffer, index), index, &texture)
        return texture.flatMap(CVMetalTextureGetTexture)
    }

    private func scale(_ frame: CVPixelBuffer, to size: (width: Int, height: Int)) -> CVPixelBuffer? {
        guard let transfer, let out = buffer(size.width, size.height, CVPixelBufferGetPixelFormatType(frame)),
              VTPixelTransferSessionTransferImage(transfer, from: frame, to: out) == noErr else { return nil }
        return out
    }

    private func buffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)-\(format)"
        if pools[key] == nil {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// Whether the pair is across a cut, from their luma on a coarse grid.
    static func isCut(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(b), height = CVPixelBufferGetHeight(b)
        guard CVPixelBufferGetWidth(a) == width, CVPixelBufferGetHeight(a) == height,
              CVPixelBufferGetPlaneCount(a) > 0, CVPixelBufferGetPlaneCount(b) > 0 else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        return SceneCut.isCut(width: width, height: height, a: { pa[$1 * ra + $0] }, b: { pb[$1 * rb + $0] })
    }

    /// Where |A − B| is small (the area didn't change), the output is the average of A and B; where it
    /// changed, the generated image; a soft ramp in between. Chroma follows the luma of its 2×2 block.
    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    constant float lo = 2.0 / 255.0, hi = 8.0 / 255.0;
    kernel void blendStaticLuma(texture2d<float, access::read> ya [[texture(0)]],
                                texture2d<float, access::read> yb [[texture(1)]],
                                texture2d<float, access::read> ym [[texture(2)]],
                                texture2d<float, access::write> yo [[texture(3)]],
                                uint2 g [[thread_position_in_grid]]) {
        if (g.x >= yo.get_width() || g.y >= yo.get_height()) return;
        float a = ya.read(g).r, b = yb.read(g).r;
        float moved = smoothstep(lo, hi, abs(a - b));
        yo.write(float4(mix((a + b) * 0.5, ym.read(g).r, moved)), g);
    }
    kernel void blendStaticChroma(texture2d<float, access::read> ya [[texture(0)]],
                                  texture2d<float, access::read> yb [[texture(1)]],
                                  texture2d<float, access::read> ca [[texture(2)]],
                                  texture2d<float, access::read> cb [[texture(3)]],
                                  texture2d<float, access::read> cm [[texture(4)]],
                                  texture2d<float, access::write> co [[texture(5)]],
                                  uint2 g [[thread_position_in_grid]]) {
        if (g.x >= co.get_width() || g.y >= co.get_height()) return;
        float d = 0;
        for (uint j = 0; j < 2; j++) for (uint i = 0; i < 2; i++) {
            uint2 p = min(g * 2 + uint2(i, j), uint2(ya.get_width() - 1, ya.get_height() - 1));
            d = max(d, abs(ya.read(p).r - yb.read(p).r));
        }
        float moved = smoothstep(lo, hi, d);
        float2 still = (ca.read(g).rg + cb.read(g).rg) * 0.5;
        co.write(float4(mix(still, cm.read(g).rg, moved), 0, 0), g);
    }
    """
}
