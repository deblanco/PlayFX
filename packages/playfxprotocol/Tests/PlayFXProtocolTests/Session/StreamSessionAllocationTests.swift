import Foundation
import Testing

@testable import PlayFXProtocol

// In TakionAllocationTests' suite (serialized) because the malloc hook it uses is process-wide.
extension TakionAllocationTests {
    /// Counts handler calls without allocating (a recorder would).
    private final class Tally: @unchecked Sendable {
        var connected = 0
        var video = 0
        var audio = 0
        var haptics = 0
    }

    /// Video, audio and haptics through the session's link: header, GMAC, decrypt, reorder, FEC-free assembly,
    /// the AV layer and the app's handler. Like `theAVHandlerPathDoesNotAllocate`, the zero is asserted in an
    /// optimised build (`scripts/test.sh -c release -Xswiftc -enable-testing --filter TakionAllocationTests`); the
    /// debug run only checks the behaviour.
    @Test func theStreamSessionPathDoesNotAllocate() throws {
        let tally = Tally()
        let session = StreamSession(
            address: "127.0.0.1", target: .ps5v1, registKey: SessionVector.registKey, rpKey: SessionVector.rpKey,
            settings: avcSettings, transport: .bsd, options: StreamSessionOptions(), environment: StreamEnvironment(),
            events: { event, _ in
                switch event {
                case .connected: tally.connected += 1
                case .videoAccessUnit: tally.video += 1
                case .audioPacket: tally.audio += 1
                case .haptics: tally.haptics += 1
                default: break
                }
            })
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: StreamInputs.sessionID, launchSpec: "x", handshakeKey: StreamInputs.handshakeKey,
            keyPair: vectorKeyPair())
        let template = StreamConnectedInfo(
            target: .ps5v1, consoleModel: .ps5, probe: .fallback, probeSucceeded: false, probeFailure: nil,
            requested: avcSettings.launchRequest(target: .ps5v1, model: .ps5), videoCodec: .h264, profiles: [],
            audioHeader: AudioHeader(channels: 0, bitsPerSample: 0, sampleRate: 0, frameSize: 0),
            serverVersion: nil, serverVersionText: nil, consoleSignatureMatches: false, takionVersion: 12, transport: "memory")
        let link = StreamLink(
            session: session, gate: session.gate, handshake: handshake, handshakeKey: StreamInputs.handshakeKey,
            dualSense: true, ps5: true, microphone: false, videoCodec: .h264, template: template)
        var configuration = TakionConfiguration()
        configuration.clientTag = TakionVec.clientTag
        let connection = TakionConnection(configuration: configuration, transport: MemoryTransport(), delegate: link)
        link.connection = connection
        connection.setCongestionSource(link)
        let console = FakeTakionConsole()
        try connection.connect()
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        defer { scratch.deallocate() }
        func feed(_ bytes: [UInt8]) {
            bytes.withUnsafeBytes { scratch.copyMemory(from: $0) }
            connection.transportDidReceive(UnsafeMutableRawBufferPointer(rebasing: scratch[0..<bytes.count]), at: takionNow())
        }
        feed(console.initAck())
        feed(console.cookieAck())
        #expect(connection.isConnected)
        // The HelloReply is the bang; the StreamInfo after it is secured.
        feed(console.dataChunk(message: SessionBytes.helloReply()))
        console.secure()
        feed(console.dataChunk(message: SessionBytes.streamInfo))
        #expect(tally.connected == 1)

        var packets: [[UInt8]] = []
        let source = [UInt8](repeating: 0, count: 2) + [0, 0, 0, 1, 0x41, 9, 9, 9, 9, 9, 9, 9]
        #if DEBUG
        let frames = 150
        #else
        let frames = 3000
        #endif
        for n in 0..<frames {
            packets.append(console.av(
                video: true, packetIndex: UInt16(truncatingIfNeeded: n), frameIndex: UInt16(truncatingIfNeeded: n + 1),
                word: videoWord(index: 0, total: 1, fec: 0), field18: 0x0367, byte20: 0, payload: source))
            packets.append(console.av(
                video: false, packetIndex: UInt16(truncatingIfNeeded: n), frameIndex: UInt16(truncatingIfNeeded: 100 + n),
                word: audioWord(total: 3, unitSize: 40, redundant: 2, source: 1), codec: 5, stream: 0,
                payload: [UInt8](repeating: UInt8(n & 0xff), count: 120)))
            if n % 3 == 0 {
                packets.append(console.av(
                    video: false, packetIndex: UInt16(truncatingIfNeeded: n), frameIndex: UInt16(truncatingIfNeeded: 1 + n / 3),
                    word: audioWord(total: 1, unitSize: 12, redundant: 0, source: 1), codec: 5, stream: 2,
                    payload: [UInt8](repeating: 7, count: 12)))
            }
        }
        // Warm up (buffers grow to their size), then count.
        let warmUp = 30
        for p in packets.prefix(warmUp) { feed(p) }
        let rest = Array(packets.dropFirst(warmUp))
        let measured = countAllocations {
            for (n, p) in rest.enumerated() {
                feed(p)
                // What the connection's 200 ms timer does: ask the link for the counters.
                if n % 50 == 0 { _ = link.congestionInputs() }
            }
        }
        let count = try #require(measured, "malloc_logger is not available")
        #if DEBUG
        // A debug build allocates inside unspecialised standard-library code, so no bound means anything here.
        _ = count
        #else
        #expect(count == 0, "\(count) allocations over \(rest.count) packets")
        #endif
        #expect(tally.video >= frames - 5 && tally.audio >= frames - 10 && tally.haptics >= frames / 3 - 5)
        #expect(connection.stats.droppedBadGMAC == 0)
        #expect(link.snapshot().congestionReports > 0)
        link.detach()
        connection.close()
        withExtendedLifetime(session) {}
    }
}
