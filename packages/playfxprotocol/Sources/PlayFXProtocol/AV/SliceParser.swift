enum SliceKind: Equatable, Sendable {
    case p
    case i
    /// Any other slice type: no IDR or reference logic applies to it.
    case other
}

/// What the receiver reads from the first slice of an access unit (av.md section 5).
struct SliceInfo: Equatable {
    var kind: SliceKind
    var isIDR: Bool
    /// P slices: the picture referenced is `referenceDistance + 1` frames back. Nil when unknown.
    var referenceDistance: Int?
    var nalType = 0
    /// HEVC P slices: `num_negative_pics`.
    var numNegativePics = 0
    /// HEVC P slices: bit position, in the access unit as transmitted (escaped), of each
    /// `used_by_curr_pic_s0_flag`. Positions are counted from the first byte of the access unit, MSB first.
    var usedFlagBits = SIMD16<Int32>(repeating: 0)
}

/// Slice header parsing and the HEVC reference rewrite. Holds scratch buffers, so it isn't thread safe and
/// allocates nothing once warm.
final class SliceParser {
    /// Only the first start code within this many bytes is looked at (av.md section 5).
    static let searchLimit = 64
    /// How much of a NAL unit is un-escaped for header parsing (the headers are a few dozen bytes).
    static let headerLimit = 160
    /// HEVC: `num_negative_pics` above this is rejected.
    static let maxNegativePics = 16

    private var rbsp: [UInt8] = []
    private var origin: [Int] = []

    init() {
        rbsp.reserveCapacity(Self.headerLimit)
        origin.reserveCapacity(Self.headerLimit)
    }

    /// Parses the first slice NAL unit of `au`. Nil when there is no start code in the first 64 bytes, the
    /// NAL type isn't one of the slice types, or the header doesn't parse.
    func firstSlice(
        in au: UnsafeRawBufferPointer, codec: VideoCodec, h264: H264Parameters?, hevc: HEVCParameters?
    ) -> SliceInfo? {
        guard let nal = Self.fourByteStartCode(in: au) else { return nil }
        switch codec {
        case .h264:
            guard let h264 else { return nil }
            return parseH264(au, nal: nal, h264)
        case .hevc:
            guard let hevc else { return nil }
            return parseHEVC(au, nal: nal, hevc)
        }
    }

    /// The NAL header offset after the first 4-byte start code `00 00 00 01` that begins at offset 0...64
    /// (av.md 4.3: a 3-byte start code isn't found).
    static func fourByteStartCode(in au: UnsafeRawBufferPointer) -> Int? {
        guard au.count >= 4 else { return nil }
        for i in 0...min(searchLimit, au.count - 4)
        where au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 0 && au[i + 3] == 1 {
            return i + 4
        }
        return nil
    }

    // MARK: H.264 (section 7.3.3)

    private func parseH264(_ au: UnsafeRawBufferPointer, nal: Int, _ p: H264Parameters) -> SliceInfo? {
        guard nal < au.count else { return nil }
        let type = au[nal] & 0x1f
        guard type == 1 || type == 5 else { return nil }
        let isIDR = type == 5
        NALEscape.unescape(au, from: nal + 1, limit: Self.headerLimit, into: &rbsp, origin: &origin)
        var r = BitReader(rbsp)
        _ = r.ue()  // first_mb_in_slice
        let sliceType = Int(r.ue())
        guard !r.overrun, sliceType < 10 else { return nil }
        let t = sliceType % 5
        let kind: SliceKind = t == 0 ? .p : (t == 2 ? .i : .other)
        var info = SliceInfo(kind: kind, isIDR: isIDR, referenceDistance: nil, nalType: Int(type))
        if kind != .p { return info }

        _ = r.ue()  // pic_parameter_set_id
        if p.separateColourPlane { r.skip(2) }
        r.skip(p.log2MaxFrameNum)
        var fieldPic = false
        if !p.frameMbsOnly {
            fieldPic = r.bit() == 1
            if fieldPic { r.skip(1) }
        }
        if isIDR { _ = r.ue() }  // idr_pic_id
        if p.pocType == 0 {
            r.skip(p.log2MaxPocLsb)
            if p.bottomFieldPicOrderInFramePresent && !fieldPic { _ = r.se() }
        } else if p.pocType == 1 && !p.deltaPicOrderAlwaysZero {
            _ = r.se()
            if p.bottomFieldPicOrderInFramePresent && !fieldPic { _ = r.se() }
        }
        if p.redundantPicCntPresent { _ = r.ue() }
        if r.bit() == 1 { _ = r.ue() }  // num_ref_idx_active_override_flag, num_ref_idx_l0_active_minus1

        var distance = 0
        if r.bit() == 1 {  // ref_pic_list_modification_flag_l0
            var entry = 0
            while true {
                let idc = r.ue()
                if idc == 3 { break }
                guard idc < 3, entry < 2 else { return nil }  // at most two entries parse
                let value = r.ue()
                if idc == 0 { distance = Int(min(value, 0xffff)) }
                entry += 1
                if r.overrun { return nil }
            }
        }
        guard !r.overrun else { return nil }
        info.referenceDistance = distance
        return info
    }

    // MARK: HEVC (section 7.3.6.1)

    private func parseHEVC(_ au: UnsafeRawBufferPointer, nal: Int, _ p: HEVCParameters) -> SliceInfo? {
        guard nal + 2 <= au.count else { return nil }
        let type = Int(au[nal] >> 1) & 0x3f
        guard type == 1 || type == 20 else { return nil }
        let isIDR = type == 20
        NALEscape.unescape(au, from: nal + 2, limit: Self.headerLimit, into: &rbsp, origin: &origin)
        var r = BitReader(rbsp)
        let first = r.bit() == 1  // first_slice_segment_in_pic_flag
        if type >= 16 && type <= 23 { r.skip(1) }  // no_output_of_prior_pics_flag
        _ = r.ue()  // slice_pic_parameter_set_id
        if !first {
            if p.dependentSliceSegmentsEnabled && r.bit() == 1 { return nil }
            r.skip(p.sliceAddressBits)
        }
        r.skip(p.numExtraSliceHeaderBits)
        let sliceType = r.ue()
        guard !r.overrun, sliceType <= 2 else { return nil }
        let kind: SliceKind = sliceType == 1 ? .p : (sliceType == 2 ? .i : .other)
        var info = SliceInfo(kind: kind, isIDR: isIDR, referenceDistance: nil, nalType: Int(type))
        if kind != .p { return info }

        if p.outputFlagPresent { r.skip(1) }
        if p.separateColourPlane { r.skip(2) }
        if isIDR { return info }
        r.skip(p.log2MaxPocLsb)  // slice_pic_order_cnt_lsb
        if r.bit() == 1 { return r.overrun ? nil : info }  // short_term_ref_pic_set_sps_flag: RPS in the SPS
        if p.numShortTermRefPicSets > 0 && r.bit() == 1 { return r.overrun ? nil : info }  // predicted RPS
        let negatives = Int(r.ue())
        let positives = Int(r.ue())
        guard !r.overrun, negatives <= Self.maxNegativePics, positives <= Self.maxNegativePics else { return nil }
        info.numNegativePics = negatives
        for i in 0..<negatives {
            _ = r.ue()  // delta_poc_s0_minus1
            let flagPosition = r.position
            let used = r.bit() == 1
            guard !r.overrun else { return nil }
            let byte = origin[flagPosition >> 3]
            info.usedFlagBits[i] = Int32(byte * 8 + (flagPosition & 7))
            if used && info.referenceDistance == nil { info.referenceDistance = i }
        }
        return info
    }

    // MARK: HEVC rewrite (av.md section 5.3)

    /// Makes the P slice described by `info` reference negative picture `newDistance` instead: its
    /// `used_by_curr_pic_s0_flag` is set and those before it are cleared. Fails, leaving `au` untouched, when
    /// `newDistance` isn't below `num_negative_pics` (or above 15), or when flipping the bits would form or
    /// break an emulation-prevention sequence.
    func rewriteHEVCReference(
        _ au: UnsafeMutableBufferPointer<UInt8>, info: SliceInfo, to newDistance: Int
    ) -> Bool {
        guard info.kind == .p, info.nalType == 1, newDistance >= 0, newDistance <= 15, newDistance < info.numNegativePics else {
            return false
        }
        var touched = SIMD16<Int32>(repeating: -1)
        var originals = SIMD16<UInt8>(repeating: 0)
        var count = 0
        var ok = true
        for i in 0...newDistance {
            let position = Int(info.usedFlagBits[i])
            let index = position >> 3
            guard index < au.count else {
                ok = false
                break
            }
            let mask = UInt8(0x80) >> UInt8(position & 7)
            if !(0..<count).contains(where: { touched[$0] == Int32(index) }) {
                touched[count] = Int32(index)
                originals[count] = au[index]
                count += 1
            }
            if i == newDistance { au[index] |= mask } else { au[index] &= ~mask }
        }
        if ok {
            for c in 0..<count {
                let index = Int(touched[c])
                let old = originals[c]
                let new = au[index]
                if old == new { continue }
                if old == 0 || new == 0 || (new <= 3 && index >= 2 && au[index - 1] == 0 && au[index - 2] == 0) {
                    ok = false
                    break
                }
            }
        }
        if !ok {
            for c in 0..<count { au[Int(touched[c])] = originals[c] }
        }
        return ok
    }
}
