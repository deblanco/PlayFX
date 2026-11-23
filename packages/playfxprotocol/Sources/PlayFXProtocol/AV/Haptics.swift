/// DualSense haptics audio (av.md section 7): raw 16-bit PCM, 2 channels interleaved, in audio-format
/// packets whose stream byte is `0x02`.
public final class HapticsReceiver {
    public static let sampleRate = 3000
    public static let channels = 2

    /// How the two bytes of a sample are ordered. Open question 3 of av.md: little-endian is assumed
    /// (existing clients use the bytes as native values on little-endian machines). This is the only
    /// place to change it if the hardware says otherwise.
    public enum ByteOrder: Sendable {
        case littleEndian
        case bigEndian
    }

    public static let defaultByteOrder: ByteOrder = .littleEndian

    private let byteOrder: ByteOrder
    private let handler: (_ frameIndex: UInt16, _ samples: UnsafeBufferPointer<Int16>) -> Void
    private var startUp = AudioStartUp()
    /// "Last used" starts at 0: the first usable frame index is 1...32767.
    private var lastFrame: UInt16 = 0
    private let samples: UnsafeMutablePointer<Int16>

    /// - Parameter handler: gets each unit's interleaved L/R samples, in order. Valid only during the call.
    public init(
        byteOrder: ByteOrder = HapticsReceiver.defaultByteOrder,
        handler: @escaping (UInt16, UnsafeBufferPointer<Int16>) -> Void
    ) {
        self.byteOrder = byteOrder
        self.handler = handler
        samples = .allocate(capacity: 128)
    }

    deinit { samples.deallocate() }

    public func receive(_ unit: AVUnit) {
        guard unit.kind == .audio, let layout = AudioPacketLayout(unit), let base = unit.payload.baseAddress else {
            return
        }
        let pairs = layout.unitSize / 4  // whole stereo sample frames
        guard pairs > 0 else { return }
        for i in 0..<layout.unitCount where !startUp.skips(layout, unit: i) {
            let frame = layout.frame(ofUnit: i)
            if !Serial16.isNewer(frame, than: lastFrame) { continue }
            lastFrame = frame
            let bytes = base.assumingMemoryBound(to: UInt8.self) + i * layout.unitSize
            for s in 0..<pairs * 2 {
                let a = UInt16(bytes[2 * s]), b = UInt16(bytes[2 * s + 1])
                samples[s] = Int16(bitPattern: byteOrder == .littleEndian ? (b << 8 | a) : (a << 8 | b))
            }
            handler(frame, UnsafeBufferPointer(start: samples, count: pairs * 2))
        }
    }
}
