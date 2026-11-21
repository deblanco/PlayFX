import CoreGraphics
import Testing
@testable import StreamCore

/// Why an optional picture step that's turned on isn't running, as the stats line reports it.
@Suite struct PipelineStateTests {
    @Test func interpolationSaysWhyItIsIdle() {
        let state = { StreamRenderer.interpolationState(enabled: $0, supported: $1, streamInterval: $2, displayInterval: $3) }
        #expect(state(false, true, 1.0 / 30, 1.0 / 60) == .off)
        #expect(state(true, false, 1.0 / 30, 1.0 / 60) == .unsupported)
        #expect(state(true, true, 1.0 / 30, 1.0 / 60) == .on)
        #expect(state(true, true, 1.0 / 60, 1.0 / 120) == .on)
        // 60 fps on a 60 Hz screen: no refresh left over for an in-between image. On 75 Hz there is.
        #expect(state(true, true, 1.0 / 60, 1.0 / 60) == .screen)
        #expect(state(true, true, 1.0 / 60, 1.0 / 75) == .on)
        #expect(state(true, true, 1.0 / 30, 0) == .screen) // the screen's rate isn't measured yet
        // Its video processor kept failing: off for the rest of the run, and said so.
        let failed = { StreamRenderer.interpolationState(enabled: $0, supported: true, failed: true, streamInterval: 1.0 / 30, displayInterval: 1.0 / 60) }
        #expect(failed(true) == .failed && failed(false) == .off)
    }

    /// Each reason an HDR stream, or an SDR game with HDR on, gets no in-between images, said apart.
    @Test func interpolationSaysWhyForHDR() {
        let state = {
            StreamRenderer.interpolationState(enabled: $0, hdr: $1, supported: $2, taken: $3, tenBitSDR: $4, failed: $5,
                                              streamInterval: 1.0 / 30, displayInterval: $6)
        }
        let at60 = 1.0 / 60
        // enabled, hdr, supported, taken, tenBitSDR, failed, refresh
        #expect(state(false, true, false, false, false, true, at60) == .off) // off says nothing more
        #expect(state(false, false, true, false, true, false, at60) == .off)
        // The HDR setting on, an SDR game: 10-bit SDR frames neither engine takes.
        #expect(state(true, false, true, false, true, false, at60) == .sdrInHdr)
        #expect(state(true, false, true, false, true, true, at60) == .sdrInHdr) // why it's idle comes before a failure
        #expect(state(true, false, false, false, true, false, at60) == .unsupported) // no SDR engine: HDR off wouldn't help
        // An HDR stream on a Mac without MetalFX's interpolator; SDR's is still "unsupported".
        #expect(state(true, true, false, false, false, false, at60) == .hdrUnsupported)
        #expect(state(true, true, false, true, false, true, at60) == .hdrUnsupported)
        #expect(state(true, false, false, false, false, false, at60) == .unsupported)
        // Not taken for another reason (a frame or two while the stream switches): as before.
        #expect(state(true, true, true, false, false, false, at60) == .unsupported)
        #expect(state(true, false, true, false, false, false, at60) == .unsupported)
        // Taken: kept failing, the screen too slow, or on, the same in HDR as in SDR.
        for hdr in [false, true] {
            #expect(state(true, hdr, true, true, false, true, at60) == .failed)
            #expect(state(true, hdr, true, true, false, false, 1.0 / 30) == .screen)
            #expect(state(true, hdr, true, true, false, false, at60) == .on)
        }
    }

    /// The names the app decodes (`PacingStats.interpolation`).
    @Test func interpolationWireNames() {
        let all: [PipelineState.Interpolation] = [.off, .on, .unsupported, .screen, .still, .failed, .sdrInHdr, .hdrUnsupported]
        #expect(all.map(\.rawValue) == ["off", "on", "unsupported", "screen", "still", "failed", "sdrInHdr", "hdrUnsupported"])
    }

    @Test func upscaleSaysWhyMetalFXIsIdle() {
        let state = StreamRenderer.upscaleState
        let stream = (width: 1920, height: 1080)
        #expect(state(.bilinear, true, false, stream, CGSize(width: 3024, height: 1701)) == .bilinear)
        #expect(state(.metalFX, true, true, stream, CGSize(width: 3024, height: 1701)) == .metalfx)
        // The picture on a 1080p screen (or a smaller window) isn't larger than a 1080p stream.
        #expect(state(.metalFX, true, false, stream, CGSize(width: 1920, height: 1080)) == .notLarger)
        #expect(state(.metalFX, true, false, stream, CGSize(width: 1440, height: 810)) == .notLarger)
        #expect(state(.metalFX, false, false, stream, CGSize(width: 3024, height: 1701)) == .unsupported)
        #expect(state(.metalFX, true, false, stream, CGSize(width: 3024, height: 1701)) == .failed)
    }

    @Test func mlSaysWhyItIsIdle() {
        let state = { StreamRenderer.mlState(enabled: $0, supported: $1, ran: $2, width: $3, height: $4, eightBit: $5, refused: $6) }
        #expect(state(false, true, false, 1280, 720, true, false) == .off)
        #expect(state(true, true, true, 1280, 720, true, false) == .on)
        #expect(state(true, false, false, 1280, 720, true, false) == .unsupported)
        #expect(state(true, true, false, 2560, 1440, true, false) == .streamTooLarge)
        #expect(state(true, true, false, 1920, 1080, true, false) == .notLarger) // 1080p goes through in tiles
        #expect(state(true, true, false, 1280, 720, true, false) == .notLarger)
        #expect(state(true, true, false, 1280, 720, false, false) == .hdr) // 10-bit: the model takes 8-bit only
        #expect(state(true, true, false, 960, 540, true, true) == .streamTooLarge) // a size the model refused
        // Its video processor kept failing (or is stuck on a frame now): off, and said so.
        #expect(StreamRenderer.mlState(enabled: true, supported: true, ran: false, width: 1280, height: 720, failed: true) == .failed)
        #expect(StreamRenderer.mlState(enabled: false, supported: true, ran: false, width: 1280, height: 720, failed: true) == .off)
        // Stuck on a frame (a slow first model build, say): waiting, not failed.
        #expect(StreamRenderer.mlState(enabled: true, supported: true, ran: false, width: 1280, height: 720, stalled: true) == .stalled)
        #expect(StreamRenderer.mlState(enabled: true, supported: true, ran: false, width: 1280, height: 720, failed: true, stalled: true) == .failed)
    }
}
