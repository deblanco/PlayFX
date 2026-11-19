import Foundation
import Testing
@testable import StreamCore

@Suite struct SecretStoreTests {
    @Test func fileStoreKeepsValuesPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playfx-secrets-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileSecretStore(url: url)
        #expect(store.get("consoles") == nil)
        try store.set("consoles", #"{"HOST":1}"#)
        try store.set("accountId", "abc=")
        #expect(FileSecretStore(url: url).get("consoles") == #"{"HOST":1}"#) // survives a new instance
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        store.remove("consoles")
        store.remove("missing")
        #expect(store.get("consoles") == nil && store.get("accountId") == "abc=")
    }

    @Test func anUnreadableFileIsNeverWrittenOver() throws {
        // Saving one console's keys over a file that didn't decode would delete every other one.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playfx-secrets-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        let store = FileSecretStore(url: url)
        #expect(store.get("consoles") == nil)
        #expect(throws: (any Error).self) { try store.set("consoles", "x") }
        store.remove("consoles")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{not json")
    }

    @Test func privateFilesAreNeverReadableByOthers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("playfx-private-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("keys.json")
        try PrivateFile.write(Data("a".utf8), to: url)
        try PrivateFile.write(Data("b".utf8), to: url) // replaces
        #expect(try String(contentsOf: url, encoding: .utf8) == "b")
        let attributes = { (path: String) in try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int }
        #expect(try attributes(url.path) == 0o600 && attributes(folder.path) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keys.json"]) // no temp left
    }
}

extension Serial {
    @Suite struct SecretBridgeTests {
        @Test func bridgeReadsAndWritesTheSharedStore() throws {
            let previous = SecretStores.shared
            SecretStores.shared = MemorySecretStore() // never the real secrets
            defer { SecretStores.shared = previous }
            func reply(_ p: UnsafeMutablePointer<CChar>) -> String { defer { sc_free(p) }; return String(cString: p) }
            #expect(reply("k".withCString(sc_secret_get)) == #"{"value":null}"#)
            #expect(reply("k".withCString { k in "v".withCString { sc_secret_set(k, $0) } }) == #"{"ok":true}"#)
            #expect(reply("k".withCString(sc_secret_get)) == #"{"value":"v"}"#)
            "k".withCString(sc_secret_remove)
            #expect(SecretStores.shared.get("k") == nil)
        }
    }
}
