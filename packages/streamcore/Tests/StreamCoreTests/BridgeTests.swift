import AppKit
import Foundation
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

extension Serial {
    @Suite struct BridgeTests {
        @Test func psnURLs() throws {
            #expect(take(sc_psn_login_url()) == PSNAuth.loginURL.absoluteString)
            #expect(take(sc_psn_redirect_url()) == PSNAuth.redirectURL)
            sc_free(nil)
        }

        @Test func psnAccountId() throws {
            #expect(try call(sc_psn_account_id, "https://example.com/redirect?nothing=1")["error"] as? String == "No sign-in code in URL")

            StubURLProtocol.handler = psnStub(userId: "1")
            PSNAuth.urlSession = StubURLProtocol.session()
            defer { PSNAuth.urlSession = .shared; StubURLProtocol.handler = nil }
            #expect(try call(sc_psn_account_id, PSNAuth.redirectURL + "?code=abc")["accountId"] as? String == "AQAAAAAAAAA=")
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
        }

        @Test func eventPayloads() {
            #expect(eventPayload(.connected) as? [String: String] == ["type": "connected"])
            let quit = eventPayload(.quit(reason: "Bye", error: true, busy: true))
            #expect(quit?["type"] as? String == "quit" && quit?["reason"] as? String == "Bye" && quit?["error"] as? Bool == true)
            #expect(quit?["busy"] as? Bool == true)
            let pin = eventPayload(.loginPinRequested(incorrect: false))
            #expect(pin?["type"] as? String == "loginPin" && pin?["incorrect"] as? Bool == false)
            let nick = eventPayload(.nickname("PS5"))
            #expect(nick?["type"] as? String == "nickname" && nick?["name"] as? String == "PS5")
            #expect(eventPayload(.rumble(left: 1, right: 2)) == nil)
        }

        @Test @MainActor func rendererBeforeAttach() {
            // The bridge's renderer is process-wide; this only holds until a window is attached.
            if sc_active_mode() == -1 {
                #expect(!sc_metalfx_supported())
                #expect(sc_gpu_milliseconds() == 0)
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
            #expect(try call(sc_session_start, request)["ok"] as? Bool == true)
            let stats = try object(sc_session_stats())
            #expect(stats["active"] as? Bool == true && stats["framesDecoded"] as? Int == 0)
            "1234".withCString(sc_session_set_login_pin)

            // Loopback has no console: the session quits with an error event.
            #expect(await waitUntil { receivedEvents.lines.contains { $0.contains(#""type":"quit""#) } })
            // The quit handler stops the session on the main queue.
            #expect(await waitUntil { (try? object(sc_session_stats())["active"] as? Bool) == false })
            sc_session_stop()
            window.close()
        }
    }
}
