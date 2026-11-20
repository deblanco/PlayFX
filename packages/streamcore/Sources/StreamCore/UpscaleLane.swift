import CoreGraphics
import CoreVideo
import Foundation
import os
import QuartzCore

/// What upscales a decoded frame: Apple's ML super-resolution in the app, a stand-in in tests (CI's virtual
/// machines have none), so the lane's own work (order, dropping, the decoded frame kept with the result) is
/// tested everywhere.
protocol FrameUpscaler: AnyObject {
    /// `frame` upscaled for a picture of `target` size, made by the time it returns; nil when it doesn't run for it.
    func upscale(_ frame: CVPixelBuffer, target: CGSize) -> CVPixelBuffer?
    /// Whether frames of this size can never go through.
    func refuses(width: Int, height: Int) -> Bool
    /// Whether it's off for the rest of the run (its video processor kept failing). Thread-safe.
    var hasFailed: Bool { get }
}

extension MLSuperResolution: FrameUpscaler {}

/// Upscales decoded frames away from the display: its own queue, one frame at a time,
/// so a refresh never waits for the model (at 1080p it takes most of a 60 fps frame). Frames come out in the
/// order they went in. One frame is upscaled while at most one waits: a newer frame takes the waiting one's
/// place, and the one it replaces is dropped (counted), so the lane never falls more than a frame behind.
/// A repeated picture does not run the model again: it passes through, and can reuse the last upscaled frame.
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
        /// With `upscale` false: hand back the last upscaled frame instead of nil. Its decoded-frame
        /// attachment is left as it was (the timeline may still be showing that same buffer).
        let reuse: Bool
        /// Called on the lane's queue with the upscaled frame, or nil when it wasn't upscaled.
        let done: (CVPixelBuffer?) -> Void
    }

    private struct State {
        var busy = false
        var waiting: Job?
        var dropped = 0
        /// The last frame the model produced. Nil after `reset`, or when the last upscale produced nothing.
        var cached: CVPixelBuffer?
        /// Bumped by `reset`, so an upscale that started on the stream before doesn't refill `cached`.
        var epoch = 0
        /// Whether the last frame was upscaled, and whether its size can never be.
        var ran = false
        var refused = false
        /// When the frame in hand started (nil between frames).
        var since: Double?
    }

    private let queue = DispatchQueue(label: "streamcore.upscale", qos: .userInteractive)
    private let engine: FrameUpscaler
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Seconds one frame may take before the lane counts as stuck: well past building the model for a new size
    /// (9 s for 1080p's tiles the first time on this Mac, before macOS caches it; 0.03 s after).
    let stallLimit: Double

    init(engine: FrameUpscaler, stallLimit: Double = 15) {
        self.engine = engine
        self.stallLimit = stallLimit
    }

    /// Frames dropped because a newer one arrived while they waited.
    var dropped: Int { state.withLock { $0.dropped } }
    /// Whether a frame is being upscaled or waiting: a frame that skips the lane would overtake it.
    var isBusy: Bool { state.withLock { $0.busy } }
    /// The last upscaled frame, for a repeat that doesn't run the model. Nil after `reset` or a failed upscale.
    var lastUpscaled: CVPixelBuffer? { state.withLock { $0.cached } }
    /// Whether the last frame was upscaled, and whether its size is one the engine never takes.
    var status: (ran: Bool, refused: Bool) { state.withLock { ($0.ran, $0.refused) } }
    /// Whether the engine is off for the rest of the run (its video processor kept failing).
    var hasFailed: Bool { engine.hasFailed }
    /// Whether the frame in hand has taken longer than `stallLimit` (a call into the model that doesn't return):
    /// frames then go around the lane rather than wait behind it.
    func isStalled(now: Double = CACurrentMediaTime()) -> Bool {
        state.withLock { s in s.since.map { now - $0 > stallLimit } ?? false }
    }

    /// Queues `frame` for a picture of `target` size; `done` gets the upscaled frame (nil: use `frame` as is)
    /// on the lane's queue, in submission order. `upscale` false passes the frame through untouched, behind
    /// the ones already in the lane; `reuse` then hands back the last upscaled frame instead of nil. A frame
    /// still waiting when the next one arrives is dropped, and its `done` is never called. A pass-through is
    /// not counted as dropped.
    func submit(_ frame: CVPixelBuffer, target: CGSize, upscale: Bool = true, reuse: Bool = false,
                done: @escaping (CVPixelBuffer?) -> Void) {
        let job = Job(frame: frame, target: target, upscale: upscale, reuse: reuse, done: done)
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

    /// Drops a waiting frame, forgets the last upscaled frame, and starts the count over (a new stream).
    func reset() {
        state.withLock { s in
            s.waiting = nil
            s.dropped = 0
            s.cached = nil
            s.epoch += 1
        }
    }

    /// Waits until every frame handed in so far is done; for tests and offscreen renders.
    func waitUntilIdle() {
        while state.withLock({ $0.busy }) { queue.sync {} }
    }

    private func process(_ job: Job) -> CVPixelBuffer? {
        guard job.upscale else { return job.reuse ? state.withLock { $0.cached } : nil }
        let epoch = state.withLock { $0.epoch }
        let width = CVPixelBufferGetWidth(job.frame), height = CVPixelBufferGetHeight(job.frame)
        state.withLock { $0.since = CACurrentMediaTime() }
        let output = engine.upscale(job.frame, target: job.target)
        if let output { CVBufferSetAttachment(output, Self.decodedKey, job.frame, .shouldPropagate) }
        let ran = output != nil, refused = engine.refuses(width: width, height: height)
        // A reset during the upscale belongs to the next stream: don't put this frame back in the cache.
        state.withLock { s in
            if s.epoch == epoch { s.cached = output }
            s.ran = ran
            s.refused = refused
            s.since = nil
        }
        return output
    }
}
