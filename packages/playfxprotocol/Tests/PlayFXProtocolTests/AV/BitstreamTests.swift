import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite("AV: bitstream facts")
struct BitstreamTests {
    let slices = SliceParser()
    let h264 = H264Parameters(
        log2MaxFrameNum: 7, frameMbsOnly: true, pocType: 2, log2MaxPocLsb: 0, deltaPicOrderAlwaysZero: false,
        separateColourPlane: false, bottomFieldPicOrderInFramePresent: false, redundantPicCntPresent: false)
    let hevc = HEVCParameters(
        separateColourPlane: false, log2MaxPocLsb: 4, numShortTermRefPicSets: 0, dependentSliceSegmentsEnabled: false,
        outputFlagPresent: false, numExtraSliceHeaderBits: 0, sliceAddressBits: 0)

    func parse(_ au: [UInt8], _ codec: VideoCodec) -> SliceInfo? {
        withBytes(au) { slices.firstSlice(in: $0, codec: codec, h264: h264, hevc: hevc) }
    }

    @Test("V-AV12: H.264 slice parse")
    func h264Vectors() {
        let p9 = parse(hex("00000001419a25988a55ac33c966996698"), .h264)
        #expect(p9?.kind == .p)
        #expect(p9?.referenceDistance == 5)
        let p10 = parse(hex("00000001419a28a55ac33c9669966980"), .h264)
        #expect(p10?.kind == .p)
        #expect(p10?.referenceDistance == 0)
        let idr = parse(hex("00000001658880d2ad619e4b34cb34c0"), .h264)
        #expect(idr?.kind == .i)
        #expect(idr?.isIDR == true)
    }

    @Test("V-AV11: HEVC slice parse")
    func hevcVectors() {
        let p = parse(hex("000000010201d28beaa55ac33c9669966980"), .hevc)
        #expect(p?.kind == .p)
        #expect(p?.referenceDistance == 0)
        #expect(p?.numNegativePics == 4)
        let idr = parse(hex("000000012801ae956b0cf259a659a6"), .hevc)
        #expect(idr?.kind == .i)
        #expect(idr?.isIDR == true)
    }

    @Test("V-AV11: HEVC reference rewrite, bytes and re-parse")
    func hevcRewrite() throws {
        let original = hex("000000010201d28beaa55ac33c9669966980")
        let expected = [
            1: "000000010201d28bbaa55ac33c9669966980",
            2: "000000010201d28baea55ac33c9669966980",
            3: "000000010201d28baba55ac33c9669966980",
        ]
        for (d, text) in expected.sorted(by: { $0.key < $1.key }) {
            var au = original
            let info = try #require(parse(au, .hevc))
            let ok = au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: info, to: d) }
            #expect(ok)
            #expect(au == hex(text))
            #expect(parse(au, .hevc)?.referenceDistance == d)
        }
        var au = original
        let info = try #require(parse(au, .hevc))
        #expect(!au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: info, to: 4) })
        #expect(au == original)
        #expect(!au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: info, to: -1) })
        #expect(!au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: info, to: 16) })
        var other = info
        other.kind = .i
        #expect(!au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: other, to: 1) })
    }

    @Test("a rewrite that would form or break an emulation-prevention pattern is refused")
    func rewriteRefusals() throws {
        // Clearing the only set bit of a byte would make it 0x00: refused, bytes untouched.
        var zeroing: [UInt8] = [0xff, 0x80, 0x01]
        var fake = SliceInfo(kind: .p, isIDR: false, referenceDistance: 0, nalType: 1)
        fake.numNegativePics = 2
        fake.usedFlagBits[0] = 8
        fake.usedFlagBits[1] = 23
        #expect(!zeroing.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: fake, to: 1) })
        #expect(zeroing == [0xff, 0x80, 0x01])

        // A byte after `00 00` that would become 0x01..0x03 would form a forbidden pattern.
        var forged: [UInt8] = [0, 0, 0x02, 0, 0, 0, 0, 0]
        fake.usedFlagBits[0] = 2 * 8 + 6
        fake.usedFlagBits[1] = 2 * 8 + 7
        #expect(!forged.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: fake, to: 1) })
        #expect(forged == [0, 0, 0x02, 0, 0, 0, 0, 0])

        // The same change in a byte not preceded by two zeros is fine.
        var fine: [UInt8] = [0, 1, 0x02, 0, 0, 0, 0, 0]
        #expect(fine.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: fake, to: 1) })
        #expect(fine == [0, 1, 0x01, 0, 0, 0, 0, 0])

        // A flag position beyond the buffer is refused too.
        var short = [UInt8](repeating: 1, count: 2)
        fake.usedFlagBits[0] = 100
        #expect(!short.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: fake, to: 1) })
    }

    @Test("a rewrite across an inserted emulation-prevention byte flips the right bits (positions + 8)")
    func rewriteWithEscapedBytes() throws {
        // delta_poc_s0_minus1[0] = 5,000,000 has 22 leading zero bits, starting on a byte boundary: two zero
        // bytes and then 0x02, so an 0x03 is inserted before the flags that follow.
        func slice(used: Int) -> [UInt8] {
            annexB(StreamFixtures.hevcSlice(type: 1, sliceType: 1, pocLsb: 0, negatives: 4, used: used, firstDelta: 5_000_000))
        }
        let original = slice(used: 0)
        let escapeAt = try #require((0..<original.count - 2).first { original[$0] == 0 && original[$0 + 1] == 0 && original[$0 + 2] == 3 })
        var au = original
        let info = try #require(parse(au, .hevc))
        #expect(info.numNegativePics == 4)
        #expect(info.referenceDistance == 0)
        // All four flag positions lie after the inserted byte, so each is shifted by 8 bits.
        for i in 0..<4 { #expect(Int(info.usedFlagBits[i]) / 8 > escapeAt + 2) }
        #expect(au.withUnsafeMutableBufferPointer { slices.rewriteHEVCReference($0, info: info, to: 2) })
        #expect(au == slice(used: 2))
        // Exactly two bits changed: flag 0 cleared, flag 2 set.
        let changedBits = zip(au, original).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        #expect(changedBits == 2)
        #expect(Array(au[0...(escapeAt + 2)]) == Array(original[0...(escapeAt + 2)]))
        #expect(parse(au, .hevc)?.referenceDistance == 2)
    }

    @Test("the un-escape stops at the next start code")
    func unescapeStops() {
        var rbsp: [UInt8] = []
        var origin: [Int] = []
        let bytes: [UInt8] = [1, 0, 0, 3, 5, 0, 0, 0, 1, 9, 9]
        bytes.withUnsafeBytes { NALEscape.unescape($0, from: 0, limit: 100, into: &rbsp, origin: &origin) }
        #expect(rbsp == [1, 0, 0, 5, 0, 0])
        #expect(origin == [0, 1, 2, 4, 5, 6])
    }

    @Test("unparseable access units give nil")
    func unparseable() {
        #expect(parse([], .h264) == nil)
        #expect(parse([1, 2, 3, 4, 5, 6, 7], .h264) == nil)  // no start code
        #expect(parse(annexB([0x67, 1, 2, 3]), .h264) == nil)  // SPS, not a slice
        #expect(parse(annexB([0x44, 0x01, 1, 2, 3]), .hevc) == nil)  // PPS
        #expect(parse(annexB([0x41]), .h264) == nil)  // truncated header
        #expect(parse(annexB([0x02]), .hevc) == nil)
        #expect(parse(annexB([0x02, 0x01]), .hevc) == nil)
        #expect(parse([UInt8](repeating: 0xff, count: 70) + annexB([0x41, 0x9a]), .h264) == nil)  // start code past 64
        #expect(parse([0, 0, 1, 0x41, 0x9a, 0x28, 0xa5], .h264) == nil)  // 3-byte start code
        #expect(parse([UInt8](repeating: 0xff, count: 64) + annexB(StreamFixtures.h264Slice(idr: true, sliceType: 7)), .h264)?.kind == .i)  // begins at 64
        #expect(parse([UInt8](repeating: 0xff, count: 65) + annexB(StreamFixtures.h264Slice(idr: true, sliceType: 7)), .h264) == nil)
        #expect(withBytes(annexB([0x41, 0x9a])) { slices.firstSlice(in: $0, codec: .h264, h264: nil, hevc: nil) } == nil)
        #expect(withBytes(annexB([0x41, 0x9a])) { slices.firstSlice(in: $0, codec: .hevc, h264: nil, hevc: nil) } == nil)
        // slice_type 12 is invalid.
        var w = BitWriter()
        w.ue(0)
        w.ue(12)
        #expect(parse(annexB([0x41] + w.finish()), .h264) == nil)
    }

    @Test("H.264 slices: kinds, three-entry modification limit, other list entries, fields and POC types")
    func h264Variants() {
        func slice(_ nal: [UInt8]) -> SliceInfo? { parse(annexB(nal), .h264) }
        #expect(slice(StreamFixtures.h264Slice(idr: false, sliceType: 0, frameNum: 9, distance: 5))?.referenceDistance == 5)
        #expect(slice(StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 9))?.kind == .p)
        #expect(slice(StreamFixtures.h264Slice(idr: true, sliceType: 7))?.kind == .i)
        #expect(slice(StreamFixtures.h264Slice(idr: false, sliceType: 1))?.kind == .other)  // B
        #expect(slice(StreamFixtures.h264Slice(idr: false, sliceType: 3))?.kind == .other)  // SP

        // At most two modification entries parse; d is the value of the last idc-0 entry, else 0.
        func list(_ entries: [(Int, Int)]) -> SliceInfo? {
            var w = BitWriter()
            w.ue(0)
            w.ue(0)
            w.ue(0)
            w.bits(1, 7)
            w.bit(1)  // override flag
            w.ue(2)
            w.bit(1)
            for (idc, value) in entries {
                w.ue(idc)
                w.ue(value)
            }
            w.ue(3)
            return slice([0x41] + w.finish())
        }
        #expect(list([(1, 4), (0, 7)])?.referenceDistance == 7)
        #expect(list([(0, 2), (1, 4)])?.referenceDistance == 2)
        #expect(list([(0, 2), (0, 6)])?.referenceDistance == 6)
        #expect(list([(1, 4), (2, 4)])?.referenceDistance == 0)
        #expect(list([(0, 2), (1, 4), (0, 9)]) == nil)  // three entries
        #expect(list([(4, 1)]) == nil)  // idc above 3

        // idc above 3, and a list that never ends, are errors.
        var bad = BitWriter()
        bad.ue(0)
        bad.ue(0)
        bad.ue(0)
        bad.bits(1, 7)
        bad.bit(0)
        bad.bit(1)
        bad.ue(4)
        #expect(slice([0x41] + bad.finish()) == nil)
        var endless = BitWriter()
        endless.ue(0)
        endless.ue(0)
        endless.ue(0)
        endless.bits(1, 7)
        endless.bit(0)
        endless.bit(1)
        for _ in 0..<70 {
            endless.ue(1)
            endless.ue(0)
        }
        #expect(slice([0x41] + endless.bytes) == nil)

        // Field pictures, POC type 0 with a bottom delta, POC type 1, redundant_pic_cnt, colour planes.
        let fancy = H264Parameters(
            log2MaxFrameNum: 4, frameMbsOnly: false, pocType: 0, log2MaxPocLsb: 6, deltaPicOrderAlwaysZero: false,
            separateColourPlane: true, bottomFieldPicOrderInFramePresent: true, redundantPicCntPresent: true)
        var f = BitWriter()
        f.ue(0)
        f.ue(0)
        f.ue(0)
        f.bits(1, 2)  // colour_plane_id
        f.bits(3, 4)  // frame_num
        f.bit(0)  // field_pic_flag = 0
        f.bits(5, 6)  // poc lsb
        f.se(-2)  // delta_pic_order_cnt_bottom
        f.ue(0)  // redundant_pic_cnt
        f.bit(0)
        f.bit(1)
        f.ue(0)
        f.ue(2)
        f.ue(3)
        let fieldSlice = [0x41] + f.finish()
        #expect(withBytes(annexB(fieldSlice)) { slices.firstSlice(in: $0, codec: .h264, h264: fancy, hevc: nil) }?.referenceDistance == 2)

        var poc1 = fancy
        poc1.pocType = 1
        poc1.separateColourPlane = false
        poc1.redundantPicCntPresent = false
        poc1.frameMbsOnly = false
        var g = BitWriter()
        g.ue(0)
        g.ue(0)
        g.ue(0)
        g.bits(3, 4)
        g.bit(1)  // field_pic_flag
        g.bit(0)  // bottom_field_flag
        g.se(3)  // delta_pic_order_cnt[0]; no [1] for field pictures
        g.bit(0)
        g.bit(0)
        let poc1Slice = [0x41] + g.finish()
        #expect(withBytes(annexB(poc1Slice)) { slices.firstSlice(in: $0, codec: .h264, h264: poc1, hevc: nil) }?.referenceDistance == 0)
    }

    @Test("HEVC slices: IDR, I, B, POC, RPS in the SPS, unknown reference, several negatives")
    func hevcVariants() {
        func slice(_ nal: [UInt8], _ p: HEVCParameters? = nil) -> SliceInfo? {
            withBytes(annexB(nal)) { slices.firstSlice(in: $0, codec: .hevc, h264: nil, hevc: p ?? hevc) }
        }
        let p = slice(StreamFixtures.hevcSlice(type: 1, sliceType: 1, pocLsb: 5, negatives: 9, used: 6))
        #expect(p?.referenceDistance == 6)
        #expect(p?.numNegativePics == 9)
        #expect(slice(StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 3, used: nil))?.referenceDistance == nil)
        #expect(slice(StreamFixtures.hevcSlice(type: 1, sliceType: 2))?.kind == .i)
        #expect(slice(StreamFixtures.hevcSlice(type: 1, sliceType: 0))?.kind == .other)
        #expect(slice(StreamFixtures.hevcSlice(type: 20, sliceType: 2))?.isIDR == true)
        #expect(slice(StreamFixtures.hevcSlice(type: 19, sliceType: 2)) == nil)  // only types 1 and 20 parse
        #expect(slice(StreamFixtures.hevcSlice(type: 1, sliceType: 3)) == nil)
        #expect(slice(StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 17, used: 0)) == nil)
        #expect(slice(StreamFixtures.hevcSlice(type: 0, sliceType: 1)) == nil)

        // RPS taken from the SPS: the reference is unknown.
        var sps = BitWriter()
        sps.bit(1)
        sps.ue(0)
        sps.ue(1)
        sps.bits(0, 4)
        sps.bit(1)
        #expect(slice([0x02, 1] + sps.finish())?.referenceDistance == nil)

        // With num_short_term_ref_pic_sets > 0 the slice's RPS has a prediction flag.
        var withSets = hevc
        withSets.numShortTermRefPicSets = 3
        var predicted = BitWriter()
        predicted.bit(1)
        predicted.ue(0)
        predicted.ue(1)
        predicted.bits(0, 4)
        predicted.bit(0)
        predicted.bit(1)  // inter_ref_pic_set_prediction_flag
        #expect(slice([0x02, 1] + predicted.finish(), withSets)?.referenceDistance == nil)
        var plain = BitWriter()
        plain.bit(1)
        plain.ue(0)
        plain.ue(1)
        plain.bits(0, 4)
        plain.bit(0)
        plain.bit(0)
        plain.ue(2)
        plain.ue(0)
        plain.ue(0)
        plain.bit(0)
        plain.ue(0)
        plain.bit(1)
        #expect(slice([0x02, 1] + plain.finish(), withSets)?.referenceDistance == 1)

        // Extra header bits, output flag, colour plane, a non-first slice segment.
        var rich = hevc
        rich.numExtraSliceHeaderBits = 2
        rich.outputFlagPresent = true
        rich.separateColourPlane = true
        rich.dependentSliceSegmentsEnabled = true
        rich.sliceAddressBits = 9
        var r = BitWriter()
        r.bit(0)  // not the first slice segment
        r.ue(0)
        r.bit(0)  // dependent_slice_segment_flag
        r.bits(100, 9)
        r.bits(0, 2)
        r.ue(1)
        r.bit(1)  // pic_output_flag
        r.bits(1, 2)  // colour_plane_id
        r.bits(3, 4)
        r.bit(0)
        r.ue(1)
        r.ue(0)
        r.ue(0)
        r.bit(1)
        #expect(slice([0x02, 1] + r.finish(), rich)?.referenceDistance == 0)
        var dependent = BitWriter()
        dependent.bit(0)
        dependent.ue(0)
        dependent.bit(1)  // dependent slice segment: no slice_type follows
        dependent.bits(100, 9)
        #expect(slice([0x02, 1] + dependent.finish(), rich) == nil)
    }

    @Test("parameter sets: H.264 SPS/PPS")
    func h264ParameterSets() throws {
        let info = VideoProfileInfo(header: StreamFixtures.h264Header())
        #expect(info.codec == .h264)
        let p = try #require(info.h264)
        #expect(p.log2MaxFrameNum == 7)
        #expect(p.pocType == 2)
        #expect(p.frameMbsOnly)
        #expect(!p.redundantPicCntPresent)

        // High profile fields come first; POC types 0 and 1; redundant_pic_cnt; field coding.
        let high = VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(profile: 100), pps: StreamFixtures.h264PPS(redundant: true)))
        #expect(high.h264?.log2MaxFrameNum == 7)
        #expect(high.h264?.redundantPicCntPresent == true)
        let poc0 = VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(pocType: 0, frameMbsOnly: false, pocLsbMinus4: 5)))
        #expect(poc0.h264?.log2MaxPocLsb == 9)
        #expect(poc0.h264?.frameMbsOnly == false)
        let poc1 = VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(pocType: 1)))
        #expect(poc1.h264?.pocType == 1)
        #expect(poc1.h264?.frameMbsOnly == true)

        // Where existing clients give up, so do we: scaling matrices, huge frame_num, slice groups, bad types.
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(profile: 100, scalingMatrix: true))).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(log2FrameNumMinus4: 13))).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(pocType: 0, pocLsbMinus4: 13))).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(pocType: 3))).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(pps: StreamFixtures.h264PPS(sliceGroups: true))).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: [0x4d])).h264 == nil)
        // The codec is still known when the fields are not.
        #expect(VideoProfileInfo(header: StreamFixtures.h264Header(sps: StreamFixtures.h264SPS(pocType: 3))).codec == .h264)
    }

    @Test("parameter sets: HEVC VPS/SPS/PPS")
    func hevcParameterSets() throws {
        let info = VideoProfileInfo(header: StreamFixtures.hevcHeader())
        #expect(info.codec == .hevc)
        let p = try #require(info.hevc)
        #expect(p.log2MaxPocLsb == 4)
        #expect(p.numShortTermRefPicSets == 0)
        #expect(p.numExtraSliceHeaderBits == 0)
        #expect(!p.outputFlagPresent)
        // 1920 x 1088 with 64 x 64 CTBs: 30 x 17 = 510 CTBs, 9 bits.
        #expect(p.sliceAddressBits == 9)

        func parsed(_ sps: [UInt8], _ pps: [UInt8] = StreamFixtures.hevcPPS()) -> HEVCParameters? {
            VideoProfileInfo(header: StreamFixtures.hevcHeader(sps: sps, pps: pps)).hevc
        }
        #expect(parsed(StreamFixtures.hevcSPS(maxSubLayersMinus1: 2, numRps: 5))?.numShortTermRefPicSets == 5)
        #expect(parsed(StreamFixtures.hevcSPS(maxSubLayersMinus1: 3, numRps: 2, subLayerOrdering: false))?.numShortTermRefPicSets == 2)
        #expect(parsed(StreamFixtures.hevcSPS(scalingList: true, numRps: 7))?.numShortTermRefPicSets == 7)
        #expect(parsed(StreamFixtures.hevcSPS(pcm: true, numRps: 4))?.numShortTermRefPicSets == 4)
        #expect(parsed(StreamFixtures.hevcSPS(separateColourPlane: true))?.separateColourPlane == true)
        let pps = parsed(StreamFixtures.hevcSPS(), StreamFixtures.hevcPPS(dependent: true, output: true, extraBits: 3))
        #expect(pps?.dependentSliceSegmentsEnabled == true)
        #expect(pps?.outputFlagPresent == true)
        #expect(pps?.numExtraSliceHeaderBits == 3)

        #expect(parsed(StreamFixtures.hevcSPS(numRps: 65)) == nil)
        #expect(parsed([0x00]) == nil)
        #expect(parsed(StreamFixtures.hevcSPS(), [0x80]) == nil)
        // sps_max_sub_layers_minus1 = 7 is reserved.
        var reserved = BitWriter()
        reserved.bits(0, 4)
        reserved.bits(7, 3)
        #expect(parsed(reserved.finish()) == nil)
    }

    @Test("parameter sets: unknown or empty headers")
    func unknownHeaders() {
        #expect(VideoProfileInfo(header: []).codec == nil)
        #expect(VideoProfileInfo(header: [1, 2, 3]).codec == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.startCode + [0x44, 0x01, 0xc0]).codec == nil)
        // A header without PPS leaves the fields unparsed.
        #expect(VideoProfileInfo(header: StreamFixtures.startCode + [0x67] + escape(StreamFixtures.h264SPS())).h264 == nil)
        #expect(VideoProfileInfo(header: StreamFixtures.startCode + [0x42, 0x01] + escape(StreamFixtures.hevcSPS())).codec == nil)
    }

    @Test("bit reader: Exp-Golomb, overrun and bad prefixes never trap")
    func bitReader() {
        var w = BitWriter()
        for v in [0, 1, 2, 3, 100, 70000] { w.ue(v) }
        for v in [0, 1, -1, 2, -2, 40] { w.se(v) }
        var r = BitReader(w.finish())
        #expect([r.ue(), r.ue(), r.ue(), r.ue(), r.ue(), r.ue()] == [0, 1, 2, 3, 100, 70000])
        #expect([r.se(), r.se(), r.se(), r.se(), r.se(), r.se()] == [0, 1, -1, 2, -2, 40])
        #expect(!r.overrun)
        var bad = BitReader([0, 0, 0, 0, 0])
        _ = bad.ue()
        #expect(bad.overrun)
        var over = BitReader([0xff])
        _ = over.bits(8)
        _ = over.bit()
        #expect(over.overrun)
        var skipping = BitReader([1, 2])
        skipping.skip(100)
        #expect(skipping.overrun)
        #expect(skipping.position == 16)
    }

    @Test("Annex-B: start codes and NAL units")
    func annexBSplitting() {
        let data = hex("00000001 6742 00000001 68ce 000001 65aabb")
        withBytes(data) { raw in
            #expect(AnnexB.startCode(in: raw)?.start == 0)
            #expect(AnnexB.startCode(in: raw)?.nal == 4)
            #expect(AnnexB.startCode(in: raw, from: 4)?.start == 6)
            #expect(AnnexB.startCode(in: raw, limit: 0) == nil)
            #expect(AnnexB.nalUnits(in: raw) == [4..<6, 10..<12, 15..<18])
        }
        withBytes(hex("11 22 33")) { #expect(AnnexB.nalUnits(in: $0).isEmpty) }
        withBytes([]) { #expect(AnnexB.startCode(in: $0) == nil) }
        withBytes(hex("00000001")) { #expect(AnnexB.nalUnits(in: $0).isEmpty) }
    }

    @Test("access unit buffer grows and keeps its bytes")
    func accessUnitBuffer() {
        let buffer = AccessUnitBuffer(capacity: 4)
        let a = [UInt8](1...10)
        a.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: 10) }
        a.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: 0) }
        #expect(Array(buffer.bytes) == a)
        #expect(buffer.capacity >= 10)
        buffer.reset()
        #expect(buffer.count == 0)
        #expect(buffer.bytes.isEmpty)
    }
}
