import CoreGraphics
import CoreVideo
import Foundation
import Metal
import os
import QuartzCore

/// What upscales a decoded frame: Apple's ML super-resolution in the app, a stand-in in tests (CI's virtual
/// machines have none), so the lane's own work (order, dropping, the decoded frame kept with the result) is
/// tested everywhere.
protocol FrameUpscaler: AnyObject {
    /// Encodes `frame` upscaled for a picture of `target` size into `cb`; nil when it doesn't run for it.
    func encode(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, target: CGSize) -> CVPixelBuffer?
    /// Whether frames of this size can never go through.
    func refuses(width: Int, height: Int) -> Bool
}

extension MLSuperResolution: FrameUpscaler {}

/// Upscales decoded frames away from the display: its own queue and Metal command queue, one frame at a time,
/// so a refresh never waits for the model (at 1080p it takes most of a 60 fps frame). Frames come out in the
/// order they went in. One frame is upscaled while at most one waits: a newer frame takes the waiting one's
/// place, and the one it replaces is dropped (counted), so the lane never falls more than a frame behind.
/// See docs/ML_UPSCALING.md.
final class UpscaleLane {
    /// An upscaled frame carries the decoded frame it was made from under this attachment, for the compare
    /// view's baseline and the codec's block grid. It propagates, so in-between images made from upscaled
    /// frames carry it too.
    static let decodedKey = "PlayFXDecodedFrame" as CFString

    /// The decoded frame `image` was upscaled from; nil for one that wasn't.
    static func decodedFrame(of image: CVPixelBuffer) -> CVPixelBuffer? {
        guard let value = CVBufferCopyAttachment(image, decodedKey, nil),
              CFGetTypeID(value) == CVPixelBufferGetTypeID() else { return nil }
        return (value as! CVPixelBuffer) // a CF type: the type ID check above is the cast's check
    }

    private struct Job {
        let frame: CVPixelBuffer
        let target: CGSize
        /// False: the frame only passes through, in its place in the order.
        let upscale: Bool
        /// Called on the lane's queue with the upscaled frame, or nil when it wasn't upscaled.
        let done: (CVPixelBuffer?) -> Void
    }

    private struct State {
        var busy = false
        var waiting: Job?
        var dropped = 0
        /// Whether the last frame was upscaled, and whether its size can never be.
        var ran = false
        var refused = false
    }

    private let queue = DispatchQueue(label: "streamcore.upscale", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let engine: FrameUpscaler
    private let state = OSAllocatedUnfairLock(initialState: State())

    init?(device: MTLDevice, engine: FrameUpscaler) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        self.engine = engine
    }

    /// Frames dropped because a newer one arrived while they waited.
    var dropped: Int { state.withLock { $0.dropped } }
    /// Whether a frame is being upscaled or waiting: a frame that skips the lane would overtake it.
    var isBusy: Bool { state.withLock { $0.busy } }
    /// Whether the last frame was upscaled, and whether its size is one the engine never takes.
    var status: (ran: Bool, refused: Bool) { state.withLock { ($0.ran, $0.refused) } }

    /// Queues `frame` for a picture of `target` size; `done` gets the upscaled frame (nil: use `frame` as is)
    /// on the lane's queue, in submission order. `upscale` false passes the frame through untouched, behind
    /// the ones already in the lane. A frame still waiting when the next one arrives is dropped, and its
    /// `done` is never called.
    func submit(_ frame: CVPixelBuffer, target: CGSize, upscale: Bool = true, done: @escaping (CVPixelBuffer?) -> Void) {
        let job = Job(frame: frame, target: target, upscale: upscale, done: done)
        let start = state.withLock { s -> Bool in
            guard s.busy else { s.busy = true; return true }
            if s.waiting != nil { s.dropped += 1 }
            s.waiting = job
            return false
        }
        guard start else { return }
        queue.async { [self] in
            var next: Job? = job
            while let current = next {
                current.done(process(current))
                next = state.withLock { s in
                    defer { s.waiting = nil }
                    if s.waiting == nil { s.busy = false }
                    return s.waiting
                }
            }
        }
    }

    /// Drops a waiting frame and starts the count over (a new stream).
    func reset() { state.withLock { $0.waiting = nil; $0.dropped = 0 } }

    /// Waits until every frame handed in so far is done; for tests and offscreen renders.
    func waitUntilIdle() {
        while state.withLock({ $0.busy }) { queue.sync {} }
    }

    private func process(_ job: Job) -> CVPixelBuffer? {
        guard job.upscale else { return nil }
        let width = CVPixelBufferGetWidth(job.frame), height = CVPixelBufferGetHeight(job.frame)
        var output: CVPixelBuffer?
        if let cb = commandQueue.makeCommandBuffer() {
            let made = engine.encode(cb, job.frame, target: job.target)
            // Committed even when the engine gave up partway: work it encoded still runs, and finishes.
            cb.commit()
            cb.waitUntilCompleted()
            if let made, cb.status == .completed {
                CVBufferSetAttachment(made, Self.decodedKey, job.frame, .shouldPropagate)
                output = made
            }
        }
        let ran = output != nil, refused = engine.refuses(width: width, height: height)
        state.withLock { $0.ran = ran; $0.refused = refused }
        return output
    }
}
