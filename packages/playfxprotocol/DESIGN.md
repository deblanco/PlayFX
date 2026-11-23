# PlayFXProtocol design

How the package is built. The wire protocol itself is in [`docs/protocol`](../../docs/protocol/README.md);
this file is about using what Apple's platform gives us natively, which a portable C library like
libchiaki couldn't.

## Principles
- **Native frameworks first.** Prefer Network.framework, CryptoKit, CommonCrypto, Security, os
  (workgroups, signposts, logging), AudioToolbox, Accelerate over bundled third-party code. Every
  dependency we don't carry is one we don't have to license, update or audit.
- **Measured, not assumed.** Where two native paths compete (Network.framework vs BSD sockets for the
  stream), both sit behind one small Swift protocol and the console decides: Diagnostics' reorder-wait
  stats, lost/skipped frames, the dev latency test (docs/dev-control.md), CPU per 1,000 packets.
- **No allocation per packet in the stream path.** Raw buffers (`UnsafeRawBufferPointer`), structs, a
  preallocated ring. The stream's receive runs on its own user-interactive thread; there are no
  actors or `async` in the packet path. Control-plane code (discovery, registration, session init)
  can use `async`/`await` freely.
- **Testable without a console.** Every socket sits behind a protocol, so tests feed recorded bytes
  (`Tests/PlayFXProtocolTests/Fixtures`), the same way StreamCore injects hardware engines.

## Network
| Need | Native choice | Why |
|---|---|---|
| Discovery and wake (UDP broadcast) | BSD socket with `SO_BROADCAST` | Network.framework has no broadcast send. |
| Registration, session init (HTTP over TCP) | `NWConnection` (TCP) + our minimal HTTP/1.1 | The requests are hand-built with exact headers, so a URLSession request doesn't fit. |
| Ctrl channel (TCP) | `NWConnection` + `NWProtocolFramer` for its framing | The framer parses frames off the stream, so the message code never sees partial reads. |
| Stream (Takion, UDP, ~2,000 packets/s) | **Measure both:** `NWConnection` UDP vs a BSD socket on a dedicated thread | See below. |
| Wi-Fi QoS (WMM queues) | `serviceClass = .interactiveVideo` (NW) / `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` (socket) | Marks packets so the Mac's Wi-Fi sends them in the video access category instead of best effort: lower queuing delay under load. Public API. libchiaki sends best effort. |
| Kernel receive timestamps | `calculateReceiveTime` metadata (NW) / `SO_TIMESTAMP` (socket) | Jitter and the reorder wait are measured from when the packet hit the Mac, not when our thread woke up. |
| Interface changes | `NWPathMonitor` | Wi-Fi ⇄ Ethernet, VPN or link loss shows up as an event: reconnect or warn instead of timing out. It also tells Diagnostics which interface the stream uses. |
| Send batching | `NWConnection.batch` / one send per buffered burst | Input and feedback packets go out together. |
| Local network access | `NSLocalNetworkUsageDescription` in the app's Info.plist | Needed for LAN traffic on recent macOS (and the App Store). |

**Stream transport, the open question.** Network.framework runs UDP through Apple's user-space
networking path with batched reads, which Apple presents as cheaper per packet than socket syscalls. But
every datagram arrives as a `dispatch_data_t` (an object per packet) through a dispatch-queue callback.
A BSD socket read by a blocking `recvmsg` loop on a user-interactive thread (QoS class, optionally joined
to an `os_workgroup`) allocates nothing and wakes exactly when the packet lands. Both implementations
are small. Build both behind a `DatagramTransport` protocol and keep the one that wins on the console.

Not used: private SPI (`recvmsg_x`/`sendmsg_x`, private socket options). The App Store rejects it.

## Crypto
- AES-128 ECB/CFB/CTR: CommonCrypto (hardware AES).
- AES-GCM, HMAC-SHA256, SHA-256, secure random: CryptoKit / `SecRandomCopyBytes`.
- ECDH on secp256k1 for the stream handshake: not in CryptoKit. Pick an MIT/BSD package when the stream
  milestone starts, and check its licence file.

## Later stages (native replacements to evaluate)
- **Opus audio:** AudioToolbox's `AudioConverter` with `kAudioFormatOpus` could replace libopus (verify
  decode and encode for the mic on macOS 13+).
- **FEC:** Reed-Solomon over GF(2^8) in Swift with SIMD/Accelerate instead of jerasure + gf-complete,
  only if it measures at least as fast. Otherwise keep jerasure (BSD).
- **Instrumentation:** `os_signpost` intervals per frame (first packet → complete → decoded → shown), so
  Instruments shows where latency goes.

## Deviations from observed clients
- **Session ID.** If the console's session ID (ctrl `0x33`) is malformed, or none arrives within the start-up
  time, `ControlSession` ends the channel (`.invalidSessionID` / `.startupTimeout`). One existing client
  instead invents an ID and carries on (ctrl.md section 6.2). Whether a console accepts an invented ID is
  unverified (ctrl.md open question 8), and a stream that fails later, with a vaguer error, is harder to
  diagnose than a clear end here. Revisit if a real console is seen to need it.
- **Events carry the session.** The handler is `(ControlEvent, ControlSession)`, because the console's first
  frames (a login PIN request) can arrive before `start` returns.
