import CryptoKit
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite("AV: clarifications and the real capture")
struct CaptureTests {
    struct CapturedUnit {
        var byte0: UInt8
        var packetIndex: UInt16
        var frame: UInt16
        var index: Int
        var total: Int
        var fec: Int
        var payload: [UInt8]
    }

    func capture() throws -> [CapturedUnit] {
        let url = try #require(fixtureURL("av-capture-h264", "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let f = line.split(separator: " ")
            return CapturedUnit(
                byte0: UInt8(f[0], radix: 16)!, packetIndex: UInt16(f[1])!, frame: UInt16(f[2])!, index: Int(f[3])!,
                total: Int(f[4])!, fec: Int(f[5])!, payload: hex(String(f[6])))
        }
    }

    func sha(_ bytes: [UInt8]) -> String { sha256Hex(bytes) }

    static let expected: [UInt16: (length: Int, head: String, sha: String)] = [
        1: (103, "00000001658880867f002fc803ff087e", "7cfcb4169c975d5ff1f6120c2239b9564b5530811c76fe31be79c0fc99fb2982"),
        2: (15995, "00000001419a04422f9fe004a404fffc", "02b08cbe0820d13393ea93d17c551a8291bcdbefaf8a76d4c209129306ae5dc6"),
    ]

    func assemble(_ units: [CapturedUnit], dropping: Int?) -> (VideoLog, VideoReceiver) {
        let log = VideoLog()
        let r = log.makeReceiver()
        for u in units where u.index != dropping {
            r.feed(frame: u.frame, index: u.index, total: u.total, fec: u.fec, payload: u.payload)
        }
        return (log, r)
    }

    @Test("V-AV7: both frames rebuild to the recorded access units")
    func completeFrames() throws {
        let all = try capture()
        #expect(all.count == 20)
        for frame: UInt16 in [1, 2] {
            let units = all.filter { $0.frame == frame }
            let (log, _) = assemble(units, dropping: nil)
            let want = try #require(Self.expected[frame])
            let got = try #require(log.frames.first).bytes
            #expect(got.count == want.length)
            #expect(encodeHex(Array(got.prefix(16))) == want.head)
            #expect(sha(got) == want.sha)
            #expect(log.frames[0].info.fecRecovered == false)
        }
    }

    @Test("V-AV7: dropping any one source unit and recovering it from the parity unit gives the same bytes")
    func recoverEachSourceUnit() throws {
        let all = try capture()
        for frame: UInt16 in [1, 2] {
            let units = all.filter { $0.frame == frame }
            let k = units[0].total - units[0].fec
            let want = try #require(Self.expected[frame])
            for dropped in 0..<k {
                let (log, _) = assemble(units, dropping: dropped)
                let got = try #require(log.frames.first, "frame \(frame) without unit \(dropped)")
                #expect(sha(got.bytes) == want.sha)
                #expect(got.info.fecRecovered)
            }
        }
    }

    @Test("V-AV7: the parity unit on the wire is the encoding of the zero-padded source units")
    func parityMatchesEncoding() throws {
        let all = try capture()
        for frame: UInt16 in [1, 2] {
            let units = all.filter { $0.frame == frame }
            let k = units[0].total - units[0].fec
            let parity = try #require(units.last)
            let size = parity.payload.count
            let padded = units[0..<k].map { u in
                let pad = Int(u.payload[0]) << 8 | Int(u.payload[1])
                #expect(u.payload.count + pad == size)
                return u.payload + [UInt8](repeating: 0, count: size - u.payload.count)
            }
            #expect(ReferenceFEC.encode(source: padded, m: units[0].fec)[0] == parity.payload)
        }
    }

    // MARK: Clarifications

    @Test("waiting for an IDR: unparsable frames are handed over and leave the wait set; a 'neither' slice is dropped")
    func waitingRules() {
        let log = VideoLog()
        let r = log.makeReceiver(profiles: [VideoProfile(width: 1, height: 1, header: StreamFixtures.h264Header())])
        func frame(_ f: UInt16, _ nal: [UInt8]) { r.feed(frame: f, index: 0, total: 1, fec: 0, payload: [0, 0] + annexB(nal)) }
        frame(1, StreamFixtures.h264Slice(idr: true, sliceType: 7))
        r.feed(frame: 2, index: 0, total: 2, fec: 0, payload: [0, 0, 1])  // FEC failure: waiting
        frame(3, [0x67, 1, 2, 3])  // unparsable: handed over, wait stays set
        #expect(log.frames.map(\.info.frameIndex) == [1, 3])
        #expect(log.idr == [.fecFailed])
        frame(4, StreamFixtures.h264Slice(idr: false, sliceType: 1))  // B ("neither"): dropped
        frame(5, StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 1))  // P: dropped
        #expect(log.frames.count == 2)
        frame(6, StreamFixtures.h264Slice(idr: true, sliceType: 7))
        // Not waiting any more: a "neither" slice is handed over without a reference check.
        frame(7, StreamFixtures.h264Slice(idr: false, sliceType: 1))
        #expect(log.frames.map(\.info.frameIndex) == [1, 3, 6, 7])
    }

    @Test("the negotiated codec wins over detection from the header")
    func negotiatedCodec() {
        let header = StreamFixtures.hevcHeader()
        #expect(VideoProfileInfo(header: header).codec == .hevc)
        #expect(VideoProfileInfo(header: header, codec: .hevc).hevc != nil)
        let forced = VideoProfileInfo(header: header, codec: .h264)
        #expect(forced.codec == .h264)
        #expect(forced.h264 == nil)
        #expect(VideoProfileInfo(header: [], codec: .hevc).codec == .hevc)
        let log = VideoLog()
        let r = log.makeReceiver()
        r.setProfiles([VideoProfile(width: 1, height: 1, header: [])], codec: .h264)
        r.feed(frame: 1, index: 0, total: 1, fec: 0, payload: [0, 0, 1])
        #expect(log.frames.first?.info.codec == .h264)
    }

    @Test("the HEVC rewrite only accepts NAL type 1")
    func rewriteTypeOne() {
        let parser = SliceParser()
        var info = SliceInfo(kind: .p, isIDR: false, referenceDistance: 0, nalType: 20)
        info.numNegativePics = 2
        info.usedFlagBits[0] = 8
        info.usedFlagBits[1] = 9
        var au: [UInt8] = [1, 0x80, 0x40]
        #expect(!au.withUnsafeMutableBufferPointer { parser.rewriteHEVCReference($0, info: info, to: 1) })
    }
}
