import Foundation
import PlayFXProtocol

// Internet play on the PlayFX engine: what the library's internet start tells the app, and how it is set up.

extension PlayFXEngine {
    /// A PS5's PSN device ID: 64 hex characters (psn.md section 3.2).
    static func isDeviceID(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) }
    }

    /// The contract's three internet steps for the library's ten: `.linking` as PSN setup starts, `.data` as the data hole
    /// is opened and `.connected` once it's open (the probe on it starts). The steps between and after report nothing:
    /// the library's own `.connected` stage comes after the stream's `connected` event, and the contract has the stream's
    /// `.connected` last.
    static func remoteStage(for stage: InternetStage) -> StreamSession.RemoteStage? {
        switch stage {
        case .linkingPSN: .linking
        case .dataHole: .data
        case .probing: .connected
        case .wakingConsole, .ctrlHole, .registering, .sessionInit, .ctrl, .streamConnecting, .connected: nil
        }
    }

    private static let remoteOrder: [StreamSession.RemoteStage] = [.linking, .data, .connected]

    /// The options of an internet start: the progress goes to `progress`, the library's log lines to StreamCore's log (at
    /// debug level: they can carry the console's and this network's public addresses), the rest as the reference client
    /// has it. `PLAYFX_PROBE_IDENTITY=logOnly` (development) accepts every hole-punch probe and logs the first mismatch of
    /// each hole, for a first hardware round (holepunch.md section 10, question 1).
    static func internetOptions(
        environment: [String: String], progress: @escaping @Sendable (InternetStage) -> Void
    ) -> InternetOptions {
        var options = InternetOptions()
        options.progress = progress
        options.log = { line in Log.debug(.session, "Internet play: \(line)") }
        if environment["PLAYFX_PROBE_IDENTITY"] == "logOnly" { options.probeIdentity = .logOnly }
        return options
    }

    /// A stage of the internet start began (on the library's thread): the contract's step it stands for goes to the sink,
    /// once and in order, unless the engine is stopping or has quit.
    func remoteProgress(_ stage: InternetStage) {
        guard let step = Self.remoteStage(for: stage), let index = Self.remoteOrder.firstIndex(of: step) else { return }
        let due = locked { s -> Bool in
            guard index > s.remoteStage, !s.stopCalled else { return false }
            s.remoteStage = index
            return true
        }
        guard due, gate.enter() else { return }
        sink.deliver(.remoteProgress(step))
        endCall()
    }
}
