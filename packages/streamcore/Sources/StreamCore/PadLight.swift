import Foundation
import GameController

/// The DualSense light bar colour and the player number the console asks for (games use the light bar
/// for state: a colour per character, red/blue in a police chase), on every connected pad and on pads
/// that connect later. GameController is driven on the main queue.
public final class PadLight {
    /// The connected controllers (replaced in tests; none in a test run, see `PadHardware`).
    nonisolated(unsafe) static var controllers: () -> [GCController] = PadHardware.controllers

    /// What the console asked for last. On the main queue.
    private(set) var color: (red: UInt8, green: UInt8, blue: UInt8)?
    private(set) var player: GCControllerPlayerIndex?
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self.apply(to: controller) }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Thread-safe.
    public func setColor(red: UInt8, green: UInt8, blue: UInt8) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.color = (red, green, blue); self.applyToAll() } }
    }

    /// Thread-safe. `index` as the console counts players (0 = player 1).
    public func setPlayer(_ index: Int) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.player = Self.playerIndex(index); self.applyToAll() } }
    }

    /// Forgets the session's values and clears the player number (the light keeps its last colour: there's
    /// no "system colour" to go back to).
    public func reset() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.color = nil
                self.player = nil
                for controller in Self.controllers() { controller.playerIndex = .indexUnset }
            }
        }
    }

    @MainActor func applyToAll() { Self.controllers().forEach(apply) }

    @MainActor func apply(to controller: GCController) {
        if let color, let light = controller.light {
            light.color = GCColor(red: Float(color.red) / 255, green: Float(color.green) / 255, blue: Float(color.blue) / 255)
        }
        if let player { controller.playerIndex = player }
    }

    /// The console's player number → GameController's (players 1–4; anything else shows none).
    static func playerIndex(_ console: Int) -> GCControllerPlayerIndex {
        (0...3).contains(console) ? GCControllerPlayerIndex(rawValue: console) ?? .indexUnset : .indexUnset
    }
}
