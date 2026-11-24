import CoreVideo

/// YCbCr → RGB matrix. `auto` uses what the stream signals (the PS5 sends BT.709).
public enum ColorMatrix: String, Codable, Sendable {
    case auto, bt601, bt709, bt2020
    /// SMPTE 240M (old HD); only ever detected from a frame, not offered as a choice.
    case smpte240m

    /// Luma weights (Kr, Kb) of a concrete matrix.
    var weights: (kr: Float, kb: Float) {
        switch self {
        case .bt601: (0.299, 0.114)
        case .bt2020: (0.2627, 0.0593)
        case .smpte240m: (0.212, 0.087)
        case .auto, .bt709: (0.2126, 0.0722)
        }
    }
}

/// How the YCbCr values are scaled. `auto` uses the frame's pixel format.
public enum ColorRange: String, Codable, Sendable {
    case auto, limited, full
}

/// How the half-resolution chroma planes are brought up to luma resolution.
public enum ChromaFilter: String, Codable, Sendable {
    case bilinear, bicubic
}

/// Where chroma samples sit relative to luma, from `kCVImageBufferChromaLocation…`.
enum ChromaSiting: Equatable {
    case left, center, topLeft, top, bottomLeft, bottom

    /// Offset, in chroma texels, from center siting (what plain texel-center sampling assumes).
    var shift: SIMD2<Float> {
        switch self {
        case .left: [0.25, 0]
        case .center: [0, 0]
        case .topLeft: [0.25, 0.25]
        case .top: [0, 0.25]
        case .bottomLeft: [0.25, -0.25]
        case .bottom: [0, -0.25]
        }
    }
}

/// The colorimetry a decoded frame carries.
struct FrameColor: Equatable {
    var matrix: ColorMatrix
    var fullRange: Bool
    var siting: ChromaSiting
    /// HDR10: the samples carry the PQ (SMPTE ST 2084) transfer curve, so they decode to light levels.
    var pq = false
    /// 10-bit samples (HDR): read as 16-bit unorm, a code c is c·64/65535, so the range constants differ.
    var tenBit = false

    /// Reads the frame's attachments; missing ones fall back to what H.264/HEVC imply
    /// (BT.709 for HD, BT.601 for SD, limited range, left-sited chroma).
    init(_ frame: CVPixelBuffer) {
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(frame, key, nil).map { "\($0)" }
        }
        let signaled = attachment(kCVImageBufferYCbCrMatrixKey).flatMap { name in
            Self.matrices[name]
        }
        matrix = signaled ?? (CVPixelBufferGetHeight(frame) >= 720 ? .bt709 : .bt601)
        let format = CVPixelBufferGetPixelFormatType(frame)
        fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        pq = attachment(kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        siting = attachment(kCVImageBufferChromaLocationTopFieldKey).flatMap { name in
            Self.sitings[name]
        } ?? .left
    }

    // Attachment values → our types; built once, not per frame.
    private static let matrices: [String: ColorMatrix] = [
        kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String: .bt601,
        kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String: .smpte240m,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String: .bt709,
        kCVImageBufferYCbCrMatrix_ITU_R_2020 as String: .bt2020,
    ]
    private static let sitings: [String: ChromaSiting] = [
        kCVImageBufferChromaLocation_Center as String: .center,
        kCVImageBufferChromaLocation_TopLeft as String: .topLeft,
        kCVImageBufferChromaLocation_Top as String: .top,
        kCVImageBufferChromaLocation_BottomLeft as String: .bottomLeft,
        kCVImageBufferChromaLocation_Bottom as String: .bottom,
    ]

    init(matrix: ColorMatrix, fullRange: Bool, siting: ChromaSiting, pq: Bool = false) {
        self.matrix = matrix
        self.fullRange = fullRange
        self.siting = siting
        self.pq = pq
    }

    /// An HDR frame: 10-bit samples with the PQ curve. Rendering switches to float textures and EDR for it.
    static func isHDR(_ frame: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(frame)
        guard format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange else { return false }
        return CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil).map { "\($0)" }
            == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    }
}

/// The `nv12ToRGB` kernel's parameters (layout matches `YCbCrParams` in the shader).
struct YCbCrConversion: Equatable {
    /// Luma offset, luma scale, chroma offset, chroma scale.
    var range: SIMD4<Float>
    /// R←Cr, G←Cb, G←Cr, B←Cb.
    var coefficients: SIMD4<Float>
    /// Chroma siting shift (x, y), 1 for bicubic chroma, and 1 when the samples are PQ (HDR10).
    var chroma: SIMD4<Float>

    /// Applies the user's overrides to what the frame says.
    init(frame: FrameColor, matrix: ColorMatrix, range: ColorRange, chroma filter: ChromaFilter) {
        let m = matrix == .auto ? frame.matrix : matrix
        let full = range == .auto ? frame.fullRange : range == .full
        self.range = Self.range(full: full, tenBit: frame.tenBit)
        let (kr, kb) = m.weights
        let kg = 1 - kr - kb
        coefficients = [2 * (1 - kr), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg, 2 * (1 - kb)]
        let shift = frame.siting.shift
        chroma = [shift.x, shift.y, filter == .bicubic ? 1 : 0, frame.pq ? 1 : 0]
    }

    /// Luma offset and scale, chroma offset and scale, for samples as the shader reads them: 8-bit codes as
    /// c/255; 10-bit ones, high-bit aligned in 16-bit words, as c·64/65535 (not c/1023: 940, limited-range
    /// white, would read 0.4% low).
    static func range(full: Bool, tenBit: Bool) -> SIMD4<Float> {
        guard tenBit else {
            let mid: Float = 128.0 / 255, black: Float = 16.0 / 255
            if full { return [0, 1, mid, 1] }
            return [black, 255.0 / 219, mid, 255.0 / 224]
        }
        let unit: Float = 64.0 / 65535 // one 10-bit code step
        let codes: (black: Float, luma: Float, mid: Float, chroma: Float, max: Float) = (64, 876, 512, 896, 1023)
        return full
            ? [0, 1 / (codes.max * unit), codes.mid * unit, 1 / (codes.max * unit)]
            : [codes.black * unit, 1 / (codes.luma * unit), codes.mid * unit, 1 / (codes.chroma * unit)]
    }

    /// RGB for one (Y, Cb, Cr) triple of 8-bit codes — the shader's math, for tests and reference.
    func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> SIMD3<Float> {
        let l = (Float(y) / 255 - range.x) * range.y
        let b = (Float(cb) / 255 - range.z) * range.w
        let r = (Float(cr) / 255 - range.z) * range.w
        let c = coefficients
        let out = SIMD3<Float>(l + c.x * r, l - c.y * b - c.z * r, l + c.w * b)
        return out.clamped(lowerBound: .zero, upperBound: .one)
    }
}
