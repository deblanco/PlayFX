# Session start: from pairing keys to the stream connection

Status: draft 1 (clean-room spec, facts only). Covers the local-network (LAN) path. The PSN relay
path is summarised in §11 but not specified.

Related documents:

- `rpcrypt.md`: session key derivation (§5, session mode) and the per-message cipher (§2). This
  document's `sessionAesKey`, `sessionIvSeed` and `K_hmac` are rpcrypt.md's `K`, `S` and `H`, and its
  versions PS4 8.0 / 9.0 / 10.0 and PS5 1.0 are rpcrypt.md's targets `PS4-8`, `PS4-9`, `PS4-10` and `PS5-1`.
- `ctrl.md`: the control channel (its HTTP start request, binary framing, message catalogue).
- `registration.md`: where the RegistKey and RP-Key come from. `discovery.md`: finding and waking the
  console.

Conventions: all multi-byte integers are big-endian unless a field says otherwise. "Client choice
(observed)" marks behaviour of an existing client that the console doesn't dictate, as far as is known.
Byte strings are written in hex.

---

## 1. Inputs

What the client holds before it starts:

| Name | Size | Origin | Notes |
|---|---|---|---|
| `consoleAddress` | – | discovery or user | IPv4 (or IPv6) address of the console. |
| `consoleKind` | – | discovery / pairing | PS4 or PS5. Picks paths and protocol versions (§3). |
| `registKey` | 16 bytes | pairing (`PS4-RegistKey` / `PS5-RegistKey`) | The hex value from pairing, decoded to bytes, then zero-padded to 16 bytes. In practice it is 8 ASCII characters (lower-case hex digits, e.g. `0123abcd`) followed by 8 zero bytes. |
| `rpKey` | 16 bytes | pairing (`RP-Key`) | Secret input to session key derivation. |
| `clientDeviceId` | 32 bytes | made per session by the client | Layout in §6.2. |
| Stream preferences | – | user | Resolution, frame rate, bitrate, codec. Mostly used by the next stage; the codec is also announced on ctrl (`ctrl.md` §3). |

The console must be awake (not in rest mode) and must already have paired this client. Waking is
done through discovery (`discovery.md`).

---

## 2. Overview: connections and order

All in one session, against the same `consoleAddress`:

| # | Step | Transport | Console port | Lifetime |
|---|---|---|---|---|
| 1 | **Session init**: one HTTP request and its response header | TCP | 9295 | Closed by the client once the response header is in (`Connection: close`). A new connection for each attempt (§5). |
| 2 | (client pause) | – | – | The client waits about 10 ms before step 3: client choice (observed). Another client is known to wait 20 ms on PS5. |
| 3 | **Ctrl**: an HTTP start request, then a binary message channel on the same socket | TCP | 9295 | Stays open for the whole session (`ctrl.md`). |
| 4 | Ctrl start-up: wait for a **session ID**, or a **login PIN** request first (§8) | over #3 | – | Up to 10 s (client choice, observed). |
| 5 | **Network probe** (MTU and round-trip test over Takion) | UDP | 9297 | Short-lived. Next stage, not specified here. |
| 6 | **Stream connection** (Takion: ECDH handshake, launch spec, A/V, input) | UDP | 9296 | Whole session. Next stage. |

The session-init and ctrl connections both go to TCP 9295. They are two separate TCP connections:
the first is closed before the second is opened.

```
client                                    console
  |-- TCP connect :9295 ------------------->|
  |-- GET <init path> (RP-Registkey, ...) -->|
  |<-- HTTP/1.1 200 + RP-Nonce -------------|   (or an error + RP-Application-Reason)
  |-- close -------------------------------->|
  |   derive session keys from (RP-Nonce, rpKey)       [rpcrypt.md, session mode]
  |-- TCP connect :9295 ------------------->|
  |-- GET <ctrl path> (RP-Auth, RP-Did, ...)>|   encrypted header values, ctrl.md §3
  |<-- HTTP/1.1 200 + RP-Server-Type -------|
  |<======= binary ctrl frames, both ways =====>|  (login PIN?) → session ID → features
  |-- UDP :9297 network probe ------------->|   next stage
  |-- UDP :9296 stream connection --------->|   next stage
```

---

## 3. Console kinds, protocol versions and paths

The protocol version is sent as the `RP-Version` / `Rp-Version` header value. Known values:

| Console | Version string | Session-init path | Ctrl path |
|---|---|---|---|
| PS4, protocol 8.0 | `8.0` | `/sce/rp/session` | `/sce/rp/session/ctrl` |
| PS4, protocol 9.0 | `9.0` | `/sce/rp/session` | `/sce/rp/session/ctrl` |
| PS4, protocol 10.0 | `10.0` | `/sie/ps4/rp/sess/init` | `/sie/ps4/rp/sess/ctrl` |
| PS5, protocol 1.0 | `1.0` | `/sie/ps5/rp/sess/init` | `/sie/ps5/rp/sess/ctrl` |

The version also selects:

- the session key derivation and HMAC key in `rpcrypt.md`: 8.0 and 9.0 share the older PS4 scheme,
  10.0 has its own, and PS5 1.0 has its own;
- the optional ctrl headers: `RP-StartBitrate` for PS4 10.0 and PS5, and `RP-StreamingType` and
  `RP-PadProcNo` for PS5 only (`ctrl.md` §3).

These are protocol versions, not console firmware versions. Which firmware answers with which version
isn't recorded here (see §13).

Starting version (client choice, observed): `1.0` for a PS5 and `10.0` for a PS4. If the console
answers with a different one, the client downgrades (§5.3).

---

## 4. Session-init request

Sent as soon as the TCP connection to `consoleAddress:9295` is up. It is plain text and nothing in it
is encrypted. Byte-exact form (each line ends in CR LF, and an empty line ends the request):

```
GET <session-init path> HTTP/1.1\r\n
Host: <host>:9295\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: 0\r\n
RP-Registkey: <registKey hex>\r\n
Rp-Version: <version string>\r\n
\r\n
```

| Header | Value |
|---|---|
| request line | `GET`, the path from §3, `HTTP/1.1`. |
| `Host` | The console's numeric address as text (e.g. `192.0.2.10`), `:`, port `9295`. For IPv6 the existing client writes the bare numeric address with no brackets (unverified against a console). |
| `User-Agent` | Exactly `remoteplay Windows`. |
| `Connection` | `close`. |
| `Content-Length` | `0`. There is no body. |
| `RP-Registkey` | Lower-case hex of the `registKey` bytes up to (not including) the first zero byte. For the usual 8-character key that is 16 hex digits: key `0123abcd` gives `3031323361626364`. |
| `Rp-Version` | The version string from §3. Note the spelling `Rp-Version` here. The ctrl request uses `RP-Version`. |

Header order and spelling above are what existing clients send. Whether the console needs that exact
order or case is unknown, so send them exactly as shown.

Note for cross-checking: one existing client's hex formatter writes the letters `k`–`p` instead of
`a`–`f` for nibbles 0xA–0xF. That never shows up with real keys, because ASCII digits and `a`–`f` have
no nibble ≥ 0xA. An implementation should write normal lower-case hex.

---

## 5. Session-init response

### 5.1 Reading it

The client reads until the first `\r\n\r\n` and ignores anything after it (no body is expected), then
closes the connection.

- Status line: it must start with `HTTP/1.1 ` and be followed by a decimal status code.
- Header lines: `Name: value`, one space after the colon (optional), lines ending in CR LF.
- An existing client keeps the whole response header within 512 bytes. Real responses fit, but don't
  rely on that limit.
- Match header names case-insensitively. Existing clients match `RP-Nonce` and `RP-Application-Reason`
  case-sensitively and `RP-Version` case-insensitively.

### 5.2 Response headers

| Header | Format | Meaning |
|---|---|---|
| `RP-Nonce` | Base64 (standard alphabet, `=` padding) of exactly 16 bytes | **Success** token: the `sessionNonce` that goes into session key derivation. It isn't encrypted. Any other length means the response is invalid. |
| `RP-Application-Reason` | Hex number with no `0x`, e.g. `80108b10` (parsed as base 16) | Why the console refused. See §5.4. |
| `RP-Version` | Version string, e.g. `9.0` | The protocol version the console speaks. It matters when the request was refused for a version mismatch. |

Success means status `200` **and** an `RP-Nonce` that decodes to 16 bytes. Any other status, or a 200
without a valid nonce, is a failure. The console's failure status code isn't recorded (§13). Use
`RP-Application-Reason` instead.

### 5.3 Version negotiation

When the request fails and both of these hold:

- `RP-Application-Reason` is `0x80108B11` (version mismatch) or `0x80108BFF` (unspecified), and
- `RP-Version` is present and differs from the version that was sent,

then the client maps the console's `RP-Version` to a known version for the same console kind (PS5:
`1.0`; PS4: `8.0`, `9.0`, `10.0`) and repeats the whole session init on a **new TCP connection** with
that version (new path and `Rp-Version`).

- A PS4 that reports `5.0` is retried as `9.0`: client choice (observed heuristic).
- Any other unknown version ends the attempt as "version mismatch".
- At most 3 session-init requests in total (the first, then up to two retries). If the third still
  reports a mismatch, the session fails: client choice (observed).

The version that finally succeeds is the **negotiated version**. It selects the key derivation, the
ctrl path and the ctrl headers from then on.

### 5.4 `RP-Application-Reason` values

| Value | Meaning | What the client should do |
|---|---|---|
| `0x80108B10` | Remote Play is **already in use** (another client is connected, or the console hasn't yet released the previous session) | Retry later. A console was seen to stay "in use" for about 9 s after a session ended. |
| `0x80108B15` | Remote Play on the console has **crashed** | Fail. The user may need to restart Remote Play or the console. |
| `0x80108B11` | **Protocol version mismatch** | §5.3. If there's no usable `RP-Version`, fail as version mismatch. |
| `0x80108BFF` | Unspecified | If `RP-Version` differs from the one sent, handle as §5.3. Otherwise fail as unknown. |
| `0x80108B09` | Registration failed (seen in pairing answers; probably a bad pairing PIN) | Fail. Listed because it shares the code space; it isn't known to be sent at session init. |
| `0x80108B02` | Invalid PSN ID (pairing) | Same as above. |
| any other value / missing | Unknown refusal | Fail as unknown. |

The table lists every value known to existing clients. What the console returns for an unknown or
revoked `RP-Registkey` isn't recorded (§13).

### 5.5 Connection-level failures

| Condition | Meaning (as far as known) |
|---|---|
| TCP connect refused (RST) on 9295 | Remote Play isn't accepting connections: Remote Play disabled, the console in rest mode or still starting, or the wrong host. Report as "connection refused". |
| TCP connect timeout (5 s, client choice, observed) | Host unreachable or asleep. |
| No complete response header within 5 s, or the peer closes first | Unknown failure. |

If the name resolved to several addresses, the client tries each in turn and uses the first that
accepts the TCP connection. That address is used for every later connection.

---

## 6. Values set up by the client

### 6.1 Session keys

Once `sessionNonce` is in hand, the client derives the two 16-byte session keys from
(`negotiated version`, `sessionNonce`, `rpKey`) as in rpcrypt.md §5 (session mode; there `N` = nonce and
`R` = RP-Key):

- `sessionAesKey` (`K`): the AES-128 key;
- `sessionIvSeed` (`S`): hashed with a counter to make each message's IV.

How they're used during the session:

```
IV(counter)        = first 16 bytes of HMAC-SHA256(K_hmac[version], sessionIvSeed || uint64_be(counter))
encrypt(counter,P) = AES-128-CFB128(key = sessionAesKey, iv = IV(counter)), applied to P from its first byte
```

- `K_hmac[version]` is the per-version HMAC key `H` in rpcrypt.md §2.4.
- Each message is a separate CFB stream: the IV is recomputed from that message's counter, and no
  cipher state carries over from one message to the next.
- There is no padding: the ciphertext is as long as the plaintext.
- Decrypting is the CFB inverse with the same key and IV.
- The counter is a 64-bit unsigned integer. In practice ctrl counters stay small.
- The keys are the same in both directions. Direction is told apart only by **which counter** is
  used, and each direction counts on its own from 0 (`ctrl.md` §4). The client's message n and the
  console's message n therefore use the same IV. That is how the protocol works; it isn't a bug to
  "fix".

The session-init exchange itself uses no encryption. Its only cryptographic output is the nonce.

### 6.2 `clientDeviceId` (sent as `RP-Did` on ctrl)

32 bytes, made fresh for each session:

| Offset | Length | Value |
|---|---|---|
| 0 | 10 | `00 18 00 00 00 07 00 40 00 80` (fixed) |
| 10 | 16 | Random bytes from a cryptographically secure generator |
| 26 | 6 | `00 00 00 00 00 00` |

### 6.3 Stream handshake key

`streamHandshakeKey`: 16 random bytes (cryptographically secure), made after ctrl start-up and before
the stream connection. It is used by the next stage (Appendix A).

---

## 7. Ctrl connection

Specified in `ctrl.md`. In short:

- a new TCP connection to `consoleAddress:9295`;
- a `GET <ctrl path>` with encrypted, base64 header values (`RP-Auth` = `registKey` encrypted, `RP-Did`,
  `RP-OSType`, and so on), which take up the client's ctrl counters 0…n−1;
- a `200` response with `RP-Server-Type` (encrypted, the console's counter 0) and maybe `RP-Prohibit`;
- after that the socket carries binary ctrl frames in both directions for the rest of the session.

`RP-Server-Type` tells PS4 / PS4 Pro / PS5 apart (`ctrl.md` §3.3). Existing clients use it to lower
their stream request:

- a base PS4 (0) doesn't get 1080p: 720p at the same frame rate instead, when the user allows
  automatic downgrade;
- a PS4 or PS4 Pro (0 or 1) gets H.264 only.

Note that the codec is already announced in the ctrl request (`RP-StreamingType`, PS5 only) before
the server type is known.

---

## 8. Start-up states on ctrl (login PIN, session ID)

After the ctrl HTTP response, the console's first meaningful frame is one of these:

1. **Session ID** (ctrl type `0x33`). The console accepted the client, and the session can go on to
   the stream stage.
2. **Login PIN request** (ctrl type `0x04`). The console's user profile is protected by a login
   passcode, so the client must ask the user for it.
   - The client sends the PIN with ctrl type `0x8004`.
   - The console answers with a login result (`0x05`): `00` accepted, `01` wrong PIN.
   - A wrong PIN is followed by another PIN request.
   - Once the PIN is accepted, the session ID follows.
   - The client may wait for the user for as long as it likes.

Timeouts, all client choices (observed):

- up to 10 s after the ctrl connection is up for (1) or (2);
- after a PIN is sent, again up to 10 s for a session ID or a new PIN request.

If no session ID arrives in that time, one existing client makes up a local session ID and carries on
(`ctrl.md` §6.2). Whether a console then accepts the stream is unverified (§13).

A login PIN request that arrives **after** the session ID can't be met, and existing clients end the
session.

---

## 9. Timeouts and retries (summary)

Unless stated otherwise these are client choices (observed), not console requirements.

| What | Value |
|---|---|
| Session-init TCP connect | 5 s per address |
| Session-init send | 5 s |
| Session-init response header | 5 s |
| Session-init attempts (version negotiation) | at most 3 |
| Pause between session-init success and ctrl connect | ~10 ms (another client: 20 ms on PS5) |
| Ctrl TCP connect | 5 s |
| Ctrl response header | 5 s. On timeout, reconnect and resend the identical request once. |
| Ctrl connection reset before the response | Reconnect and resend the identical request up to 3 times, 35 ms apart. A console was seen resetting ctrl while still getting ready after session init. |
| Session ID / PIN request after ctrl is up | 10 s |
| User PIN entry | unbounded |
| Console-side: no heartbeat reply | The console ends the session after about 30 s with no heartbeat reply (`ctrl.md` §7). This one is console behaviour, as observed. |

---

## 10. End states before streaming starts

How each console condition shows up on the wire at this stage:

| Condition | Wire signal |
|---|---|
| Console busy (Remote Play in use) | Session init refused with `RP-Application-Reason: 80108b10`. |
| Remote Play crashed | `RP-Application-Reason: 80108b15`. |
| Version mismatch | `80108b11` (or `80108bff`) plus `RP-Version` (§5.3). |
| Console in rest mode / Remote Play not listening | TCP 9295 refused or unanswered (exact behaviour unverified, §13). Discovery reports standby (`discovery.md`). |
| Login PIN needed | Ctrl message `0x04` after the ctrl handshake. |
| Credentials rejected | Not confirmed (§13). Expected to show as a refused session init or a non-200 ctrl response. |
| Ctrl refused or dropped | Ctrl HTTP status ≠ 200, a TCP reset or close, or a malformed response. |

A suggested client-side set of end reasons (client choice). These names are this spec's own:

| End reason | When |
|---|---|
| `stoppedByClient` | The user or app stopped the session. |
| `sessionInitUnknown` | Session init failed with no specific reason (network, parse, unknown reason code, bad nonce). |
| `sessionInitRefused` | TCP connect refused on 9295 during session init. |
| `consoleBusy` | `80108b10`. Worth retrying after a few seconds. |
| `remotePlayCrashed` | `80108b15`. |
| `versionMismatch` | Version negotiation failed. |
| `ctrlFailed` | The ctrl response wasn't 200, ctrl was lost before or during the session, or there was a PIN request after the session ID. |
| `ctrlConnectFailed` / `ctrlRefused` | The ctrl TCP connect failed or was refused. |
| `streamFailed`, `streamRemoteDisconnected`, `streamRemoteShutdown` | Next stage. The console sends a reason text when it disconnects the stream, and `Server shutting down` means the console is going down or into rest mode. |

PlayFX's own retry policy, for reference: busy → retry soon. Unexplained ctrl or stream loss →
reconnect. Remote disconnect with a reason, rest mode, incompatible → don't retry.

---

## 11. PSN relay path (out of scope, differences noted)

When the console is reached through PSN rather than on the LAN, the same session-init and ctrl HTTP
texts are carried over a UDP "RUDP" transport set up by PSN hole punching.

Differences seen at this stage:

- `Host` carries the address and ctrl port that hole punching selected, not 9295.
- After the session-init response the RUDP layer exchanges a finish/ack.
- On PS5 the client's ctrl counter skips one value after the ctrl request (`ctrl.md` §10).
- There's an extra "switch to stream connection" exchange (ctrl `0x34`) before the stream stage.

RUDP framing, hole punching and PSN account handling need their own spec, which is a later
milestone.

---

## 12. Outputs for the next stage (stream connection)

Named facts this stage hands over:

| Name | Value / origin |
|---|---|
| `consoleAddress` | The address that accepted session init (§5.5). |
| `streamPort` | UDP 9296 (stream connection). |
| `probePort` | UDP 9297 (network probe, before the stream). |
| `negotiatedVersion` | §5.3. PS4 8.0 / 9.0 / 10.0 or PS5 1.0. The stream stage uses it too (launch spec, key tables). |
| `sessionAesKey`, `sessionIvSeed` | §6.1. The stream stage uses them again for the launch spec, in rpcrypt.md §2.3's keystream-only form at counter 0 (the same IV as `RP-Auth`, independent of the ctrl counters). |
| `sessionId` | ASCII string `[A-Za-z0-9]`, from ctrl `0x33` minus its first byte (`ctrl.md` §6.2). |
| `streamHandshakeKey` | §6.3, 16 bytes. |
| ECDH key pair | Made by the client for the stream handshake (Appendix A). |
| `serverType` | From `RP-Server-Type`: 0 PS4, 1 PS4 Pro, 2 PS5, or absent. |
| Video request | Width, height, max fps, bitrate (kbps) and codec, after the downgrades in §7. Existing clients' presets (client choice, observed): 360p 2000 kbps, 540p 6000, 720p 10000, 1080p 15000, at 30 or 60 fps. |
| `streamingType` | What was announced on ctrl (PS5): 1 H.264, 2 H.265, 3 H.265 HDR. |
| Ctrl channel | Open, with its counters running. It must keep answering heartbeats while streaming. |
| `dualSenseEnabled` | Whether the DualSense enable messages were sent (`ctrl.md` §6.4). |
| MTU in/out, RTT | Output of the network probe (the next stage's own first step). If the probe fails, existing clients fall back to 1454 / 1454 bytes and 1 ms (client choice, observed). |

---

## Observed on a real console

From PlayFX's own hardware check (PS5, `system-version` 14230000, LAN, 2026-11-23):

- Session init on a ready console: status 200, `RP-Version` 1.0, accepted on the first request, about 20 ms; the
  ctrl connection was up about 20 ms later.
- In **rest mode** (discovery status 620), the TCP connection to 9295 for session init was **refused** at once:
  there is no HTTP answer to read. A client should treat "refused" plus a standby discovery answer as "wake it
  first".
- After a wake packet the console answered discovery as ready about 9 s later, and a session could start again.

## 13. Open questions

1. The HTTP status code the console uses for refusals (only "not 200" is known).
2. What the console answers when `RP-Registkey` is unknown or revoked, or when `rpKey` is wrong (that
   would only show at ctrl, since `RP-Auth` wouldn't decrypt to the RegistKey).
3. What session init does when the console is in rest mode: refused, a timeout, or a reason code.
4. The mapping from console firmware to protocol version (`8.0`, `9.0`, `10.0`), and whether PS5 has
   versions other than `1.0`.
5. Whether a refusal response carries other headers that existing clients ignore. A capture would
   settle this.
6. IPv6: whether the `Host` header needs brackets.
7. Whether the console checks header order or case (`Rp-Version` vs `RP-Version`).
8. Whether a client-made session ID (when the console never sends `0x33`) really works.
9. Whether an `RP-Registkey` containing a zero byte (truncated by the "up to the first zero" rule) can
   happen.

---

## 14. Known-answer vectors

Made-up identities only. Fixed inputs:

| Input | Value |
|---|---|
| `consoleAddress` | `192.0.2.10` (TEST-NET-1) |
| `registKey` | ASCII `0123abcd` + 8 zero bytes = `30313233616263640000000000000000` |
| `rpKey` | `a0a1a2a3a4a5a6a7a8a9aaabacadaeaf` |
| `sessionNonce` | `000102030405060708090a0b0c0d0e0f` (header value `AAECAwQFBgcICQoLDA0ODw==`) |

How they were checked:

- **[I]**: computed by an independent Python script written from this spec's text (in the session
  scratchpad, not in the repo).
- **[C]**: the same value came out of a small C harness linked against chiaki-ng's own cipher, base64
  and ECDH routines.
- The session keys (V-S3) were derived independently from rpcrypt.md §5 and its `data/` tables, and
  matched the harness.

### V-S1. Session-init request, PS5 [I; text checked by hand against existing client output format]

```
GET /sie/ps5/rp/sess/init HTTP/1.1\r\n
Host: 192.0.2.10:9295\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: 0\r\n
RP-Registkey: 3031323361626364\r\n
Rp-Version: 1.0\r\n
\r\n
```

PS4 10.0 is the same with path `/sie/ps4/rp/sess/init` and `Rp-Version: 10.0`. PS4 9.0 uses path
`/sce/rp/session` and `Rp-Version: 9.0`.

### V-S2. Session-init success response (illustrative shape)

```
HTTP/1.1 200 OK\r\n
RP-Nonce: AAECAwQFBgcICQoLDA0ODw==\r\n
\r\n
```

→ `sessionNonce` = `000102030405060708090a0b0c0d0e0f` [I]. Real consoles may send more headers.

Refusal example: a non-200 status with `RP-Application-Reason: 80108b10` → console busy.

### V-S3. Session keys for the fixed inputs

| Version | `sessionAesKey` | `sessionIvSeed` | Check |
|---|---|---|---|
| PS5 1.0 | `598fa9a031d01820db25cab6e90bb19b` | `ac7d50f394ea6588f0488f76e4170c8a` | [I][C] (rpcrypt.md §5.1) |
| PS4 10.0 | `f7e760687cea0ce70c1c129f67c087c8` | `e978b89a1098296fb32415b9b5713be0` | [I][C] (rpcrypt.md §5.1) |
| PS4 9.0 | `35394aed0d6cda5620d3c3a748eb1adf` | `d8905e42bce052e092e354911ad33688` | [I][C] (rpcrypt.md §5.2) |

### V-S4. Per-message IVs (§6.1), from the keys in V-S3 [I][C]

| Version | IV(0) | IV(5) | IV(0x0102030405060708) |
|---|---|---|---|
| PS5 1.0 | `0a894340fc4845e95ddd09d81177fef6` | `aa43c204afffe7e708129e8d075c6e0f` | `b60c50d0d3ac6404c947e8aa110c8351` |
| PS4 10.0 | `c8b0c57d4b68ff953209efa913889d06` | `5183f0941626679ea4f3d6dcd6ac234b` | `3d33cfde9275e774b027268650a7fad3` |
| PS4 9.0 | `d799a38dc0086f841bc81345eb18f7be` | `53bf311e0cc6ac60c0b052e31b6d2d28` | `ee51faf35fbc957a20d2901f67eb5a31` |

### V-S5. `clientDeviceId` used by the ctrl vectors

Random part `202122232425262728292a2b2c2d2e2f`:

```
00180000000700400080 202122232425262728292a2b2c2d2e2f 000000000000
```

The full ctrl request built from these inputs is vector V-C1 in `ctrl.md`.

---

## Appendix A. Stream-handshake crypto (for picking libraries now)

The stream stage itself is a later milestone. These facts are enough to choose primitives:

- **Curve**: secp256k1 (the Koblitz curve used by Bitcoin), *not* NIST P-256.
- **Key pair**: a fresh random key pair per session, made before the stream connection starts.
- **Public key encoding**: SEC1 / X9.62 uncompressed point, 65 bytes: `04 || X (32) || Y (32)`.
- **Signature over the client's public key**: `HMAC-SHA256(key = streamHandshakeKey (16 bytes),
  message = the 65-byte public key)`, 32 bytes. Public key and signature travel together in the stream
  handshake.
- **Console's key**: the console sends its own 65-byte public key and a 32-byte signature the same way.
  Existing clients don't check the console's signature. That it is HMAC-SHA256 under the same
  handshake key is a reasonable guess but unverified.
- **Shared secret**: plain ECDH, the 32-byte big-endian **X coordinate** of the shared point, with no
  KDF or hashing applied. It is then fed, with `streamHandshakeKey`, into the stream key schedule (next
  stage).
- The next stage also needs: HMAC-SHA256, AES-128 in ECB (to make a keystream), AES-128-GCM (only for
  the 4-byte GMAC tags), and SHA-256.

### Vector A-1 [I][C]

| Field | Value |
|---|---|
| private key A | `0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20` |
| public key A | `0484bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b08cc43d63b2859d469fee15f31c9edb5324266e6fd0407e87382d60fc4511acd8` |
| `streamHandshakeKey` | `404142434445464748494a4b4c4d4e4f` |
| signature A = HMAC-SHA256(handshake key, public key A) | `2fe2ebd67dac0d482eec54294c0e5df4408fbbce5404ded3215798fac833e53c` |
| private key B (stand-in for the console) | `8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0` |
| public key B | `04a36b48691898f4c058cd18442495b9202f859f28c9400190be3b04f5f0655c94d0b245e8ed621cdb21d24fc8b6db2309fa38dcd8b1da0c5b11786e04fc66a526` |
| signature B (same rule) | `f1cdeeb1a7b99337b684d4462b7fce83b07eb77a2bbc24d4327a0d992cf8bccc` [I only] |
| shared secret (X coordinate) | `0c1fbe7f56ae330d92c6b86cd82e0879addd6822fe20f2419176352093908297` |

Library notes for Swift on macOS:

- Apple CryptoKit and Security.framework have **no secp256k1**. You need a separate library, for
  example bitcoin-core's libsecp256k1 (MIT) or a Swift wrapper of it. Its default ECDH callback
  *hashes* the point, so you must supply a callback that returns the raw X coordinate.
- AES-128-CFB128 and AES-ECB are available through CommonCrypto (`kCCModeCFB`, `kCCModeECB`).
- HMAC-SHA256, SHA-256 and AES-GCM are in CryptoKit.

---

## Sources

- chiaki-ng (AGPL-3.0), read for facts only, at the submodule commit this repository records.
- PlayFX's own field notes: `PLAN.md` (console "in use" for ~9 s after a session; PS5 ending the
  stream when the keyboard is enabled) and `docs/NETWORK.md` (console resetting ctrl during start-up;
  pause before ctrl).
