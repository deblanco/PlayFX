import Foundation

@testable import PlayFXProtocol

/// Synthetic H.264 / HEVC parameter sets and slices for the tests (built from the ITU-T syntax).
enum StreamFixtures {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    // MARK: H.264

    static func h264SPS(
        profile: Int = 77, log2FrameNumMinus4: Int = 3, pocType: Int = 2, scalingMatrix: Bool = false,
        frameMbsOnly: Bool = true, pocLsbMinus4: Int = 2
    ) -> [UInt8] {
        var w = BitWriter()
        w.bits(profile, 8)
        w.bits(0, 8)
        w.bits(50, 8)
        w.ue(0)
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            w.ue(3)  // chroma_format_idc 3
            w.bit(0)  // separate_colour_plane_flag
            w.ue(0)
            w.ue(0)
            w.bit(0)
            w.bit(scalingMatrix ? 1 : 0)
        }
        w.ue(log2FrameNumMinus4)
        w.ue(pocType)
        if pocType == 0 {
            w.ue(pocLsbMinus4)
        } else if pocType == 1 {
            w.bit(0)
            w.se(-1)
            w.se(2)
            w.ue(2)
            w.se(1)
            w.se(-3)
        }
        w.ue(9)
        w.bit(0)
        w.ue(119)
        w.ue(67)
        w.bit(frameMbsOnly ? 1 : 0)
        return w.finish()
    }

    static func h264PPS(redundant: Bool = false, sliceGroups: Bool = false) -> [UInt8] {
        var w = BitWriter()
        w.ue(0)
        w.ue(0)
        w.bit(1)
        w.bit(0)
        w.ue(sliceGroups ? 1 : 0)
        w.ue(0)
        w.ue(0)
        w.bit(0)
        w.bits(0, 2)
        w.se(0)
        w.se(0)
        w.se(0)
        w.bit(1)
        w.bit(0)
        w.bit(redundant ? 1 : 0)
        return w.finish()
    }

    static func h264Header(sps: [UInt8] = h264SPS(), pps: [UInt8] = h264PPS()) -> [UInt8] {
        startCode + [0x67] + escape(sps) + startCode + [0x68] + escape(pps)
    }

    /// One H.264 slice NAL unit (header byte included) with log2_max_frame_num 7, POC type 2.
    static func h264Slice(idr: Bool, sliceType: Int, frameNum: Int = 0, distance: Int? = nil) -> [UInt8] {
        var w = BitWriter()
        w.ue(0)
        w.ue(sliceType)
        w.ue(0)
        w.bits(frameNum, 7)
        if idr { w.ue(0) }
        if sliceType % 5 == 0 {
            w.bit(0)  // num_ref_idx_active_override_flag
            if let distance {
                w.bit(1)
                w.ue(0)
                w.ue(distance)
                w.ue(3)
            } else {
                w.bit(0)
            }
        }
        w.bits(0xaa55, 16)
        return [idr ? 0x65 : 0x41] + escape(w.bytes)
    }

    // MARK: HEVC

    static func hevcSPS(
        maxSubLayersMinus1: Int = 0, scalingList: Bool = false, pcm: Bool = false, numRps: Int = 0,
        subLayerOrdering: Bool = true, separateColourPlane: Bool = false
    ) -> [UInt8] {
        var w = BitWriter()
        w.bits(0, 4)
        w.bits(maxSubLayersMinus1, 3)
        w.bit(1)
        w.bits(0, 88)
        w.bits(150, 8)
        for _ in 0..<maxSubLayersMinus1 {
            w.bit(1)  // profile present
            w.bit(1)  // level present
        }
        if maxSubLayersMinus1 > 0 { w.bits(0, 2 * (8 - maxSubLayersMinus1)) }
        for _ in 0..<maxSubLayersMinus1 {
            w.bits(0, 88)
            w.bits(0, 8)
        }
        w.ue(0)
        w.ue(separateColourPlane ? 3 : 1)
        if separateColourPlane { w.bit(1) }
        w.ue(1920)
        w.ue(1088)
        w.bit(1)
        w.ue(0)
        w.ue(0)
        w.ue(0)
        w.ue(4)
        w.ue(0)
        w.ue(0)
        w.ue(0)  // log2_max_pic_order_cnt_lsb_minus4
        w.bit(subLayerOrdering ? 1 : 0)
        for _ in 0..<(subLayerOrdering ? maxSubLayersMinus1 + 1 : 1) {
            w.ue(9)
            w.ue(0)
            w.ue(0)
        }
        w.ue(0)
        w.ue(3)
        w.ue(0)
        w.ue(3)
        w.ue(3)
        w.ue(3)
        w.bit(scalingList ? 1 : 0)
        if scalingList {
            w.bit(1)
            for sizeId in 0..<4 {
                var matrixId = 0
                while matrixId < 6 {
                    if matrixId == 1 {
                        w.bit(0)
                        w.ue(1)
                    } else {
                        w.bit(1)
                        let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                        if sizeId > 1 { w.se(-3) }
                        for _ in 0..<coefNum { w.se(2) }
                    }
                    matrixId += sizeId == 3 ? 3 : 1
                }
            }
        }
        w.bit(1)
        w.bit(1)
        w.bit(pcm ? 1 : 0)
        if pcm {
            w.bits(7, 4)
            w.bits(7, 4)
            w.ue(0)
            w.ue(2)
            w.bit(1)
        }
        w.ue(numRps)
        return w.finish()
    }

    static func hevcPPS(dependent: Bool = false, output: Bool = false, extraBits: Int = 0) -> [UInt8] {
        var w = BitWriter()
        w.ue(0)
        w.ue(0)
        w.bit(dependent ? 1 : 0)
        w.bit(output ? 1 : 0)
        w.bits(extraBits, 3)
        return w.finish()
    }

    static func hevcHeader(sps: [UInt8] = hevcSPS(), pps: [UInt8] = hevcPPS()) -> [UInt8] {
        startCode + [0x40, 0x01, 0x0c, 0x01] + startCode + [0x42, 0x01] + escape(sps) + startCode + [0x44, 0x01]
            + escape(pps)
    }

    /// One HEVC slice NAL unit (2 header bytes included): TRAIL_R P/I or IDR_N_LP, POC LSB 4 bits.
    static func hevcSlice(
        type: Int, sliceType: Int, pocLsb: Int = 0, negatives: Int = 0, used: Int? = 0, firstDelta: Int = 0, tail: [UInt8] = [0xa5, 0x5a]
    ) -> [UInt8] {
        var w = BitWriter()
        w.bit(1)
        if type >= 16 { w.bit(0) }
        w.ue(0)
        w.ue(sliceType)
        if type != 19 && type != 20 {
            w.bits(pocLsb, 4)
            w.bit(0)
            w.ue(negatives)
            w.ue(0)
            for i in 0..<negatives {
                w.ue(i == 0 ? firstDelta : 0)
                w.bit(used == i ? 1 : 0)
            }
        }
        w.bits(0, 3)
        return [UInt8(type << 1), 1] + escape(w.bytes) + tail
    }
}
