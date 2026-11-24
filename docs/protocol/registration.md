# Registration (pairing)

Registration pairs a client with a console once. The user opens the console's pairing screen, which shows
an 8-digit PIN:

- PS5: Settings > System > Remote Play > **Pair Device** (older firmware: "Link Device").
- PS4: Settings > Remote Play Connection Settings > **Add Device**.

The client sends the PIN and the user's PSN account ID; the console answers with the keys the client stores
and uses for every later session and for wake (see "Pairing record").

LAN registration has two steps: a UDP **search** that checks the console is listening, then one HTTP-style
**request/response** over TCP whose bodies are encrypted with RP crypt ([rpcrypt.md](rpcrypt.md)).

Internet (PSN) registration needs no PIN: it uses the same request and response over the reliable-UDP
channel of an internet session ([rudp.md](rudp.md)), with a key made from values exchanged through PSN
instead of the PIN. It is section 8.

## 1. Inputs

| Input | Type | Notes |
|-------|------|-------|
| Console address | IPv4 or IPv6 | From discovery or entered by the user |
| Target | `PS4-8`, `PS4-9`, `PS4-10`, `PS5-1` | See "Target selection" |
| PIN | unsigned 32-bit integer | The 8 decimal digits shown on screen, read as a decimal number (`"01234567"` -> 1234567). Used as `BE32(PIN)` in rpcrypt.md |
| PSN account ID | 8 bytes | The user's numeric PSN account ID (unsigned 64-bit) encoded **little-endian**. On the wire it is the standard base64 (RFC 4648, `+/`, `=` padding) of those 8 bytes: 12 characters ending in `=` |
| PSN online ID | ASCII string | Only for `PS4-8`/`PS4-9`, as an alternative to the account ID (the user's sign-in name) |

The account ID must belong to the console user who opened the pairing screen; otherwise the console refuses
with reason `0x80108b02` (section 6).

PlayFX obtains the account ID from PSN's OAuth token info (`user_id`, a decimal string) and encodes it as
above. That is PlayFX's choice; the protocol only needs the 8 bytes.

### Target selection

The client must pick the target before it builds the request. Options observed in practice:

- **Fixed by console family (PlayFX's choice):** `PS5-1` for a PS5, `PS4-10` for a PS4. Any PS4 on firmware 8.0
  or later accepts `PS4-10`.
- **From discovery (reference-client choice):** parse the discovery `system-version` value as a decimal
  integer `v` and the console type from `device-discovery-protocol-version` (discovery.md):

  | Condition | Target |
  |-----------|--------|
  | PS5 and `v >= 8050001` | `PS5-1` |
  | PS5 and `v >= 8050000` | PS5, version unknown (rpcrypt.md section 2.4 quirk) |
  | PS4 and `v >= 8000000` | `PS4-10` |
  | PS4 and `v >= 7000000` | `PS4-9` |
  | PS4 and `v > 0` | `PS4-8` |

  These thresholds are a client choice (observed), not a statement by the console.

## 2. Search (UDP)

| | PS4 | PS5 |
|---|---|---|
| Console UDP port | 9295 | 9295 |
| Client sends (5 bytes) | `SRC2` + `0x00` = `53 52 43 32 00` | `SRC3` + `0x00` = `53 52 43 33 00` |
| Console answers (first 4 bytes) | `RES2` = `52 45 53 32` | `RES3` = `52 45 53 33` |

- The client sends the 5-byte datagram from an ephemeral UDP port to `<console>:9295` (unicast). The console
  replies to the sender's address and port.
- The client compares only the **first 4 bytes** of each datagram it receives. A datagram that does not start
  with the expected 4 bytes is ignored and the client keeps waiting.
- The **source address** of the matching answer is the address used for the TCP request.
- The console only answers while its pairing screen (with the PIN) is open. When it is not open, the
  console's port is closed and the client gets an ICMP "port unreachable", which a connected UDP socket
  reports as "connection refused". Treat that as "pairing screen not open".
- Timeout: the reference client waits 3000 ms for the answer (client choice, observed). It sends the search
  once and does not resend.
- A broadcast variant exists: the same datagram sent to a broadcast address on port 9295, from a socket with
  broadcast enabled and bound to the wildcard address. PlayFX uses unicast only.

After the matching answer, the reference client waits **100 ms** before connecting, because a PS4 may
not accept the TCP connection immediately (client choice, observed; keep it).

## 3. Request (TCP)

Connect TCP to `<address of the search answer>:9295`. Reference connect timeout: 3000 ms (client choice).
Send the header, then the body. The connection is used for one request and one response.

### 3.1 Header

The header is ASCII with `\r\n` line endings, and it is sent exactly as below, including the **second line,
which consists of a space followed by `HTTP/1.1`** (an artefact consoles accept; reproduce it
byte-for-byte):

```
POST <path> HTTP/1.1\r\n
 HTTP/1.1\r\n
HOST: <host>\r\n
User-Agent: remoteplay Windows\r\n
Connection: close\r\n
Content-Length: <body length, decimal>\r\n
[RP-Version: <version>\r\n]
\r\n
```

| Field | Value |
|-------|-------|
| `<path>` for `PS5-1` | `/sie/ps5/rp/sess/rgst` |
| `<path>` for `PS4-10` | `/sie/ps4/rp/sess/rgst` |
| `<path>` for `PS4-8`, `PS4-9` | `/sce/rp/regist` |
| `HOST` header name | upper case, `HOST` |
| `<host>` (LAN) | the literal placeholder `10.0.2.15`. It is not the console's or client's address; consoles accept it |
| `<host>` (PSN) | the client's LAN IPv4 address as text (section 8.3) |
| `RP-Version` | present for `PS4-9` (`9.0`), `PS4-10` (`10.0`) and `PS5-1` (`1.0`); **absent** for `PS4-8` |

Header order is as shown. The header ends with an empty line (`\r\n\r\n` overall). The body follows
immediately on the same connection.

### 3.2 Body

Byte layout (offsets in hex):

| Offset | Length | Content |
|--------|-------:|---------|
| `0x000` | `0x1e0` | Filler `F`, with the masked seed written into it (below) |
| `0x1e0` | `L` | Inner text, encrypted with RP crypt (registration context, counter 0) |

Total body length = `0x1e0 + L`; this is the `Content-Length`.

**Filler.** The reference client fills all `0x1e0` bytes with `0x41` (`'A'`) before writing the masked seed.
Other values should be possible (see rpcrypt.md open question 3); for byte-exact compatibility with the test
vectors use `0x41`.

**Masked seed `M`** (16 bytes, rpcrypt.md sections 6 and 7):

| Target | Where `M` goes |
|--------|----------------|
| `PS4-10`, `PS5-1` | `M[8..15]` at body offset `0x0c7..0x0ce` (8 bytes); `M[0..7]` at body offset `0x191..0x198` (8 bytes) |
| `PS4-8`, `PS4-9` | `M[0..15]` at body offset `0x11c..0x12b` (16 bytes) |

Note the order for `PS4-10`/`PS5-1`: the **second** half of `M` comes first in the body.

For `PS4-10`/`PS5-1` the two column selectors come from the filler: `key_col = body[0x18d] & 0x1f`,
`mask_col = body[0x000] >> 3`. With `0x41` filler these are `key_col = 1`, `mask_col = 8`.

**Inner text** (ASCII, `\r\n` line endings, no trailing empty line, no NUL):

| Target / identity | Inner text |
|-------------------|------------|
| `PS4-10`, `PS5-1` (account ID) | `Client-Type: dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f\r\nNp-AccountId: <base64 account ID>\r\n` |
| `PS4-8`, `PS4-9` with account ID | `Client-Type: Windows\r\nNp-AccountId: <base64 account ID>\r\n` |
| `PS4-8`, `PS4-9` with online ID | `Client-Type: Windows\r\nNp-Online-Id: <online ID>\r\n` |

The `Client-Type` value for `PS4-10`/`PS5-1` is a fixed 64-character lowercase hex string (shown in full above).
`PS4-10`/`PS5-1` always use the account ID; the online ID is only accepted by `PS4-8`/`PS4-9`. With a base64
account ID (12 characters) the `PS4-10`/`PS5-1` inner text is 107 bytes, so the body is 587 bytes
(`0x24b`); the legacy account-ID inner text is 50 bytes (body 530).

**Encryption.** Encrypt the inner text in place with the registration context at counter 0 (rpcrypt.md
section 2), using `K`, `S`, `H` from rpcrypt.md section 6.1 / 6.2 (LAN) or 7 (PSN).

## 4. Response

### 4.1 Reading it

1. Read bytes until the header terminator `\r\n\r\n` has been received. The reference client allows up to 1500
   bytes for header plus body and a 3000 ms timeout (client choices).
2. The status line must start with `HTTP/1.1 ` (9 bytes, including the space), followed by a decimal status
   code. The reason phrase is not used. Line endings may be `\r\n` or `\n`.
3. Header lines are `Name: value`. **Trim spaces and tabs around the value**: a real PS5 pads it, e.g.
   `Content-Length:        195` (see "Observed on a real console" below). Header names are matched
   case-sensitively in the reference client (`Content-Length`, `RP-Application-Reason`); matching them
   case-insensitively is harmless.
4. **Status other than 200**: registration failed. Read `RP-Application-Reason` if present: a hexadecimal
   number, with or without a `0x` prefix (e.g. `80108b09` or `0x80108b09`). See section 6. There is no body to
   decrypt.
5. **Status 200**: `Content-Length` (decimal) must be present and greater than 0. Read exactly that many body
   bytes after the header (the reference client allows 3000 ms more). Some or all of the body may arrive in the
   same read as the header.

### 4.2 Body

Decrypt the whole body with the **same** registration context, at **counter 0** (rpcrypt.md section 6.3). The
plaintext is a list of `Name: value` lines (`\r\n` line endings; one optional space after the colon; same
grammar as response headers). The names below are case-sensitive. `XX` stands for `PS5` when the target is
`PS5-1` and `PS4` otherwise.

| Name | Value encoding | Meaning | Required |
|------|----------------|---------|----------|
| `XX-RegistKey` | hex text (pairs of hex digits) | Registration key, see 5.1 | yes |
| `RP-Key` | 32 hex digits -> exactly 16 bytes | Session key input `R` in rpcrypt.md section 5 | yes |
| `XX-Mac` | 12 hex digits -> exactly 6 bytes | Console MAC address | yes |
| `XX-Nickname` | text | Console name | no |
| `RP-KeyType` | integer (decimal) | Key type; stored, otherwise unused by the client | no |
| `RP-SupportCmd` | integer (decimal) | Support flags; informational only | no |
| `AP-Ssid` | text | Access-point SSID (purpose not verified; see Open questions) | no |
| `AP-Bssid` | text | Same, BSSID | no |
| `AP-Key` | text | Same, key | no |
| `AP-Name` | text | Same, name | no |

Unknown names are ignored. Hex digits may be upper or lower case. The reference client only takes a line
into account once its line ending has been read, so a final line without `\r\n` would be lost (which suggests consoles
end every line with `\r\n`). A new implementation should accept an unterminated last line as well.

If a required value is missing or malformed (odd number of hex digits, non-hex characters, wrong length), the registration fails ("unusable
reply").

The reference client caps text fields (exclusive of terminator): SSID 47, BSSID 31, AP key 79, AP name 31,
nickname 31 bytes, and skips longer values (client choice).

## 5. Pairing record (what to persist)

| Field | Type / length | Source | Used for |
|-------|---------------|--------|----------|
| Registration key | 16 bytes | `XX-RegistKey`, see 5.1 | Session request, ctrl auth, wake |
| RP key | 16 bytes | `RP-Key` | Session crypto (`R` in rpcrypt.md 5) |
| Console MAC | 6 bytes | `XX-Mac` | Identifying the console (matches discovery `host-id`, see discovery.md) |
| Console nickname | text, up to 31 bytes | `XX-Nickname` | Display |
| Key type | uint32 | `RP-KeyType` | Stored only |
| Target | enum | the target used to register | Choosing paths and crypto later |
| PSN account ID | 8 bytes | the input | Later sessions (session.md) |
| Console address | text | discovery / user | Reconnecting |
| AP SSID / BSSID / key / name | text | `AP-*` | Stored only (not used by PlayFX) |

These are secrets (except nickname/MAC/address): store them in the Keychain, never log them.

### 5.1 Registration key format

The `XX-RegistKey` value is hex text. Decoded, it is the registration key **as ASCII text**: in practice 8
lowercase hex characters (so the header carries 16 hex digits, and the decoded value is 8 bytes such as
`61 31 62 32 63 33 64 34` = `"a1b2c3d4"`).

Store it in a **16-byte field**: the decoded bytes, then zero bytes up to 16. All later uses depend on that
layout:

- **Wake** (discovery.md): the decoded bytes up to the first `0x00`, read as a hexadecimal number.
- **Session request** (session.md): the bytes up to the first `0x00`, hex-encoded again (which gives back the
  original 16 hex digits).
- **Ctrl auth** (ctrl.md): all 16 bytes, including the zero padding, are encrypted.

If the decoded value is longer than 16 bytes the reference client rejects it as invalid.

## 6. Failures

### 6.1 Console reason codes (`RP-Application-Reason`)

| Code | Meaning |
|------|---------|
| `0x80108b09` | Registration failed: the PIN is wrong or has expired. A new PIN appears when the pairing screen is reopened |
| `0x80108b02` | Invalid PSN ID: the account ID or online ID does not belong to the console user who opened the pairing screen |
| `0x80108b10` | Remote Play is already in use |
| `0x80108b11` | `RP-Version` mismatch: the console does not accept the target the client used |
| `0x80108b15` | Remote Play on the console crashed |
| `0x80108bff` | Unknown error |

The same code space is used by the session request (session.md).

### 6.2 Other failure cases

| Phase | Symptom | Meaning |
|-------|---------|---------|
| Search | ICMP port unreachable / connection refused | Pairing screen not open |
| Search | no `RESx` within the timeout | Console not reachable or screen not open |
| Search | network error (host down, no route) | Console unreachable from this network |
| TCP connect | refused / timeout | Console stopped listening (screen closed) or network dropped |
| Response | non-200 status | Rejected; see `RP-Application-Reason` |
| Response | no `Content-Length`, or 0 | Unusable reply |
| Response | body missing a required field | Unusable reply |
| Any after search | connection closed or timed out | Console stopped answering (screen closed, network drop) |

It is useful to report whether the console had answered the search, since "never answered" and "answered,
then stopped" have different user-facing fixes.

## 7. Timing summary

| Step | Value | Kind |
|------|-------|------|
| Search answer wait | 3000 ms, single send | client choice (observed) |
| Pause after search answer | 100 ms | client choice (observed), needed by some PS4s |
| TCP connect | 3000 ms | client choice (observed) |
| Send header + body | 3000 ms | client choice (observed) |
| Response header | 3000 ms | client choice (observed) |
| Response body | 3000 ms more | client choice (observed) |
| PIN lifetime | a few minutes on the console | console behaviour (observed by users, not measured) |

## 8. Registration through PSN (no PIN)

The same request and response as sections 3–5, sent over the internet path instead of TCP, with the PIN
replaced by secrets exchanged through PSN. The result is a normal pairing record (section 5).

### 8.1 When it happens

- **At the start of every internet session** (the reference): right after the ctrl hole is punched
  (holepunch.md §8, step 8), before session init. The session then uses the registration key and RP key
  **this** registration returned for its session init and ctrl, not the stored ones.
- **Register-only (PIN-less pairing):** the same steps, then the session is stopped (the PSN session left,
  psn.md §8) and the keys are stored as a pairing. This is how PlayFX pairs without a code (`PSNPairing`).

Requirements: a PSN session in which the console has joined and sent `customData1` (psn.md §6), and the ctrl
hole (holepunch.md). Targets: only `PS4-10` and `PS5-1` (the reference: `PS5-1` for a PS5, `PS4-10` for a PS4).
There is no search step (no `SRC2`/`SRC3`) and no TCP.

### 8.2 What replaces the PIN

| LAN (section 3, rpcrypt.md section 6.1) | PSN (rpcrypt.md section 7) |
|---|---|
| `K` = key table column XOR the PIN in bytes 12–15 | `K` = key table column XOR `E`, where `E` = RP-crypt encryption of `customData1` under the context {`K = data1`, `S = data2`, `H` of the target} at counter 0 |
| masked seed with `m` = `0x29` / `0xd3` | masked seed with `m'` = `0xd7` (PS4-10) / `0x2b` (PS5-1), different formula (rpcrypt.md section 7) |
| the user types the PIN shown on the console | `data1`, `data2`: 16 random bytes each that the client sent to the console through PSN's start command (psn.md §6.3); `customData1`: 16 bytes the console sent back through PSN (psn.md §6.5) |

So the shared secret is bound to this PSN session: only a client that started the session (and so chose
`data1`/`data2`) and saw the console's `customData1` can build the key. The account ID in the inner text must
still be the console user's (`0x80108b02` otherwise, presumably as on the LAN).

Everything else in the body is as section 3.2: `0x41` filler, the masked seed at `0x0c7`/`0x191`, the inner
text `Client-Type: dabfa2ec…d34f\r\nNp-AccountId: <base64 account ID>\r\n` encrypted at counter 0; 587 bytes.

### 8.3 Header

As section 3.1, with `HOST:` set to the client's LAN IPv4 address: the `addr` of the `LOCAL` candidate of the
client's ctrl-hole OFFER (holepunch.md §4.1), e.g. `HOST: 192.168.1.20`. No port.

### 8.4 Transport

Over the ctrl hole's RUDP channel (rudp.md §5, §6):

1. RUDP handshake (INIT … COOKIE_ACK). The console's INIT_ACK is the reference's "console answered" signal
   (it decides between "refused" and "never answered", stream.md §11.2 reasons 13 and 14).
2. One request: the REQUEST wrapper plus one DATA message holding the **header and the body together**.
3. One DATA message back holding the **whole** response, header and body (`Content-Length` bytes must all be
   in it; the reference reads up to 1500 bytes).
4. ACK, then the console's FINISH (rudp.md §6.3).

### 8.5 Response

As section 4: status 200 and a body decrypted with the same context at counter 0, or a non-200 status with
`RP-Application-Reason`. The pairing record fields are the same as a PIN pairing's (section 5). The console's
LAN address is not learned (PlayFX stores an empty address until the console is found on the home network).

### 8.6 Timing (client choices, observed)

| Step | Value |
|---|---|
| Whole registration, as waited for by the session | 10 s; a registration still running then is cancelled and the session ends as plainly stopped. A registration that fails before that ends the session as "refused" if the console had answered the RUDP handshake, "unanswered" otherwise |
| Each RUDP step | 1 s per try, 3 tries (rudp.md §10) |
| Whole PIN-less pairing as PlayFX runs it (PSN setup + registration) | 20–30 s; PlayFX gives up after 120 s |

### 8.7 Vector [I]

`PS5-1`, `HOST` `192.168.1.20`, the body `data/vectors/regist-body-psn-ps5-1.hex` (test-vectors.md section 4.2:
`D1` = `10…1f` = psn.md's `data1`, `D2` = `20…2f` = `data2`, `CD` = `30…3f` = psn.md vector P3's
`customData1`). Header (159 bytes):

```
POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: 192.168.1.20\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 587\r\nRP-Version: 1.0\r\n\r\n
```

Request = header + body = 746 bytes. With `localSeq` `0x1234` and `ack` `0x5679` the datagram starts
`c00c244f244f2030 12345679 c2f4244f244f0230 1234 504f5354…` (DATA `lenField` `0xC000 | (8 + 2 + 746)`), 768 bytes
in all.

## Observed on a real console

From PlayFX's own hardware check (PS5, `system-version` 14230000, PS5-1 target, LAN, 2026-11-23):

- Answer header to a valid request, byte for byte:
  `HTTP/1.1 200 OK\r\nConnection: close\r\nRP-Feature: 3\r\nContent-Length:        195\r\n\r\n` (81 bytes),
  then a 195-byte body. `Content-Length`'s value is right-aligned with spaces after the colon.
  `RP-Feature: 3` is not otherwise known; store or ignore it.
- After an answer the client could not use, the console stopped answering the search (`SRC3` refused), so the
  pairing screen's code can't be retried: reopening the pairing screen gives a new code and the search works
  again.
- Pairing the same client again with the same PSN account returned the same registration key and `RP-Key` as
  that account's earlier pairing (and the same MAC and nickname): a new pairing doesn't replace the old keys.
- The whole exchange (search, TCP request, answer) took about 0.1 s.

## Open questions

1. The HTTP status code used with each `RP-Application-Reason` is not recorded; only "not 200" matters to
   the client. Implementations should not depend on a specific status.
2. Whether consoles need the odd ` HTTP/1.1` second line, the `10.0.2.15` placeholder, or the `0x41` filler is
   untested; they are reproduced because they are known to work.
3. Whether the console sends `RES2`/`RES3` with a trailing `0x00` (5 bytes) or 4 bytes is not recorded; compare
   only the first 4 bytes.
4. The exact semantics of `RP-KeyType`, `RP-SupportCmd` and the `AP-*` fields are unknown.
5. Registration through PSN (section 8) is unverified by PlayFX on its own code: does its registration key work for
   sessions on the home network, and does the console return the same keys as a PIN pairing of the same account
   (a repeated LAN pairing did, see "Observed on a real console")?
6. Whether the console needs a registration through PSN before every internet session (the reference always
   does one), or accepts session init with keys stored from an earlier pairing.
7. The PSN-mode `PS4-10` path is untested on a console by PlayFX.
