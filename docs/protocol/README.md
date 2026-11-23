# PlayStation Remote Play protocol specification

This folder specifies the PS4/PS5 Remote Play protocol as far as PlayFX needs it, in enough detail to build
an interoperable client (`PlayFXProtocol`, Swift) from these documents alone.

## Documents

| Document | Covers |
|----------|--------|
| [discovery.md](discovery.md) | LAN discovery (search, response fields, polling, when a console counts as gone) and wake from rest mode |
| [registration.md](registration.md) | Pairing with the console PIN: UDP search, HTTP request/response, body layout and encryption, errors, the pairing record to store |
| [rpcrypt.md](rpcrypt.md) | "RP crypt": key/IV derivation and the AES-CFB payload cipher, for registration (LAN and PSN) and session use, PS4 and PS5 |
| [session.md](session.md) | Session request and session handshake (written separately) |
| [ctrl.md](ctrl.md) | The ctrl channel: request, message framing, counters (written separately) |
| [test-vectors.md](test-vectors.md) | Known-answer vectors for discovery, wake, RP crypt and registration, and how each was verified |
| [`data/`](data/) | Constant tables (hex) used by rpcrypt.md, with SHA-256 checksums in rpcrypt.md section 3 |
| [`data/vectors/`](data/vectors/) | Large test vectors (full registration bodies) |

Not yet covered here: the streaming transport (Takion, audio/video, FEC, feedback) and internet play (PSN
session setup, NAT traversal, reliable UDP). Those need their own documents before they can be implemented.

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
