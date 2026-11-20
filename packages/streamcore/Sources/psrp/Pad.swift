import AppKit
import Foundation
import GameController
import StreamCore

// psrp pad [--port 7778] [--foreground] — the Mac's controller without a console: logs what the pad sends (in
// PlayStation terms) and plays rumble and adaptive-trigger effects on it, to check each on hardware.
//
//   /state                                   latest merged state as JSON (incl. motion)
//   /rumble?l=0-255&r=0-255&ms=800           heavy (left) / light (right) motor, then off
//   /trigger?side=l|r|both&effect=off|feedback|weapon|vibration[&start=0.2&end=0.6&strength=1&freq=0.3]
//   /trigger?side=r&mode=0x25&p=0x04,0x01,0x07   raw DualSense effect (mode + params), through the decoder
//   /light?r=0-255&g=0-255&b=0-255           light bar colour, as a game sets it over Remote Play
//   /player?n=0-3                            player number lights, as the console counts (0 = player 1)
//   /quit
//
// Findings on macOS 27 (DualSense over Bluetooth): the PS button never reaches the app; it opens the Games
// app unless a game-category app (LSApplicationCategoryType public.app-category.games) is frontmost. To
// check that, run the binary from inside a .app with such an Info.plist, with --foreground.

final class PadProbe {
    let input = ControllerInput()
    let rumble = Rumble()
    let triggers = AdaptiveTriggers()
    let light = PadLight()
    var state = ControllerState()
    var left = TriggerEffect.off, right = TriggerEffect.off
    private var lastLine = ""

    init() {
        // Each physical element by GameController's name, to check the mapping.
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            (n.object as? GCController).map(Self.watchElements)
        }
        GCController.controllers().forEach(Self.watchElements)
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "frontmost"), (NSApplication.didResignActiveNotification, "in the background")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in log("[app] \(label)") }
        }
        input.onChange = { [weak self] s in
            guard let self else { return }
            state = s
            let line = Self.describe(s)
            if line != lastLine { lastLine = line; log("[pad] \(line)") }
        }
    }

    static func watchElements(_ controller: GCController) {
        log("[element] buttons: \(controller.physicalInputProfile.buttons.keys.sorted().joined(separator: ", "))")
        if let home = controller.extendedGamepad?.buttonHome {
            log("[element] home: preferred gesture state \(home.preferredSystemGestureState.rawValue)"
                + " (0 enabled, 1 always receive, 2 disabled)")
        } else { log("[element] no buttonHome") }
        for (name, button) in controller.physicalInputProfile.buttons {
            button.pressedChangedHandler = { _, _, pressed in if pressed { log("[element] \(name) (\(button.sfSymbolsName ?? "-"))") } }
        }
    }

    /// Everything but motion, compactly: pressed buttons, triggers, sticks off-center, touches.
    static func describe(_ s: ControllerState) -> String {
        var parts = ControllerState.buttonNames.filter { s.buttons & $0.value != 0 }.keys.sorted()
        if s.l2 > 0 { parts.append("L2=\(s.l2)") }
        if s.r2 > 0 { parts.append("R2=\(s.r2)") }
        func stick(_ name: String, _ x: Int16, _ y: Int16) {
            let (fx, fy) = (Float(x) / Float(Int16.max), Float(y) / Float(Int16.max))
            if abs(fx) > 0.15 || abs(fy) > 0.15 { parts.append(String(format: "%@(%+.2f,%+.2f)", name, fx, fy)) }
        }
        stick("LS", s.leftX, s.leftY)
        stick("RS", s.rightX, s.rightY)
        for t in s.touches { parts.append(String(format: "touch#%d(%.2f,%.2f)", t.id, t.x, t.y)) }
        return parts.isEmpty ? "(idle)" : parts.joined(separator: " ")
    }

    func handle(path: String, query: [String: String]) -> (Int, String, Data) {
        func text(_ s: String, _ status: Int = 200) -> (Int, String, Data) { (status, "text/plain", Data("\(s)\n".utf8)) }
        switch path {
        case "/state":
            struct Motion: Encodable { let gyro: [Float]; let accel: [Float] }
            struct State: Encodable {
                let summary: String; let buttons: UInt32; let l2: UInt8; let r2: UInt8
                let sticks: [Int16]; let touches: [[Float]]; let motion: Motion?
            }
            let s = DispatchQueue.main.sync { state }
            let motion = s.motion.map { Motion(gyro: [$0.gyro.x, $0.gyro.y, $0.gyro.z], accel: [$0.accel.x, $0.accel.y, $0.accel.z]) }
            let body = State(summary: Self.describe(s), buttons: s.buttons, l2: s.l2, r2: s.r2,
                             sticks: [s.leftX, s.leftY, s.rightX, s.rightY],
                             touches: s.touches.map { [Float($0.id), $0.x, $0.y] }, motion: motion)
            return (200, "application/json", (try? JSONEncoder().encode(body)) ?? Data())
        case "/rumble":
            let l = UInt8(query["l"] ?? "") ?? 0, r = UInt8(query["r"] ?? "") ?? 0
            rumble.apply(left: l, right: r)
            let ms = Int(query["ms"] ?? "") ?? 800
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { self.rumble.apply(left: 0, right: 0) }
            log("[pad] rumble left \(l) right \(r) for \(ms) ms")
            return text("ok")
        case "/trigger":
            let effect: TriggerEffect
            if let mode = query["mode"] {
                let bytes = (query["p"] ?? "").split(separator: ",").compactMap { Self.byte(String($0)) }
                guard let m = Self.byte(mode) else { return text("bad mode", 400) }
                effect = TriggerEffect(mode: m, parameters: bytes)
            } else {
                let f = { (k: String, d: Float) in query[k].flatMap(Float.init) ?? d }
                switch query["effect"] ?? "off" {
                case "off": effect = .off
                case "feedback": effect = .feedback((0..<10).map { $0 >= Int(f("start", 0) * 9) ? f("strength", 1) : 0 })
                case "weapon": effect = .weapon(start: f("start", 0.2), end: f("end", 0.6), strength: f("strength", 1))
                case "vibration": effect = .vibration((0..<10).map { $0 >= Int(f("start", 0) * 9) ? f("strength", 1) : 0 },
                                                      frequency: f("freq", 0.3))
                default: return text("effect must be off, feedback, weapon or vibration", 400)
                }
            }
            let side = query["side"] ?? "both"
            DispatchQueue.main.sync {
                if side != "r" { left = effect }
                if side != "l" { right = effect }
                triggers.apply(left: left, right: right)
            }
            log("[pad] trigger \(side): \(effect)")
            return text("\(side): \(effect)")
        case "/light":
            let c = { (k: String) in UInt8(query[k] ?? "") ?? 0 }
            light.setColor(red: c("r"), green: c("g"), blue: c("b"))
            log("[pad] light bar \(c("r")), \(c("g")), \(c("b"))")
            return text("ok")
        case "/player":
            // As the console counts: 0 = player 1.
            let n = Int(query["n"] ?? "") ?? 0
            light.setPlayer(n)
            log("[pad] player \(n + 1)")
            return text("ok")
        case "/quit":
            DispatchQueue.main.async { self.light.reset(); PadQuiet.now() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return text("bye")
        default:
            return text("not found", 404)
        }
    }

    /// "37", "0x25" or "25h"-free hex with a 0x prefix.
    static func byte(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("0x") ? UInt8(t.dropFirst(2), radix: 16) : UInt8(t)
    }
}

func pad(_ args: Args) throws {
    let probe = PadProbe()
    let port = UInt16(args["port"] ?? "") ?? 7778
    try serve(port: port) { probe.handle(path: $0, query: $1) }
    PadQuiet.installSignalHandlers() // Ctrl-C mid-effect leaves the pad quiet
    log("Pad probe: http://127.0.0.1:\(port)/state  (/rumble?l=200&r=0, /trigger?side=r&effect=weapon, /light?r=255&g=0&b=0, /player?n=0, /quit)")
    // GameController delivers on the main run loop. --foreground: a regular, frontmost app, which is
    // what system-gesture opt-outs (PS button) apply to.
    if args.has("foreground") {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        withExtendedLifetime(probe) { NSApp.run() }
    } else {
        withExtendedLifetime(probe) { RunLoop.main.run() }
    }
}
