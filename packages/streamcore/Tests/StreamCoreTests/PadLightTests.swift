import GameController
import Testing
@testable import StreamCore

extension Serial {
    /// Serial: `PadLight.controllers` is process-wide.
    @Suite struct PadLightTests {
        @Test func mapsTheConsolesPlayerNumbers() {
            #expect(PadLight.playerIndex(0) == .index1)
            #expect(PadLight.playerIndex(3) == .index4)
            #expect(PadLight.playerIndex(4) == .indexUnset)
            #expect(PadLight.playerIndex(-1) == .indexUnset)
        }

        @Test @MainActor func appliesTheConsolesValuesToEveryPadAndForgetsThemAtTheEnd() async {
            let pads = [GCController.withExtendedGamepad(), GCController.withExtendedGamepad()]
            let saved = PadLight.controllers
            PadLight.controllers = { pads }
            defer { PadLight.controllers = saved }
            let light = PadLight()
            light.setPlayer(1)
            light.setColor(red: 255, green: 0, blue: 64)
            await settle()
            #expect(pads.allSatisfy { $0.playerIndex == .index2 })
            #expect(light.color?.red == 255 && light.color?.blue == 64)

            // A pad that connects later gets the same values.
            let late = GCController.withExtendedGamepad()
            light.apply(to: late)
            #expect(late.playerIndex == .index2)

            light.reset()
            await settle()
            #expect(light.color == nil && light.player == nil)
            #expect(pads.allSatisfy { $0.playerIndex == .indexUnset })
        }

        /// Lets the main queue run what was dispatched to it.
        @MainActor private func settle() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
    }
}
