import COpus
import Foundation
import PlayFXProtocol

/// Decodes the console's game audio (Opus, av.md section 6.4) to 16-bit PCM with libopus. Used by the Takion
/// receive thread only. The PCM buffer is allocated once, so a packet costs no allocation.
final class PlayFXOpusPlayback {
    let channels: Int
    let sampleRate: Int
    /// Frames made for a lost packet: the header's frame size (10 ms on today's consoles).
    let concealFrames: Int
    private let decoder: OpaquePointer
    private let pcm: UnsafeMutablePointer<Int16>
    /// The most one packet can hold: 120 ms.
    private let capacityFrames: Int

    /// Nil when the header isn't something libopus can decode (1 or 2 channels at 8, 12, 16, 24 or 48 kHz).
    init?(_ header: AudioHeader) {
        guard (1...2).contains(header.channels), [8000, 12000, 16000, 24000, 48000].contains(header.sampleRate),
              let decoder = copus_decoder_create(Int32(header.sampleRate), Int32(header.channels))
        else { return nil }
        self.decoder = decoder
        channels = header.channels
        sampleRate = header.sampleRate
        capacityFrames = header.sampleRate * 120 / 1000
        // A frame must be a multiple of 2.5 ms to be concealed.
        let valid = header.frameSize > 0 && header.frameSize <= capacityFrames && header.frameSize * 400 % header.sampleRate == 0
        concealFrames = valid ? header.frameSize : header.sampleRate / 100
        pcm = .allocate(capacity: capacityFrames * header.channels)
    }

    deinit {
        copus_decoder_destroy(decoder)
        pcm.deallocate()
    }

    /// Decodes one Opus packet: the samples (valid until the next call) and their frame count, or nil when libopus
    /// refused it.
    func decode(_ packet: UnsafeRawBufferPointer) -> (samples: UnsafePointer<Int16>, frames: Int)? {
        guard let base = packet.baseAddress, !packet.isEmpty else { return nil }
        let frames = copus_decode(
            decoder, base.assumingMemoryBound(to: UInt8.self), Int32(packet.count), pcm, Int32(capacityFrames))
        return frames > 0 ? (UnsafePointer(pcm), Int(frames)) : nil
    }

    /// The packet-loss concealment of one lost frame.
    func conceal() -> (samples: UnsafePointer<Int16>, frames: Int)? {
        let frames = copus_decode(decoder, nil, 0, pcm, Int32(concealFrames))
        return frames > 0 ? (UnsafePointer(pcm), Int(frames)) : nil
    }

    /// Forgets the stream's history, after a gap too long to conceal.
    func reset() { copus_decoder_reset(decoder) }
}

/// Encodes the microphone's 10 ms frames to the 40-byte Opus packets the console takes (av.md section 8.2).
/// Not thread safe: the engine serialises it.
final class PlayFXOpusMicrophone {
    private let encoder: OpaquePointer
    private let packet: UnsafeMutablePointer<UInt8>

    /// Nil when libopus can't make the encoder.
    init?() {
        guard let encoder = copus_encoder_create(
            Int32(MicrophoneSettings.sampleRate), Int32(MicrophoneSettings.channels), Int32(MicrophoneSettings.bitrate))
        else { return nil }
        self.encoder = encoder
        packet = .allocate(capacity: 64)
    }

    deinit {
        copus_encoder_destroy(encoder)
        packet.deallocate()
    }

    /// The packet for `samples` (960 interleaved stereo values), or nil unless it comes out exactly 40 bytes long.
    func encode(_ samples: UnsafeBufferPointer<Int16>) -> [UInt8]? {
        guard samples.count == MicrophoneSettings.pcmValuesPerFrame, let base = samples.baseAddress else { return nil }
        let length = copus_encode(encoder, base, Int32(MicrophoneSettings.frameSamples), packet, 64)
        guard length == MicrophoneSettings.packetSize else { return nil }
        return Array(UnsafeBufferPointer(start: packet, count: Int(length)))
    }
}
