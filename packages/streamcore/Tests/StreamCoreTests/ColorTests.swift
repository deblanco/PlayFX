import CoreVideo
import Testing
@testable import StreamCore

@Suite struct ColorMathTests {
    let hd = FrameColor(matrix: .bt709, fullRange: false, siting: .left)

    func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tolerance: Float = 1e-3) -> Bool {
        ((a - b) * (a - b)).sum() < tolerance * tolerance
    }

    @Test func coefficientsPerMatrix() {
        let c = { (m: ColorMatrix) in YCbCrConversion(frame: hd, matrix: m, range: .auto, chroma: .bilinear).coefficients }
        #expect(close(c(.bt709), [1.5748, 0.1873, 0.4681, 1.8556]))
        #expect(close(c(.bt601), [1.402, 0.3441, 0.7141, 1.772]))
        #expect(close(c(.bt2020), [1.4746, 0.1646, 0.5714, 1.8814]))
        #expect(close(c(.smpte240m), [1.576, 0.2266, 0.4766, 1.826]))
        #expect(c(.auto) == c(.bt709)) // the frame says BT.709
    }

    @Test func limitedAndFullRange() {
        let limited = YCbCrConversion(frame: hd, matrix: .auto, range: .auto, chroma: .bilinear)
        #expect(limited.rgb(y: 235, cb: 128, cr: 128) == [1, 1, 1])
        #expect(limited.rgb(y: 16, cb: 128, cr: 128) == [0, 0, 0])
        let red = limited.rgb(y: 63, cb: 102, cr: 240)
        #expect(red.x > 0.99 && red.y < 0.01 && red.z < 0.01, "\(red)")

        let full = YCbCrConversion(frame: hd, matrix: .auto, range: .full, chroma: .bilinear)
        #expect(full.rgb(y: 255, cb: 128, cr: 128) == [1, 1, 1])
        #expect(abs(full.rgb(y: 16, cb: 128, cr: 128).x - 16.0 / 255) < 1e-4) // not crushed to black
        let fullFrame = FrameColor(matrix: .bt709, fullRange: true, siting: .left)
        #expect(YCbCrConversion(frame: fullFrame, matrix: .auto, range: .auto, chroma: .bilinear).range == full.range)
        #expect(YCbCrConversion(frame: fullFrame, matrix: .auto, range: .limited, chroma: .bilinear).range == limited.range)
    }

    @Test func chromaSitingAndFilter() {
        #expect(ChromaSiting.left.shift == [0.25, 0])
        #expect(ChromaSiting.center.shift == [0, 0])
        #expect(ChromaSiting.topLeft.shift == [0.25, 0.25])
        #expect(ChromaSiting.top.shift == [0, 0.25])
        #expect(ChromaSiting.bottomLeft.shift == [0.25, -0.25])
        #expect(ChromaSiting.bottom.shift == [0, -0.25])
        #expect(YCbCrConversion(frame: hd, matrix: .auto, range: .auto, chroma: .bicubic).chroma == [0.25, 0, 1, 0])
        #expect(YCbCrConversion(frame: hd, matrix: .auto, range: .auto, chroma: .bilinear).chroma == [0.25, 0, 0, 0])
    }

    @Test func readsTheFrameAttachments() throws {
        let tagged = try makeNV12(width: 64, height: 32, fullRange: true, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                                  siting: kCVImageBufferChromaLocation_TopLeft,
                                  luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
        #expect(FrameColor(tagged) == FrameColor(matrix: .bt2020, fullRange: true, siting: .topLeft))
        let sd601 = try makeNV12(width: 64, height: 32, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                                 siting: kCVImageBufferChromaLocation_Center,
                                 luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
        #expect(FrameColor(sd601) == FrameColor(matrix: .bt601, fullRange: false, siting: .center))
        let old = try makeNV12(width: 64, height: 32, matrix: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995,
                               luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
        #expect(FrameColor(old).matrix == .smpte240m)
        // Untagged: BT.601 below 720 lines, BT.709 from 720 up; chroma left-sited.
        let untaggedSD = try makeNV12(width: 64, height: 32, matrix: nil, siting: nil,
                                      luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
        #expect(FrameColor(untaggedSD) == FrameColor(matrix: .bt601, fullRange: false, siting: .left))
        let untaggedHD = try makeNV12(width: 16, height: 720, matrix: nil, siting: kCVImageBufferChromaLocation_DV420,
                                      luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
        #expect(FrameColor(untaggedHD) == FrameColor(matrix: .bt709, fullRange: false, siting: .left))
        for (tag, siting) in [(kCVImageBufferChromaLocation_Top, ChromaSiting.top),
                              (kCVImageBufferChromaLocation_Bottom, .bottom),
                              (kCVImageBufferChromaLocation_BottomLeft, .bottomLeft)] {
            let f = try makeNV12(width: 8, height: 8, siting: tag, luma: { _, _ in 0 }, chroma: { _, _ in (128, 128) })
            #expect(FrameColor(f).siting == siting)
        }
    }
}

extension StreamRendererTests {
    /// Red channel along the middle row of a mid-gray frame with the given Cr per chroma column,
    /// rendered 1:1 without sharpening.
    func redRow(_ params: RenderParams, siting: CFString = kCVImageBufferChromaLocation_Left,
                cr: @escaping (Int) -> UInt8) throws -> [Int] {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params = params
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.display(try makeNV12(width: 64, height: 64, siting: siting,
                               luma: { _, _ in 100 }, chroma: { x, _ in (128, cr(x)) }))
        let out = try render(r, size: (64, 64))
        return (0..<64).map { pixel(out, width: 64, x: $0, y: 32).r }
    }

    /// Chroma red on the left half, neutral on the right.
    func redAcrossChromaEdge(_ params: RenderParams, siting: CFString = kCVImageBufferChromaLocation_Left) throws -> [Int] {
        try redRow(params, siting: siting) { $0 < 16 ? 200 : 128 }
    }

    @Test func matrixOverrideChangesTheColors() throws {
        let r = try #require(StreamRenderer(inputWidth: 32, inputHeight: 32))
        r.showsTestPattern = false
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        let red = { try makeNV12(width: 32, height: 32, y: 63, cb: 102, cr: 240) } // BT.709 red, tagged 709
        r.display(try red())
        #expect(pixel(try render(r, size: (32, 32)), width: 32, x: 16, y: 16).r > 245)
        r.params.colorMatrix = .bt601
        r.display(try red())
        #expect(pixel(try render(r, size: (32, 32)), width: 32, x: 16, y: 16).r < 240)
    }

    @Test func bicubicChromaKeepsMoreColorDetail() throws {
        var bilinear = RenderParams(), bicubic = RenderParams()
        bilinear.chroma = .bilinear
        bicubic.chroma = .bicubic
        // Flat chroma: both filters agree.
        #expect(try redRow(bilinear) { _ in 160 } == redRow(bicubic) { _ in 160 })
        // Fine color detail (a 4-texel chroma wave): bilinear smooths it, bicubic keeps more of it.
        let wave: (Int) -> UInt8 = { [128, 200, 128, 56][$0 % 4] }
        let gray = try redRow(bilinear) { _ in 128 }[32]
        let detail = { (row: [Int]) in row[8..<56].map { abs($0 - gray) }.reduce(0, +) }
        let soft = try redRow(bilinear, cr: wave), sharp = try redRow(bicubic, cr: wave)
        #expect(detail(sharp) > detail(soft), "bicubic \(detail(sharp)) vs bilinear \(detail(soft))")
    }

    @Test func chromaSitingMovesTheEdge() throws {
        let params = RenderParams()
        let left = try redAcrossChromaEdge(params)
        let center = try redAcrossChromaEdge(params, siting: kCVImageBufferChromaLocation_Center)
        // Center-sited chroma sits a quarter chroma texel further right, so the edge is later.
        #expect(center[31] > left[31], "center \(center[31]) vs left \(left[31])")
    }

    @Test func accurateColorTagsTheView() throws {
        let r = try #require(StreamRenderer(inputWidth: 8, inputHeight: 8))
        #expect(r.view.colorspace?.name == CGColorSpace.sRGB)
        r.params.accurateColor = false
        #expect(r.view.colorspace == nil)
        r.params.accurateColor = true
        #expect(r.view.colorspace?.name == CGColorSpace.sRGB)
    }
}
