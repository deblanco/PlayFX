// pfxp: drives PlayFXProtocol against a real console, side by side with `psrp` (libchiaki).
//
//   pfxp discover [--host IP] [--timeout S]       consoles on the LAN (or one address)
//   pfxp wake [--host IP] [--new]                  wakes a console paired in ~/.config/psrp/config.json
//                                                  (--new: with a pairing made by `pfxp pair`)
//   pfxp pair --host IP --pin 12345678 [--ps4]     pairs; saves to ~/.config/playfx-protocol/config.json
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

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "discover": try discover(args)
    case "wake": try wake(args)
    case "pair": try pair(args)
    default:
        print("usage: pfxp discover [--host IP] [--timeout S] | wake [--host IP] [--new] | pair --host IP --pin PIN [--ps4]")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("pfxp: \(error)\n".utf8))
    exit(1)
}
