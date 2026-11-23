# LAN discovery and wake

Consoles on the local network answer a small text-based search protocol over UDP. The same channel carries
the **wake** packet that brings a paired console out of rest mode.

## 1. Ports and versions

| | PS4 | PS5 |
|---|---|---|
| Console UDP port (search and wake) | **987** | **9302** |
| `device-discovery-protocol-version` | `00020020` | `00030010` |

A client that wants to find both kinds sends two searches, one to each port, each with its own version
string.

## 2. Client socket

- One UDP socket, used both to send and to receive answers. The console answers to the source address and
  port of the search.
- Enable broadcast (`SO_BROADCAST`) on it, since searches are usually broadcast.
- Local port: the reference client binds the first free port in **9303..9319**, and an ephemeral port if
  none is free (client choice, observed). Binding in that range is recommended; see Open questions.
- IPv4 is the normal case. IPv6 unicast works the same way (no IPv6 broadcast).

## 3. Messages: common text format

Search and wake messages are ASCII text in an HTTP-like form:

- First line: `<METHOD> * HTTP/1.1`.
- Each line, including the last, ends with a **single `\n` (0x0a)**, not `\r\n`.
- Header lines are `name:value` with **no space** after the colon.
- No blank line at the end.
- The datagram ends with one **`0x00` byte** after the last `\n` (the NUL is part of the datagram).

## 4. Search

### 4.1 Request

```
SRCH * HTTP/1.1\n
device-discovery-protocol-version:<version>\n
<0x00>
```

PS4 (sent to port 987), 60 bytes including the final `0x00`:

```
"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00020020\n\0"
```

PS5 (sent to port 9302): same with `00030010`.

### 4.2 Where to send it

- **Broadcast**: to `255.255.255.255`. On macOS a limited broadcast may leave through only one interface,
  so also send to each IPv4 interface's **directed broadcast** address (e.g. `192.168.1.255`) of every
  interface that is up, has broadcast, and is not loopback (PlayFX and the reference client both do this).
- **Unicast**: to a known console address (e.g. a manually added console, or one on another subnet).

### 4.3 Response

The console answers with one UDP datagram from its port, to the client's port:

```
HTTP/1.1 <status> <reason>\r\n
<name>:<value>\r\n
...
```

Parsing rules (what a client must accept):

- The datagram must start with exactly `HTTP/1.1 ` (9 bytes including the space); otherwise ignore it.
- `<status>` is a decimal number. The reason phrase is free text and is not used.
- Lines end with `\r\n` or `\n`; accept both.
- Header lines are `name:value`, with **at most one optional space** after the colon. Names are compared
  case-sensitively (all lowercase as listed).
- A line with an empty value, or without a colon, makes the datagram invalid (the reference client discards
  the whole datagram).
- The datagram may end with or without a terminating `0x00`; stop at the first `0x00`.
- Unknown names are ignored.
- A datagram buffer of 512 bytes is enough in practice (the reference client reads up to 511 bytes).

Status codes:

| Status | Reason phrase (as observed) | Host state |
|--------|------------------------------|------------|
| `200` | `Ok` | **Ready**: on and awake |
| `620` | `Server Standby` | **Standby**: rest mode, can be woken |
| other | | Unknown |

Fields:

| Name | Value | Meaning |
|------|-------|---------|
| `host-id` | 12 hex digits | Console ID; equals the console's MAC address as hex (the same 6 bytes as the registration `XX-Mac`). The key that identifies a console across answers |
| `host-type` | `PS4` or `PS5` | Console family |
| `host-name` | text | User-visible console name |
| `host-request-port` | decimal | TCP port of the console's request service as advertised (typically `997`). The session itself connects to port 9295 (session.md); the client only stores this value |
| `device-discovery-protocol-version` | `00020020` or `00030010` | `00030010` means PS5; anything else is treated as PS4 |
| `system-version` | 8 decimal digits | Console system software version as a decimal number (e.g. `07020001`). Used by some clients to pick the registration target (registration.md) |
| `running-app-titleid` | text | Title ID of the app or game in the foreground, when there is one (e.g. `CUSA00000`, `PPSA00000`) |
| `running-app-name` | text | Its name |

Which family a console is: use `device-discovery-protocol-version == "00030010"` (the reference client's
test). `host-type` carries the same information.

Answers without `host-id` cannot be tracked and should be ignored.

The host's address is the **source IP** of the answer datagram (no field carries it).

## 5. Discovery as a service (polling)

Consoles do not announce themselves; a client polls. Observed behaviour, all **client choices**:

| Parameter | Reference desktop client | PlayFX |
|-----------|--------------------------|--------|
| Interval between rounds | 500 ms | 300 ms |
| Delay before the first round | (0 / not significant) | 0 ms |
| Rounds without an answer before a host is dropped | 3 | 3 |
| Max hosts tracked | 16 | 16 |

One **round** sends, in this order: the PS4 search to the target address on port 987, then to each directed
broadcast address on 987, then the PS5 search to the target address on 9302, then to each directed
broadcast on 9302. "Target address" is `255.255.255.255`, or a single console address for unicast; directed
broadcasts are only added when the target is `255.255.255.255`.

Answers arrive asynchronously on the same socket and are matched to hosts by `host-id`:

- A new `host-id` adds a host. A known one updates the host's fields (state, port, name, versions, running
  app) and marks it seen in the current round.
- **Gone rule**: number the rounds 1, 2, 3, ... (the number increases when a round starts). Each answer stamps
  its host with the current round number. At the start of round `r`, before sending, a host whose stamp `s`
  satisfies `s + 3 < r` is removed. So a host that last answered in round `s` disappears at the start of
  round `s + 4`, after three complete rounds with no answer (about 0.9 s at 300 ms, 1.5 s at 500 ms, plus the
  time until the next round).
- Report changes when a host appears, disappears, or any field changes.

PlayFX's one-shot "discover" runs this service for a fixed time (its caller's timeout) and returns the
hosts known at the end.

## 6. Wake

Wakes a console in rest mode (status 620). Only a console paired with the credential reacts. There is no
answer; a client confirms by searching again until the console answers `200`.

### 6.1 Packet

```
WAKEUP * HTTP/1.1\n
client-type:vr\n
auth-type:R\n
model:w\n
app-type:r\n
user-credential:<credential>\n
device-discovery-protocol-version:<version>\n
<0x00>
```

Same text rules as section 3 (`\n` endings, no space after colons, trailing `0x00`). Header order is as
shown. Values `vr`, `R`, `w`, `r` are literal (case matters).

| Field | Value |
|-------|-------|
| destination port | 987 (PS4) or 9302 (PS5) |
| `<version>` | `00020020` (PS4) or `00030010` (PS5) |
| `<credential>` | unsigned decimal, no leading zeros, no sign (see 6.2) |

### 6.2 Credential

The credential comes from the stored **registration key** (registration.md, "Pairing record", 16-byte field):

1. Take the bytes up to the first `0x00` (normally 8 ASCII characters such as `a1b2c3d4`).
2. Read them as a **hexadecimal** number (case-insensitive) into an unsigned 64-bit integer.
3. Write it in **decimal**.

Example: registration key text `a1b2c3d4` -> `0xa1b2c3d4` -> `user-credential:2712847316`.

The reference desktop client rejects keys longer than 8 characters before the first `0x00`. Since the
value is at most 8 hex digits in practice, it fits in 32 bits.

### 6.3 Where to send it

- Unicast to the console's last known address on its port (987 / 9302).
- PlayFX also sends the same packet to every IPv4 directed broadcast address (section 4.2) on the same port,
  because a PS5 in deep rest may stop answering ARP for its own address while still receiving broadcasts
  (PlayFX's observation; client choice).
- A single send per address is typical; resending a few times is harmless (client choice).

## 7. Timing summary

| Item | Value | Kind |
|------|-------|------|
| Search interval | 300-500 ms | client choice |
| Drop after | 3 silent rounds | client choice |
| Wake retries | 1 per address | client choice |
| Console reply delay | not measured; replies normally arrive within one interval | observed |

## Sources

- Public: Home Assistant community thread on PS5 status probing (UDP 9302, status 200 = on, 620 = rest):
  <https://community.home-assistant.io/t/ps5-integration/298604?page=2>
- Public: ps5-wake utility (wake over UDP 9302 with a `user-credential` field):
  <https://github.com/iharosi/ps5-wake>
- Public: ps4-waker (PS4 discovery and wake on UDP 987): <https://github.com/dhleong/ps4-waker>
- The reference client's behaviour, as noted in the README's clean-room section.

## Observed on a real console

From PlayFX's own hardware check (PS5 in rest mode, `system-version` 14230000, LAN, 2026-11-23): unicast and
broadcast searches both got an answer within the first 2 s round (status 620, standby). After a wake packet
with the console's credential, it stopped answering for a few seconds, then answered with status 200 (ready)
within 10 s of the wake.

## Open questions

1. **Reply port.** Whether a console always answers to the search's source port, or prefers the 9303..9319
   range, is not verified; binding in that range is the safe choice.
2. **Trailing `0x00`.** Whether consoles need the NUL at the end of search/wake datagrams is untested; send it.
3. **Cross-family answers.** Whether a PS5 also answers the PS4 search on 987 (or the reverse) is not
   recorded. Deduplicate by `host-id`.
4. **`system-version` encoding.** The reference thresholds (registration.md) imply PS4 `08000000` ~ 8.00 and PS5
   values from `08050000`; an exact digit-by-digit format is not documented.
5. **Credential sign.** A public tool shows `user-credential:-NNNN` (a minus sign) as a placeholder; the
   reference client always sends an unsigned decimal. Use unsigned.
