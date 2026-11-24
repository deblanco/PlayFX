import Foundation
import Network

/// Watches the Mac's network while a stream runs. The stream's sockets stay bound to the network they
/// started on, so when the Mac moves to another one (Wi-Fi ↔ Ethernet, another Wi-Fi, back online after
/// a drop) the stream is dead even before it times out; the host reconnects right away instead.
final class NetworkWatch: @unchecked Sendable {
    /// What matters about the network for a stream: whether it's usable, and through which interface.
    struct Summary: Equatable {
        var online: Bool
        /// The interface traffic goes through first (e.g. "en0"), nil when offline.
        var primary: String?
    }

    enum Change: Equatable {
        /// The Mac is online again, or on a different network: reconnect.
        case changed
        /// The network went away: nothing to do until it's back.
        case offline
    }

    /// Whether going from `old` to `new` means the stream should reconnect.
    static func change(from old: Summary, to new: Summary) -> Change? {
        if old.online, !new.online { return .offline }
        if new.online, !old.online { return .changed }
        if new.online, old.primary != new.primary { return .changed }
        return nil
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "playfx.network-watch")
    private var last: Summary?

    /// `onChange` runs on a background queue; the first report (the network at start) isn't a change.
    init(onChange: @escaping (Change) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let summary = Summary(online: path.status == .satisfied,
                                  primary: path.status == .satisfied ? path.availableInterfaces.first?.name : nil)
            defer { self.last = summary }
            guard let last = self.last, let change = Self.change(from: last, to: summary) else { return }
            Log.info(.session, "Network \(change == .offline ? "went away" : "changed (now \(summary.primary ?? "?"))")")
            onChange(change)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
