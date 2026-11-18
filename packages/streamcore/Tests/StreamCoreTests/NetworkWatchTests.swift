import Testing
@testable import StreamCore

@Suite struct NetworkWatchTests {
    typealias S = NetworkWatch.Summary

    @Test func reconnectsWhenTheMacIsOnAnotherNetworkOrBackOnline() {
        let wifi = S(online: true, primary: "en0"), ethernet = S(online: true, primary: "en7"), off = S(online: false, primary: nil)
        #expect(NetworkWatch.change(from: wifi, to: ethernet) == .changed)
        #expect(NetworkWatch.change(from: off, to: wifi) == .changed)
        #expect(NetworkWatch.change(from: wifi, to: off) == .offline)
        #expect(NetworkWatch.change(from: wifi, to: wifi) == nil) // e.g. an address renewal
        #expect(NetworkWatch.change(from: off, to: off) == nil)
    }

    @Test func eventPayload() {
        #expect(networkPayload(.changed)["online"] as? Bool == true)
        #expect(networkPayload(.offline)["online"] as? Bool == false)
        #expect(networkPayload(.changed)["type"] as? String == "network")
    }

    @Test func startsAndStopsQuietly() async throws {
        var changes: [NetworkWatch.Change] = []
        var watch: NetworkWatch? = NetworkWatch { changes.append($0) }
        try await Task.sleep(for: .milliseconds(200)) // the first report is the network at start, not a change
        #expect(changes.isEmpty)
        watch = nil
        _ = watch
    }
}
