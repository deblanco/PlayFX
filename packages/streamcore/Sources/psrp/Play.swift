import AppKit
import AVFoundation
import CoreVideo
import Foundation
import StreamCore

// psrp play <clip.mov> [--interpolate] [--jitter MS] [--seconds N] [--screen NAME]
// The frame-pacing bench on a real screen, without a console: plays a clip through the real renderer at
// its frame rate (looping), in a borderless window on a display (the Sidecar iPad when there is one, or
// the one named), optionally with network-like jitter, and reports each second what was actually
// presented: all images, in-between ones, frames skipped, and the pacing delay.

func play(_ args: Args) throws {
    guard let input = args.positional.first else {
        throw fail("usage: psrp play <clip.mov> [--interpolate] [--jitter MS] [--seconds N] [--screen NAME]")
    }
    let url = URL(fileURLWithPath: input)
    let asset = AVURLAsset(url: url)
    let track = try blocking { try await asset.loadTracks(withMediaType: .video).first }
    guard let track else { throw fail("\(input) has no video") }
    let fps = Double(try blocking { try await track.load(.nominalFrameRate) })
    let jitter = (Double(args["jitter"] ?? "") ?? 0) / 1000
    let seconds = Double(args["seconds"] ?? "") ?? 10

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screens = NSScreen.screens
    let wanted = args["screen"]?.lowercased() ?? "sidecar"
    let screen = screens.first { $0.localizedName.lowercased().contains(wanted) } ?? NSScreen.main ?? screens[0]

    guard let renderer = StreamRenderer(inputWidth: 1920, inputHeight: 1080) else { throw fail("no renderer") }
    renderer.params.frameInterpolation = args.has("interpolate")
    renderer.streamFrameRate = fps.rounded()
    let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
    window.contentView = renderer.view
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    print(String(format: "playing %@ at %.2f fps on %@ (%.0f Hz), interpolation %@, jitter up to %.0f ms",
                 url.lastPathComponent, fps, screen.localizedName, Double(screen.maximumFramesPerSecond),
                 renderer.params.frameInterpolation ? "on" : "off", jitter * 1000))

    // Feeds the clip at its rate, looping; each frame arrives up to `jitter` late, never early.
    Thread.detachNewThread {
        var index: UInt64 = 0
        let start = CACurrentMediaTime() + 0.5
        while true {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) {
                let due = start + Double(index) / fps + Double.random(in: 0...jitter)
                let wait = due - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                renderer.display(frame, index: index)
                index += 1
            }
        }
    }

    var shown: [Double] = [], generated: [Double] = []
    var second = 0
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
        second += 1
        guard second > 2 else { return } // let the clock and the interpolation model settle
        shown.append(renderer.shownFramesPerSecond)
        generated.append(renderer.generatedFramesPerSecond)
        print(String(format: "  shown %5.1f/s · in-between %5.1f/s · skipped %d frames, %d in-between · delay %.1f ms · made at %@ in %.1f ms (%@)",
                     renderer.shownFramesPerSecond, renderer.generatedFramesPerSecond, renderer.skippedFrames,
                     renderer.skippedInterpolations, renderer.pacingDelayMilliseconds,
                     renderer.interpolationSize.map { "\($0.width)x\($0.height)" } ?? "—", renderer.interpolationCostMilliseconds,
                     renderer.interpolationStages))
        if Double(second) >= seconds + 2 {
            let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(v.count, 1)) }
            print(String(format: "mean: shown %.1f/s, in-between %.1f/s; skipped %d frames, %d in-between; delay %.1f ms",
                         mean(shown), mean(generated), renderer.skippedFrames, renderer.skippedInterpolations,
                         renderer.pacingDelayMilliseconds))
            exit(0)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    app.run()
}
