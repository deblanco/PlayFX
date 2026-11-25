/// The video codecs of a stream.
public enum VideoCodec: Sendable, Equatable {
    case h264
    case hevc
}

/// The SPS/PPS fields the slice-header parsers need (av.md section 5). Parsing gives up (returns nil) where the
/// reference clients do, and on anything malformed.
struct H264Parameters: Equatable {
    var log2MaxFrameNum: Int
    var frameMbsOnly: Bool
    var pocType: Int
    var log2MaxPocLsb: Int
    var deltaPicOrderAlwaysZero: Bool
    var separateColourPlane: Bool
    var bottomFieldPicOrderInFramePresent: Bool
    var redundantPicCntPresent: Bool

    private static let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// `sps` and `pps` are the NAL unit bodies without the header byte, emulation prevention removed.
    static func parse(sps: [UInt8], pps: [UInt8]) -> H264Parameters? {
        var r = BitReader(sps)
        let profile = r.bits(8)
        r.skip(16)  // constraint flags, level_idc
        _ = r.ue()  // seq_parameter_set_id
        var separate = false
        if highProfiles.contains(profile) {
            let chromaFormat = r.ue()
            if chromaFormat == 3 { separate = r.bit() == 1 }
            _ = r.ue()
            _ = r.ue()
            r.skip(1)  // qpprime_y_zero_transform_bypass_flag
            if r.bit() == 1 { return nil }  // seq_scaling_matrix_present_flag
        }
        let log2FrameNum = Int(r.ue()) + 4
        guard !r.overrun, log2FrameNum - 4 <= 12 else { return nil }
        let pocType = Int(r.ue())
        var log2Poc = 0
        var alwaysZero = false
        switch pocType {
        case 0:
            log2Poc = Int(r.ue()) + 4
            if log2Poc - 4 > 12 { return nil }
        case 1:
            alwaysZero = r.bit() == 1
            _ = r.se()
            _ = r.se()
            let cycle = r.ue()
            if cycle > 255 { return nil }
            for _ in 0..<cycle { _ = r.se() }
        case 2: break
        default: return nil
        }
        _ = r.ue()  // max_num_ref_frames
        r.skip(1)  // gaps_in_frame_num_value_allowed_flag
        _ = r.ue()  // pic_width_in_mbs_minus1
        _ = r.ue()  // pic_height_in_map_units_minus1
        let frameMbsOnly = r.bit() == 1
        guard !r.overrun else { return nil }

        var p = BitReader(pps)
        _ = p.ue()  // pic_parameter_set_id
        _ = p.ue()  // seq_parameter_set_id
        p.skip(1)  // entropy_coding_mode_flag
        let bottomPresent = p.bit() == 1
        if p.ue() != 0 { return nil }  // slice groups (FMO) are not used by consoles
        _ = p.ue()
        _ = p.ue()
        p.skip(1 + 2)  // weighted_pred_flag, weighted_bipred_idc
        _ = p.se()
        _ = p.se()
        _ = p.se()
        p.skip(2)  // deblocking_filter_control_present_flag, constrained_intra_pred_flag
        let redundant = p.bit() == 1
        guard !p.overrun else { return nil }

        return H264Parameters(
            log2MaxFrameNum: log2FrameNum, frameMbsOnly: frameMbsOnly, pocType: pocType, log2MaxPocLsb: log2Poc,
            deltaPicOrderAlwaysZero: alwaysZero, separateColourPlane: separate,
            bottomFieldPicOrderInFramePresent: bottomPresent, redundantPicCntPresent: redundant)
    }
}

struct HEVCParameters: Equatable {
    var separateColourPlane: Bool
    var log2MaxPocLsb: Int
    var numShortTermRefPicSets: Int
    var dependentSliceSegmentsEnabled: Bool
    var outputFlagPresent: Bool
    var numExtraSliceHeaderBits: Int
    /// `Ceil(Log2(PicSizeInCtbsY))`: the width of `slice_segment_address`.
    var sliceAddressBits: Int

    /// `sps` and `pps` are the NAL unit bodies without the 2-byte header, emulation prevention removed.
    static func parse(sps: [UInt8], pps: [UInt8]) -> HEVCParameters? {
        var r = BitReader(sps)
        r.skip(4)  // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(r.bits(3))
        guard maxSubLayersMinus1 <= 6 else { return nil }
        r.skip(1)  // sps_temporal_id_nesting_flag
        // profile_tier_level(1, maxSubLayersMinus1): 88 bits of general profile, then general_level_idc.
        r.skip(88 + 8)
        var profilePresent: UInt8 = 0
        var levelPresent: UInt8 = 0
        for i in 0..<maxSubLayersMinus1 {
            if r.bit() == 1 { profilePresent |= 1 << UInt8(i) }
            if r.bit() == 1 { levelPresent |= 1 << UInt8(i) }
        }
        if maxSubLayersMinus1 > 0 { r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent & (1 << UInt8(i)) != 0 { r.skip(88) }
            if levelPresent & (1 << UInt8(i)) != 0 { r.skip(8) }
        }
        _ = r.ue()  // sps_seq_parameter_set_id
        let chromaFormat = r.ue()
        var separate = false
        if chromaFormat == 3 { separate = r.bit() == 1 }
        let width = Int(r.ue())
        let height = Int(r.ue())
        if r.bit() == 1 {  // conformance_window_flag
            for _ in 0..<4 { _ = r.ue() }
        }
        _ = r.ue()  // bit_depth_luma_minus8
        _ = r.ue()  // bit_depth_chroma_minus8
        let log2Poc = Int(r.ue()) + 4
        guard !r.overrun, log2Poc - 4 <= 12 else { return nil }
        let orderingInfoPresent = r.bit() == 1
        for _ in (orderingInfoPresent ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = r.ue()
            _ = r.ue()
            _ = r.ue()
        }
        let log2MinCb = Int(r.ue()) + 3
        let log2DiffCb = Int(r.ue())
        _ = r.ue()  // log2_min_luma_transform_block_size_minus2
        _ = r.ue()  // log2_diff_max_min_luma_transform_block_size
        _ = r.ue()  // max_transform_hierarchy_depth_inter
        _ = r.ue()  // max_transform_hierarchy_depth_intra
        guard !r.overrun, log2MinCb + log2DiffCb <= 30 else { return nil }
        if r.bit() == 1 {  // scaling_list_enabled_flag
            if r.bit() == 1 { skipScalingListData(&r) }
        }
        r.skip(2)  // amp_enabled_flag, sample_adaptive_offset_enabled_flag
        if r.bit() == 1 {  // pcm_enabled_flag
            r.skip(8)
            _ = r.ue()
            _ = r.ue()
            r.skip(1)
        }
        let numRps = r.ue()
        guard !r.overrun, numRps <= 64 else { return nil }

        var p = BitReader(pps)
        _ = p.ue()  // pps_pic_parameter_set_id
        _ = p.ue()  // pps_seq_parameter_set_id
        let dependent = p.bit() == 1
        let output = p.bit() == 1
        let extraBits = Int(p.bits(3))
        guard !p.overrun else { return nil }

        let ctbSize = 1 << (log2MinCb + log2DiffCb)
        let ctbs = ((width + ctbSize - 1) / ctbSize) * ((height + ctbSize - 1) / ctbSize)
        var addressBits = 0
        while (1 << addressBits) < ctbs { addressBits += 1 }

        return HEVCParameters(
            separateColourPlane: separate, log2MaxPocLsb: log2Poc, numShortTermRefPicSets: Int(numRps),
            dependentSliceSegmentsEnabled: dependent, outputFlagPresent: output,
            numExtraSliceHeaderBits: extraBits, sliceAddressBits: addressBits)
    }

    /// `scaling_list_data()` (H.265 section 7.3.4).
    private static func skipScalingListData(_ r: inout BitReader) {
        for sizeId in 0..<4 {
            var matrixId = 0
            while matrixId < 6 {
                if r.bit() == 0 {
                    _ = r.ue()  // scaling_list_pred_matrix_id_delta
                } else {
                    let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 { _ = r.se() }
                    for _ in 0..<coefNum { _ = r.se() }
                }
                matrixId += sizeId == 3 ? 3 : 1
            }
        }
    }
}

/// What the receiver keeps per stream-info resolution: the codec (from the video header) and the parsed
/// parameter sets, if they could be parsed.
struct VideoProfileInfo {
    var codec: VideoCodec?
    var h264: H264Parameters?
    var hevc: HEVCParameters?

    /// Looks at the Annex-B parameter sets of a video header (av.md section 4.2).
    /// `codec`: the negotiated codec; when nil it is detected from the header's first NAL unit.
    init(header: [UInt8], codec negotiated: VideoCodec? = nil) {
        codec = negotiated
        header.withUnsafeBytes { raw in
            let nals = AnnexB.nalUnits(in: raw)
            func find(_ match: (UInt8) -> Bool, headerBytes: Int) -> [UInt8]? {
                for range in nals where range.count > headerBytes && match(raw[range.lowerBound]) {
                    return NALEscape.unescape(UnsafeRawBufferPointer(rebasing: raw[(range.lowerBound + headerBytes)..<range.upperBound]))
                }
                return nil
            }
            guard let first = nals.first.map({ raw[$0.lowerBound] }) else { return }
            let detected: VideoCodec? = (first >> 1) & 0x3f == 32 ? .hevc : (first & 0x1f == 7 ? .h264 : nil)
            let chosen = negotiated ?? detected
            if chosen == .hevc {
                codec = .hevc
                if let sps = find({ ($0 >> 1) & 0x3f == 33 }, headerBytes: 2),
                    let pps = find({ ($0 >> 1) & 0x3f == 34 }, headerBytes: 2)
                {
                    hevc = HEVCParameters.parse(sps: sps, pps: pps)
                }
            } else if chosen == .h264 {
                codec = .h264
                if let sps = find({ $0 & 0x1f == 7 }, headerBytes: 1),
                    let pps = find({ $0 & 0x1f == 8 }, headerBytes: 1)
                {
                    h264 = H264Parameters.parse(sps: sps, pps: pps)
                }
            }
        }
    }
}
