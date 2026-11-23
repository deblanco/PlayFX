import Foundation

// Packet statistics behind the congestion report (takion.md §8) and the layer's diagnostics counters.

/// What the AV layer knows about the last interval (av.md §4.5 counts frames, duplicates and completion).
struct CongestionInputs: Sendable, Equatable {
    /// Video units received and missing since the previous call (the AV layer resets them).
    var videoReceived = 0
    var videoLost = 0
    /// Audio packets received so far (cumulative, haptics excluded) and the highest audio frame index seen.
    var audioPacketsReceived = 0
    var audioHighestFrameIndex: UInt16 = 0
}

/// Where the congestion report gets its numbers. Called from the receive thread once per report.
protocol CongestionSource: AnyObject, Sendable {
    func congestionInputs() -> CongestionInputs
}

/// The arithmetic of §8.3 over what the source reports: the audio loss estimate from the frame-index span and the
/// ceiling `maxLoss`. Owns the audio reference points between intervals.
struct CongestionReporter: Sendable {
    private(set) var previousAudioPackets = 0
    private(set) var previousHighest: UInt16 = 0

    init(previousAudioPackets: Int = 0, previousHighest: UInt16 = 0) {
        self.previousAudioPackets = previousAudioPackets
        self.previousHighest = previousHighest
    }

    /// The `(received, lost)` of this interval, 16-bit truncated.
    mutating func report(_ inputs: CongestionInputs, maxLoss: Double) -> (received: UInt16, lost: UInt16) {
        let audio = max(inputs.audioPacketsReceived - previousAudioPackets, 0)
        let span = Int(inputs.audioHighestFrameIndex &- previousHighest)
        let audioLost = audio < span ? span - audio : 0
        previousAudioPackets = inputs.audioPacketsReceived
        previousHighest = inputs.audioHighestFrameIndex
        var r = inputs.videoReceived + audio
        var l = inputs.videoLost + audioLost
        let total = r + l
        if total > 0 && Double(l) / Double(total) > maxLoss {
            l = Int((Double(total) * maxLoss).rounded(.down))
            r = total - l
        }
        return (UInt16(truncatingIfNeeded: r), UInt16(truncatingIfNeeded: l))
    }
}

/// Counters of the whole layer, snapshot through `TakionConnection.stats`.
struct TakionStats: Sendable, Equatable {
    var datagramsReceived = 0
    /// Datagrams whose receive time is the callback time because the transport had no kernel time.
    var softwareTimestamps = 0
    var bytesReceived = 0
    var videoPackets = 0
    var audioPackets = 0
    var controlPackets = 0
    var dataChunksDelivered = 0
    var duplicateChunks = 0
    var dataAcksReceived = 0
    var droppedTruncated = 0
    var droppedBadGMAC = 0
    var droppedUnknownType = 0
    var droppedMalformed = 0
    var droppedWindow = 0
    var avHeld = 0
    var avHeldOverflow = 0
    var datagramsSent = 0
    var bytesSent = 0
    var retransmissions = 0
    var chunksGivenUp = 0
    var congestionReports = 0
    var sendErrors = 0
    var reorder = ReorderStats()
}
