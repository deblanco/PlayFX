import AppKit
import Foundation
import os
import Testing
@testable import StreamCore

/// Takes ownership of a string returned by the bridge.
private func take(_ p: UnsafeMutablePointer<CChar>) -> String {
    defer { sc_free(p) }
    return String(cString: p)
}

private func object(_ p: UnsafeMutablePointer<CChar>) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(take(p).utf8)) as? [String: Any])
}

private func call(_ f: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>, _ s: String) throws -> [String: Any] {
    try object(s.withCString(f))
}

private func json<T: Encodable>(_ v: T) -> String { String(decoding: try! JSONEncoder().encode(v), as: UTF8.self) }

private let receivedEvents = LockedLines()
private let receivedLogs = LockedLines()

extension Serial {
    @Suite struct BridgeTests {
        @Test func logsReachTheHostScrubbed() {
            sc_set_log_callback({ level, area, message in
                receivedLogs.append("\(level) \(String(cString: area)) \(String(cString: message))")
            }, false)
            defer { sc_set_log_callback(nil, false) }
            Log.debug(.session, "not without detailed logs")
            Log.warning(.psn, "refresh failed: refresh_token=abc")
            sc_set_log_detailed(true)
            Log.debug(.session, "detailed now")
            // Other tests log in parallel; look at this test's messages only.
            let mine = receivedLogs.lines.filter { $0.contains("refresh failed") || $0.contains("detailed") }
            #expect(mine == ["2 psn refresh failed: refresh_token=<redacted>", "0 session detailed now"])
        }

        @Test func blockingCallsReturnOrGiveUpAndCancel() throws {
            #expect(try blocking(timedOut: "late") { 42 }.get() == 42)
            #expect(throws: ConsoleError.self) { try blocking(timedOut: "late") { throw ConsoleError.message("no") }.get() }
            // Too slow: the caller gets the timeout, and the work is cancelled, not left to finish later.
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            let slow = blocking(timeout: 0.1, timedOut: "late") { () async throws -> Int in
                do { try await Task.sleep(for: .seconds(5)) } catch { cancelled.withLock { $0 = true }; throw error }
                return 1
            }
            #expect(throws: (any Error).self) { try slow.get() }
            if case .failure(let error) = slow { #expect(error.localizedDescription == "late") }
            Thread.sleep(forTimeInterval: 0.2)
            #expect(cancelled.withLock { $0 })
        }

        @Test func psnURLs() throws {
            // Each sign-in URL carries a new device ID; the rest is fixed.
            let withoutDUID = { (url: String) in url.replacingOccurrences(of: #"&duid=[0-9a-f]{48}"#, with: "", options: .regularExpression) }
            #expect(withoutDUID(take(sc_psn_login_url())) == withoutDUID(PSNAuth.loginURL.absoluteString))
            #expect(take(sc_psn_redirect_url()) == PSNAuth.redirectURL)
            sc_free(nil)
        }

        @Test func psnAccountId() throws {
            // Never the real store: a successful sign-in here would replace the user's PSN tokens.
            let real = PSNAccount.shared
            let store = MemoryTokenStore()
            PSNAccount.shared = PSNAccount(store: store)
            defer { PSNAccount.shared = real }
            #expect(try call(sc_psn_account_id, "https://example.com/redirect?nothing=1")["error"] as? String == "No sign-in code in URL")

            StubURLProtocol.handler = psnStub(userId: "1")
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            #expect(try call(sc_psn_account_id, PSNAuth.redirectURL + "?code=abc")["accountId"] as? String == "AQAAAAAAAAA=")
            #expect(store.tokens?.accessToken == "tok123") // kept in the test's store only
            StubURLProtocol.handler = psnStub(userId: nil)
            #expect(try call(sc_psn_account_id, "abc")["error"] as? String == "PSN sign-in failed: no user_id in token info")
        }

        @Test func register() throws {
            #expect(try call(sc_register, "not json")["error"] != nil)
            #expect(try call(sc_register, #"{"address":"127.0.0.1"}"#)["error"] != nil)
            let bad = #"{"address":"127.0.0.1","ps5":true,"accountId":"AQID","pin":"12345678"}"#
            #expect(try call(sc_register, bad)["error"] as? String == "The PSN account ID must be 8 bytes encoded as base64")
            let loopback = #"{"address":"127.0.0.1","ps5":true,"accountId":"AQEBAQEBAQE=","pin":"12345678"}"#
            #expect((try call(sc_register, loopback)["error"] as? String)?.hasPrefix("Registration failed") == true)
        }

        @Test func wakeup() {
            #expect(!"{}".withCString(sc_wakeup))
            #expect(!json(fakeCredentials(registKey: "zz")).withCString(sc_wakeup))
            _ = json(fakeCredentials()).withCString(sc_wakeup)
        }

        @Test func discover() throws {
            let text = take(sc_discover(50))
            #expect(try JSONDecoder().decode([DiscoveredConsole].self, from: Data(text.utf8)).count >= 0)
            #expect(text.hasPrefix("["))
            // Asked directly at an address nothing answers on (TEST-NET-1): no consoles.
            #expect(take("192.0.2.1".withCString { sc_discover_host($0, 50) }) == "[]")
        }

        @Test func eventPayloads() {
            #expect(eventPayload(.connected) as? [String: String] == ["type": "connected"])
            let quit = eventPayload(.quit(reason: "Bye", error: true, kind: .busy))
            #expect(quit?["type"] as? String == "quit" && quit?["reason"] as? String == "Bye" && quit?["error"] as? Bool == true)
            #expect(quit?["kind"] as? String == "busy")
            let progress = eventPayload(.remoteProgress(.data))
            #expect(progress?["type"] as? String == "remoteProgress" && progress?["stage"] as? String == "data")
            let pin = eventPayload(.loginPinRequested(incorrect: false))
            #expect(pin?["type"] as? String == "loginPin" && pin?["incorrect"] as? Bool == false)
            let nick = eventPayload(.nickname("PS5"))
            #expect(nick?["type"] as? String == "nickname" && nick?["name"] as? String == "PS5")
            #expect(eventPayload(.rumble(left: 1, right: 2)) == nil)
            #expect(eventPayload(.light(red: 1, green: 2, blue: 3)) == nil)
            #expect(eventPayload(.playerIndex(0)) == nil)
        }

        @Test @MainActor func rendererBeforeAttach() {
            // The bridge's renderer is process-wide; this only holds until a window is attached.
            if sc_active_mode() == -1 {
                #expect(!sc_metalfx_supported())
                #expect(sc_gpu_milliseconds() == 0)
                #expect(sc_shown_fps() == 0)
                let pacing = take(sc_pacing_stats())
                #expect(pacing.contains("\"skippedFrames\":0"))
                #expect(pacing.contains("\"interpolation\":\"off\"") && pacing.contains("\"upscale\":\"bilinear\""))
                #expect(pacing.contains("\"ml\":\"off\"") && pacing.contains("\"displayHz\":0"))
                sc_session_sleep() // no session: nothing to put to sleep
                #expect(sc_set_render_params(#"{"upscaler":"metalfx"}"#)) // no renderer: accepted, no-op
            }
        }

        @Test @MainActor func sessionLifecycle() async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false // ARC owns it
            let attached = sc_attach_macos_window(Unmanaged.passUnretained(window).toOpaque())
            if attached {
                #expect(window.contentView?.subviews.isEmpty == false)
                #expect(!sc_attach_macos_window(Unmanaged.passUnretained(window).toOpaque())) // only once
            }
            #expect(sc_active_mode() == 0) // bilinear until a frame has gone through MetalFX
            #expect(sc_set_render_params(#"{"upscaler":"bilinear","sharpness":0.5,"compare":true}"#))
            #expect(!sc_set_render_params(#"{"upscaler":"fsr"}"#)) // rejected, nothing changes
            #expect(!sc_set_render_params("not json"))
            _ = sc_metalfx_supported()

            sc_set_event_callback { message in receivedEvents.append(String(cString: message)) }
            defer { sc_set_event_callback(nil) }

            #expect(try object(sc_session_stats())["active"] as? Bool == false)
            #expect(try call(sc_session_start, "{")["error"] != nil)
            var broken = fakeCredentials()
            broken.rpKey = "AAAA"
            #expect(try call(sc_session_start, #"{"credentials":\#(json(broken))}"#)["error"] as? String == "Invalid console credentials")

            var options = StreamSession.Options()
            options.audio = false
            let request = #"{"credentials":\#(json(fakeCredentials())),"options":\#(json(options))}"#
            #expect(!keepingAwake)
            #expect(try call(sc_session_start, request)["ok"] as? Bool == true)
            #expect(keepingAwake) // no sleeping mid-stream
            let stats = try object(sc_session_stats())
            #expect(stats["active"] as? Bool == true && stats["framesDecoded"] as? Int == 0)
            #expect(stats["rttMs"] as? Double == 0) // not measured until connected
            "1234".withCString(sc_session_set_login_pin)

            // Loopback has no console: the session quits with an error event.
            #expect(await waitUntil { receivedEvents.lines.contains { $0.contains(#""type":"quit""#) } })
            // The quit handler stops the session on the main queue, keeping the last frame up.
            #expect(await waitUntil { (try? object(sc_session_stats())["active"] as? Bool) == false })
            if let r = renderer { #expect(r.showsTestPattern) } // no frame ever came: the backdrop kept moving
            #expect(!keepingAwake) // the session ended
            sc_session_stop() // the host went home: idle pattern back
            if let r = renderer { #expect(r.showsTestPattern) }

            // Only the current session's events reach the host: not the "Stopped" quit of one that was
            // replaced (the UI ended the new stream on it), nor that of one the host stopped.
            let silent = fakeCredentials(address: "192.0.2.1") // TEST-NET: never answers
            let quiet = #"{"credentials":\#(json(silent)),"options":\#(json(options))}"#
            receivedEvents.clear()
            #expect(try call(sc_session_start, quiet)["ok"] as? Bool == true)
            #expect(try call(sc_session_start, quiet)["ok"] as? Bool == true) // replaces the first
            sc_session_stop()
            try await Task.sleep(for: .milliseconds(300))
            #expect(!receivedEvents.lines.contains { $0.contains(#""type":"quit""#) })

            // A quit's late cleanup must not end a session started after it.
            #expect(try call(sc_session_start, request)["ok"] as? Bool == true)
            weak let started = session
            let stale = try StreamSession(credentials: fakeCredentials(), options: options)
            cleanUpAfterQuit(of: stale)
            #expect(try object(sc_session_stats())["active"] as? Bool == true)
            stale.stop()
            sc_session_stop()
            // Nothing keeps a stopped session alive (its event handler must not retain it).
            #expect(await waitUntil { started == nil })
            window.close()
        }

        @Test @MainActor func readsMainOnlyStateWithABoundedWait() async {
            #expect(readOnMain { 7 } == 7) // on main: at once
            // From another thread while main is free: main's answer.
            let free = OSAllocatedUnfairLock<Int?>(initialState: nil)
            Thread { let v = readOnMain { 8 }; free.withLock { $0 = v } }.start()
            #expect(await waitUntil { free.withLock { $0 } != nil })
            #expect(free.withLock { $0 } == 8)
            // Main busy longer than the wait: nil, instead of waiting for good (a test process's main, or a stuck one).
            let busy = OSAllocatedUnfairLock<(done: Bool, value: Int?)>(initialState: (false, nil))
            Thread { let v = readOnMain(timeout: 0.05) { 9 }; busy.withLock { $0 = (true, v) } }.start()
            Thread.sleep(forTimeInterval: 0.3)
            #expect(busy.withLock { $0.done } && busy.withLock { $0.value } == nil)
            await MainActor.run {} // let the late read run
        }

        @Test @MainActor func latencyTestTakesTheSessionFromMain() async throws {
            // The dev-control port runs the test on its HTTP thread while main may be ending the stream:
            // the session is taken on main, so a stop main is in the middle of wins, and nothing is tested.
            var options = StreamSession.Options()
            options.audio = false
            let silent = fakeCredentials(address: "192.0.2.1") // TEST-NET: never answers
            #expect(try call(sc_session_start, #"{"credentials":\#(json(silent)),"options":\#(json(options))}"#)["ok"] as? Bool == true)
            let answer = OSAllocatedUnfairLock<String?>(initialState: nil)
            Thread { let text = take(sc_latency_test(1)); answer.withLock { $0 = text } }.start()
            Thread.sleep(forTimeInterval: 0.2) // main is busy: the HTTP thread has asked for the session by now
            sc_session_stop()
            #expect(await waitUntil { answer.withLock { $0 } != nil })
            #expect(answer.withLock { $0 } == #"{"error":"No stream to test"}"#)
        }
    }
}
