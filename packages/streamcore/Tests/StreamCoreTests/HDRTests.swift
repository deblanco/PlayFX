import CoreVideo
import Metal
import Testing
@testable import StreamCore

/// A 10-bit (x420) frame with one Y/Cb/Cr 10-bit code, tagged BT.2020 + PQ unless `pq` is false.
func makeHDRFrame(width: Int, height: Int, y: UInt16, cb: UInt16 = 512, cr: UInt16 = 512, pq: Bool = true) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &out)
    let buffer = try #require(out)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    if pq {
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        for row in 0..<h {
            for col in 0..<w {
                if plane == 0 { base[row * stride + col] = y << 6 } else {
                    base[row * stride + col * 2] = cb << 6
                    base[row * stride + col * 2 + 1] = cr << 6
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

@Suite struct HDRTests {
    @Test func recognisesHDR10Frames() throws {
        #expect(FrameColor.isHDR(try makeHDRFrame(width: 16, height: 16, y: 500)))
        #expect(!FrameColor.isHDR(try makeHDRFrame(width: 16, height: 16, y: 500, pq: false))) // 10-bit SDR
        #expect(!FrameColor.isHDR(try makeNV12(width: 16, height: 16, y: 100, cb: 128, cr: 128)))
        #expect(FrameColor(try makeHDRFrame(width: 16, height: 16, y: 500)).pq)
    }

    @Test func showsPQLightLevelsAboveSDRWhite() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.setHDR(true)
        #expect(r.hdrActive)
        // 1000 nits: PQ signal ≈ 0.7518 → 10-bit limited code 64 + 0.7518 × 876 ≈ 723.
        r.display(try makeHDRFrame(width: 64, height: 64, y: 723))
        let device = r.commandQueue.device
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        let cb = try #require(r.commandQueue.makeCommandBuffer())
        r.encode(cb, pass: pass, drawableSize: CGSize(width: 64, height: 64))
        cb.commit()
        cb.waitUntilCompleted()
        var pixel = [Float16](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 64 * 8, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        let level = Float(pixel[1]) // green ≈ luminance for a neutral gray
        #expect(level > 4.3 && level < 5.6, "1000 nits should be ~4.9× SDR white, got \(level)")

        r.setHDR(false)
        #expect(!r.hdrActive)
    }
}
