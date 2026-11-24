// pfxp: drives PlayFXProtocol against a real console, side by side with `psrp` (libchiaki).
//
//   pfxp discover [--host IP] [--timeout S]       consoles on the LAN (or one address)
//   pfxp wake [--host IP] [--new]                  wakes a console paired in ~/.config/psrp/config.json
//                                                  (--new: with a pairing made by `pfxp pair`)
//   pfxp pair --host IP --pin 12345678 [--ps4]     pairs; saves to ~/.config/playfx-protocol/config.json
//   pfxp session [--host IP] [--new] [--seconds N] [--login-pin PIN|-] [--sleep]
//                                                  session init + ctrl; prints each event with its time, then
//                                                  ends cleanly (--sleep: puts the console to rest instead)
//   pfxp stream [...]                              a whole stream (Stream.swift lists the options, among them
//                                                  --press for scripted input and --drop for simulated loss)
//
// `wake --new` from rest mode checks that a pairing made here works. Keys are never printed.
import Foundation
import PlayFXProtocol

struct Credentials: Codable {
    var address: String
    var ps5: Bool
    var nickname: String
    var mac: String
    var registKey: String
    var rpKey: String
    var accountId: String
}

struct Config: Codable {
    var accountId: String?
    var consoles: [Credentials] = []

    static func load(_ url: URL) -> Config {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    }

    /// Written 0600 through a fresh temporary file renamed over the old one: it holds pairing keys.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid())").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fail("Can't write \(temp)") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let closed = close(fd) == 0
        guard written == data.count, closed, rename(temp, url.path) == 0 else {
            unlink(temp)
            throw fail("Can't write \(url.path)")
        }
    }
}

struct Failure: Error, CustomStringConvertible { let description: String }
func fail(_ message: String) -> Failure { Failure(description: message) }

let home = FileManager.default.homeDirectoryForCurrentUser
let psrpConfig = home.appendingPathComponent(".config/psrp/config.json")
let ownConfig = home.appendingPathComponent(".config/playfx-protocol/config.json")

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func discover(_ args: [String]) throws {
    let timeout = option("timeout", in: args).flatMap(Double.init) ?? 2
    let started = Date()
    let found = try Discovery.discoverThrowing(host: option("host", in: args), timeout: timeout)
    print("\(found.count) console(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    for console in found {
        let app = console.runningAppName.map { ", running \($0)" } ?? ""
        print("  \(console.name ?? "?")  \(console.address)  \(console.kind == .ps5 ? "PS5" : "PS4")  "
              + "\(console.state)  system \(console.systemVersion ?? "?")  id \(console.hostID)\(app)")
    }
}

func wake(_ args: [String]) throws {
    let file = args.contains("--new") ? ownConfig : psrpConfig
    let config = Config.load(file)
    let host = option("host", in: args)
    guard let console = host.map({ h in config.consoles.first { $0.address == h } }) ?? config.consoles.first else {
        throw fail("No console paired in \(file.path)\(host.map { " at \($0)" } ?? "")")
    }
    guard let key = Data(base64Encoded: console.registKey), key.count == 16 else {
        throw fail("The saved pairing for \(console.nickname) has no usable registration key")
    }
    let sent = Discovery.wake(address: console.address, registKey: Array(key), ps5: console.ps5)
    print(sent ? "Wake sent to \(console.nickname) at \(console.address)" : "Wake to \(console.address) failed")
}

func pair(_ args: [String]) throws {
    guard let host = option("host", in: args) else { throw fail("pair needs --host IP") }
    guard let pinText = option("pin", in: args), pinText.count == 8, let pin = UInt32(pinText) else {
        throw fail("pair needs --pin with the 8 digits the console shows")
    }
    let ps5 = !args.contains("--ps4")
    guard let accountText = Config.load(psrpConfig).accountId, let account = Data(base64Encoded: accountText),
          account.count == 8 else {
        throw fail("No PSN account ID in \(psrpConfig.path)")
    }
    let started = Date()
    let result: PairingResult
    do {
        result = try Registration.register(address: host, ps5: ps5, accountId: Array(account), pin: pin)
    } catch let error as RegistrationError {
        let reason = error.reasonCode.map { String(format: " reason 0x%08x", $0) } ?? ""
        throw fail("Pairing failed (\(error.kind)\(reason), console answered: \(error.consoleAnswered)): "
                   + error.userMessage(ps5: ps5))
    }
    var config = Config.load(ownConfig)
    config.accountId = accountText
    config.consoles.removeAll { $0.address == host }
    config.consoles.append(Credentials(
        address: host, ps5: ps5, nickname: result.nickname,
        mac: result.mac.map { String(format: "%02x", $0) }.joined(separator: ":"),
        registKey: Data(result.registKey).base64EncodedString(), rpKey: Data(result.rpKey).base64EncodedString(),
        accountId: accountText))
    try config.save(to: ownConfig)
    print("Paired with \(result.nickname) (\(result.target)) in "
          + "\(String(format: "%.1f", Date().timeIntervalSince(started))) s; saved to \(ownConfig.path)")
}

/// Prints one line at a time, from any thread.
let printLock = NSLock()
func say(_ line: String) {
    printLock.lock()
    print(line)
    fflush(stdout)
    printLock.unlock()
}

/// Session init and ctrl against a console paired in psrp's config (or `--new`: ours). Prints only what is
/// safe: never keys, the nonce, the session ID's text or encrypted header values.
func session(_ args: [String]) async throws {
    let file = args.contains("--new") ? ownConfig : psrpConfig
    let config = Config.load(file)
    let host = option("host", in: args)
    guard let console = host.map({ h in config.consoles.first { $0.address == h } }) ?? config.consoles.first else {
        throw fail("No console paired in \(file.path)\(host.map { " at \($0)" } ?? "")")
    }
    guard let regist = Data(base64Encoded: console.registKey), regist.count == 16,
          let rp = Data(base64Encoded: console.rpKey), rp.count == 16 else {
        throw fail("The saved pairing for \(console.nickname) has no usable keys")
    }
    let seconds = option("seconds", in: args).flatMap(Double.init) ?? 20
    // `--login-pin -` reads the PIN from stdin, so it doesn't show in `ps`.
    var pin = option("login-pin", in: args)
    if pin == "-" { pin = readLine(strippingNewline: true) }
    let started = Date()
    @Sendable func stamp() -> String { String(format: "%6.2f s", Date().timeIntervalSince(started)) }

    let ended = Locked(false)
    let givenPIN = pin
    let handler: @Sendable (ControlEvent, ControlSession) -> Void = { event, current in
        switch event {
        case .sessionInitialized(let version, let attempts):
            say("\(stamp())  session init ok: status 200, version \(version.protocolVersion), \(attempts) request(s)")
        case .connected(let model, let prohibited):
            say("\(stamp())  ctrl connected: server type \(model.map { "\($0)" } ?? "unknown")"
                + (prohibited ? ", picture prohibited" : ""))
        case .loginPINRequested:
            say("\(stamp())  login PIN requested")
            if let pin = givenPIN {
                do { try current.sendLoginPIN(pin); say("\(stamp())  login PIN sent") } catch {
                    say("\(stamp())  --login-pin is not a valid PIN")
                }
            }
        case .loginPINResult(let accepted):
            say("\(stamp())  login PIN \(accepted ? "accepted" : "wrong")")
        case .sessionID(let id):
            say("\(stamp())  session ID received (\(id.length) characters)")
        case .heartbeat(let count):
            say("\(stamp())  heartbeat #\(count)")
        case .displayNotice(let notice):
            switch notice {
            case .a(let set): say("\(stamp())  display notice A \(set ? "set" : "cleared")")
            case .b(let payload, let clears): say("\(stamp())  display notice B, \(payload.count) bytes, clears: \(clears)")
            }
        case .keyboardOpened(let text):
            say("\(stamp())  keyboard opened (\(text.utf8.count) bytes of text)")
        case .keyboardTextChanged(let sequence, let text):
            say("\(stamp())  keyboard text changed #\(sequence) (\(text.utf8.count) bytes)")
        case .keyboardClosed:
            say("\(stamp())  keyboard closed by console")
        case .notice(let type, let payload):
            say("\(stamp())  notice type 0x\(String(format: "%04x", type)), \(payload.count) bytes")
        case .ended(let reason):
            say("\(stamp())  ended: \(reason)")
            ended.with { $0 = true }
        }
    }

    say("Starting a session with \(console.nickname) at \(console.address)")
    let control: ControlSession
    do {
        control = try await ControlSession.start(
            address: console.address, target: console.ps5 ? .ps5v1 : .ps4v10, registKey: Array(regist),
            rpKey: Array(rp), events: handler)
    } catch let error as SessionError {
        throw fail("Session failed (\(error)): \(error.userMessage(ps5: console.ps5))")
    }
    func wait(_ limit: Double) async {
        let deadline = Date().addingTimeInterval(limit)
        while !ended.with({ $0 }) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    await wait(seconds)
    if args.contains("--sleep") && !ended.with({ $0 }) {
        say("\(stamp())  sending go to bed")
        try? control.goToBed()
        await wait(3)
    }
    control.stop()
    await wait(2)
}

/// A lock-protected value shared with the event handler.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "discover": try discover(args)
    case "wake": try wake(args)
    case "pair": try pair(args)
    case "session": try await session(args)
    case "stream": try await stream(args, configFile: args.contains("--new") ? ownConfig : psrpConfig)
    case "bench-transport": try benchTransport(args)
    default:
        print("usage: pfxp discover [--host IP] [--timeout S] | wake [--host IP] [--new] | pair --host IP --pin PIN [--ps4]\n"
              + "       | session [--host IP] [--new] [--seconds N] [--login-pin PIN] [--sleep]\n"
              + "       | stream [--host IP] [--new] [--seconds N] [--resolution 360|540|720|1080] [--fps 30|60]\n"
              + "                [--codec h264|hevc|hevc-hdr] [--bitrate KBPS] [--transport bsd|nw] [--out FILE]\n"
              + "                [--audio-out FILE] [--login-pin PIN|-] [--mic-info]\n"
              + "                [--press SCRIPT] [--trace-input] [--drop PERCENT [--drop-burst N]]\n"
              + "                  SCRIPT: BUTTONS@SECONDS[:HOLD_MS] or AXIS=VALUE@SECONDS[:HOLD_MS], comma-separated, from\n"
              + "                  `connected`, e.g. ps@2,circle@4,cross+up@7:300,ly=-1@9:2000 (hold 150 ms by default;\n"
              + "                  buttons: cross circle square triangle l1 r1 l2 r2 l3 r3 options share create ps touchpad\n"
              + "                  up down left right; axes: lx ly rx ry -1...1, l2 r2 0...1)\n"
              + "                  --drop: TESTING ONLY, drops that % (above 0, at most 50) of received datagrams; --drop-burst\n"
              + "                  N (1 to 1000) drops N in a row each time\n"
              + "                  --trace-input: print each controller state handed to the session when it changes\n"
              + "       | bench-transport [--packets N] [--rate R]   (loopback only)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("pfxp: \(error)\n".utf8))
    exit(1)
}
