# Control channel ("ctrl")

Status: draft 1 (clean-room spec, facts only). LAN path over TCP. The PSN relay differences are in §10.

The ctrl channel is a TCP connection to the console's port 9295. It is opened after a successful
session init (`session.md` §4–§5) and stays open for the whole session. It starts with one HTTP-style
request and response. After that, the same socket carries length-prefixed binary messages in both
directions, with encrypted payloads.

Prerequisites from `session.md`:

- `negotiatedVersion`;
- `sessionAesKey` and `sessionIvSeed` (§6.1; rpcrypt.md §5's `K` and `S`);
- `registKey` (16 bytes, zero-padded);
- `clientDeviceId` (32 bytes, §6.2);
- the console address.

Conventions: integers are big-endian unless stated. "Client choice (observed)" marks existing-client
behaviour the console isn't known to require. Type ids are written in hex.

---

## 1. Cipher (as used on ctrl)

Every encrypted ctrl item (an HTTP header value or a binary message payload) is encrypted on its own:

```
IV(n)        = HMAC-SHA256(K_hmac[negotiatedVersion], sessionIvSeed || uint64_be(n))[0..16)
E(n, P)      = AES-128-CFB128(key = sessionAesKey, iv = IV(n)) over P
D(n, C)      = the CFB128 inverse with the same key and IV
```

- `n` is that item's counter value (§4). The cipher restarts for every item, so nothing carries over.
- The output is as long as the input, with no padding and no authentication tag.
- `K_hmac` is rpcrypt.md §2.4's `H` for the negotiated version. This is rpcrypt.md §2.2 applied to ctrl,
  and rpcrypt.md §5.3 gives the counter model that §4 here spells out.

---

## 2. Connection

1. Open TCP to `consoleAddress:9295`. This is a new connection, separate from the closed session-init
   one. Existing clients wait about 10 ms after session init first (client choice, observed).
2. Send the ctrl start request (§3).
3. Read the response up to and including the first `\r\n\r\n`. **Any bytes received after that
   belong to the binary frame stream** (§5) and must be kept.
4. From then on: binary frames in both directions until the session ends (§9).

Retries during steps 2–3 (client choice, observed):

- If the TCP connection is reset or closed before the response header arrives, close the socket,
  wait 35 ms, open a new connection and resend the **byte-identical** request. Do this up to 3 times.
  Consoles have been seen resetting the ctrl connection while still getting ready after session init.
- If no response header arrives within 5 s, reconnect once and resend the identical request.

The request is not rebuilt for a resend: counters 0…k−1 were used once, when it was built (§4).

---

## 3. Start request and response

### 3.1 Request

Byte-exact layout. Lines end in CR LF. Lines in `[ ]` are sent only for the versions shown.

```
GET <ctrl path> HTTP/1.1\r\n
Host: <host>:9295\r\n
User-Agent: remoteplay Windows\r\n
Connection: keep-alive\r\n
Content-Length: 0\r\n
RP-Auth: <b64 E(0, registKey)>\r\n
RP-Version: <version string>\r\n
RP-Did: <b64 E(1, clientDeviceId)>\r\n
RP-ControllerType: 3\r\n
RP-ClientType: 11\r\n
RP-OSType: <b64 E(2, "Win10.0.0\0")>\r\n
RP-ConPath: 1\r\n
[PS5 only]               RP-PadProcNo: 3\r\n
[PS4 10.0 and PS5 only]  RP-StartBitrate: <b64 E(3, 00 00 00 00)>\r\n
[PS5 only]               RP-StreamingType: <b64 E(4, streamingType as uint32 little-endian)>\r\n
\r\n
```

| Header | Plaintext | Plaintext size | Counter | Notes |
|---|---|---|---|---|
| request line | – | – | – | Path from `session.md` §3: `/sie/ps5/rp/sess/ctrl`, `/sie/ps4/rp/sess/ctrl` (PS4 10.0), or `/sce/rp/session/ctrl` (PS4 8.0 and 9.0). |
| `Host` | – | – | – | Numeric console address, `:9295`. |
| `User-Agent` | – | – | – | `remoteplay Windows`. |
| `Connection` | – | – | – | `keep-alive`. |
| `Content-Length` | – | – | – | `0`. |
| `RP-Auth` | `registKey`, all 16 bytes including the zero padding | 16 | 0 | Proves the pairing. Base64 is 24 characters. |
| `RP-Version` | – | – | – | Negotiated version string (`1.0`, `10.0`, `9.0`, `8.0`). Spelled `RP-Version` here. Session init spells it `Rp-Version`. |
| `RP-Did` | `clientDeviceId` | 32 | 1 | Base64 is 44 characters. |
| `RP-ControllerType` | – | – | – | Literal `3`. |
| `RP-ClientType` | – | – | – | Literal `11`. |
| `RP-OSType` | ASCII `Win10.0.0` plus one zero byte | 10 | 2 | Base64 is 16 characters. |
| `RP-ConPath` | – | – | – | Literal `1`. |
| `RP-PadProcNo` | – | – | – | Literal `3`. PS5 only. Without it, PS5s were seen sending some adaptive-trigger effects in a form the controller doesn't apply. |
| `RP-StartBitrate` | 4 zero bytes | 4 | 3 | PS4 10.0 and PS5. Existing clients always send zero. Its byte order is unknown, since zero reads the same either way. |
| `RP-StreamingType` | uint32 **little-endian**: 1 = H.264, 2 = H.265, 3 = H.265 with HDR | 4 | 4 | PS5 only. |

- Base64 is the standard alphabet with `=` padding.
- Counters are given for a PS5. On PS4 10.0 the counters are 0–3, and on PS4 8.0/9.0 they are 0–2.
- After the request the client's next counter is **5 on PS5, 4 on PS4 10.0, and 3 on PS4 8.0/9.0**.
- Header order and spelling are as sent by existing clients. Keep them.

### 3.2 Response

- Status line `HTTP/1.1 <code> ...`. Only `200` means success. Anything else means ctrl failed and the
  session ends.
- Existing clients keep the response header within 512 bytes.
- Headers that matter:

| Header | Format | Meaning |
|---|---|---|
| `RP-Server-Type` | Base64 of 16 bytes, encrypted with the **console's counter 0**: plaintext = `D(0, decoded)` | Byte 0 of the plaintext is the console model: `0` PS4, `1` PS4 Pro, `2` PS5. Bytes 1–15 are unknown. If it decodes to anything other than 16 bytes, treat the server type as unknown. A header that isn't valid base64 makes existing clients fail the ctrl start. |
| `RP-Prohibit` | Decimal; `1` = set | The console won't show its picture to Remote Play right now (protected content on screen). The client should show a "can't display" state. Other values, or no header: not prohibited. |

Counter rule (as existing clients do it): the console's counter 0 goes to `RP-Server-Type` only when
that header is present and decodes to 16 bytes. Otherwise the first binary payload from the console
uses counter 0. See §11 Q1.

Existing clients' reaction to the server type (client choice):

- PS4 (0) with a 1080p request → ask for 720p at the same frame rate, if the user allows downgrade;
- PS4 or PS4 Pro (0 or 1) → H.264.

---

## 4. Counters

There are two independent 64-bit counters, both reset to 0 when the ctrl start request is built:

| Counter | Used for | Advances |
|---|---|---|
| `localCounter` (client → console) | The encrypted request headers (§3.1), then each **binary message the client sends that has a non-empty payload** | +1 per item |
| `remoteCounter` (console → client) | `RP-Server-Type` (§3.2), then each **binary message received with a non-empty payload** | +1 per item |

- Messages with an empty payload (length 0) aren't encrypted and **don't** advance the counter.
  Examples: heartbeat request and reply, go-to-bed.
- Every received message with a non-empty payload advances `remoteCounter`, **including types the
  client doesn't recognise**. Decrypt (or at least count) every one, or later messages won't decrypt.
- Outgoing messages take counter values in the order their frames are written to the socket.
- The same counter value in the two directions gives the same IV (same keys, same derivation).

---

## 5. Binary framing

Every message, in both directions, is an 8-byte header followed by the payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `payloadLength`, uint32 big-endian: the number of payload bytes after the header |
| 4 | 2 | `type`, uint16 big-endian (§6) |
| 6 | 2 | reserved, `00 00` when sent. Existing clients ignore it on receive. |
| 8 | `payloadLength` | payload, encrypted: `E(counter, plaintext)` when `payloadLength > 0` |

- The header itself is never encrypted.
- There is no other delimiter. Frames follow each other directly on the TCP stream, and the receiver
  splits them by `payloadLength`, buffering partial frames.
- Existing clients use a 512-byte receive buffer and fail on larger frames. That is a client limit, not
  a protocol one: accept larger frames (keyboard text can be long).

---

## 6. Message catalogue

C→S means client to console. S→C means console to client. Names are this spec's own.

| Type | Dir | Name | Payload (plaintext) |
|---|---|---|---|
| `0x0001` | S→C | Display notice A | ≥1 byte (§6.7) |
| `0x0004` | S→C | Login PIN request | empty |
| `0x0005` | S→C | Login result | 1 byte: `00` accepted, `01` PIN incorrect |
| `0x000D` | C→S | Keyboard enable | 16 bytes (§6.5) |
| `0x0011` | C→S | Controller-features connect (sent with DualSense enable) | 16 bytes (§6.4) |
| `0x0013` | C→S | DualSense features enable | 3 bytes `00 40 00` |
| `0x0014` | C→S | Go to home screen | 16 bytes `00 FF` + 14 × `00` |
| `0x0016` | S→C | Display notice B | ≥2 bytes (§6.7) |
| `0x0020` | C→S | Keyboard enable toggle | 1 byte `01` |
| `0x0021` | S→C | Keyboard opened (console focused a text field) | §6.5 |
| `0x0022` | S→C | Keyboard closed by console | ignored (any) |
| `0x0023` | C→S | Keyboard set text | §6.5 |
| `0x0024` | S→C | Keyboard text changed (console side) | §6.5 |
| `0x0025` | C→S | Keyboard close | 4 bytes, uint32: `0` accept (Return), `1` reject (Esc) |
| `0x0030` | C→S | Microphone connect | 2 bytes `00 00` |
| `0x0033` | S→C | Session ID | §6.2 |
| `0x0034` | S→C | Switch-to-stream acknowledgement (PSN relay only) | empty |
| `0x0036` | C→S | Microphone state | 4 bytes `00 01 XX 59` (§6.6) |
| `0x0050` | C→S | Go to bed (put the console into rest mode) | empty |
| `0x00FE` | S→C | Heartbeat request | empty |
| `0x01FE` | C→S | Heartbeat reply | empty |
| `0x0910` | C→S | Display devices | 4 bytes `00 00 00 00` |
| `0x8004` | C→S | Login PIN reply | the PIN as ASCII digits, no terminator (§6.3) |

Notes:

- Unknown S→C types: ignore them, but still advance `remoteCounter` (§4).
- There is no IDR (keyframe) request on ctrl. It goes over the stream connection (next stage).
- Controller input, haptics and trigger effects also go over the stream connection. Their only ctrl
  parts are `RP-ControllerType`, `RP-PadProcNo` and the DualSense enable messages.
- There is no ctrl message to end the session (§9).

### 6.1 Heartbeat (`0xFE` → `0x1FE`)

- The console sends a heartbeat request with an empty payload. The client answers right away with a
  heartbeat reply with an empty payload. Neither touches the counters.
- The console ends the session if no heartbeat reply reaches it for about **30 s** (observed).
- The console's sending interval isn't recorded (§11). The client never starts heartbeats on the LAN
  path. For the PSN path, see §10.

### 6.2 Session ID (`0x33`)

Plaintext payload:

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `0x4A` in observed traffic. Probably the length of what follows (74), but existing clients don't use it as one. |
| 1 | rest | ASCII session ID, characters `A–Z a–z 0–9` only, no terminator |

The `sessionId` passed to the stream stage is bytes 1…end as text.

Existing clients' checks (client choice):

- warn if byte 0 isn't `0x4A`;
- reject a session ID shorter than 24 or longer than 78 characters, or one with other characters;
- ignore a second `0x33`.

**Fallback (client choice, observed).** If the session ID is missing or invalid, one existing client
makes one up and carries on: the decimal number of seconds of a monotonic clock, followed by the
base64 of 48 random bytes. This happens when the ID is rejected, or when nothing arrived within 10 s
of ctrl coming up. Whether a console accepts a made-up ID is unverified (§11).

Once a session ID has been accepted (or made up), the client sends its feature messages (§8).

### 6.3 Login PIN (`0x04`, `0x8004`, `0x05`)

1. The console sends a login PIN request (`0x04`, empty) **before** the session ID when the console
   user's profile has a login passcode.
2. The client asks the user and sends a login PIN reply (`0x8004`) whose plaintext is the PIN as ASCII
   digits (e.g. `31 32 33 34` for "1234"), encrypted with the next `localCounter`.
3. The console sends a login result (`0x05`, 1 byte): `00` accepted, then the session ID follows;
   `01` wrong PIN, then a new `0x04` follows.
4. Repeat until the PIN is accepted or the user gives up.

A `0x04` after the session ID has been received ends the session in existing clients (client choice).

### 6.4 DualSense features (`0x13`, `0x11`)

Sent when the client wants DualSense features (haptics, adaptive triggers). Existing clients send them
for PS5. Order, both encrypted with consecutive `localCounter` values:

1. `0x0013` with `00 40 00`
2. `0x0011` with `a0 ab 51 bd d1 7e 00 00 ff ff ff ff ff 00 00 00`

The meaning of the bytes isn't known. Send them exactly as shown.

### 6.5 Text keyboard

The console can ask the client for text when a text field is focused.

**Enabling** (C→S, client choice): `0x000D` with the 16 bytes
`00 00 00 01 00 00 05 ae 00 00 00 00 00 00 00 00`, then `0x0020` with `01`.

- **Warning (observed by PlayFX):** sending these to a PS5 makes it end the stream at once, with the
  stream-level reason `Server shutting down`. Existing clients leave the keyboard disabled. The right
  handshake isn't known (§11).

**Keyboard opened, `0x0021` (S→C):**

| Offset | Size | Field |
|---|---|---|
| 0 | 28 | unknown |
| 28 | 4 | `textLength`, uint32 BE |
| 32 | `textLength` | current text of the field (UTF-8 assumed) |

**Keyboard set text, `0x0023` (C→S):** replaces the field's text.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `sequence`, uint32 BE. The first set-text message of the session is 1, then +1 each time (client choice, observed; it isn't known whether the console checks it). |
| 4 | 4 | `textLength`, uint32 BE |
| 8 | 24 | zero |
| 32 | 4 | `textLength` again, uint32 BE |
| 36 | `textLength` | the text, UTF-8, no terminator |

**Keyboard text changed, `0x0024` (S→C):**

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | sequence (uint32 BE) |
| 4 | 4 | unknown |
| 8 | 4 | `textLength`, uint32 BE |
| 12 | 4 | unknown |
| 16 | 16 | unknown |
| 32 | 4 | unknown |
| 36 | 4 | `textLength` again (assumed) |
| 40 | `textLength` | the text |

**Keyboard close, `0x0025` (C→S):** 4 bytes, uint32 BE. `00000000` accepts (like Return) and
`00000001` rejects (like Esc).

**Keyboard closed by console, `0x0022` (S→C):** the field lost focus. Ignore the payload, but count it
(§4).

### 6.6 Microphone (`0x30`, `0x36`)

- `0x0030` with `00 00`: "microphone connect". Sent once, before the client starts sending microphone
  audio over the stream (next stage).
- `0x0036` with `00 01 XX 59` sets the microphone state, where `XX` is `01` or `00`. Existing clients'
  start-up sequence sends `00 01 01 59` **twice** (§8). Which of `00` and `01` means muted isn't clear
  from existing clients (§11).

### 6.7 Display notices (`0x01`, `0x16`)

What existing clients make of these (semantics inferred, not confirmed):

- `0x0001` byte 0 = `01`: notice A is set, meaning the picture may become unavailable.
- `0x0001` byte 0 = `00`: notice A is cleared. If notice B isn't active, the picture is available
  again.
- `0x0016` while notice A is set: unless bytes 0–1 are `01 FF`, the console is showing content that
  can't be streamed (shown to the user as "can't display").
- `0x0016` with bytes 0–1 = `01 FF`: that state is cleared.

This is the same state that `RP-Prohibit: 1` (§3.2) reports at connect time.

### 6.8 Other client messages

- `0x0014` go to home screen: 16 bytes `00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00`. Asks the
  console to show its home screen.
- `0x0050` go to bed: empty payload. Puts the console into rest mode. The console then ends the
  session (§9).
- `0x0910` display devices: `00 00 00 00`. Part of the start-up set (§8). Its meaning isn't known.

---

## 7. Heartbeat timing

| Party | Behaviour |
|---|---|
| Console | Sends heartbeat requests at intervals (exact period unknown). Ends the session after about 30 s with no reply (observed). |
| Client, LAN | Answers each request at once. Never sends heartbeats on its own. |
| Client, PSN relay | Also sends an unrequested reply every 4.95 s once the first request has arrived (client choice, observed; see §10). |

The client should keep answering heartbeats from the moment ctrl is up until the session ends,
whatever the stream connection is doing.

---

## 8. Start-up sequence on ctrl

```
client                                              console
  |-- [HTTP] GET <ctrl path> (counters 0..k-1) ------->|
  |<- [HTTP] 200, RP-Server-Type (remote ctr 0) -------|
  |                                                     |
  |   (if the console wants a login PIN)                |
  |<- 0x0004 login PIN request (empty) -----------------|
  |-- 0x8004 PIN (local ctr k) ------------------------>|
  |<- 0x0005 result (remote ctr 1)  00 ok / 01 wrong ---|   (wrong → back to 0x0004)
  |                                                     |
  |<- 0x0033 session ID (next remote ctr) --------------|
  |-- feature messages (next local ctrs, in order): --->|
  |     [DualSense] 0x0013, 0x0011                      |
  |     [keyboard ] 0x000D, 0x0020   (off by default)   |
  |     0x0036 00 01 01 59                              |
  |     0x0036 00 01 01 59                              |
  |     0x0910 00 00 00 00                              |
  |<- 0x00FE / 0x01FE heartbeats, notices, … -----------|   (any time from here on)
  |   → stream stage (session.md §12)                   |
```

- The feature set and its order are a client choice (observed), sent right after the session ID.
- Existing clients wait up to 10 s for the session ID (or a PIN request) after ctrl comes up. After a
  PIN is sent they wait up to 10 s again.

---

## 9. How the session ends

There is no ctrl "goodbye" message. Ends seen at the ctrl level:

| Event | What happens on the wire | Meaning / suggested client handling |
|---|---|---|
| Client stops | The client closes the ctrl TCP connection (and ends the stream connection, next stage) | Normal stop. |
| Client sends go-to-bed (`0x50`) | The console goes into rest mode. The stream connection is then ended by the console, with reason text `Server shutting down` expected (§11). | Normal end. Don't reconnect. |
| Console closes ctrl (TCP FIN) | Read returns end-of-stream | Ctrl is over. The cause usually shows on the stream connection (a remote disconnect with a reason text). Existing clients don't treat a bare FIN as an error. |
| TCP error or reset | A read or write error | Connection lost, cause unknown. Worth reconnecting. |
| No heartbeat replies for ~30 s | The console ends the session | The client side shows the same as above. |
| Login PIN request after the session ID | – | The client gives up (client choice). |
| Ctrl HTTP status ≠ 200, bad response, connect failure or refusal | – | Ctrl failed. The session never starts. |
| Frame larger than the client's buffer | – | Existing clients fail ctrl. Avoid this by allowing large frames. |

Session-init refusal codes (`RP-Application-Reason`) and the suggested end-reason set are in
`session.md` §5.4 and §10.

---

## 10. PSN relay (RUDP) differences seen at ctrl

Out of scope beyond this list. When ctrl runs over PSN's UDP relay instead of TCP:

- The same HTTP request and binary frames travel inside RUDP messages. `Host` carries the
  hole-punched address and port.
- **PS5:** after building the ctrl request, `localCounter` is advanced by one more without using that
  value. With the 5 header counters (0–4), the first binary message uses counter 6.
- **Login PIN reply:** the payload is encrypted with counter value `localCounter − 1` (one less than
  the next unused value), and `localCounter` still advances by one. This is observed client behaviour
  that works over the relay. Why it works isn't known.
- **Switch to stream connection:** the client sends an RUDP-level request, and the console
  acknowledges with ctrl `0x0034` (empty) before the stream starts.
- **Heartbeats:** besides answering requests, the client sends an unrequested heartbeat reply every
  4950 ms once the first request has arrived. Replies can be lost on the relay. Client choice
  (observed).
- An RUDP "finish" message from the console ends ctrl.

---

## 11. Open questions

1. Does the console give its counter 0 to `RP-Server-Type` even when the header is absent or
   malformed? Existing clients advance `remoteCounter` only when it decodes to 16 bytes.
2. How often the console sends heartbeat requests, and the exact timeout (about 30 s is recorded).
3. The correct keyboard-enable handshake for PS5 (§6.5). The known one ends the stream.
4. Which `XX` value in `0x0036` means muted.
5. What display notices `0x0001` and `0x0016` mean, and their full payloads.
6. What `0x0011`, `0x0013`, `0x0910`, and the unknown fields of `0x0021`, `0x0024` and
   `RP-Server-Type` bytes 1–15 mean.
7. Whether the console checks the keyboard `sequence` field.
8. Whether the console accepts a session made with a client-made session ID (§6.2).
9. Whether the stream-level reason after go-to-bed is always `Server shutting down`.
10. Whether byte 0 of the session ID message is always its length.
11. Why the PSN-relay PIN reply uses counter `localCounter − 1` (§10).
12. Whether `RP-StartBitrate` carries a meaningful non-zero value (byte order and units unknown).

---

## 12. Known-answer vectors

Same made-up inputs and markers as `session.md` §14:

- `registKey` `0123abcd` + 8 zero bytes;
- `rpKey` `a0…af`;
- nonce `00…0f`;
- address `192.0.2.10`;
- `clientDeviceId` `00180000000700400080 202122232425262728292a2b2c2d2e2f 000000000000`.

Session keys are from `session.md` V-S3.

Markers:

- [I]: computed by the independent Python script from this spec.
- [C]: the same value came out of a C harness linked against chiaki-ng's cipher and base64.
- The session keys behind every row were also derived independently from rpcrypt.md §5
  (`session.md` V-S3).

### V-C1. Ctrl start request, PS5, `streamingType` = 2 (H.265) [I][C]

```
GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n
Host: 192.0.2.10:9295\r\n
User-Agent: remoteplay Windows\r\n
Connection: keep-alive\r\n
Content-Length: 0\r\n
RP-Auth: At1kpVXuVkWfSAj4uw5Z6g==\r\n
RP-Version: 1.0\r\n
RP-Did: AgLF531dlzOoNd5VV3A/ARdz1zNGsz/s2NZS1Lud53k=\r\n
RP-ControllerType: 3\r\n
RP-ClientType: 11\r\n
RP-OSType: WppWi0vRPn6MYw==\r\n
RP-ConPath: 1\r\n
RP-PadProcNo: 3\r\n
RP-StartBitrate: hBNd0Q==\r\n
RP-StreamingType: bHrR3w==\r\n
\r\n
```

Next `localCounter` = 5.

Raw ciphertexts:

| Item | Ciphertext |
|---|---|
| `RP-Auth` | `02dd64a555ee56459f4808f8bb0e59ea` |
| `RP-Did` | `0202c5e77d5d9733a835de5557703f011773d73346b33fecd8d652d4bb9de779` |
| `RP-OSType` | `5a9a568b4bd13e7e8c63` |
| `RP-StartBitrate` | `84135dd1` |
| `RP-StreamingType` | `6c7ad1df` |

### V-C2. Ctrl start request, PS4 10.0 [I][C]

The same as V-C1, with these changes:

- path `/sie/ps4/rp/sess/ctrl` and `RP-Version: 10.0`;
- no `RP-PadProcNo` and no `RP-StreamingType`;
- encrypted values:
  - `RP-Auth: N7LirEio935gaE5np3Tq2Q==`
  - `RP-Did: irESUyEEXgGaFjmEo2BQEesbMio8H0FFgsoQh/JZYGg=`
  - `RP-OSType: dgDI1RykIcw6WQ==`
  - `RP-StartBitrate: bpEReQ==`

Next `localCounter` = 4.

### V-C3. Ctrl start request, PS4 9.0 [I][C]

- path `/sce/rp/session/ctrl` and `RP-Version: 9.0`;
- no optional headers;
- encrypted values:
  - `RP-Auth: 8Hp9RDVRqLd+/QLGUHvR9w==`
  - `RP-Did: Uix96LtYLK+7STqi8rX0gnevJZ7eDhvd3a4tdIGtB6w=`
  - `RP-OSType: hW3WhjU/euJqhw==`

Next `localCounter` = 3.

### V-C4. `RP-Server-Type` decryption, PS5 [I][C]

The response header `RP-Server-Type: MOxWljSMNSGfSAj4uw5Z6g==` decodes to
`30ec5696348c35219f4808f8bb0e59ea`. `D(0, ·)` of that is `02000000000000000000000000000000`, so the
server type is 2 (PS5).

Its last 8 bytes match `RP-Auth`'s ciphertext, because both use counter 0 (the same IV) and the
plaintexts agree there (zero bytes).

### V-C5. Plain frames (no encryption) [I]

| Message | Bytes |
|---|---|
| Heartbeat reply | `00 00 00 00 01 fe 00 00` |
| Go to bed | `00 00 00 00 00 50 00 00` |
| Heartbeat request (S→C) | `00 00 00 00 00 fe 00 00` |

### V-C6. Login PIN reply "1234", PS5, `localCounter` = 5 [I][C]

Plaintext `31323334`, which gives:

```
00000004 8004 0000 9bf82809
```

The same message on PS4 10.0 at counter 5 is `00000004 8004 0000 6084531f`, and on PS4 9.0 it is
`00000004 8004 0000 340694f0`.

### V-C7. Session ID received, PS5, `remoteCounter` = 1 [I][C]

The plaintext is `4a` followed by 74 ASCII characters: `ABC…XYZabc…xyz012…789` (62 characters), then
`ABCDEFGHIJKL`.

The frame on the wire:

```
0000004b 0033 0000
485b87a4391fd134e0fcb43f391e556b8e8601bd95d432c262d42b6e8a7562d1
4952f1cbf256c87ae11147f7f4fd52fcc4d6140595a3caaaf2e98c4f60031cf3
e12ea890026b4bf19e21f4
```

Decrypting the 75-byte payload with `D(1, ·)` gives back the plaintext, and the resulting `sessionId`
is the 74 characters.

### V-C8. Microphone state, PS5, `localCounter` = 6 [I][C]

Plaintext `00010159`:

```
00000004 0036 0000 837aca85
```

### V-C9. Keyboard set text "hi", PS5, `localCounter` = 7, sequence 1 [I][C]

Plaintext, 38 bytes:

```
00000001 00000002 0000000000000000 00000000000000000000000000000000 00000002 6869
```

Frame:

```
00000026 0023 0000
b2231dce4fa03fbd6fe77254bfb595bdbd84e8114941afbb3c97365e3b48850bee6deecfb8bf
```
