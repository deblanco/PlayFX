# RUDP: the reliable-UDP control transport (internet play)

Status: draft 1 (clean-room spec, facts only). Internet (PSN) path only. Nothing here is used on the LAN.

On the LAN, registration, session init and ctrl each use a TCP connection to port 9295. Over the internet
there is no TCP: the console and the client have punched one UDP path for control (the **ctrl hole**,
holepunch.md), and the same HTTP texts and ctrl frames ride on it inside a small datagram protocol that
this spec calls **RUDP**.

What RUDP carries, in order, over the one ctrl-hole socket:

| # | Exchange | Spec for the content | RUDP shape |
|---|---|---|---|
| 1 | Registration through PSN (every internet session) | registration.md §8 | handshake, one request, one reply, finish (§5, §6) |
| 2 | Session init (and its version-negotiation retries) | session.md §4–§5 | handshake, one request, one reply, finish (§5, §6) |
| 3 | Ctrl: the HTTP start request, then binary frames both ways for the whole session | ctrl.md | handshake, one request, one reply, then reliable data (§5, §6, §7) |
| 4 | Switch to the stream connection (after the network probe) | §8 | one reliable data message, answered by ctrl `0x0034` |

The A/V stream (Takion) does **not** use RUDP; it runs on the second hole (holepunch.md §7).

Related documents: holepunch.md (how the socket is obtained), psn.md (the PSN side), session.md §11,
ctrl.md §10. Conventions as in README.md: big-endian, hex, "client choice (observed)" for the reference
client's own choices.

---

## 1. Datagrams and messages

- Every RUDP datagram holds **one or more messages**, back to back. Each message is an 8-byte header and
  its own data. The datagram is sent on the connected ctrl-hole socket (holepunch.md §7), so no address
  appears in RUDP.
- A datagram never holds part of a message; the reference reads up to 1500 bytes per datagram (client
  choice).

### 1.1 Message header (8 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | `lenField`, BE16. High 4 bits: `0xC` in every message the client sends (meaning unknown; receivers mask them off). Low 12 bits: `8 + dataLength` of **this** message only (not counting a following message). |
| 2 | 4 | constant `24 4f 24 4f` (`0x244F244F`) |
| 6 | 2 | `type`, BE16 (§2). Its first byte is called **`flags`** below (the reference dispatches on that byte alone for received messages). |
| 8 | `dataLength` | data (§2) |

Receiving a datagram (as the reference does it, client choice where noted):

1. Fewer than 9 bytes: drop it (the reference treats ≤ 8 bytes as a receive error).
2. `dataLength = (lenField & 0x0FFF) − 8`. If that is more than what remains in the datagram, take what
   remains (client choice). If `lenField & 0x0FFF` is 8 or less, the message has no data.
3. If 8 or more bytes remain after this message's data, they are the next message: parse it the same way.
4. **`peerSeq`** of a message = its data bytes 0–1 as BE16, when it has at least 2 data bytes. The value the
   client acknowledges is `peerSeq + 1` (mod 2^16), called **`peerNext`** below.

The 12-bit length limits one message to 4095 bytes including its header. Registration, session init and
ctrl frames fit.

---

## 2. Message types

| `type` | `flags` | Name (this spec's) | Direction | Data layout |
|---|---|---|---|---|
| `0x8030` | `0x80` | INIT | C→S | §5.1 (14 bytes) |
| `0xD000` | `0xD0` | INIT_ACK | S→C | ≥ 8 bytes; bytes 8… are the **cookie** (§5.2) |
| `0x9030` | `0x90` | COOKIE | C→S | §5.3 (14 bytes + cookie) |
| `0xA030` | `0xA0` | COOKIE_ACK | S→C | ≥ 2 bytes; bytes 0–1 = `peerSeq` (§5.4) |
| `0x2030` | `0x20` | REQUEST wrapper | C→S | 4 bytes: `seq` (BE16), `ack` (BE16); always followed in the same datagram by one DATA message carrying the request (§6.1) |
| `0x0230` | `0x02` | DATA | both | `seq` (BE16), then the payload (an HTTP text or one ctrl frame) |
| `0x2430` | `0x24` | ACK | both | `seq` (BE16), `ack` (BE16), then 2 more bytes; the client always sends `00 92` (§4.3) |
| `0x1230` | `0x12` | DATA variant (console) | S→C | `seq`, `ack` (BE16 each), 4 unknown bytes, payload from data offset 8 (§7.3) |
| `0x2630` | `0x26` | DATA variant (console) | S→C | `seq`, `ack`, 2 unknown bytes, payload from data offset 6 (§7.3) |
| `0x36…` | `0x36` | DATA variant (console) | S→C | `seq`, `ack`, …; payload offset not established (§7.3, §11) |
| `0xC000` | `0xC0` | FINISH | S→C | may be empty; ends an HTTP-style exchange or the channel (§6.3, §9) |
| `0x242E` | `0x24` | (known value, purpose unclear) | S→C | handled like any `0x24` ACK; the switch itself is acknowledged with ctrl `0x0034` (§8) |
| `0x022F` | `0x02` | (known value, purpose unknown) | – | never sent by the client |

Notes:

- The low byte of the type is `0x30` in everything the client sends. The console's INIT_ACK and FINISH
  are matched on the `flags` byte only, so their low byte isn't checked; `0xD000` and `0xC000` are the
  full values the reference lists for them.
- Which `flags` values the console uses for which purpose was learned from traffic by the reference's
  authors; there is no specification behind it. See §11 for what is unclear.

---

## 3. Fields shared by all messages

| Name | Size | Meaning |
|---|---|---|
| `seq` | 2 | The sender's sequence counter value for this message (§4). |
| `ack` | 2 | The next sequence value the sender expects from the peer, i.e. the peer's last `seq` + 1. |
| `tag` | 4 | A per-connection value the client puts in INIT and COOKIE (§4.2). |

---

## 4. Counters and the tag

### 4.1 The client's sequence counter (`localSeq`)

- 16 bits. Set once, when the client sets up RUDP on the ctrl-hole socket, to a random value in
  `0x01FF..0x5FFE` (the reference: a random 32-bit number mod `0x5E00`, plus `0x01FF`; client choice).
- **Not reset** between the exchanges of the session's table above: registration, session init and ctrl
  all continue the same counter on the same socket.
- Messages that **take** a value (use the current value, then add 1, wrapping 65535 → 0): INIT, COOKIE,
  the REQUEST wrapper (its DATA message reuses the same value, §6.1), DATA, the switch message (§8).
- ACK **doesn't take** a value: its `seq` field is the current (next unused) value, unchanged.
- A retry (§10) is a new message and takes a new value.

### 4.2 The tag

- 32 bits, set once together with the counter: a random 32-bit number plus `0x8000`, mod 2^32 (client
  choice). Sent in every INIT and COOKIE of the session. Its purpose is unknown.

### 4.3 What the client acknowledges

- `peerNext` = the console message's `seq` + 1 (§1.1 step 4). The client sends ACK with
  `ack = peerNext` and `seq` = its current `localSeq` (unchanged), followed by `00 92` (meaning unknown;
  always these two bytes).
- During ctrl (§7) the client acknowledges every console data message it receives. When a datagram holds
  several messages, the reference uses the **first** message's `peerNext` for every ACK it sends for that
  datagram (client choice). That ACK then doesn't cover the later messages of the datagram. A new
  implementation should acknowledge each console data message with its own `seq + 1` (recommendation;
  nothing known about the console requires the reference's behaviour).

---

## 5. The handshake (before each HTTP exchange)

Each of the exchanges 1–3 in the table at the top starts with this four-message handshake on the same
socket. The reference does it again for every exchange (and for each session-init retry, session.md
§5.3).

```
client                                              console
  |-- INIT (seq=s, tag) ------------------------------->|
  |<- INIT_ACK (… cookie) ------------------------------|
  |-- COOKIE (seq=s+1, tag, cookie) ------------------->|
  |<- COOKIE_ACK (seq=p) -------------------------------|    peerNext = p+1
```

### 5.1 INIT (client → console), 22 bytes on the wire

| Data offset | Size | Value |
|---|---|---|
| 0 | 2 | `seq` = `localSeq` (then +1) |
| 2 | 6 | `0b 01 01 00 01 00` |
| 8 | 4 | `tag` (BE32) |
| 12 | 2 | `05 82` |

`lenField` = `0xC016`. The constant bytes' meaning is unknown; send them exactly.

### 5.2 INIT_ACK (console → client)

- Recognised by `flags` = `0xD0`. The reference requires at least 8 data bytes.
- Data bytes 0–7: not used by the client (meaning unknown).
- Data bytes 8 to the end: the **cookie**, opaque, copied unchanged into COOKIE. Its length is whatever
  remains.

### 5.3 COOKIE (client → console)

Same 14-byte layout as INIT (with the next `seq` and the same `tag`), followed by the cookie bytes.
`lenField` = `0xC000 | (8 + 14 + cookieLength)`.

### 5.4 COOKIE_ACK (console → client)

Recognised by `flags` = `0xA0`, at least 2 data bytes. `peerNext` = its `seq` + 1. That value is the `ack`
of the request that follows (§6.1).

---

## 6. One HTTP-style exchange

Used for registration, session init and the ctrl start request. The HTTP texts are byte-for-byte those of
the LAN path, except for the `Host`/`HOST` header value (session.md §11, ctrl.md §10, registration.md §8).

```
client                                              console
  |-- REQUEST wrapper(seq=q, ack=peerNext) + DATA(seq=q, whole request) -->|   one datagram
  |<- DATA (seq=r, whole response: header [+ body]) ----------------------|
  |-- ACK (seq=q+1, ack=r+1, 00 92) -------------------------------------->|
  |<- FINISH --------------------------------------------------------------|   registration and session init only
```

### 6.1 The request

One datagram with two messages:

1. REQUEST wrapper: `type 0x2030`, `lenField 0xC00C`, data = `seq` (BE16) then `ack` = `peerNext` from
   COOKIE_ACK (BE16).
2. DATA: `type 0x0230`, data = the **same** `seq` value, then the complete request (registration:
   header and body together; session init and ctrl: the header, which is the whole request).
   `lenField = 0xC000 | (8 + 2 + requestLength)`.

The two messages share one counter value; `localSeq` advances by one for the pair.

### 6.2 The response

- The client waits for a message whose `flags & 0x0F` is `0x2` or `0x6` (DATA or one of its variants), at
  least 2 data bytes long. If the datagram's first message isn't one, the following messages in the same
  datagram are tried (client choice, observed).
- The **whole** HTTP response is in that one message: data bytes 2 to the end. The reference reads it from
  offset 2 whatever the variant. It must contain the header terminator `\r\n\r\n`; a registration
  response must also contain all `Content-Length` body bytes. Nothing is reassembled across messages.
- Then parse it exactly as on the LAN (session.md §5, ctrl.md §3.2, registration.md §4). For ctrl, bytes
  after the header terminator in that message are already binary ctrl frames (as on TCP, ctrl.md §2).
- `peerNext` = this message's `seq` + 1.

### 6.3 Closing the exchange

- **Ctrl:** the client sends one ACK (`ack = peerNext`) and the channel goes on as §7. No FINISH.
- **Registration and session init** (`Connection: close`): the client sends ACK (`ack = peerNext`) and
  waits for a FINISH (`flags 0xC0`). If none comes after the retries of §10 the reference logs it and
  carries on (client choice). After FINISH, the next exchange starts again at §5.

---

## 7. Ctrl over RUDP

After §6.3 the ctrl channel behaves as ctrl.md says (counters, frames, heartbeats, ctrl.md §10's PSN
differences), with each ctrl frame carried in one RUDP message.

### 7.1 Client → console

- Each ctrl frame (8-byte ctrl header + encrypted payload, ctrl.md §5) is one DATA message: `type 0x0230`,
  data = `seq` (takes a value) then the frame. One frame per message, one message per datagram.
- The message is kept for retransmission under the key `seq + 1` (the `ack` value that confirms it).
- The reference holds the frame's length in an 8-bit variable while building the message, so a frame
  longer than 255 bytes (header included) is mangled. That's a limit of the reference, not of the
  protocol: the 12-bit `lenField` allows frames up to 4085 bytes.

### 7.2 Retransmission (client choice, observed)

| Rule | Value |
|---|---|
| Retransmit a kept message when it was last sent more than | 400 ms ago |
| Checked every | 200 ms |
| Give up on a message (drop it silently) after | 25 retransmissions |
| A kept message is released when an ACK or data variant arrives with `ack` ≥ its key | 16-bit serial-number comparison (RFC 1982 style: `a < b` when `(b − a) mod 2^16` is in `1..32767`) |
| At most | 16 messages kept; a 17th is sent once but not kept (the reference reports an error and goes on) |

A retransmission resends the identical bytes (same `seq`).

### 7.3 Console → client, per message `flags` (as the reference handles them)

For every message in a received datagram (also the 2nd, 3rd … message):

| `flags` | `ack` read from | Client sends ACK? | Ctrl frame starts at data offset |
|---|---|---|---|
| `0x02` | – | yes | 2 |
| `0x12` | data 2–3 | yes | 8 |
| `0x26` | data 2–3 | yes | 6 |
| `0x36` | data 2–3 | yes | 2 (as the reference does it; doubtful, §11) |
| `0x24` (ACK) | data 2–3 | no | – (no frame) |
| `0xC0` (FINISH) | – | no | – the console ended ctrl (§9) |
| anything else | – | yes | 4 (client choice, observed) |

- A message with fewer than 4 data bytes (other than FINISH) is skipped (client choice).
- **Frame check (client choice, observed):** at the frame offset there must be a whole ctrl frame and
  nothing else: the BE32 `payloadLength` there must equal `dataLength − offset − 8`. Otherwise the
  message's content is dropped (the ACK is still sent). Taken frames go into the ctrl frame stream of
  ctrl.md §5 in arrival order.
- The reference keeps no record of received `seq` values: it neither reorders nor drops duplicates (a
  console retransmission would be processed twice and break the ctrl counters, ctrl.md §4). A new
  implementation should ignore a data message whose `seq` it has already taken (recommendation; the
  console's retransmission behaviour is unverified, §11).

**What the reference assumes about the console's `seq` (answers to implementer questions):**

- **Contiguity is never checked.** The reference never compares a console `seq` with an earlier one. The
  `ack` it sends is always derived from the message just received (`seq + 1` of the datagram's first
  message, §4.3), never from a running "next expected" value. So whether the console's data `seq`s continue
  contiguously from COOKIE_ACK's `seq + 1` (and from the HTTP response's `seq + 1` into ctrl) is **not
  established**; in the reference's design it doesn't matter. An implementation that wants to detect
  duplicates or gaps must not rely on contiguity without a capture (§11).
- **Duplicates: never.** No received message is ever treated as a duplicate, in the HTTP exchanges or in
  ctrl. (In the HTTP exchanges a repeated response can't do harm: the reference reads one response per
  request and moves on; a late copy arriving afterwards is read by the next step as an unexpected message,
  which costs that step a try, §10.)
- **Layouts of `0x12`, `0x26`, `0x36`:** nothing beyond the table above is known. In all three, data bytes
  0–1 are taken as the console's `seq` and bytes 2–3 as its `ack`. For `0x12` the reference skips 4 more bytes
  (frame at 8), for `0x26` 2 more (frame at 6). For `0x36` it reads the `ack` at 2–3 but then looks for the
  frame at offset **2**, i.e. over the `ack` bytes; such a message passes the frame check only by accident,
  so in practice the reference drops the ctrl content of `0x36` messages (it still acknowledges them). The
  real offset for `0x36` is open (§11); by the pattern of the others it would be 10 (2 + 2 + 4 + 2), which is
  a guess, not an observation. The HTTP exchange (§6.2) reads any of these from offset 2, which is right
  only for `0x02`.
- Receive errors (a datagram that can't be read or parsed) are skipped. The reference gives up on ctrl
  only when receiving has failed continuously for 10 s, retrying every 50 ms (client choice).

---

## 8. Switch to the stream connection

After the network probe (stream.md §5), before the stream connection, the client sends one DATA message:

| Data offset | Size | Value |
|---|---|---|
| 0 | 2 | `seq` (takes a value; kept for retransmission like §7.1) |
| 2 | 8 | `00 00 00 10 00 0d 00 00` |
| 10 | 16 | 16 random bytes (cryptographically secure in the reference) |

`lenField` = `0xC022` (34 bytes on the wire).

- Bytes 2–9 have the shape of a ctrl frame header (payload length 16, type `0x000D`), but the 16 bytes
  are **not** encrypted with the ctrl cipher and the ctrl counters are **not** advanced.
- The console acknowledges with a ctrl frame of type `0x0034` with an empty payload (ctrl.md §6),
  delivered like any ctrl frame (§7.3).
- The reference waits up to 5 s for it and ends the session without it (client choice). Then it starts
  the stream connection on the data hole.

---

## 9. How it ends

- **Console:** a FINISH (`flags 0xC0`) during ctrl ends the ctrl channel; the reference ends the session
  as a ctrl failure. Otherwise the console ends the session through the stream layer (a Disconnect,
  stream.md §11) or by no longer answering.
- **Client:** there is no client-side RUDP close message. The reference simply stops using and closes the
  socket at the end of the session, then leaves the PSN session (psn.md §8).
- **Liveness:** none at the RUDP level; ctrl heartbeats (ctrl.md §6.1, §7) keep the session up. Over RUDP
  the client also sends an unrequested heartbeat reply every 4950 ms (ctrl.md §10), which also keeps the
  NAT mappings of the ctrl hole alive.

---

## 10. Timeouts and retries (client choices, observed)

| Step | Wait per try | Tries | On failure |
|---|---|---|---|
| INIT → INIT_ACK | 1 s | 3 (each try sends a new INIT with a new `seq`) | the exchange fails ("console didn't answer" for registration) |
| COOKIE → COOKIE_ACK | 1 s | 3 (new COOKIE, new `seq`, same cookie) | the exchange fails |
| Request → response DATA | 1 s | 3 (each try resends the request as a new wrapper + DATA pair with a new `seq`) | the exchange fails |
| ACK → FINISH | 1 s | 3 (resends the identical ACK) | ignored, carry on |
| Ctrl start request | as "Request → response DATA" (the LAN path's extra resend after a timeout never applies here) | 3 | ctrl fails |
| Ctrl data retransmission | §7.2 | 25 | message dropped |
| Switch → ctrl `0x0034` | 5 s | 1 | session ends |

During the request/handshake waits, any message of the wrong kind counts as a failed try and causes a
resend (client choice, observed). A more tolerant receiver (keep waiting for the wanted kind until the try
times out) is allowed by everything known about the console.

---

## 11. Open questions

1. What the high nibble `0xC` of `lenField` means, and what the console puts there.
2. The meaning of INIT's constant bytes (`0b 01 01 00 01 00`, `05 82`), of the `tag`, of INIT_ACK's data
   bytes 0–7, and of ACK's trailing `00 92`.
3. The `flags` byte looks like a bit set (`0x80` INIT, `0x20` "has an ack field", `0x02` "has a payload",
   `0x04`/`0x10` "has extra fields"?), which would explain the data offsets of `0x12` (8) and `0x26` (6) but
   not the reference's offset 2 for `0x36`. Only captures can settle the layout of `0x12`, `0x26` and `0x36`
   and what their extra bytes are.
4. Whether the console retransmits unacknowledged data, after how long, and whether it ever reorders. The
   reference processes every received data message once per arrival. Also whether the console's data `seq`s
   are contiguous across the handshake, the HTTP response and ctrl (the reference never checks, §7.3).
5. Whether an HTTP response can be split over several DATA messages (the reference assumes not; real
   registration and session-init responses fit in one).
6. Whether the console expects a fresh handshake before each exchange (the reference always does one) or
   would accept several exchanges after one handshake.
7. Whether a client-side close exists (the official client may send FINISH at the end).
8. What happens if the client's `seq` values restart (the reference never resets them within a session).
9. Whether the console needs the switch message's 16 bytes to be random, or checks them.

---

## 12. Known-answer vectors

Made-up values. `localSeq` starts at `0x1234`, `tag` = `0x89abcdef`, the console's COOKIE_ACK had
`seq = 0x5678` (so `peerNext` = `0x5679`). Marks as in test-vectors.md: **[I]** computed by an independent
script from this text; **[C]** the same bytes came out of a copy of the reference's RUDP code driven by a
harness with `send()` and the random-number source stubbed (nothing was sent anywhere).

### R1. INIT, `seq 0x1234` [I][C]

```
c016 244f244f 8030 | 1234 0b0101000100 89abcdef 0582
```

### R2. COOKIE, `seq 0x1235`, cookie `c0 c1 … cf` (16 bytes) [I][C]

```
c026 244f244f 9030 | 1235 0b0101000100 89abcdef 0582 c0c1c2c3c4c5c6c7c8c9cacbcccdcecf
```

### R3. Session init request over RUDP, `seq 0x1236`, `ack 0x5679` [I][C]

The request text (183 bytes, CR LF line ends):

```
GET /sie/ps5/rp/sess/init HTTP/1.1\r\n
Host: 198.51.100.7:50123\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: 0\r\n
RP-Registkey: 3031323361626364\r\n
Rp-Version: 1.0\r\n
\r\n
```

The datagram (205 bytes): wrapper, then DATA with the same `seq`:

```
c00c 244f244f 2030 | 1236 5679
c0c1 244f244f 0230 | 1236 474554202f7369652f7073352f72702f736573732f696e697420485454502f312e310d0a
486f73743a203139382e35312e3130302e373a35303132330d0a557365722d4167656e743a2072656d6f7465706c6179
2057696e646f77730d0a436f6e6e656374696f6e3a20636c6f73650d0a436f6e74656e742d4c656e6774683a20300d0a
52502d5265676973746b65793a20333033313332333336313632363336340d0a52702d56657273696f6e3a20312e300d
0a0d0a
```

(Line breaks inside the hex are layout only.)

### R4. ACK of a console message with `seq 0x5679` (so `ack 0x567a`); `localSeq` is now `0x1237` [I][C]

```
c00e 244f244f 2430 | 1237 567a 0092
```

### R5. Ctrl heartbeat reply in a DATA message, `seq 0x1237` [I][C]

The ctrl frame is `00000000 01fe 0000` (ctrl.md V-C5).

```
c012 244f244f 0230 | 1237 0000000001fe0000
```

Kept for retransmission under key `0x1238`.

### R6. Switch to the stream connection, `seq 0x1238`, random bytes `40 41 … 4f` [I][C]

```
c022 244f244f 0230 | 1238 00000010000d0000 404142434445464748494a4b4c4d4e4f
```

### R7. Parsing a console datagram with two messages [I][C]

```
c00e244f244f2430 567812390092 c012244f244f0230 56790000000000fe0000
```

| Message | `type` / `flags` | data | `peerSeq` → `peerNext` | Meaning |
|---|---|---|---|---|
| 1 | `0x2430` / `0x24` | `5678 1239 0092` | `0x5678` → `0x5679` | ACK: everything up to key `0x1239` is confirmed (R5's and R6's kept messages are released) |
| 2 | `0x0230` / `0x02` | `5679` + `00000000 00fe 0000` | `0x5679` → `0x567a` | a ctrl heartbeat request; the client answers with an ACK (the reference uses `ack 0x5679`, message 1's `peerNext`, §4.3) and a heartbeat reply |
