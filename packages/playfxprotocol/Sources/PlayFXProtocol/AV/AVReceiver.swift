import Foundation

/// The audio/video layer's single entry point: feed it the units the transport produces and it routes them to
/// video assembly, game audio or haptics, and calls back with finished access units, Opus packets and PCM.
///
/// Not thread safe: one thread (the transport's receive thread) feeds it, and the callbacks run on it.
public final class AVReceiver {
    public let video: VideoReceiver
    public let audio: AudioReceiver
    public let haptics: HapticsReceiver

    public init(
        video: VideoCallbacks,
        audio: @escaping (AudioEvent) -> Void,
        haptics: @escaping (UInt16, UnsafeBufferPointer<Int16>) -> Void,
        hapticsByteOrder: HapticsReceiver.ByteOrder = HapticsReceiver.defaultByteOrder,
        idrOnMissingReference: Bool = false,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.video = VideoReceiver(callbacks: video, idrOnMissingReference: idrOnMissingReference, clock: clock)
        self.audio = AudioReceiver(handler: audio)
        self.haptics = HapticsReceiver(byteOrder: hapticsByteOrder, handler: haptics)
    }

    /// Applies the console's StreamInfo (stream.md section 6.6): the resolutions with their parameter sets,
    /// and the 14-byte audio header. Returns false (and keeps the old audio setup) for an audio header
    /// of the wrong length.
    @discardableResult
    public func setStreamInfo(profiles: [VideoProfile], audioHeader: [UInt8], codec: VideoCodec? = nil) -> Bool {
        video.setProfiles(profiles, codec: codec)
        guard let header = AudioHeader(audioHeader) else { return false }
        audio.setHeader(header)
        return true
    }

    public func receive(_ unit: AVUnit) {
        switch unit.kind {
        case .video:
            video.receive(unit)
        case .audio:
            if unit.streamByte == AVUnit.hapticsStreamByte {
                haptics.receive(unit)
            } else {
                audio.receive(unit)
            }
        }
    }
}
