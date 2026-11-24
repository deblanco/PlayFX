# Takion: the UDP transport (stream 9296, network probe 9297)

Status: draft 1 (clean-room spec, facts only). LAN path. Takion over a PSN hole-punched socket uses the
same packets; how that socket is obtained and what differs around it is §18.

Takion is the datagram transport under the stream connection. It is an SCTP-like protocol (RFC 4960 was
clearly its model: verification tags, a four-way INIT / INIT_ACK / COOKIE / COOKIE_ACK handshake, TSNs,
cumulative acks with gap blocks), extended with unreliable audio/video packets, controller-input packets
and a per-packet authentication tag ("GMAC") and stream cipher ("the stream cipher" below).

Related documents:

- `session.md`: what comes before (session init, ctrl) and the inputs listed in its §12, in particular
  `consoleAddress`, `negotiatedVersion`, `streamHandshakeKey` and the ECDH key pair (Appendix A there).
- `stream.md` (written separately): the protobuf "stream connection" messages carried in Takion data
  chunks (big/bang handshake, ECDH exchange, launch spec, stream info, heartbeat, disconnect, controller and
  haptics messages). This document says how those bytes travel; `stream.md` says what they mean.
- `av.md` (written separately): video/audio frames, FEC, codecs. This document parses the AV packet header
  (§7) and decrypts the payload; `av.md` takes it from there.

Conventions: as in `README.md`. Naming: this document's **big** and **bang** are `stream.md`'s **Hello** and
**HelloReply** (the client's first stream message and the console's answer). All multi-byte integers are big-endian unless a field says otherwise
(the feedback-state motion fields are little-endian, §9.2). Offsets are from the first byte of the UDP
datagram unless stated. "Client choice (observed)" marks behaviour of an existing client that the console
isn't known to require. "PlayFX's reorder policy (our own design)" (§12) is PlayFX's own algorithm and may
be implemented as described.

Names used in this document (this spec's own):

| Name | Meaning |
|---|---|
| `clientTag`, `consoleTag` | The two 32-bit verification tags exchanged in the handshake (§4). |
| TSN | 32-bit transmission sequence number of a reliable data chunk (§5). |
| `keyPos` | 64-bit position in a stream-cipher context's key stream; the low 32 bits travel in packets (§6). |
| `ctxUp`, `ctxDown` | The stream-cipher contexts for client → console and console → client (§6.1). |
| `takionVersion` | 7, 9 or 12: selects the AV header layout and feedback-state size (§1.2). |
| `ecdhSecret` | The 32-byte ECDH shared secret (session.md Appendix A). |

---

## 1. Overview

### 1.1 Two Takion connections per session

| Use | Console port | When | Crypto | `takionVersion` (client side) |
|---|---|---|---|---|
| Network probe ("senkusha" in the protobuf schema's names, §10) | UDP 9297 | after ctrl has a session ID, before the stream | none | 7 |
| Stream connection | UDP 9296 | after the probe, for the rest of the session | from the bang on (§6.7) | 9 for PS4 targets, 12 for `PS5-1` |

Each is a separate UDP socket (a new local port), connected to `consoleAddress` and the port above, and
each runs its own handshake (§4). The probe connection is closed before the stream connection is opened.

### 1.2 Takion versions

The version is not negotiated inside Takion. The client announces it in the stream layer (`stream.md`:
the big message's client version; on the probe, the protocol request of §10) and uses it locally to parse
AV packets:

| `takionVersion` | Used for | AV header (§7) | Feedback state body (§9.2) |
|---|---|---|---|
| 7 | network probe | 18-byte base layout (§7.4) | not sent |
| 9 | PS4 (`PS4-8`, `PS4-9`, `PS4-10`) | §7.2, audio payload at 19 | 25 bytes |
| 12 | PS5 (`PS5-1`) | §7.2, audio has a stream byte, payload at 20 | 28 bytes |

### 1.3 Datagram = one packet

Every UDP datagram carries exactly one Takion packet. There is no bundling of several chunks into one
datagram (unlike SCTP), and no Takion-level fragmentation except the data-chunk continuation of §5.3.
The first byte's low nibble is the packet type.

Existing clients read datagrams into a 1500-byte buffer (client choice, observed); the console's packets
are sized by the negotiated MTU (§10) and fit. The client asks for a 4 MiB socket receive buffer, halving
down to 256 KiB if refused and finally falling back to 102400 bytes (client choice, observed): a single
keyframe can exceed 100 KB.

On the stream socket the IP Don't-Fragment bit is set when the probe succeeded and cleared when it failed
(client choice, observed). On the probe socket it is always set, so that the MTU tests mean something.

---

## 2. Packet types

| Type (low nibble of byte 0) | Name (this spec's) | Direction | GMAC at | `keyPos` (low 32) at | `keyPos` field zeroed for the GMAC? | Payload encrypted? |
|---|---|---|---|---|---|---|
| 0 | control | both | 5..8 | 9..12 | **yes** | no |
| 1 | feedback history | client → console | 8..11 | 4..7 | no | yes, from offset 12 |
| 2 | video | console → client | 10..13 | 14..17 | no | yes, the AV payload (§7) |
| 3 | audio (and PS5 haptics) | console → client; also client → console microphone (§7.5) | 10..13 | 14..17 | no | yes, the AV payload |
| 4 | (handshake) | – | – | – | – | Value known, never seen in use. |
| 5 | congestion report | client → console | 7..10 | 11..14 | **yes** | no |
| 6 | feedback state | client → console | 8..11 | 4..7 | no | yes, from offset 12 |
| 8 | (client info) | – | – | – | – | Value known, never seen in use. |

The high nibble of byte 0 is 0 for every type except AV packets, where bit 4 is a header flag (§7.1).
Receivers mask with `0x0f` before dispatching. A receiver drops datagrams of any other type.

GMAC computation and the zeroing rule are in §6.5. Before the stream keys exist (and always on the probe
connection), the GMAC and `keyPos` fields are sent as zero (§6.7).

---

## 3. Control packets (type 0)

### 3.1 Header

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `0x00` (packet type 0) |
| 1 | 4 | Verification tag: the **receiver's** tag. The client writes `consoleTag`; the console writes `clientTag`. In the client's INIT it is 0. |
| 5 | 4 | GMAC (§6.5), or zero |
| 9 | 4 | `keyPos` low 32 bits (§6.6), or zero |
| 13 | 1 | Chunk type (table below) |
| 14 | 1 | Chunk flags |
| 15 | 2 | Chunk length = payload length + 4 |
| 17 | n | Chunk payload |

The datagram length must equal 17 + payload length, i.e. `datagram length − 13 = chunk length`. A
received control packet whose tag isn't `clientTag`, or whose length doesn't match, is dropped.

### 3.2 Chunk types

| Value | Chunk | Direction | Payload |
|---|---|---|---|
| `0x00` | DATA | both | §5.1 |
| `0x01` | INIT | client → console | §4.1 |
| `0x02` | INIT_ACK | console → client | §4.2 |
| `0x03` | DATA_ACK | both | §5.5 |
| `0x0a` | COOKIE (cookie echo) | client → console | §4.3 |
| `0x0b` | COOKIE_ACK | console → client | none |

Any other chunk type is dropped. There is no ABORT, SHUTDOWN or HEARTBEAT chunk in use; see §13.

---

## 4. Connection handshake

```
client                                              console
  |-- INIT (tag field 0; clientTag, a_rwnd, 100/100, TSN0) -->|
  |<-- INIT_ACK (tag field clientTag; consoleTag, ..., cookie[32])|
  |-- COOKIE (tag field consoleTag; cookie[32]) ------------->|
  |<-- COOKIE_ACK (tag field clientTag) ----------------------|
  connected: DATA / DATA_ACK, AV, feedback, congestion
```

None of the four handshake packets carries a GMAC or `keyPos` (both fields zero), and none is
retransmitted by the reliable-data machinery of §5.6.

### 4.1 INIT (client → console)

Header: tag field 0, GMAC 0, `keyPos` 0, chunk type `0x01`, flags `0x00`, chunk length `0x0014`.
Payload (16 bytes), datagram length 33:

| Payload offset | Size | Field | Client value |
|---|---|---|---|
| 0 | 4 | Initiator tag = `clientTag` | 32 random bits, fresh per connection (non-zero) |
| 4 | 4 | Advertised receive window (a_rwnd) | `0x00019000` (102400) (client choice, observed) |
| 8 | 2 | Outbound streams | `0x0064` (100) |
| 10 | 2 | Inbound streams | `0x0064` (100) |
| 12 | 4 | Initial TSN | equal to `clientTag` |

The client's first data chunk uses TSN = `clientTag`; each further data chunk takes the next value
(mod 2^32).

### 4.2 INIT_ACK (console → client)

Header: tag field `clientTag`, chunk type `0x02`, flags `0x00`, chunk length `0x0034`. Payload (48 bytes),
datagram length 65:

| Payload offset | Size | Field |
|---|---|---|
| 0 | 4 | `consoleTag` |
| 4 | 4 | Console a_rwnd |
| 8 | 2 | Console outbound streams |
| 10 | 2 | Console inbound streams |
| 12 | 4 | Console initial TSN |
| 16 | 32 | State cookie (opaque) |

Checks the existing client makes; it fails the connection when any fails:

- the datagram is at least 65 bytes, type byte `0x00`, tag field = `clientTag`, length rule of §3.1;
- chunk type `0x02` and flags `0x00`;
- `consoleTag` ≠ 0;
- console outbound streams ≥ 1 and ≤ 100, console inbound streams ≥ 100.

The console's data chunks then start at TSN = `consoleTag`: the existing client initialises its receive
window from `consoleTag`, not from the initial-TSN field, and that works with real consoles. Whether the
initial-TSN field always equals `consoleTag` is an open question (§16); a client should start its window
at `consoleTag`.

### 4.3 COOKIE (client → console)

Header: tag field `consoleTag`, GMAC 0, `keyPos` 0, chunk type `0x0a`, flags `0x00`, chunk length
`0x0024`. Payload: the 32 cookie bytes from INIT_ACK, unchanged. Datagram length 49.

### 4.4 COOKIE_ACK (console → client)

Header: tag field `clientTag`, chunk type `0x0b`, flags `0x00`, chunk length `0x0004`, no payload.
Datagram length 17.

If the first datagram received while waiting for COOKIE_ACK has chunk type `0x02` (the console repeated
its INIT_ACK), the client reads one more datagram and checks that one instead.

### 4.5 Timeouts and retries (client choice, observed)

| Step | Wait | Tries |
|---|---|---|
| INIT → INIT_ACK | 5 s per try | 3 (the same INIT, same `clientTag`, resent) |
| COOKIE → COOKIE_ACK | 5 s per try | 3 |

On top of that, the stream connection gives the whole handshake 5 s from the start and fails if it isn't
connected by then; the probe gives it 30 s. In practice a console answers INIT within milliseconds.

---

## 5. Reliable data

### 5.1 DATA chunk payload

First (or only) fragment of a message:

| Payload offset | Size | Field |
|---|---|---|
| 0 | 4 | TSN |
| 4 | 2 | Channel |
| 6 | 2 | Zero |
| 8 | 1 | Data type (§5.2) |
| 9 | n | Message bytes |

Datagram length = 26 + n. The header's chunk length is n + 13.

Continuation fragment (§5.3): the same without the data-type byte (message bytes from payload offset 8;
datagram length = 25 + n; chunk length n + 12).

Receivers take the data type from payload offset 8 and the message from offset 9. A DATA chunk with fewer
than 9 payload bytes is dropped. A non-zero value at payload offsets 6..7 is unexpected but not fatal.

### 5.2 Data types and the boundary to stream.md

| Data type | Message bytes are | Sent by |
|---|---|---|
| `0x00` | a protobuf stream message (`stream.md`) | both |
| `0x07` | rumble (controller vibration) data (`stream.md`) | console |
| `0x09` | pad info (light bar colour, player index, motion reset, haptic/trigger intensity) (`stream.md`) | console |
| `0x0b` | adaptive-trigger effects (`stream.md`) | console |

Existing clients drop DATA chunks with any other data type (after acknowledging them, §5.5). Clients only
ever send data type `0x00`.

The message bytes of DATA chunks are **not encrypted** at the Takion layer; they are only covered by the
GMAC. (Fields inside a stream message may be encrypted by the stream layer, e.g. the launch spec; see
`stream.md`.)

### 5.3 Chunk flags and fragmentation

| Flags | Meaning |
|---|---|
| `0x01` | Last (or only) fragment of a message. Every unfragmented message, in both directions. |
| `0x00` | More fragments of this message follow. |

The console's DATA chunks carry flags `0x01`; existing clients treat each console chunk as a complete
message and don't reassemble.

The client splits a message only when it doesn't fit (observed for the big message, which carries the
launch spec): let `M = min(mtuIn, mtuOut) − 50` (the probe's results, §10; 50 bytes of allowance for IP
and UDP headers). Then:

- while the remainder is larger than `M − 26` (nothing sent yet) or `M − 25` (after the first
  fragment), send a fragment of exactly `M − 26` (first, with the data-type byte) or `M − 25`
  (continuation, without it) message bytes, flags `0x00`;
- send the rest (at least 1 byte) with flags `0x01`, as a first fragment if nothing was sent yet, else as
  a continuation.

So every fragment but the last is a datagram of exactly `M` bytes. (The existing client's loop has an
off-by-one: with a remainder of exactly `M − 25` after the first fragment it sends it with flags `0x00`
and no final fragment. Don't copy that.) Each fragment takes its own TSN and
`keyPos` and is acknowledged and retransmitted on its own. With the fallback MTU of 1454 a message of up to
1378 bytes needs no split.

### 5.4 Channels

The channel is a 16-bit label. Values the client uses (client choice, observed, but kept identical to
existing clients):

| Channel | Used for |
|---|---|
| 1 | most stream messages (big, heartbeat, controller connection, stream info, disconnect), probe protocol request / big / disconnect |
| 2 | corrupt-frame reports and IDR (keyframe) requests (`stream.md`) |
| 8 | probe commands (§10) |
| 9 | stream-info ack (`stream.md`) |

The console's channel values are ignored by existing clients.

### 5.5 DATA_ACK

Payload (12 bytes, plus 4 per gap block):

| Payload offset | Size | Field |
|---|---|---|
| 0 | 4 | Cumulative TSN: every TSN up to and including this one has arrived |
| 4 | 4 | a_rwnd of the sender of the ack |
| 8 | 2 | Gap block count `g` |
| 10 | 2 | Duplicate-TSN count |
| 12 | 4·g | Gap blocks |

Chunk type `0x03`, flags `0x00`.

**Client → console.** The client sends one DATA_ACK whenever it has delivered one or more new in-order
console chunks (§12.1), right after delivering them, with: cumulative TSN = the TSN of the last chunk
delivered, a_rwnd = `0x00019000`, gap count 0, duplicate count 0. That is a 29-byte datagram (chunk
length `0x0010`). It is sent once (not retransmitted); it carries a GMAC once the keys exist.
Recommendation (not done by the existing client): when a duplicate of an already-delivered chunk arrives,
send the same cumulative ack again. Without it, a lost ack makes the console retransmit until it gives up.

**Console → client.** Console acks may carry gap blocks. The existing client accepts an ack whose length
is exactly 12 + 4·g bytes, uses only the cumulative TSN and ignores gap blocks and a_rwnd: every unacked
client chunk whose TSN ≤ the cumulative TSN (serial order, §11) is done. A non-zero duplicate count is
unexpected; such an ack is accepted only if the length rule holds. The layout of a gap block is presumed to
be SCTP's (two 16-bit offsets from the cumulative TSN, start and end) but is unverified (§16).

### 5.6 Retransmission (client side, client choice, observed)

Every client DATA chunk is kept, byte for byte, until acked:

- A checker runs every 100 ms. Any kept chunk last sent more than 200 ms ago is sent again, **identical**
  (same TSN, same `keyPos`, same GMAC).
- After 25 resends a chunk is given up silently (about 5–7.5 s after it was first sent).
- At most 1024 unacked chunks are kept; a chunk sent while 1024 are outstanding is sent once and not kept.
- No window or congestion limit is applied to sending.

Only DATA chunks are retransmitted. Acks, AV, feedback and congestion packets are sent once (feedback
history has its own repeat scheme, §9.4).

---

## 6. Crypto

### 6.1 Contexts

After the bang (`stream.md`), each side derives two independent contexts from `ecdhSecret` (32 bytes) and
`streamHandshakeKey` (16 bytes, session.md §6.3):

| Context | Index byte | Used for |
|---|---|---|
| `ctxUp` | `0x02` | everything the client sends: GMACs of its control, congestion, feedback and microphone packets; encryption of its feedback and microphone payloads |
| `ctxDown` | `0x03` | everything the console sends: GMAC checks of its control and AV packets; decryption of AV payloads |

Each direction has exactly one `keyPos` sequence (§6.6), shared by all packet types sent in that direction.

### 6.2 Context derivation

```
D            = HMAC-SHA256(key = ecdhSecret (32 bytes),
                           msg = 0x01 || index || 0x00 || streamHandshakeKey (16) || 0x01 || 0x00)   (21-byte message)
cipherKey    = D[0..16)      AES-128 key of the key stream
ivBase       = D[16..32)     16-byte counter base
```

### 6.3 Little-endian counter addition

`A ⊕+ v` (this spec's notation) means: read the 16-byte value `A` as an unsigned 128-bit integer in
**little-endian** order (byte 0 least significant), add the integer `v`, reduce mod 2^128 and write it back
little-endian. For example `ff ff 00 … 00 ⊕+ 1 = 00 00 01 00 … 00`. (This is the opposite of the usual
big-endian CTR increment.)

### 6.4 Key stream and payload encryption

The key stream of a context is a sequence of bytes indexed by a 64-bit stream position `p`:

```
block(j)     = AES-128-Encrypt(cipherKey, ivBase ⊕+ j)        (AES-ECB of one block, j = 0, 1, 2, …)
keystream[p] = block(⌊p / 16⌋)[p mod 16]
```

To encrypt (or decrypt, the same operation) `n` bytes at stream position `P`: XOR byte `i` with
`keystream[P + i]` for `i = 0 … n−1`. `P` need not be a multiple of 16.

Which stream position a packet's payload uses: always **`keyPos + 16`**, where `keyPos` is the packet's
64-bit key position (§6.6). The 16 bytes at `keyPos … keyPos+15` are never used for payload.

### 6.5 GMAC

**GMAC keys.** A context's GMAC key changes every 45000 key-stream bytes ("epochs"):

```
G(base, e)   = let d = SHA-256(base (16 bytes) || (ivBase ⊕+ (e · 44910)) (16 bytes));   d[0..16) XOR d[16..32)
gmacKey(0)   = G(cipherKey, 0)            (that is: d = SHA-256(cipherKey || ivBase))
gmacKey(e)   = G(gmacKey(0), e)           for e ≥ 1   (base is gmacKey(0), not cipherKey and not gmacKey(e−1))
epoch(k)     = 0 if k = 0, else ⌊(k − 1) / 45000⌋     for a packet with 64-bit keyPos k
```

So `keyPos` 1 … 45000 is epoch 0, 45001 … 90000 epoch 1, and so on. The constants 45000 and 44910 are
different on purpose; both are as stated.

**Tag.** For a packet with 64-bit key position `k`:

1. Take the whole datagram as sent (every byte from offset 0 to the end, payload already encrypted).
2. Set its 4 GMAC bytes to zero. For control (type 0) and congestion (type 5) packets also set the 4
   `keyPos` bytes to zero. For all other types the `keyPos` field stays in.
3. Compute AES-128-GCM with key `gmacKey(epoch(k))`, **16-byte IV** `ivBase ⊕+ ⌊k / 16⌋`, the bytes from
   step 2 as additional authenticated data, and an empty plaintext.
4. The GMAC is the first 4 bytes of the 16-byte GCM tag. Write it into the GMAC field (and restore the
   `keyPos` field if it was zeroed).

The IV is 16 bytes, not the usual 12, so GCM's pre-counter block is derived by GHASH (NIST SP 800-38D
§7.1, "len(IV) ≠ 96"). Use a GCM implementation that accepts a 16-byte nonce.

The receiver repeats steps 2–4 with the sender's context and compares the 4 bytes. A packet whose GMAC
doesn't match is dropped and must not update the receiver's `keyPos` reference (§6.6).

### 6.6 Choosing and carrying `keyPos`

**Sender (client).** The client keeps one 64-bit counter `U` for `ctxUp`, starting at 0 when the contexts
are created. For each secured packet it sends, it takes `keyPos = U` and then advances `U`. The advance
used by existing clients (client choice, observed; it is odd but consoles accept it, and a new client
should copy it):

```
advance(s) = s + (s mod 16)          (not a round-up to a multiple of 16)
```

| Packet | `s` | Encrypted bytes |
|---|---|---|
| DATA chunk | n = message bytes in the chunk (not counting the 8- or 9-byte prefix) | none |
| DATA_ACK | 29 (the datagram length) → advance 42 | none |
| congestion report | 15 (the datagram length) → advance 30 | none |
| feedback state / history | 16 + body length | body, at `keyPos + 16` |
| microphone audio | 16 + audio payload length | payload, at `keyPos + 16` |

The packet carries `keyPos mod 2^32`, big-endian, at its `keyPos` offset (§2). Packets sent before the
contexts exist carry `keyPos` 0 and GMAC 0 and don't advance anything.

What the console needs is that payload key-stream ranges never overlap (each encrypted payload uses
`keyPos + 16 … keyPos + 16 + len − 1`, and `advance(16 + len) ≥ 16 + len` guarantees that) and, most
likely, that `keyPos` only grows. Whether it checks more is unknown (§16).

**Receiver (client), reconstructing the 64-bit value.** The console's packets carry only the low 32
bits `L`. The client keeps `R`, the 64-bit `keyPos` of the last console packet that authenticated (all
types share it; initially 0). For a received `L`, with `Rlo = R mod 2^32` and `Rhi = ⌊R / 2^32⌋`:

- if `L` is after `Rlo` in 32-bit serial order (§11) but numerically smaller (`L < Rlo`), it wrapped
  forward: `hi = Rhi + 1`;
- else if `L` is before `Rlo` in serial order but numerically larger (`L > Rlo`) and `Rhi > 0`, it is a
  late packet from before a wrap: `hi = Rhi − 1`;
- else `hi = Rhi`.

The candidate is `k = hi · 2^32 + L`. Verify the GMAC with `k`; only if it matches set `R = k`.

### 6.7 When crypto starts

- **Probe connection:** never. All GMAC and `keyPos` fields are zero and nobody checks them.
- **Stream connection, before the bang:** the client sends GMAC 0 and `keyPos` 0 (INIT, COOKIE, the big
  message and its retransmissions, its acks, congestion reports). It accepts the console's control packets
  without checking their GMAC. AV packets that arrive before the contexts exist are held (the existing
  client holds up to 32 and drops further ones) and processed, with GMAC check, once they exist.
- **The switch:** the client creates both contexts while it processes the console's bang chunk, before it
  acknowledges that chunk. So the DATA_ACK for the bang is normally the first secured client packet, with
  `keyPos` 0. From then on every client packet of types 0, 1, 3, 5 and 6 carries a GMAC, and every console
  packet is checked. Console chunks still queued (not yet delivered) when the contexts appear are checked
  then, and dropped if they fail.
- A client chunk sent before the switch and retransmitted after it is resent unchanged, with its zero
  GMAC and `keyPos` (§5.6).

---

## 7. AV packets (types 2 and 3)

### 7.1 Byte 0

| Bits | Meaning |
|---|---|
| 0–3 | 2 = video, 3 = audio |
| 4 | Extension flag: 3 extra header bytes follow the fixed header (contents unknown, skipped) |
| 5–7 | Not used by existing clients (ignored) |

### 7.2 Header, `takionVersion` 9 and 12 (stream connection)

| Offset | Size | Video | Audio |
|---|---|---|---|
| 0 | 1 | byte 0 (§7.1) | byte 0 |
| 1 | 2 | packet index (16-bit serial, §11) | packet index |
| 3 | 2 | frame index (16-bit serial) | frame index |
| 5 | 4 | unit word, video layout (below) | unit word, audio layout (below) |
| 9 | 1 | codec (`av.md`) | codec |
| 10 | 4 | GMAC | GMAC |
| 14 | 4 | `keyPos` low 32 bits | `keyPos` low 32 bits |
| 18 | 2 | 16-bit field, meaning in `av.md` (seen: `0x0367`) | offset 18: 1 byte, unknown, ignored |
| 20 | 1 | bits 5–7: adaptive stream index (`byte >> 5`); bits 0–4 unknown | – |
| 21 | | payload (video) | v9: payload at 19. v12: offset 19 is a **stream byte** (`0x02` = haptics, anything else = audio), payload at 20 |

If the extension flag (bit 4 of byte 0) is set, 3 bytes are inserted after the fixed header: video payload
at 24; audio v9 payload at 22; audio v12 stream byte at 22 and payload at 23.

Minimum lengths: video 25 bytes, audio v9 20, audio v12 21 (shorter datagrams are dropped).

Unit word (32 bits, big-endian):

| Layout | Bits 31–21 | Bits 20–10 | Bits 9–0 |
|---|---|---|---|
| Video | unit index (11 bits) | total units in frame − 1 (11 bits) | FEC units in frame (10 bits) |

| Layout | Bits 31–24 | Bits 23–16 | Bits 15–8 | Bits 7–4 | Bits 3–0 |
|---|---|---|---|---|---|
| Audio | unit index (8 bits) | total units − 1 (8 bits) | unit size in bytes | FEC units | source units |

(For audio the 16 low bits are one field split into three: `unitSize = w >> 8`, `fecUnits = (w >> 4) & 0xf`,
`sourceUnits = w & 0xf`, where `w` is the low 16 bits.) "Total units" includes the FEC units.

### 7.3 What happens to an AV packet, and the boundary to av.md

1. Check the GMAC with `ctxDown` (§6.5; `keyPos` field kept in). Drop on mismatch.
2. Parse the header (§7.2). Video packets go through the reorder queue (§12.2); audio and haptics packets
   are passed on at once in arrival order.
3. Decrypt the payload (from the payload offset to the end of the datagram) with `ctxDown` at stream
   position `keyPos + 16` (§6.4).
4. Hand `av.md`: video/audio, the haptics flag (v12 audio), packet index, frame index, unit index, total
   units, FEC units (video) or the three audio fields, codec, the offset-18 field and adaptive stream index
   (video), and the decrypted payload.

Haptics packets (v12 audio with stream byte `0x02`) are audio-format packets carrying the DualSense
haptic signal; `av.md` decodes them like audio.

### 7.4 Header, `takionVersion` 7 (probe)

18 bytes, used both ways on the probe connection. Same as §7.2 for offsets 0–9 and 14–17, except: the unit
word always uses the **video** layout (also for audio-type packets), offsets 10–13 are zero (no GMAC), and
`keyPos` is zero. Video-type packets add 3 bytes (offsets 18–19 the 16-bit field, offset 20 adaptive stream
index); payload at 18 (audio type) or 21 (video type), plus 3 with the extension flag.

### 7.5 Client microphone packets (optional)

Not needed for streaming. For completeness, the client's audio packets (type 3, sent only after the
microphone was connected and unmuted on ctrl, and only while it stays unmuted, `stream.md` §9.10 /
`ctrl.md` §6.6):

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `0x03` |
| 1 | 2 | packet index = local frame counter |
| 3 | 2 | frame index = counter + 1 |
| 5 | 4 | `0x00022821`: unit index 0, total units 3, low half `0x2821` (unit size 0x28 = 40, 2 FEC, 1 source) |
| 9 | 1 | codec `0x05` |
| 10 | 4 | GMAC (`ctxUp`) |
| 14 | 4 | `keyPos` low 32 |
| 18 | 1 (PS4) or 2 (PS5) | zero |
| 19 / 20 | 120 | encrypted at `keyPos + 16`: the new 40-byte Opus frame, then the frame from two packets back, then the one from one packet back |

The counter is 16 bits and goes 0 … 65535, 0, … (client choice, observed).

---

## 8. Congestion report (type 5) and packet statistics

### 8.1 Layout (15 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `0x05` |
| 1 | 2 | zero |
| 3 | 2 | packets received in the interval (16-bit, truncated) |
| 5 | 2 | packets lost in the interval (16-bit, truncated) |
| 7 | 4 | GMAC (`ctxUp`, `keyPos` field zeroed for the computation, §6.5) |
| 11 | 4 | `keyPos` low 32 |

### 8.2 Period

Every 200 ms, from the moment the stream connection's Takion socket exists (so the first ones go out
during the handshake and before the bang, unsecured) until the stream connection ends (client choice,
observed). The console's stream info can carry a congestion-control interval (`stream.md`); existing
clients don't use it.

### 8.3 What is counted (client choice, observed)

Over each 200 ms interval:

- **Video:** when the first packet of a newer video frame arrives, the frame before it is finished
  (`av.md`): add its units received (source + FEC, duplicates not counted) to `received` and
  `expected − received` to `lost`, where `expected` = the frame's total units (source + FEC). One exception
  (av.md §4.5): with an FEC unit count of 0, `expected` = source units + 1, so even a complete frame reports
  one lost unit (never seen on a console, where the FEC count isn't 0).
- **Audio:** count every audio packet received (`aud`) and track the highest audio frame index seen
  (`hi`, in 16-bit serial order). At the end of the interval `audLost = d − aud` if `aud < d`, else 0,
  where `d = (hi − hiPrev) mod 2^16` and `hiPrev` is `hi` at the end of the previous interval (initially 0).
  Add `aud` to `received` and `audLost` to `lost`. Duplicates and reordered packets therefore never make
  `lost` negative, and the 16-bit wrap is handled.
- **Clamp:** with a configured ceiling `maxLoss` (PlayFX: 0.05; the user setting in other clients), if
  `total = received + lost > 0` and `lost / total > maxLoss`, report `lost = ⌊total · maxLoss⌋` and
  `received = total − lost`. (This keeps the console from cutting the bitrate too hard on a bursty link.)
- Then reset the counters and send.

---

## 9. Feedback: controller input (types 6 and 1)

Controller input travels in two unreliable packet types: **feedback state** (sticks and motion, the
latest values) and **feedback history** (button, trigger and touch events). Buttons and triggers are
**only** in the history; sticks and motion are **only** in the state.

### 9.1 Common header (12 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `0x06` (state) or `0x01` (history) |
| 1 | 2 | sequence number (16-bit serial; §9.3, §9.4) |
| 3 | 1 | state: `0x00` (one state). History: number of events in the body **minus one** (0 for an empty body). The console adds one back and rejects a packet that claims more events than it holds. |
| 4 | 4 | `keyPos` low 32 |
| 8 | 4 | GMAC (`ctxUp`; `keyPos` field kept in) |
| 12 | n | body, encrypted with `ctxUp` at `keyPos + 16` |

Order of construction: take `keyPos` (§6.6 with `s = 16 + n`), encrypt the body, write `keyPos`, compute
the GMAC over the whole datagram (GMAC field zero), write it.

**No microphone state in feedback.** Neither the feedback state (§9.2) nor the history events (§9.4) carry
a mic or mute bit, in the reference: its button set has 16 buttons (none for the mic), and a DualSense's mute
button is consumed by the client (it toggles the client's own mute, ctrl.md §6.6) and never forwarded.

### 9.2 Feedback state body

`takionVersion` 9: 25 bytes. `takionVersion` 12: 28 bytes (the same 25, then `00 00 01`).

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `0xa0` | constant |
| 1 | 2 | gyro x | u16 **little-endian**, `⌊65535 · (g + 30) / 60⌋` |
| 3 | 2 | gyro y | same |
| 5 | 2 | gyro z | same |
| 7 | 2 | accel x | u16 **little-endian**, `⌊65535 · (a + 5) / 10⌋` |
| 9 | 2 | accel y | same |
| 11 | 2 | accel z | same |
| 13 | 4 | orientation | u32 **little-endian**, compressed quaternion (below) |
| 17 | 2 | left stick x | int16 big-endian |
| 19 | 2 | left stick y | int16 big-endian |
| 21 | 2 | right stick x | int16 big-endian |
| 23 | 2 | right stick y | int16 big-endian |
| 25 | 3 | (v12 only) `00 00 01` | constant |

- Gyro `g` in rad/s, range −30 … 30; acceleration `a` in units of standard gravity (g), gravity included,
  range −5 … 5. Clamp to the range first (the formula is undefined outside it). Existing clients compute
  the formula in 32-bit float and truncate toward zero.
- Idle values: gyro 0 (→ `0x7fff`), accel (0, 1, 0) (→ `0x7fff`, `0x9999`, `0x7fff`), orientation
  (x, y, z, w) = (0, 0, 0, 1), sticks 0.
- Sticks: −32768 … 32767; x positive to the right, y positive **down** (pushed toward the player).
- Axes and orientation follow the DualShock/DualSense sensor frame. The orientation is a unit quaternion
  the client supplies; existing clients estimate it from gyro and accel with a sensor-fusion filter (client
  choice).

Compressed quaternion (q = (x, y, z, w), components in that order, index 0…3):

1. `m` = index of the component with the largest absolute value (the first such index on ties).
2. bit 0 = 1 if `q[m] < 0`, else 0; bits 1–2 = `m`.
3. For the other three components in index order (i = 0, 1, 2 over the indices ≠ m): clamp `v` to
   [−√½, √½], compute `⌊(v + √½) · 511 / (2·√½)⌋` (a 9-bit value 0 … 511) and put it at bits `3 + 9i …
   11 + 9i`.
4. Bits 30–31 are 0.

### 9.3 Feedback state timing (client choice, observed)

- Sent when the sticks or motion values changed since the last state sent, as soon as the change is
  seen, and otherwise at least every 200 ms with the current values.
- No minimum spacing is enforced: the rate follows the controller's update rate. The console's required
  rate is unknown (§16).
- Sequence number: starts at 0 for each stream connection, +1 per state packet.

### 9.4 Feedback history

**Event encoding** (the body is a list of events, **newest first**):

Buttons with a value byte (3 bytes: `0x80`, code, value; value `0xff` pressed, `0x00` released; for L2/R2
the analog value 0 … 255):

| Button | Code |
|---|---|
| D-pad up / down / left / right | `0x80` / `0x81` / `0x82` / `0x83` |
| L1 / R1 | `0x84` / `0x85` |
| L2 / R2 (analog) | `0x86` / `0x87` |
| Cross / Circle / Square / Triangle | `0x88` / `0x89` / `0x8a` / `0x8b` |

Buttons with press/release codes (2 bytes: `0x80`, code):

| Button | Press | Release |
|---|---|---|
| Options | `0xac` | `0x8c` |
| Share / Create | `0xad` | `0x8d` |
| PS | `0xae` | `0x8e` |
| L3 | `0xaf` | `0x8f` |
| R3 | `0xb0` | `0x90` |
| Touchpad click | `0xb1` | `0x91` |

Touch (5 bytes):

| Byte | Value |
|---|---|
| 0 | `0xd0` finger down or moved, `0xc0` finger lifted |
| 1 | touch id, 0 … 127 |
| 2 | `x >> 4` |
| 3 | `((x & 0x0f) << 4) | (y >> 8)` |
| 4 | `y & 0xff` |

`x` and `y` are 12-bit coordinates from the touchpad's top-left corner: x 0 … 1919; y 0 … 941 on a PS4
DualShock 4 touchpad; PlayFX uses y 0 … 1079 for PS5 (client choice). A lifted finger repeats its last
position. Touch ids: a new finger takes the next id (0 … 127, wrapping); it keeps it while down. At most
two fingers.

**From state changes to events** (client choice, observed, in this order for one change):

1. button releases, in the order cross, circle, square, triangle, d-pad left, right, up, down, L1, R1,
   L3, R3, options, share, touchpad, PS;
2. touch changes, finger slot 0 then 1: a finger whose id changed or that was lifted → a lift event
   (`0xc0`, its old id and position); otherwise a finger now down whose id or position changed → a
   down/move event (`0xd0`);
3. button presses, same order as 1;
4. L2 if its value changed, then R2.

(Releasing the click before lifting the finger matters: the console keeps the finger down if it sees the
lift while the click is still held.)

**Numbering and packets** (as reported by existing clients' authors; the console behaviour is observed,
not documented):

- Every event takes the next 16-bit event number, starting at 0 for each stream connection.
- Each new event is sent in a packet of its own, right away: header sequence number = the new event's
  number; body = the new event followed by up to 8 earlier events, newest first (so at most 9 events); byte
  3 = event count − 1.
- The console remembers the last event number it applied. From a packet it applies only as many of the
  newest events as the number moved since then, oldest of those first; a repeat of a packet it has
  already applied changes nothing. Putting two new events into one packet loses one (the console
  applies only the newest new one), hence one packet per event.
- History packets aren't acknowledged. So the last packet, if nothing newer follows, is sent again
  **unchanged** (same sequence number and body, new `keyPos` and GMAC) 20, 50, 100 and 200 ms after it was
  first sent; a new event cancels the remaining repeats. Without this a lost release leaves a button held.
- If events come faster than packets can be sent, up to 64 packets are queued; beyond that the oldest
  queued packet is dropped (numbering is unaffected).

---

## 10. Network probe (UDP 9297)

### 10.1 Is it required?

The existing client always runs it, between ctrl start-up and the stream connection, and **continues
with fallback values when it fails** (any error or timeout): `mtuIn = mtuOut = 1454`, RTT 1 ms, and the
stream socket without Don't-Fragment. Streams start and run that way. So a client may treat the probe as
best effort. Whether a console streams normally when the probe was never attempted at all (no
connection to 9297) is unverified (§16); PlayFX should run it.

Its outputs are used for: the big message's fragmentation (§5.3), the MTU fields of the launch spec and
stream messages (`stream.md`), and the stream socket's Don't-Fragment bit.

### 10.2 Exchange, tests and outputs

Specified once, in **`stream.md` §5** (connection on Takion version 7, the version request, the empty
Hello, the RTT test with its 548-byte pings and pongs, the inbound and outbound MTU bisection, the end). The
probe's raw ping/pong datagrams use the version-7 AV header of §7.4 above. Vector T13 (§15) has the probe's
protobuf message bytes.

## 11. Sequence numbers

Serial-number arithmetic (RFC 1982) for n-bit values `a`, `b` (n = 16 or 32):

- `a` is **before** `b` iff `a ≠ b` and either (`a < b` and `b − a < 2^(n−1)`) or (`a > b` and
  `a − b > 2^(n−1)`).
- `a` is **after** `b` iff `a ≠ b` and either (`a < b` and `b − a > 2^(n−1)`) or (`a > b` and
  `a − b < 2^(n−1)`).
- At a distance of exactly 2^(n−1) neither holds.
- Additions wrap mod 2^n.

| Number | Bits | Start | Wraps |
|---|---|---|---|
| TSN | 32 | own tag (client) / `consoleTag` (console) | yes |
| `keyPos` on the wire | 32 (low half of 64) | 0 | yes, reconstructed per §6.6 |
| AV packet index, frame index | 16 | console's choice | yes, often (every ~11 minutes at high bitrates) |
| feedback state / history sequence | 16 | 0 | yes |

---

## 12. Receive ordering

### 12.1 Reliable data (client choice, observed)

The client keeps a receive window of 16 TSNs starting at the next expected TSN (initially `consoleTag`):

- a chunk inside the window is stored (a second copy of a stored chunk is dropped);
- a chunk before the window (already delivered) is dropped;
- a chunk at or beyond window start + 16 is dropped (the console will retransmit it);
- after each arrival, all chunks from the window start onward that are present are delivered in TSN
  order, the window moves past them, and, if anything was delivered, one DATA_ACK is sent (§5.5).

### 12.2 PlayFX's reorder policy (our own design): the video queue

Audio and haptics are not reordered. Video packets are delivered to `av.md` in packet-index order through
a queue of **256 slots**, using 16-bit serial order (§11):

- **Start.** The first video packet sets the queue start to its packet index minus its unit index (the
  first packet of its frame), so earlier units of that frame are still waited for.
- **Arrival of packet `i`:**
  1. If `i` is before the queue start: if it belongs to a remembered skipped hole and is the first copy
     of it (§12.3, "late"), it feeds the estimator; either way it is dropped.
  2. If `i` is at or past the queue's end and doesn't fit (it is at or past start + 256): **make room**:
     repeatedly deliver the in-order packets at the head, and if there are none, skip the run of missing
     packets at the head up to the first buffered one (recorded as a skipped hole, "queue full", whose
     waiting started when the head started waiting, or now), until `i` fits or the queue is empty or
     nothing changes. Each round clears the running wait. Packets that arrived are never thrown away to
     make room.
  3. Store `i` (a duplicate of a stored packet is dropped; slots between the old end and `i` become
     missing).
  4. **Flush** (below).
- **Flush**, at `now`:
  1. Deliver all in-order packets at the head.
  2. If a hole was waiting and the queue start has reached the hole's end, the whole hole arrived while
     waiting: feed `now − waitStart` to the estimator as a lateness sample (§12.3) and clear the wait.
  3. If the queue is empty: clear the wait; done.
  4. The head is missing. If no wait is running: start one (`waitStart = now`, hole end = start + the
     number of missing packets at the head); done.
  5. If `now − waitStart ≤ wait` (the estimator's current value): done.
  6. Otherwise skip the missing run at the head up to the first buffered packet (record a skipped hole,
     not "queue full"), clear the wait and go back to 1. A burst therefore pays one wait, not one per
     packet.
  7. Afterwards, expire old skipped holes (§12.3).
- **Timer.** While a wait runs, the receive loop wakes when it would run out (remaining time rounded up
  to whole milliseconds) and flushes, so a hole is skipped even if no further packet arrives.
- If the 16-bit distance makes the order ambiguous (exactly half the space away from the queue's end),
  the queue restarts at that packet when it is empty; otherwise the packet is dropped.

### 12.3 PlayFX's reorder policy (our own design): the reorder-wait estimator

All times in microseconds. Constants: `MIN = 3000`, `MAX = 20000`, `INITIAL = 16000`, `LOST = 100000`,
32 remembered skipped holes, at most 256 packets per remembered hole. `clamp(x)` = x limited to
[`MIN`, `MAX`]. State: `wait` (initially `INITIAL`), `sampled` (initially false), `srtt`, `rttvar`.

**Sample** `d` (a lateness; negative values count as 0):

```
if not sampled: sampled = true; srtt = d; rttvar = d / 2          (integer division, toward zero)
else:           rttvar += (|d − srtt| − rttvar) / 4;  srtt += (d − srtt) / 8     (each division toward zero, in that order)
target = clamp(srtt + 4·rttvar)
floor  = wait − wait / 20
wait   = target                     if target ≥ wait
         clamp(max(target, floor))  otherwise                       (down by at most 5 % per sample)
```

**Hole filled while waiting** (§12.2 flush step 2): sample `d = now − waitStart`.

**Hole skipped** (begin, count, waitStart, now, queueFull): if count > 256, keep only the last 256 packets
of it (begin += count − 256). Store it in the next of 32 slots, round robin; if that slot still holds an
unresolved hole, resolve it first (below). Remember begin, count, waitStart, the skip time, `queueFull`,
and an empty set of packets seen.

**Packet before the queue start arrives** (`i`, now): first expire (below). Then look for a remembered hole
with `0 ≤ (i − begin) mod 2^16 < count`. If found and `i` wasn't seen yet for that hole: mark it seen,
count it as late, take `d = now − holeWaitStart`, **sample** `min(d, MAX)`, then set
`wait = max(wait, clamp(d + d / 4))`. It is "late" (true). A second copy, or a packet of no remembered
hole, is not late (and is simply dropped).

**Expire** (now): every remembered hole skipped at least `LOST` ago is resolved.

**Resolve** a hole: if none of its packets came late, it was real loss: if it wasn't skipped because the
queue was full, **shrink**: `w = clamp(wait − wait / 20)`; if `sampled` and `w < target` (with `target =
clamp(srtt + 4·rttvar)`), `w = min(target, wait)`; `wait = w`. Then free the slot.

Rationale (PlayFX's): skipping too early loses a frame (FEC has few units to spare, then the stream waits
for a keyframe), waiting too long only delays the frames behind the hole. Late packets therefore raise the
wait at once, while loss lowers it slowly and never below what late packets have shown.

---

## 13. Shutdown

- **Client ends the stream:** it sends the stream layer's disconnect message (protobuf, message type 8,
  reason text `Client Disconnecting`, `stream.md`) as an ordinary reliable DATA chunk on channel 1, then
  stops: it doesn't wait for the ack and closes the UDP socket. The probe ends the same way (§10.2 step 9).
- **Console ends the stream:** it sends a disconnect message with a reason text (`stream.md`; e.g.
  `Server shutting down` when going to rest mode). The client acknowledges it like any chunk, then ends
  the connection.
- **No Takion-level teardown:** there is no ABORT or SHUTDOWN chunk. The Takion layer has no idle timeout
  either: liveness is the stream layer's heartbeat (every 1 s, `stream.md`) and ctrl's heartbeat
  (`ctrl.md` §7). The console ends a session after about 30 s without ctrl heartbeat replies (session.md
  §9).
- **Socket errors** (ICMP port unreachable surfacing as a receive error, the socket closed) end the
  connection on the client side.
- After the console ends a session, a new one may be refused as "in use" for several seconds
  (session.md §5.4).

---

## 14. Timing summary

| What | Value | Kind |
|---|---|---|
| INIT_ACK wait | 5 s per try, 3 tries | client choice (observed) |
| COOKIE_ACK wait | 5 s per try, 3 tries | client choice (observed) |
| Stream connection: handshake must finish within | 5 s | client choice (observed) |
| Probe: handshake must finish within | 30 s | client choice (observed) |
| Data retransmission check | every 100 ms | client choice (observed) |
| Data retransmission after | > 200 ms since last send | client choice (observed) |
| Data retransmissions per chunk | 25, then given up | client choice (observed) |
| Unacked chunks kept | 1024 | client choice (observed) |
| Receive window (console chunks) | 16 TSNs | client choice (observed) |
| a_rwnd advertised | 102400 bytes | client choice (observed) |
| Congestion report | every 200 ms | client choice (observed) |
| Feedback state | on change, and at least every 200 ms | client choice (observed) |
| Feedback history repeats of the last packet | 20, 50, 100, 200 ms after sending | client choice (observed) |
| Feedback history packet queue | 64 | client choice (observed) |
| AV packets held before keys exist | 32 | client choice (observed) |
| GMAC key epoch | 45000 key-stream bytes | protocol |
| GMAC key derivation step | 44910 per epoch | protocol |
| Video reorder wait | 3 … 20 ms, initially 16 ms, measured (§12.3) | PlayFX's own design |
| Skipped hole counted as lost after | 100 ms | PlayFX's own design |
| Probe: protocol request ack, bang, echo acks, client-MTU replies | 5 s each | client choice (observed) |
| Probe: pong wait | 1 s per ping, 10 pings | client choice (observed) |
| Probe: MTU test wait `T` | clamp(5 · RTT, 5 ms, 500 ms), 3 tries per size | client choice (observed) |
| Probe MTU range | 576 … 1454 | client choice (observed) |
| Probe fallback | MTU 1454 / 1454, RTT 1 ms, no Don't-Fragment | client choice (observed) |
| Stream heartbeat | 1 s (`stream.md`) | client choice (observed) |

---

## 15. Known-answer vectors

Made-up inputs only. How each value was checked:

- **[I]**: computed by an independent Python script written from this document's text (session
  scratchpad, not in the repo; Python `cryptography` for AES-ECB and AES-GCM with a 16-byte nonce).
- **[C]**: the same bytes came out of the reference client's own code, run as a black box in a small C
  harness built against its sources: its packet senders (with their `keyPos` counter, GMAC, encryption and
  socket send captured on loopback) for client packets; its AV parser, GMAC check and decryption, and its
  INIT_ACK / COOKIE_ACK readers for the console packets built by the script; its protobuf encoder for T13;
  its estimator for T15; its congestion thread for T16. All values equal.
- **[U]**: the §6 formulas also reproduce the reference client's own unit-test values (context derivation
  with index 42, key stream at positions 0x30 and 2^32 + 0x420, encryption at 0x11 and 2^32 + 0x420, a GMAC
  key for epoch 1, and the GMAC of a captured console audio packet at `keyPos` 0x6b1de0 = 156 · 45000, i.e.
  epoch 155). Those values are not reproduced here.

Common inputs:

| Input | Value |
|---|---|
| `ecdhSecret` | `0c1fbe7f56ae330d92c6b86cd82e0879addd6822fe20f2419176352093908297` (session.md vector A-1) |
| `streamHandshakeKey` | `404142434445464748494a4b4c4d4e4f` (session.md vector A-1) |
| `clientTag` | `0x1234abcd` |
| `consoleTag` | `0x5a5aa5a5` |

### T1. Contexts (§6.2, §6.5) [I][C]

| | `ctxUp` (index 2) | `ctxDown` (index 3) |
|---|---|---|
| `cipherKey` | `aab471a3cbf72bd3695e3c4685748764` | `5bf637e18135678aaf55ecd224d9c9d7` |
| `ivBase` | `5f2c42295c59b08bd8eefe95fc41d933` | `31622bc48b544790e3e66edb6f076599` |
| `gmacKey(0)` | `efb46f04ea764602469af984592adc01` | `9e49c31e08230d3b4bd82b3a6963990f` |
| `gmacKey(1)` | `b8495627df0efd22779f5fa8c3d98f29` | `d40895030660d42bbe9c3f489c077920` |
| `gmacKey(2)` | `eb7ea4d9e7354e87ca130c2f55928d09` | `dbd050900085554a3aa15100599ce052` |

### T2. Counter addition and key stream (§6.3, §6.4) [I][C]

| Case | Value |
|---|---|
| `ffff0000000000000000000000000000 ⊕+ 1` | `00000100000000000000000000000000`; AES-128(`ctxUp.cipherKey`, that) = `d4172304946b4cab0ecee0a585b5956b` |
| `ffffffffffffffffffffffffffffffff ⊕+ 2` | `01000000000000000000000000000000`; AES-128(`ctxUp.cipherKey`, that) = `f2b166b7846bfe1e8fc451254950a08c` |
| `G(ctxUp.cipherKey, 3)` with `ivBase` replaced by `00112233445566778899aabbccddeeff` (`⊕+ 134730` gives `4a1f2433445566778899aabbccddeeff`) | `59bb1f522ab2b2caa1bc95e1853b11c0` |
| `ctxDown` key stream, positions 0 … 47 | `f0046b4e6e0f41e543bf8c759ff079ed41308fc09ff16035f770303b75470812fff6158a13f9d8ca42ec24ca150012e4` |
| `ctxDown` key stream, positions 0x25 … 0x38 | `f9d8ca42ec24ca150012e49f391380f024b573fc` |
| `ctxDown` key stream, positions 2^32 + 0x10 … +0x2f | `ea58f2433cb8945a901dba03bc3f2d93107567d40abafba4f6a34931bdf3a5b7` |
| `ctxUp`, encrypt `4e619f945d4b8ebd2a154d036acd49569cc75ce3e700179a38d9695345f90cb58c05650f70` at position 0x11 | `055a8c62fae18809b51b7842dd979e4751bc014f81c68cfe0c8b26f911d037124999b3e2a3` |

(The two AES lines check the little-endian addition through the key-stream generator: AES of `ivBase ⊕+ j`
with `ivBase` set to the left-hand value.)

### T3. Handshake datagrams (§4) [I][C]

```
INIT        00 00000000 00000000 00000000 01 00 0014 | 1234abcd 00019000 0064 0064 1234abcd
INIT_ACK    00 1234abcd 00000000 00000000 02 00 0034 | 5a5aa5a5 00019000 0064 0064 5a5aa5a5 c0c1…dedf
COOKIE      00 5a5aa5a5 00000000 00000000 0a 00 0024 | c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf
COOKIE_ACK  00 1234abcd 00000000 00000000 0b 00 0004
```

As single hex strings:

- INIT (33 bytes): `00000000000000000000000000010000141234abcd00019000006400641234abcd` [I][C: sent by the library]
- INIT_ACK (65 bytes, a made-up console answer with cookie `c0 c1 … df`):
  `001234abcd0000000000000000020000345a5aa5a500019000006400645a5aa5a5c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf`
  [I][C: accepted by the library, which read tag `0x5a5aa5a5`, a_rwnd `0x19000`, 100/100 streams,
  initial TSN `0x5a5aa5a5` and the cookie]
- COOKIE (49 bytes): `005a5aa5a500000000000000000a000024c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf`
  [I][C: sent by the library]
- COOKIE_ACK (17 bytes): `001234abcd00000000000000000b000004` [I][C: accepted by the library]

### T4. Client DATA chunk [I][C]

Message bytes `08 03` (a heartbeat, `stream.md`), TSN `clientTag + 5` = `0x1234abd2`, channel 1, flags
`0x01`, data type 0, `keyPos` 0x2a, `ctxUp`:

```
00 5a5aa5a5 728e7fd2 0000002a 00 01 000f | 1234abd2 0001 0000 00 | 0803
```

`005a5aa5a5728e7fd20000002a0001000f1234abd200010000000803` (28 bytes). The next `keyPos` is
0x2a + advance(2) = 0x2e.

### T5. Client DATA_ACK [I][C]

Cumulative TSN `consoleTag + 3` = `0x5a5aa5a8`, `keyPos` 0x2e, `ctxUp`:

`005a5aa5a590cccf3b0000002e030000105a5aa5a80001900000000000` (29 bytes). Next `keyPos` 0x2e + 42 = 0x58.

### T6. Congestion report [I][C]

Received 1234, lost 5, `keyPos` 0x58, `ctxUp` (GMAC computed with the `keyPos` field zeroed):

`05 0000 04d2 0005 dc494724 00000058` = `05000004d20005dc49472400000058`. Next `keyPos` 0x58 + 30 = 0x76.

### T7. Feedback state [I][C]

Inputs: gyro (0.5, −1.25, 0) rad/s, accel (0.1, 0.98, −0.2) g, orientation (x, y, z, w) = (0.1, 0.2, 0.3,
0.927362), left stick (1000, −2000), right stick (−32768, 32767); sequence 7; `keyPos` 0x76; `ctxUp`.

| | Value |
|---|---|
| body v9 (25 bytes) | `a02182aa7aff7f8e821599e07a1e79742d03e8f83080007fff` |
| packet v9 (37 bytes) | `06000700000000763d746d715ea32215af0117aa44ef78a4aee799e0148f16582c24f2259a` |
| next `keyPos` after v9 | 0x76 + advance(41) = 0xa8 |
| body v12 (28 bytes) | `a02182aa7aff7f8e821599e07a1e79742d03e8f83080007fff000001` |
| packet v12 (40 bytes) | `06000700000000765d5f370b5ea32215af0117aa44ef78a4aee799e0148f16582c24f2259a8db46e` |
| next `keyPos` after v12 | 0x76 + advance(44) = 0xae |
| idle body v12 | `a0ff7fff7fff7fff7f9999ff7ffef7ef1f0000000000000000000001` |
| compressed (0, 0.6, 0, −0.8) | `0x1ffd87ff` (largest is w, index 3, negative: low bits `111`) |

Body v9 field by field (bytes as sent): `a0`; gyro `21 82`, `aa 7a`, `ff 7f` (values 0x8221, 0x7aaa,
0x7fff, little-endian); accel `8e 82`, `15 99`, `e0 7a` (0x828e, 0x9915, 0x7ae0); orientation `1e 79 74 2d`
(0x2d74791e); sticks `03 e8`, `f8 30`, `80 00`, `7f ff` (big-endian).
The values were chosen away from rounding boundaries, so 32-bit and 64-bit float arithmetic agree.

### T8. Feedback history [I][C]

Body, newest first: cross pressed (`80 88 ff`), then an older touch down, id 3 at (1000, 500)
(`d0 03 3e 81 f4`). Sequence `0x0102`, byte 3 = 1 (two events), `keyPos` 0x9a, `ctxUp`:

| | Value |
|---|---|
| body | `8088ffd0033e81f4` |
| packet (20 bytes) | `010102010000009a129d1363764121db8bb9061b` |

More events: options pressed `80ac`; L2 at 0x80 `808680`; finger id 127 lifted at (1919, 1079) `c07f77f437`.

### T9. Console video packet, `takionVersion` 12 [I][C]

Packet index 0x0100, frame 0x0020, unit 2 of 8 with 1 FEC unit (word `0x00401c01`), codec 3, offset-18
field `0x0367`, offset-20 byte `0x20` (adaptive stream index 1), `keyPos` 0x12345 (epoch 1, so
`gmacKey(1)` is used), `ctxDown`, plaintext payload
`000000016742c01e95a80f0044101112131415161718191a1b1c1d1e1f202122`:

`020100002000401c0103fbdbd50000012345036720fe5a29b383a50e557c13daccf19c6bda34c2dd681f3c0de029ad4b4617678e85`

[C]: the library parsed packet index 0x100, frame 0x20, unit 2, total 8, FEC 1, codec 3, field 0x367,
adaptive index 1, payload at offset 21, accepted the GMAC and decrypted the payload back to the plaintext.

### T10. Console audio packets [I][C]

Payload plaintext `a0a1a2a3a4a5a6a7a8a9aaab`, codec 5, low half of the unit word `0x5021` (unit size 0x50,
2 FEC, 1 source), `ctxDown`:

| Packet | Value |
|---|---|
| v12 haptics: index 5, frame 7, unit 0 of 3, stream byte `0x02`, `keyPos` 0x2000 | `03000500070002502105f4333d50000020000002744a562bfb539e9d1e2dc630` |
| v9 audio: index 6, frame 8, unit 1 of 3, `keyPos` 0x2040 | `03000600080102502105c15fd70200002040000825619230ae3aa40edaae85` |

[C]: parsed as haptics (payload at 20) and audio (payload at 19), GMACs accepted, payloads decrypted to the
plaintext.

### T11. Console DATA chunk [I][C]

Message `08 01`, TSN `consoleTag`, channel 1, flags 1, `keyPos` 0x40, `ctxDown`:
`001234abcdf2a6d179000000400001000f5a5aa5a500010000000801` (GMAC accepted by the library).

### T12. `keyPos` reconstruction (§6.6) [I][C]

| Reference `R` | Received low 32 `L` | Result |
|---|---|---|
| 0 | `0x00000010` | `0x10` |
| `0xfffffff0` | `0x00000020` | `0x1_00000020` (wrapped forward) |
| `0x1_00000020` | `0xfffffff0` | `0x0_fffffff0` (late, from before the wrap) |
| `0x1_00000020` | `0x80000020` | `0x1_80000020` (exactly half the space: neither, `hi` unchanged) |
| 0 | `0xfffffff0` | `0xfffffff0` (before, but `hi` is already 0) |
| `0x2_fffffff0` | `0x00000040` | `0x3_00000040` |

### T13. Probe messages (§10) [I][C]

Field numbers used (protobuf, `stream.md`'s schema): message: 1 = type (enum), 2 = big, 10 = disconnect,
14 = probe payload, 31 = protocol request. Big: 1 client version, 2 session key, 3 launch spec, 4 encrypted
key. Disconnect: 1 reason. Protocol request: 1 supported versions (repeated, **not** packed). Probe payload:
1 command (0 echo, 1 MTU, 3 bandwidth, 4 client MTU), 2 echo, 3 MTU, 5 client MTU. Echo: 1 state (bool). MTU:
1 id, 2 mtu_req (and optional fields 3–6, not sent). Client MTU: 1 id, 2 mtu_req, 3 state (bool), 4 mtu_down.
Required fields are written even when zero or false; unset optional fields are left out.

| Message | Bytes |
|---|---|
| protocol request [9] | `081ffa01020809` |
| big (empty, client version 9) | `08001208080912001a002200` |
| echo on | `080c7206080012020801` |
| echo off | `080c7206080012020800` |
| MTU command id 1, mtu_req 1454 | `080c720908011a05080110ae0b` |
| client-MTU id 1, mtu_req 1454, state true, mtu_down 1454 | `080c720e08042a0a080110ae0b180120ae0b` |
| client-MTU id 2, mtu_req 1454, state false, mtu_down 1400 | `080c720e08042a0a080210ae0b180020f80a` |
| disconnect "Client Disconnecting" | `080852160a14436c69656e7420446973636f6e6e656374696e67` |

Ping number 3 with tag `0xdeadbeef`: 548 bytes, starting
`0300000000007ffc00ff000000000000000000000000deadbeef`, then zeros.

### T14. GMAC epochs [I][C]

The T6 congestion report (received 1234, lost 5) at other `keyPos` values, `ctxUp`:

| `keyPos` | Epoch | Datagram |
|---|---|---|
| 45000 (`0xafc8`) | 0 | `05000004d2000550384da60000afc8` |
| 45001 (`0xafc9`) | 1 | `05000004d20005866990210000afc9` |
| 90001 (`0x15f91`) | 2 | `05000004d20005dc38665100015f91` |
| 2^32 + 0x420 | 95443 | `05000004d200056449814600000420` (only the low 32 bits travel) |

### T15. PlayFX reorder-wait estimator trace (§12.3) [I][C]

Times in µs. Wait after each step:

| # | Event | Result |
|---|---|---|
| 1 | hole filled, lateness 7000 (first sample: srtt 7000, rttvar 3500, target clamp(21000) = 20000) | wait 20000 |
| 2 | hole filled, 7000 (target 17500, floor 19000) | 19000 |
| 3 | hole filled, 9000 | 18050 |
| 4 | hole skipped: begin 100, count 3, waiting since 1 000 000, skipped at 1 010 000 | 18050 |
| 5 | packet 101 arrives at 1 012 000: late, lateness 12000 (sample; cover 15000) | late; 19999 |
| 6 | packet 101 again at 1 012 500 | not late |
| 7 | hole skipped: begin 200, count 2, at 1 115 000; then expire at 1 215 000 (hole 1 had a late packet: nothing; hole 2 lost: shrink, held at target 19999) | 19999 |
| 8 | hole skipped because the queue was full: begin 300, count 300, at 1 301 000 → kept as begin 344, count 256 | – |
| 9 | packet 300 at 1 302 000 | not late (not in the kept part) |
| 10 | packet 344 at 1 302 000: late, lateness 2000 | late; 20000 |

### T16. Congestion numbers (§8.3) [I][C]

`maxLoss` 0.05. [C] is the library's own congestion thread, its report captured off the socket.

| Case | Inputs | Reported (received, lost) |
|---|---|---|
| a | video 500 received / 3 lost; 45 audio packets, highest frame index 0x0005, previous interval's 0xffd0 (d = 53 across the wrap) | 545, 11 |
| b | video 100 / 40; 10 audio packets, frame indices 1 … 10, previous 0 | 143, 7 (clamped: 150 · 0.05 = 7.5 → 7) |
| c | no video; 12 audio packets with duplicates, highest 10, previous 0 | 12, 0 (never negative) |

---

## Observed on a real console (2026-11-24)

PS5 (system 14230000), PlayFX's own client, two connections per stream (the probe and the stream):

- The stream connection used Takion version 12; the probe connection version 9 was answered on a PS5 every time
  (open question 13: v9 works; [12] still untried).
- No packet failed the GMAC check and nothing was retransmitted in about 20,900 received packets over four
  sessions; the `keyPos` rules of §6.6 as written were accepted by the console (open question 3: they work;
  whether simpler ones would is still untested).
- Both receive paths (a BSD socket thread and Network.framework) gave the same results on this LAN.

## 16. Open questions

1. **Console initial TSN.** Whether the INIT_ACK initial-TSN field always equals `consoleTag`. Existing
   clients start their window at `consoleTag`, which works; a capture of a real INIT_ACK would settle it.
2. **Gap blocks and duplicate TSNs** in console DATA_ACKs: layout presumed SCTP's, unverified. Whether a
   console ever sends duplicate-TSN entries (an ack with them fails the existing client's length check).
3. **`keyPos` rules the console enforces.** Whether it requires strictly increasing values, rejects
   reuse, or would accept a simpler advance (e.g. round up to 16). Copy §6.6 exactly until tested.
4. **Skipping the probe.** Whether a console streams normally if no connection to 9297 is ever made
   (failure after connecting is known to be tolerated).
5. **Feedback rates.** The rate of feedback state the console expects, whether it ends a session without
   feedback, and what it does with packets whose sequence number goes backwards.
6. **History semantics.** The "apply as many events as the number moved" behaviour is reported by other
   clients' authors from testing; PlayFX hasn't verified it independently.
7. **Unknown header bits.** AV byte 0 bits 5–7; the 3 extension bytes (bit 4); audio offset 18; the low 5
   bits of video offset 20; bytes 1–2 of the congestion report. Packet types 4 and 8 have never been seen.
8. **Console-side fragmentation.** Whether the console ever sends DATA chunks with flags `0x00` (a split
   message); existing clients would mis-handle them.
9. **GMAC before the bang.** Whether the console's pre-bang control packets carry a GMAC at all (existing
   clients don't check), and what the console does with a client packet whose GMAC is wrong (presumably
   drops it silently).
10. **Console retransmission timing** (its RTO and give-up count), and what it does when the client's
    receive window drops its chunks.
11. **Channels.** Whether the console cares about the channel values in §5.4.
12. **PS5 touchpad y range** (PlayFX uses 0 … 1079; the PS4 range is 0 … 941) and whether the console
    clamps.
13. **Probe on PS5.** The probe sends client version 9 and versions [9] to a PS5 too; that works in
    practice, but what a PS5 would answer to [12] is unknown.

---

## 17. Implementation pitfalls

- **Little-endian counters.** `ivBase ⊕+ j` adds in little-endian byte order (§6.3). A big-endian CTR
  mode (CommonCrypto `kCCModeCTR`) gives the wrong stream: build the counter blocks yourself and encrypt
  them with AES-ECB.
- **16-byte GCM nonce.** The GMAC uses a 16-byte IV, so GHASH derives the pre-counter block. Check the GCM
  API accepts it (and test against T4–T11) or implement GHASH; a 12-byte-only API won't do.
- **Payload at `keyPos + 16`**, GMAC IV at `⌊keyPos / 16⌋`, GMAC epoch at `⌊(keyPos − 1) / 45000⌋`: three
  different derived values from one number.
- **Zeroing differs by type:** control and congestion packets zero the `keyPos` field for the GMAC;
  feedback and AV packets keep it. The GMAC field is always zeroed.
- **`gmacKey(e)` derives from `gmacKey(0)`**, not from `cipherKey` and not from `gmacKey(e − 1)`; and the
  step constant is 44910, not 45000.
- **The `keyPos` advance is `s + (s mod 16)`**, not a round-up, and DATA chunks advance by the message
  length only, while acks and congestion reports advance by the datagram length.
- **Endianness inside the feedback state:** motion fields are little-endian, sticks big-endian.
- **History byte 3 is count − 1**, and each new event goes in its own packet.
- **One `keyPos` sequence per direction**, shared by all packet types; the receive-side 64-bit
  reconstruction is shared by control and AV packets too.
- **Retransmit unchanged:** a resent DATA chunk keeps its `keyPos` and GMAC, even across the crypto
  switch.
- **Check the GMAC before parsing anything else**, and update the `keyPos` reference only after it
  verifies.

---

## 18. Internet play

Over the internet both Takion connections (the network probe and the stream connection) run on the **data
hole** (holepunch.md): one UDP socket, already `connect()`ed to the console address and port that hole
punching selected. Nothing in the Takion packets changes. The differences are around them:

| Item | LAN (§1.1) | Internet |
|---|---|---|
| Console port, probe | 9297 | the data hole's selected port |
| Console port, stream | 9296 | the **same** port and socket as the probe |
| Client socket | a new socket per connection | one socket for both; the probe's end does **not** close it; the stream connection closes it when it ends |
| Before each Takion handshake | – | the client reads and discards whatever is queued on the socket (late hole-punch probes or packets of the previous connection): it waits up to 200 ms at a time, for at most 1 s (client choice, observed) |
| Between probe and stream | – | the RUDP switch message on the ctrl hole and ctrl `0x0034` (rudp.md §8) |
| Don't-Fragment, receive buffer, traffic class | as §10 / §14 | set on the data-hole socket the same way |

- The client still sends INIT first (§4); the console's packets come from the selected address, which the
  connected socket filters.
- Liveness and shutdown are as §13. With NAT in the path a long gap in traffic could let a mapping expire;
  during streaming there is constant traffic in both directions (AV, feedback, acks), and the stream
  layer's heartbeat runs every second.
- MTU: the probe measures the internet path as on the LAN; nothing is assumed about it (path MTUs below
  1454, for example through PPPoE or VPNs, are found by the probe's MTU test, stream.md §5.5).

## Sources

- chiaki-ng (AGPL-3.0), read for facts only, at commit d8efd673bc93bbc16e9f646c5b24e0dee013abcc (the chiaki-ng
  submodule commit this repository recorded until 2026-11-24): its Takion, send buffer, stream cipher,
  congestion, packet statistics, feedback, probe and reorder sources, the protobuf schema and the unit tests. Its reorder-wait estimator and the 256-slot
  video queue behaviour (§12.2–§12.3) were written by PlayFX's author (commits `f1da1512`, `7b89a47e`,
  `d8efd673`, November 2026) and are described here as PlayFX's own design.
- RFC 4960 (SCTP): the model for the chunk format and the handshake. RFC 1982: serial-number arithmetic.
  RFC 6298: the srtt/rttvar smoother used in §12.3. NIST SP 800-38D: GCM with IVs other than 96 bits.
- PlayFX's own notes: `docs/NETWORK.md` (receive buffer size, Wi-Fi real-time marking, the packet
  statistics wrap fix, the reorder queue and wait, the probe's RTT on Wi-Fi).
