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
