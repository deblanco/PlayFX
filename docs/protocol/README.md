# PlayStation Remote Play protocol specification

This folder specifies the PS4/PS5 Remote Play protocol as far as PlayFX needs it, in enough detail to build
an interoperable client (`PlayFXProtocol`, Swift) from these documents alone.

## Documents

| Document | Covers |
|----------|--------|
| [discovery.md](discovery.md) | LAN discovery (search, response fields, polling, when a console counts as gone) and wake from rest mode |
| [registration.md](registration.md) | Pairing with the console PIN: UDP search, HTTP request/response, body layout and encryption, errors, the pairing record to store; registration through PSN without a PIN (§8) |
| [rpcrypt.md](rpcrypt.md) | "RP crypt": key/IV derivation and the AES-CFB payload cipher, for registration (LAN and PSN) and session use, PS4 and PS5 |
| [session.md](session.md) | Session init over HTTP: request, nonce, refusals, the session crypt, what the stream stage gets |
| [ctrl.md](ctrl.md) | The ctrl channel: request, message framing, counters, every message, heartbeats, how it ends |
| [takion.md](takion.md) | Takion, the UDP transport (9296, and 9297 for the probe): packets, handshake, chunks and acks, GKCrypt (AES-GCM, key positions), the AV packet header, congestion reports, controller feedback packets, sequence numbers, PlayFX's own reorder policy |
| [stream.md](stream.md) | The stream connection over Takion: protobuf messages, the network probe, the Hello/HelloReply handshake with secp256k1 ECDH, the launch spec, stream info, heartbeats, IDR and corrupt-frame reports, quit reasons, rumble, trigger effects, haptics, LED, motion, touch, the mic |
| [av.md](av.md) | Audio and video frames: unit assembly, the Reed-Solomon (Cauchy, GF(2^8)) FEC in full, the Annex-B access unit, H.264/HEVC bitstream facts, Opus audio and haptics, the mic upstream |
| [psn.md](psn.md) | Internet play, PSN side: token requirements, console list and device IDs, the push-notification WebSocket, the remote-play session (create, start, `customData1`, leave), session messages (OFFER/RESULT/ACCEPT) and their JSON, errors, timeouts |
| [holepunch.md](holepunch.md) | Internet play, NAT traversal: UPnP and STUN, the candidate list, the 88-byte probe packets, choosing the pair, the ctrl and data holes and what each carries, the end-to-end sequence |
| [rudp.md](rudp.md) | Internet play, the reliable-UDP control transport on the ctrl hole: framing, message types, counters and acks, the handshake, carrying registration/session init/ctrl, retransmission, the switch to the stream, the end |
| [test-vectors.md](test-vectors.md) | Known-answer vectors for discovery, wake, RP crypt and registration (including PSN-mode registration crypto), and how each was verified |
| [`data/`](data/) | Constant tables (hex) used by rpcrypt.md, with SHA-256 checksums in rpcrypt.md section 3 |
| [`data/vectors/`](data/vectors/) | Large test vectors (full registration bodies, a PS5 Hello) |

Internet play is covered by psn.md, holepunch.md and rudp.md, plus "Internet play" sections in session.md
(§11), ctrl.md (§10), takion.md (§18) and stream.md (§16). Unlike the LAN documents, nothing in them has been
checked against a real internet session by PlayFX's own code yet; their open questions say what only such a
session (or a capture of the official app) can settle. Their known-answer vectors are in the documents
themselves.

## Clean-room process

- **Spec writers** read the reference open-source client (chiaki-ng, AGPL-3.0) and public sources, and wrote
  down **facts only**: wire formats, field layouts and offsets, constants and tables, message text, state
  sequences, algorithms as byte-level steps, timeouts and error meanings. No code, pseudo-code that follows
  its functions, identifiers, comments or program structure was carried over. Where the reference client
  makes a choice the protocol doesn't require (a retry count, a timeout), the spec labels it
  "client choice (observed)".
- **Implementers** get only these documents. They never open chiaki-ng or any other implementation of this
  protocol.
- **A missing fact** is added to the spec (by a spec writer, as a fact) instead of being looked up by the
  implementer. Each document has an "Open questions" section for facts that are unclear or unverified.
- **Verification** was done against the reference client as a black box: the test vectors were computed by a
  script written from the spec text alone and compared with the reference library's output (test-vectors.md).
  Nothing was sent to a real console.

**Honest limits.** This is a best-effort clean room, not a guaranteed one. The AI models that wrote and will
implement it have very likely seen chiaki-ng and similar projects in training, so the implementers'
"never saw the code" is weaker than in a traditional clean room with separated human teams. The constant
tables are copied as data because the protocol cannot work without them; whether such tables are
protectable is a legal question. **Have a lawyer review this process and the resulting code before a Mac
App Store submission.**

## Conventions

- **Byte order.** Multi-byte integers on the wire are **big-endian** (network order) unless a field says
  otherwise. Exceptions are called out where they occur (for example the PSN account ID, which is
  little-endian).
- **Offsets and sizes** are in bytes and 0-based. Hex numbers are written `0x1e0`; plain numbers are decimal.
- **Hex strings** in tables and code blocks (`3f1cc4b6...`) are byte sequences, two lowercase hex digits per
  byte, first byte first, no separators. Line breaks inside a long hex block are layout only.
- **Ranges** `a..b` are inclusive on both ends.
- **Text messages** are ASCII. Line endings are written `\n` (0x0a) and `\r\n` (0x0d 0x0a); `\0` or `<0x00>`
  is a single zero byte. Each document says which line ending a message uses; they differ between messages.
- **Byte arithmetic** in derivations is mod 256 (see rpcrypt.md section 4). `^` is XOR, `||` is
  concatenation, `BE32(x)`/`BE64(x)` are big-endian encodings.
- **Base64** is standard RFC 4648 (alphabet `A-Z a-z 0-9 + /`, `=` padding) unless stated otherwise.
- **Targets** (console family + Remote Play version) are named `PS4-8`, `PS4-9`, `PS4-10`, `PS5-1`
  (rpcrypt.md section 1). Names like `K`, `S`, `H` and table file names are this spec's own.
- **MUST-level facts vs choices.** Text without a label describes what consoles send or expect. "Client
  choice (observed)" marks behaviour of the reference client that an implementation may change.
- **Secrets.** Pairing keys, registration keys and account IDs are secrets: never log them, never put real
  ones in tests or docs. All values in these documents are made up.
