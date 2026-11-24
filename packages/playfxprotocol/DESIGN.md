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
| Stream (Takion, UDP, ~2,000 packets/s) | **A BSD socket on a dedicated thread** (default); `NWConnection` UDP kept as an alternative | See below. |
| Wi-Fi QoS (WMM queues) | `serviceClass = .interactiveVideo` (NW) / `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` (socket) | Marks packets so the Mac's Wi-Fi sends them in the video access category instead of best effort: lower queuing delay under load. Public API. libchiaki sends best effort. |
| Kernel receive timestamps | `calculateReceiveTime` metadata (NW) / `SO_TIMESTAMP` (socket) | Jitter and the reorder wait are measured from when the packet hit the Mac, not when our thread woke up. |
| Interface changes | `NWPathMonitor` | Wi-Fi ⇄ Ethernet, VPN or link loss shows up as an event: reconnect or warn instead of timing out. It also tells Diagnostics which interface the stream uses. |
| Send batching | `NWConnection.batch` / one send per buffered burst | Input and feedback packets go out together. |
| Local network access | `NSLocalNetworkUsageDescription` in the app's Info.plist | Needed for LAN traffic on recent macOS (and the App Store). |

**Stream transport.** Network.framework runs UDP through Apple's user-space
networking path with batched reads, which Apple presents as cheaper per packet than socket syscalls. But
every datagram arrives as a `dispatch_data_t` (an object per packet) through a dispatch-queue callback.
A BSD socket read by a blocking `recvmsg` loop on a user-interactive thread (QoS class, optionally joined
to an `os_workgroup`) allocates nothing and wakes exactly when the packet lands. Both implementations
are small. Both are built behind a `DatagramTransport` protocol (`StreamTransport.bsd` / `.nw`).

**Decision (2026-11-24): the BSD socket thread is the default; Network.framework stays, built and tested.**
On loopback (release, 20,000 packets/s) the BSD thread took 8.2 ms CPU per 1,000 packets against 27 ms, with
0 allocations per packet against 28. On the PS5 (1080p60 HEVC in a game, 11–14 Mbit/s, about 41,000 packets
in 30 s each) the two were indistinguishable: nothing lost on either. The cheaper path matters more on a phone
(battery, heat), and BSD sockets are fully supported on iOS, so an iOS port doesn't change the default; `.nw`
is kept as a fallback in case a platform or network turns up where it does better (re-measure on an iPhone).
Network.framework's one real advantage, following path changes, is had with `NWPathMonitor` beside the socket.

Not used: private SPI (`recvmsg_x`/`sendmsg_x`, private socket options). The App Store rejects it.

## Crypto
- AES-128 ECB/CFB/CTR: CommonCrypto (hardware AES).
- HMAC-SHA256, SHA-256, secure random: CryptoKit / `SecRandomCopyBytes`.
- The Takion GMAC (AES-GCM with a 16-byte IV, empty plaintext, 4-byte tag) is our own table-driven GHASH over
  CommonCrypto AES: CryptoKit's GCM allocates on every call and the stream path allows none. A randomised
  differential test checks it against CryptoKit's `AES.GCM` with a 16-byte nonce.
- ECDH on secp256k1 for the stream handshake: not in CryptoKit. libsecp256k1 v0.8.0 (bitcoin-core, MIT),
  vendored unmodified as the C target `CSecp256k1` (core + ECDH module; `Sources/CSecp256k1/README.PlayFX`).
  When the app first links PlayFXProtocol, `scripts/third-party-licenses.py` must list it.

## Later stages (native replacements to evaluate)
- **Opus audio:** AudioToolbox's `AudioConverter` with `kAudioFormatOpus` could replace libopus (verify
  decode and encode for the mic on macOS 13+).
- **FEC:** Reed-Solomon over GF(2^8) in Swift with SIMD/Accelerate instead of jerasure + gf-complete,
  only if it measures at least as fast. Otherwise keep jerasure (BSD).
- **Instrumentation:** `os_signpost` intervals per frame (first packet → complete → decoded → shown), so
  Instruments shows where latency goes.

## StreamSession
`StreamSession` (Sources/PlayFXProtocol/Session) runs a whole stream: `ControlSession`, the network probe, the
Takion stream connection and its handshake, the AV layer, controller input and the end. Its API and the exact
thread of each event are documented on the class.

- **Two threads deliver events.** The Takion receive thread calls the app's handler directly for `connected` (once,
  before any AV event), `audioHeader`, `videoAccessUnit`, `parameterSets`, `audioPacket` and `haptics`, with no
  allocation per packet; the handler must be fast and copy what it keeps. Everything else (rumble, trigger effects,
  pad info, quality, ctrl events, `stats`, `ended`) goes to the session's private serial queue. An `EventGate`
  guarantees that no handler call is in flight, or starts, once `ended` has been delivered.
- **One end.** `stop()`, a console Disconnect, a lost Takion connection and a ctrl end all reach one `finish` on the
  control queue, which sends the Disconnect, closes Takion and ctrl and delivers `ended` exactly once.
- **`start` throws until the stream is up** (`StreamStartError`, no `ended` event); after that every ending is an
  `ended` event. The probe is best effort (stream.md section 5): a failure uses the fallbacks and is reported in
  `connected`.
- **Feedback numbering lives in `TakionConnection`.** It numbers and repeats the state and history packets itself
  (takion.md sections 9.3, 9.4), so the session passes it bodies from `FeedbackState.body` and events from
  `ControllerEvent.events`; `FeedbackStateBuilder` and `FeedbackHistoryBuilder` would number a second time.
- **Simulated receive loss (testing only).** `StreamSessionOptions.simulatedReceiveLoss` (`SimulatedLoss`: percent,
  burst, seed; off by default) wraps the stream connection's `DatagramTransport` in `LossyDatagramTransport`, which
  drops datagrams before Takion sees them, so FEC, the reorder queue, Takion retransmission and corrupt-frame reports
  run on real console traffic. It is armed when the stream is up (the handshake is left alone) and never touches the
  probe. The gate is splitmix64 plus integer maths, behind an `UnfairLock` for the counter (`StreamStats.simulatedDrops`):
  no allocation per packet, asserted by the release allocation test with loss on. `percent` is the long-run share of
  datagrams dropped whatever the burst; a burst starts with probability `p / (n (1 - p) + p)`. A lost frame still sends a
  corrupt-frame report, which allocates: that is per lost frame, not per packet.
- **Controller script.** `ControllerScript` (`pfxp stream --press`) turns `BUTTONS@SECONDS[:HOLD_MS]` and
  `AXIS=VALUE@SECONDS[:HOLD_MS]` entries into the `ControllerState` at any time `t` (`state(at:)`) and the next moment
  it changes (`nextChange(after:)`); overlapping entries combine. `pfxp` sends that state at least every 100 ms and
  wakes at each change to send it at once.
- **Two receive-side diagnostics.** `StreamStats.videoCodecByte` (the last `codec` byte of a video header) and
  `padInfoBodyLength` (17 or 25) record what the console actually sends: the codec byte is otherwise unused (the AV layer
  is told the codec from the launch spec), and both forms of pad info parse. They are set on the receive thread only
  when the value changes, so the per-packet cost is one comparison.
- **Mic frames.** The packets are built and sent (`sendMicrophoneFrame`); there is no Opus encoder yet, so the app
  encodes. `setMicrophone(on:)` is ctrl signalling only.

## Internet play
`StreamSession.start(remote:...)` and `Registration.registerThroughPSN` reach a console through PSN (docs/protocol
holepunch.md section 8). `InternetConnector` (Sources/PlayFXProtocol/Internet) runs steps 1 to 8 and hands an `InternetLink`
to `StreamSession`, which runs session init and ctrl (9, 10) and then asks the link for the data hole, the probe and stream
sockets and the switch (11 to 14).

- **One new seam per layer, the LAN path untouched.** `ControlSession` talks to a `CtrlLink` (`NWCtrlLink`: the TCP
  connection and framer, as before; `RUDPCtrlLink`: the ctrl hole's RUDP channel). Session init's `BlockingTCPConnection`
  is implemented over RUDP (`RUDPHTTPConnection`: `send` runs the whole exchange), so version negotiation, retries and
  errors are the LAN code. `ControlEnvironment.internet` switches the three ctrl.md section 10 differences (a PS5 skips
  one counter after the request, the PIN reply uses `localCounter - 1`, an unrequested heartbeat reply every 4.95 s) and
  makes a failure before the response header final instead of retried.
- **The hole punch stays blocking and thread-based.** `PSNPunchSignaling` implements `PunchSignaling` over
  `PSNRemotePlaySession` (which was split into `receiveOffer`/`sendOffer` and `sendAccept`/`receiveAccept`, so the punch's
  order of calls maps one to one) and waits for each async call on the punch's own thread. It keeps the PSN error that ended
  a call, so the app sees `.psn(...)` and not a vague "signalling failed".
- **One socket per hole, handed on as a descriptor.** After the data hole, `POSIXPunchSocket.releaseDescriptor()` gives the
  connected descriptor to `BSDDatagramTransport(adopting:)`. The probe gets a `dup` (its end closes only the copy), the
  stream connection the original (its end closes the socket), and `PunchedSocket.drain` empties the queue before each (takion.md
  section 18). The receive loop is the LAN one, so the allocation test covers it. Internet play uses the BSD transport only
  (Network.framework can't adopt a descriptor).
- **Giving everything back is the link's job.** `InternetLink.shutdown()` closes the sockets and the RUDP connection, leaves the
  PSN session (DELETE, the wait, the push channel) and removes the UPnP mappings; it runs once, on every path: a failed
  or cancelled `prepare`, a failed start, `stop()`, a console end, a dropped session. Cancelling interrupts the punch, STUN,
  the PSN waits and RUDP through one `CancelToken`.
- **Cancelling returns at once, quitting can wait.** A cancelled start starts the shutdown and returns without waiting for
  the PSN leave (up to 13 s on a bad network). `StreamSession.stopAndWait()` stops and waits for the DELETE and the UPnP
  removal: use it when the process exits next. Waits for the RUDP switch acknowledgement end at once on a cancel, a
  closed connection or the console's FINISH (`RUDPConnection.waitForSwitch`), so none of them is reported as a missing
  `0x0034`.
- **Descriptors.** The link clears the punched descriptor in the same locked section that marks it shut, and the probe
  and stream transports take it under that lock, so a closed number is never `dup`ed or adopted.
- **Typed errors.** `InternetStartError` wraps PSN, hole-punch, registration (`consoleAnswered` picks stream.md reasons 13
  and 14), session and stream failures, with `userMessage`, `endReason` and `retryClass`. It is a separate type from
  `StreamStartError`, so code that handles the LAN errors doesn't change.
- **Tests.** `InternetRig` (Tests/.../Session) wires `FakePSN` (HTTP and WebSocket stubs), `InternetConsole`
  (PlayFXProtocolTestSupport: `PunchedUDPEndpoint` answers probes, `RUDPConsole` speaks registration, init, ctrl and the
  switch through the same `CtrlPeer` as the LAN console, the probe and stream Takion consoles share the data endpoint)
  and a fake router. Every socket is loopback; the punch sockets are wrapped in the loopback guard.

## Deviations from observed clients
- **Hole-punch probes are checked.** The reference answers any parseable probe from anyone. Here a probe counts only if
  its sender is the console (hashed id and `sid` from its OFFER) and its receiver is us; others create no derived
  candidate, get no answer and can't select a pair. holepunch.md section 5.1 calls the console's own perspective in its
  probes assumed, so the first mismatch of a hole is logged once (which fields differed, never their values).
  `InternetOptions.probeIdentity = .logOnly` accepts them like the reference and only logs, for the first hardware round.
- **The data hole starts when ctrl has the session ID,** not in parallel after at most 10 s (holepunch.md section 8, last
  note). Ctrl's own 10 s start-up limit still applies; the extra 5 s the reference waits is not used.
- **No third-party STUN list.** The built-in servers are used (shuffled as holepunch.md section 3.2 says); the GitHub host list
  isn't fetched.
- **A registration that outlives its 10 s** ends the start with a typed `registration` error (timeout), not "plainly stopped".

- **Session ID.** If the console's session ID (ctrl `0x33`) is malformed, or none arrives within the start-up
  time, `ControlSession` ends the channel (`.invalidSessionID` / `.startupTimeout`). One existing client
  instead invents an ID and carries on (ctrl.md section 6.2). Whether a console accepts an invented ID is
  unverified (ctrl.md open question 8), and a stream that fails later, with a vaguer error, is harder to
  diagnose than a clear end here. Revisit if a real console is seen to need it.
- **Events carry the session.** The handler is `(ControlEvent, ControlSession)`, because the console's first
  frames (a login PIN request) can arrive before `start` returns.
- **Decoder rejections raise no IDR request (av.md section 4.3 step 3).** A rejected frame only leaves `lastGood`
  alone; it doesn't set the IDR wait either (an earlier version asked for a key frame at once, which
  looped at one request per round trip when a decoder kept failing). PlayFX adds a separate, clearly
  labelled `VideoCallbacks.decoderRejecting(consecutive)`, raised at most once per second from the 5th
  rejection in a row. It is not an IDR request; the app decides what to do (rebuild the decoder, ask for a key frame).
- **Missing reference: optional IDR request.** av.md sends none; `VideoReceiver(idrOnMissingReference:)` (default
  off) requests one, for a console that turns out to ignore corrupt-frame reports.
- **Audio gap cap (not in av.md section 6.5).** An outage mustn't fire thousands of events. A gap conceals up
  to `AudioReceiver.maxConcealedFrames` frames (the larger of 64 and 500 ms of frames at the header's
  rate, 640 ms at 10 ms frames) with one `.lost` each; the rest is one `.skipped(firstFrame:count:)` event
  and the jitter buffer resynchronises.
- **Thread safety.** The congestion counters (`takeCongestionCounters`, `AudioReceiver.statistics`) sit behind
  an `OSAllocatedUnfairLock`, so the transport's 200 ms timer can read them while the receive thread
  writes; everything else in the AV layer is receive-thread only. Checked under ThreadSanitizer.
- **Mic StreamInfo off by default.** stream.md section 6.7 step 3 has existing clients always send the microphone
  StreamInfo. `StreamSession` sends it only with `StreamSessionOptions.microphone` (`pfxp stream --mic-info`).
  Whether a console needs it is for the hardware round to compare, with and without.
- **Ctrl end grace.** A ctrl end during the stream waits up to 200 ms for the console's Takion Disconnect, so the
  console's reason text isn't lost to the ctrl close that usually arrives a moment before it.
