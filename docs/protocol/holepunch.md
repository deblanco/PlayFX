# Hole punching: reaching the console over the internet

Status: draft 1 (clean-room spec, facts only). Internet (PSN) path. Not verified against a capture; the
reference client's behaviour is described as observed in its source and in PlayFX's runs through it.

Over the internet the client and the console are usually both behind NAT. They exchange address
**candidates** through PSN (psn.md §7) and then send UDP probes to each other's candidates until one pair
works, like ICE (RFC 8445) but with Sony's own messages. This happens **twice** per session:

| Hole | Opened | Carries afterwards | Replaces on the LAN |
|---|---|---|---|
| **ctrl hole** | before anything else is sent to the console | RUDP (rudp.md): registration, session init, ctrl, the switch message | TCP 9295 (registration, session init, ctrl) |
| **data hole** | after ctrl has the session ID | Takion: the network probe, then the stream connection | UDP 9297 and UDP 9296 |

Each hole is one UDP socket on the client, `connect()`ed to the console address and port that answered.
The console's ports are whatever its candidates say; they are not 9295/9296/9297.

Related: psn.md (session, notifications, the message encoding), rudp.md, registration.md §8,
session.md §11, ctrl.md §10, takion.md §18, stream.md §16. Conventions as in README.md.

---

## 1. Inputs

| Name | Size | From | Notes |
|---|---|---|---|
| PSN session | – | psn.md §6 | created, started, console joined, `customData1` received |
| `accountId` | integer | psn.md §6.1 | for `localPeerAddr` |
| `localSid` | 16-bit | random, once per PSN session | the client's "sid" in every message of both holes |
| `localHashedId` | 20 bytes | random (cryptographically secure), once per PSN session | sent base64 in each OFFER and raw in every probe packet |
| `consoleSid`, `consoleHashedId` | 16-bit, 20 bytes | the console's OFFER for this hole | replaced by each new console OFFER; the reference keeps the low 16 bits of the console's JSON `sid` (psn.md §7.3) |

Client choices (observed): `localSid` is the low 16 bits of a random 32-bit number; `localHashedId` is 20
random bytes. Nothing is known to be derived from them (the name suggests a hash, but the reference sends
random bytes and it works).

---

## 2. Local socket

For each hole, before its OFFER is built:

1. Create a UDP/IPv4 socket, set `SO_REUSEPORT` (the reference; `SO_REUSEADDR` where that is missing), bind
   to `0.0.0.0` port 0, and read back the port the system chose: **`localPort`**.
2. The reference also opens an IPv6 socket on the same port number, but its IPv6 candidates are switched
   off at build time, so that socket carries nothing in practice (client choice). Only IPv4 is described
   here.
3. Every STUN query (§3.2) and every probe (§5) for this hole is sent **from this socket**: the STUN answers
   describe this socket's NAT mapping, and the console's probes must reach the same mapping.
4. After STUN, the socket is made non-blocking with no receive timeout (client choice).

---

## 3. Finding the client's addresses

### 3.1 UPnP (optional, tried first)

Client choice (observed). Done once per PSN session, before the session is created:

- **Discovery:** SSDP M-SEARCH over IPv4 multicast, waiting 2 s for answers, multicast TTL 2, source port
  chosen by the system; the whole discovery (including fetching and parsing the description documents) is
  bounded to 7 s. The reference doesn't pick the search targets itself: it uses the miniupnpc library's
  discovery with its default target list (a BSD-licensed library, nothing Sony-specific). Those defaults are,
  as far as the spec writer knows but **not verified from the library's source here**:
  `urn:schemas-upnp-org:device:InternetGatewayDevice:1`, then
  `urn:schemas-upnp-org:service:WANIPConnection:1`, `urn:schemas-upnp-org:service:WANPPPConnection:1`,
  `upnp:rootdevice`, stopping at the first target that gets answers. Any standard IGD discovery (IGD:1 and
  IGD:2) serves the same purpose.
- **Which gateway counts:** the first discovered device that the library classifies as "a valid IGD,
  connected, with a routable external address". "Connected" is the library's test: the WAN connection
  service's `GetStatusInfo` reports `NewConnectionStatus` = `Connected`; "routable" means
  `GetExternalIPAddress` doesn't return a private or reserved address (so a router behind another NAT is
  **not** used). A gateway that is found but fails either test is treated like no gateway (STUN is used).
  The client's LAN address towards the chosen IGD (the local address of the connection that fetched its
  description) is noted as **`lanIp`**.
- **Several WAN services:** the reference uses the **first** `WANIPConnection:1` or `WANPPPConnection:1`
  service in the IGD's description document (document order) for every action below; any other WAN
  connection service is ignored.
- **Mapping (per hole):** `AddPortMapping` on the IGD's WANIPConnection/WANPPPConnection service with
  `NewExternalPort = localPort`, `NewInternalPort = localPort`, `NewInternalClient = lanIp`,
  `NewProtocol = UDP`, `NewRemoteHost` empty, `NewLeaseDuration = 0` (no expiry), and a description
  (any text; the reference writes its own name).
- **Public address:** `GetExternalIPAddress` → **`publicIp`**.
- **Cleanup:** at the end of the session, `DeletePortMapping(localPort, UDP)` for the ctrl hole's and the
  data hole's ports (attempted even when the mapping had failed).
- If the gateway isn't found, the mapping fails, or the external address can't be read, the client uses
  STUN (§3.2) for that hole.

The actions and their arguments are the standard UPnP IGD ones (UPnP Forum, "WANIPConnection:1/2 Service");
nothing Sony-specific.

### 3.2 STUN

When UPnP gave no public address. Standard STUN Binding (RFC 5389 / RFC 8489), UDP, no authentication.

**Request** (20 bytes, no attributes): `00 01` (Binding Request), `00 00` (length), `21 12 a4 42` (magic
cookie), 12 random bytes (transaction ID).

**Response check** (client choice, as observed): type `01 01` (Binding Success); datagram length equals
20 + the header's length field; same cookie and transaction ID. Attributes are walked in order (each
padded to 4 bytes); the first `XOR-MAPPED-ADDRESS` (`0x0020`) or `MAPPED-ADDRESS` (`0x0001`) wins. IPv4
value: 8 bytes (`00`, family `01`, port, address); XOR-MAPPED port is XORed with `21 12` and the address
with `21 12 a4 42` (RFC 5389 §15.2). Other attributes (SOFTWARE, MESSAGE-INTEGRITY, FINGERPRINT) are
skipped unchecked. Wait 5 s for a response per server (client choice).

**Servers** (client choice, observed):

1. First the list at `https://raw.githubusercontent.com/pradt2/always-online-stun/master/valid_hosts.txt`
   (a third-party list of public servers): up to the first 10 lines, each `host:port`.
2. Then (or when that list can't be fetched) a built-in list of 11 entries, in this order before shuffling:

   | # | Host | Port |
   |---|---|---|
   | 0 | `stun.moonlight-stream.org` | 3478 |
   | 1 | `stun.l.google.com` | 19302 |
   | 2 | `stun.l.google.com` | 19305 |
   | 3 | `stun1.l.google.com` | 19302 |
   | 4 | `stun1.l.google.com` | 19305 |
   | 5 | `stun2.l.google.com` | 19302 |
   | 6 | `stun2.l.google.com` | 19305 |
   | 7 | `stun3.l.google.com` | 19302 |
   | 8 | `stun3.l.google.com` | 19305 |
   | 9 | `stun4.l.google.com` | 19302 |
   | 10 | `stun4.l.google.com` | 19305 |

   Before each use of the built-in list the reference shuffles it in place: for `i` from 10 down to 2, swap
   entry `i` with entry `j = 1 + (random mod (i − 1))`, so `j` is in `1..i−1`. Only **entry 0** (the
   Moonlight server) is guaranteed to stay first; entry 1 can move (at `i = 2` entries 1 and 2 always swap).
   (Correction: an earlier draft said the first two stay in place.) The shuffled order persists in the
   process and is shuffled again on the next use.

The servers are tried one after the other until enough have answered (one for a single query; four for the
prediction of §3.3), so with unresponsive servers this step can take a long time: up to 10 + 11 servers at
5 s each in the worst case (client choice, observed).

A client may use any working public STUN servers; the console never sees which.

### 3.3 Predicting the NAT's port (first hole only)

Client choice (observed). With an endpoint-dependent ("symmetric") NAT, the mapping the console will see
differs from the one STUN saw. For the **ctrl hole** the reference sends Binding Requests from the same
socket to **up to four different servers**, one after the other, and keeps the reported (public address,
port) pairs `(a1,p1) … (a4,p4)`. From them it derives an **increment** `inc` and a **random-allocation**
flag, kept for the whole PSN session:

| Answers | Same public address | Result |
|---|---|---|
| 0 | – | no STUN address (§4, failure unless UPnP worked) |
| 1 | – | port `p1`, `inc = 0` |
| 2 | yes | `inc = p2 − p1`, port `p2 + 2·inc` |
| 2 | no | `inc = 0`, port `p2` |
| 3 | all | `inc = p2 − p1`; if `p3 − p2 ≠ inc`: random-allocation (and if `inc` was 0, `inc = p3 − p2`); port `p3 + inc` |
| 4 | all | port `p4`; `d1 = p2−p1`, `d2 = p3−p2`, `d3 = p4−p3`, each **mod 2^16** (a decreasing NAT gives a large positive step); all equal → `inc = d1`; `d1` equals `d2` or `d3` → `inc = d1`; `d2 = d3` → `inc = d2`; else random-allocation, `inc = d1` if non-zero, else `d2` |
| 3 or 4 | mixed | see the exact rules below |

Exact rules when the addresses differ (`=` compares the public addresses `a1…a4`; "÷" is integer division
truncating towards zero; differences are ordinary signed integers here):

| Answers | Addresses | `inc` | random-allocation |
|---|---|---|---|
| 3 | `a1 ≠ a2`, `a1 = a3` | `(p3 − p1) ÷ 2` | no |
| 3 | `a1 ≠ a2`, `a2 = a3` | `p3 − p2` | no |
| 3 | all three differ | `0` | no |
| 3 | `a1 = a2 ≠ a3` | `p2 − p1` | no |
| 4 | `a1 ≠ a2`, `a1 = a3 = a4` | `p4 − p3`; if `(p3 − p1) ÷ 2` differs: random (and if `inc` was 0, it takes that value) | maybe |
| 4 | `a1 ≠ a2`, `a1 = a4 ≠ a3` | `(p4 − p1) ÷ 4` | no |
| 4 | `a1 ≠ a2`, `a1 = a3 ≠ a4` | `(p3 − p1) ÷ 2` | no |
| 4 | `a1` differs from all others, `a2 = a3 = a4` | `p4 − p3`; if `p3 − p2` differs: random (and if `inc` was 0, it takes that value) | maybe |
| 4 | `a1` differs from all others, `a2 = a4 ≠ a3` | `(p4 − p1) ÷ 4` | no |
| 4 | `a1` differs from all others, `a2 = a3 ≠ a4` | `(p3 − p1) ÷ 2` | no |
| 4 | `a1`, `a2` each differ from all others, `a3 = a4` | `p3 − p4` (note the order) | no |
| 4 | all four differ | `0` | no |
| 4 | `a1 = a2`, `a3 ≠ a2`, `a4 = a2` | `p2 − p1`; if `(p4 − p2) ÷ 2` differs: random (and if `inc` was 0, it takes that value) | maybe |
| 4 | `a1 = a2`, `a3 ≠ a2`, `a4 ≠ a2` | `p2 − p1` | no |
| 4 | `a1 = a2 = a3 ≠ a4` | `p2 − p1`; if `p3 − p2` differs: random (and if `inc` was 0, it takes that value) | maybe |

Several of these use an answer from a different address (`(p4 − p1) ÷ 4` spans three steps; `(p3 − p1) ÷ 2`
when `a1` stands apart; the reversed `p3 − p4`). They are reproduced as observed, but they look unintended:
the prediction is a client choice, and a client may use its own. The predicted port is `p3 + inc` with 3
answers, `p4` with 4, and `p2 + 2·inc` with 2 (each kept as a 16-bit value).

The public address used is the **last** answer's. For the **data hole** only one Binding Request is sent
(one server); its answer is the base port, and `inc` and the random-allocation flag of the ctrl hole are
reused.

---

## 4. The candidate list (the client's OFFER)

Candidate fields and their JSON encoding are in psn.md §7.4. Types used by the client: `STATIC`, `LOCAL`,
`STUN`. A received candidate can also be `DERIVED` (§5.4).

### 4.1 The three basic candidates

| Candidate | `type` | `addr` | `port` | `mappedAddr` / `mappedPort` |
|---|---|---|---|---|
| LOCAL | `LOCAL` | `lanIp` (UPnP), else the first IPv4 address of an interface that is up, running and not loopback | `localPort` | `0.0.0.0` / `0` |
| STATIC | `STATIC` | `publicIp` (UPnP), else the STUN public address | **`localPort`** (not the STUN port) | `0.0.0.0` / `0` |
| STUN | `STUN` | the STUN public address | the predicted port (§3.3), or guesses (§4.3) | `0.0.0.0` / `0` |

`LOCAL`'s address is also the `HOST` value of the registration through PSN (registration.md §8.3) when
this is the ctrl hole.

**No LAN address.** Without UPnP, the reference takes the first interface (in the system's interface-list
order) that is up, running, not loopback and has an IPv4 address; on macOS that can also be a VPN tunnel
interface. If there is none, it does **not** fail: the lookup's error is ignored and the `LOCAL` candidate
is sent with an **empty** `addr` (`"addr":""`), still with `port` = `localPort`; the registration's header
then reads `HOST: ` with an empty value. Whether the console accepts that is unknown (§10). (With a
public address from STUN but no LAN address the client is most likely directly on the internet; leaving the
`LOCAL` candidate out, or using the public address, are untested alternatives.)

### 4.2 Which list is sent (client choice, observed)

Order matters: the reference puts the STUN guesses first so that the console tries them first.

| Situation | Candidate list, in order |
|---|---|
| UPnP mapping and public address OK | `STATIC`, `LOCAL` |
| STUN, `inc = 0`, STUN port = `localPort` (no port translation) | `STATIC`, `LOCAL` |
| STUN, `inc = 0`, STUN port ≠ `localPort` | `STUN`(STUN port), `STATIC`, `LOCAL` |
| STUN, `inc ≠ 0`, no random allocation | 8 × `STUN` with ports `p+inc`, `p+2·inc`, … `p+8·inc` (§4.4), then `STATIC`, `LOCAL` |
| STUN, random allocation | `N` × `STUN` guesses (§4.3), then `STATIC`, `LOCAL` |
| STUN, `inc = 0`, STUN port ≠ `localPort`, and the user forced port guessing | as random allocation (and the client then behaves as random-allocation for the probes) |
| No public address at all | the hole fails before an OFFER is sent |

`p` is the STUN base port of §3.3 (ctrl hole) or the single answer (data hole).

### 4.3 Port guesses (random allocation)

`N` = 75 by default (a user setting in the reference). Guess `i` (0-based) is `base + δ(i)` with
`δ = 0, +1, −1, +2, −2, +3, …` (that is `δ(0) = 0`, odd `i` → `+(i+1)/2`, even `i` → `−i/2`). Out of range:
above 65535 → `49152 + (port − 65536)`; below 1024 → `65535 − (1024 − port)`.

### 4.4 Increment ports

Each next port is the previous one plus `inc` (starting from `p`), computed as a **signed 32-bit integer,
not modulo 2^16**. Out of range: if the result is below 1024 while the previous port was above 1024 →
`65535 − (1024 − result)`; else below 1 → `+ 65535`; else above 65535 → `result − 65535 + 1024`. The result is
then stored as a 16-bit port (any value still above 65535 loses its high bits). (These are the reference's
rules, not a protocol requirement.)

`inc` itself can be negative (signed differences in the 2- and 3-answer rules of §3.3), but with four answers
from one address it is the 16-bit step of §3.3, so a NAT that **decreases** by 2 gives `inc = 65534`, not
`−2`. The reference then computes, from `p = 40006`: `40006 + 65534 = 105540` → above 65535 →
`105540 − 65535 + 1024 = 41029`, then `41029 + 65534 = 106563` → `42052`, and so on: it does not predict
`40004, 40002, …`. A client that wants decreasing allocations predicted should treat steps above 32767 as
negative (a client choice the reference doesn't make).

### 4.5 The other OFFER fields

| Field | Client's value |
|---|---|
| `sid` | `localSid` |
| `peerSid` | `consoleSid` as known when the OFFER is **built**: `0` for the ctrl hole (built before the console's first OFFER), the console's ctrl-hole `sid` for the data hole |
| `skey` | 16 zero bytes, base64 `AAAAAAAAAAAAAAAAAAAAAA==` |
| `natType` | `2` |
| `defaultRouteMacAddr` | empty string |
| `localPeerAddr` | `{"accountId":"<accountId>","platform":"REMOTE_PLAY"}` |
| `localHashedId` | base64 of `localHashedId` (28 characters) |

What `natType` and `skey` mean is unknown; these values work.

---

## 5. Connectivity checks (the probe packets)

### 5.1 Packet layout (88 bytes, both directions)

| Offset | Size | Request | Response |
|---|---|---|---|
| `0x00` | 4 | `06 00 00 00` | `07 00 00 00` |
| `0x04` | 20 | sender's `localHashedId` | sender's `localHashedId` |
| `0x18` | 12 | zero | zero |
| `0x24` | 20 | receiver's hashed ID (as learned from its OFFER) | receiver's hashed ID |
| `0x38` | 12 | zero | zero |
| `0x44` | 2 | sender's `sid` (BE16) | sender's `sid` |
| `0x46` | 2 | receiver's `sid` (BE16) | receiver's `sid` |
| `0x48` | 3 | zero | zero |
| `0x4B` | 5 | **request ID** (5 random bytes) | the request ID being answered, copied |
| `0x50` | 2 | zero | `BE16(sender sid) XOR` bytes 0–1 of the request's source IPv4 address |
| `0x52` | 2 | zero | `BE16(receiver sid) XOR` bytes 2–3 of that address |
| `0x54` | 2 | zero | `BE16(sender sid) XOR` that address's port (BE16) |
| `0x56` | 2 | zero | zero |

"Sender" is whoever sends the packet. In the response, `0x50..0x55` tell the requester the address and
port its request came from (as the responder saw it), masked with the sids, like STUN's XOR-MAPPED-ADDRESS.
The client fills them from the candidate the request came from (§5.4), which is the request's source.

What the reference checks on what it receives (client choice): a response must be 88 bytes, type
`07000000`, and its `0x4B..0x4F` must equal the request ID it sent; nothing else is checked. A request
(type `06000000`) is answered whatever its other fields say. That the console fills its requests and
responses in its own perspective (its hashed ID at `0x04`, its sid at `0x44`) is assumed, not observed.

### 5.2 Sequence for one hole

```
client                         PSN                          console
  |<-- OFFER(console cands, sid, hashedId) [reqId a] --------------|
  |--- RESULT [reqId a] ------------------------------------------>|
  |--- OFFER(client cands) [reqId b] ----------------------------->|
  |<-- RESULT [reqId b] -------------------------------------------|
  |                                                                 |
  |== probes: 06 to every console candidate, 07 to every 06 ======|   UDP, direct
  |   first valid 07 → selected pair; connect() the socket         |
  |                                                                 |
  |--- ACCEPT(selected pair) [reqId b+1] ------------------------->|
  |<-- ACCEPT [reqId c] --------------------------------------------|
  |--- RESULT [reqId c] ------------------------------------------>|
  |== answer any further 06 for 1 s ===============================|
```

The PSN messages (OFFER, RESULT, ACCEPT) are psn.md §7; the probes go directly between the two
addresses.

### 5.3 Sending (client choice, observed)

1. After the console's RESULT for the client's OFFER, send one request (same request ID throughout) to
   **every** console candidate, in the console's order, from the hole's socket.
2. With random allocation (§4.3) the client also opens `M` extra UDP sockets (`M` = 250 by default; a user
   setting), each bound to an ephemeral port, with IP TTL **2**, and sends the same request from each of
   them to every console `STATIC` and `STUN` candidate. The low TTL opens a mapping in the client's own
   NAT(s) without the packet reaching the console. When one of these sockets later receives anything,
   its TTL is set back to 64 and it is treated like the main socket.
3. Wait up to 0.5 s for a packet on any of the sockets. On a timeout with no valid response yet, resend the
   request to every candidate (including derived ones, §5.4) from the main socket, up to **20** times
   (about 10.5 s in all). After that the hole fails ("host unreachable").

### 5.4 Receiving

For each datagram received on any hole socket during the checks:

1. Identify the candidate by the datagram's source address and port (exact match on both). If no candidate
   matches, add it as a **`DERIVED`** candidate (address and port from the source, `mappedAddr` `0.0.0.0`,
   `mappedPort` 0), up to 3 such per hole (client choice); beyond 3 the datagram is ignored. A derived
   candidate is the console as seen through its NAT, often a port the console never announced.
2. A datagram that isn't 88 bytes: ignored if it came from a derived candidate, otherwise the reference
   fails the hole (client choice; a more tolerant client may ignore it).
3. Type `06000000` (a request from the console): answer it with a response (§5.1) **to its source**, from
   the socket it arrived on. Then, if the candidate is `DERIVED` (or random allocation is on, for any
   candidate), also send the client's request to that source **from the same socket**. This happens for
   **every** console request received from it, not once: the "hasn't answered yet" condition is always true
   here, because the first valid response ends the checks (step 4). In addition, a derived candidate is part
   of every later resend of step 3 of §5.3, which goes out from the main socket only.
4. Type `07000000` with the right request ID: this candidate and this socket are **selected**. Stop the
   checks, `connect()` the socket to the candidate's address and port, close every other socket of this
   hole.
5. Any other type: ignored from a derived candidate, otherwise the reference fails the hole.

### 5.5 After selection

1. For up to 1 s the client keeps answering requests from the console on the connected socket: each
   request (88 bytes, type `06`) gets a response; stray responses (type `07`) are ignored; the wait ends
   1 s after the last request.
2. The check succeeds only if the client answered **at least one** console request, before or during this
   second (client choice, observed: the reference treats "never asked by the console" as a failed hole).
   So the console must probe the client as well; the check is mutual.
3. Then the client sends ACCEPT (psn.md §7.6) naming the selected pair (§6), waits for the console's
   ACCEPT, answers it with RESULT, and again answers console requests for up to 1 s (no request at all is
   fine this time).

---

## 6. The selected pair (the ACCEPT's candidate)

The ACCEPT carries one candidate: the selected console candidate, with `mappedAddr`/`mappedPort` set to the
client's side of the pair (client choice, observed):

| Selected console candidate | `mappedAddr` : `mappedPort` |
|---|---|
| `LOCAL`, or `DERIVED` with a private address (`10.`, `192.168.`, `172.16.`–`172.31.`; for IPv6 `fc`/`fd`) | the client's LOCAL candidate (`lanIp : localPort`) |
| any other | the client's first OFFER candidate (the first STUN guess, or STATIC when there is no STUN candidate) |

`type`, `addr` and `port` are the console candidate's own. The ACCEPT's other fields: `natType 0`,
`localHashedId ""` (empty), `skey` zeros, `defaultRouteMacAddr ""`, `localPeerAddr` as in the OFFER,
`sid`/`peerSid` = `localSid`/current `consoleSid`.

The selected candidate's `addr` and `port` are also what the client puts in the `Host` header of session
init and ctrl (session.md §11, ctrl.md §10): `<addr>:<port>` of the **ctrl** hole's selection.

---

## 7. Which socket carries what afterwards

| Socket | Peer | Used for | Closed |
|---|---|---|---|
| ctrl hole | the ctrl selection (`addr:port`) | RUDP: registration through PSN, session init, ctrl for the whole session, the switch message (rudp.md) | at the end of the session |
| data hole | the data selection | Takion: the network probe (version 7), then the stream connection (takion.md §18) | when the stream connection ends |

Both are connected UDP sockets; nothing else (no other local port, no TCP) is used towards the console.

Before each Takion connection on the data socket the reference first reads and discards whatever is
queued on it (late probe packets): it waits up to 200 ms at a time for more, for at most 1 s in all
(client choice).

---

## 8. End-to-end: from a PSN token and the console's DUID to the stream

Every step that talks to PSN is in psn.md; times are the reference's limits (client choice).

```
client                         PSN (web API + push WebSocket)                  console
 0 |  have: access token (scopes, made with a client duid), console DUID (64 hex), account ID
 1 |-- UPnP discovery (≤ 7 s) on the LAN
 2 |-- GET push server address -------------------------->|
 3 |== open push WebSocket (wss, ping every 5 s) ========>|
 4 |-- POST create remote-play session ------------------>|
   |<- notifications: session created, member (client) created
 5 |   ctrl socket; UPnP map or STUN ×4; build ctrl OFFER (not sent yet)
 6 |-- POST start command (data1, data2) ---------------->|---- wake / invite ------------->|
   |<- notifications: member (console) created, customData1 updated <---------------------|
 7 |<- OFFER (console's ctrl candidates) ----------------------------------------------------|
   |-- RESULT; OFFER (client's ctrl candidates); <- RESULT ----------------------------------|
   |== probe packets on the ctrl socket ==================================================>|
   |-- ACCEPT; <- ACCEPT; RESULT ------------------------------------------------------------|
 8 |== RUDP: handshake, registration request/response (registration.md §8), finish =======>|
 9 |== RUDP: handshake, session init (session.md §11), finish ===========================>|
10 |== RUDP: handshake, ctrl start request/response, ctrl frames (ctrl.md §10) ==========>|
   |<= login PIN? session ID (0x33) ============================================(RUDP)====|
11 |   data socket; UPnP map or one STUN; build data OFFER
   |<- OFFER (console's data candidates) ----------------------------------------------------|
   |-- RESULT; OFFER; <- RESULT; probes on the data socket; ACCEPT; <- ACCEPT; RESULT ------|
12 |== Takion v7 network probe on the data socket (stream.md §5) =======================>|
13 |== RUDP: switch message; <- ctrl 0x0034 (≤ 5 s) =====================================>|
14 |== Takion stream connection on the data socket (stream.md §6 …) =====================>|
   |   … streaming; ctrl heartbeats over RUDP …
15 |-- DELETE session membership; <- members deleted (≤ 3 s); close WebSocket
   |-- UPnP DeletePortMapping ×2
```

Notes:

- Steps 4–7 each wait up to 30 s for their notifications. PlayFX measured about 27–28 s from start to
  picture on a real PS5 through the reference (PLAN.md).
- Step 8 happens on **every** internet session, and its keys (not stored ones) are used for steps 9–10
  (registration.md §8).
- A register-only run (PIN-less pairing) stops after step 8 and jumps to step 15.
- The order between 11 and the session ID: the reference starts the data hole once ctrl has delivered the
  session ID, the login PIN exchange is over, or 10 s have passed, and then waits up to 5 s more for the
  session ID if it hadn't come. Observed (PlayFX, 2026-11-24, see ctrl.md "Observed on a real console:
  internet play"): a client that started the data hole 0.1 s after ctrl came up got the session ID 6.2 s
  later, during the data hole; the stream then worked. So starting the data hole early is accepted by a PS5;
  whether the console waits for it before sending the session ID is open.

---

## 9. Timing summary (client choices, observed)

| What | Value |
|---|---|
| UPnP discovery | 2 s SSDP wait, ≤ 7 s total |
| STUN, per server | 5 s |
| STUN servers asked (ctrl hole) | up to 4 answers |
| Wait for the console's OFFER, for the RESULT of the client's OFFER, for the console's ACCEPT | 30 s each |
| Probe wait | 0.5 s, up to 20 resends |
| Extra sockets for random allocation | 250 (TTL 2) |
| Port guesses | 75 |
| Derived candidates kept | 3 per hole |
| Answering console requests after selection / after ACCEPT | until 1 s without a request |
| Draining the data socket before Takion | ≤ 1 s, 200 ms steps |

---

## 10. Open questions

1. What the console checks in the probe packets (hashed IDs, sids, the masked address at `0x50`), and what
   its own requests and responses contain at `0x04`–`0x47`. Only a capture can tell.
2. Whether the console needs the mutual check (§5.5 step 2), or whether a client that only got a response
   would work too.
3. What `natType`, `skey` and `defaultRouteMacAddr` mean, and whether other values change the console's
   behaviour (the console sends `natType 2` and a MAC address in the reference's logs; the client always
   sends `2`/empty in OFFERs and `0` in ACCEPT).
4. How many candidates the console accepts in an OFFER (the reference sends up to 77) and in which order it
   probes them.
5. Whether the console ever offers IPv6 candidates that work (the reference has IPv6 switched off) and
   whether PS4 consoles behave the same as PS5 (the reference's tested path is PS5).
6. Whether the console needs the ACCEPT's `mappedAddr`/`mappedPort` to be the client's real public mapping.
7. How long the console keeps the holes' NAT mappings alive without traffic (ctrl heartbeats every ~5 s keep
   the ctrl hole busy; the data hole idles between the probe and the stream connection).
8. Whether `localHashedId` is meant to be a hash of something (account, device) rather than random.
9. Whether the console accepts a `LOCAL` candidate with an empty address, and a registration with an empty
   `HOST` (§4.1).
10. Which SSDP search targets the official client uses (the reference relies on a library's defaults, §3.1).

---

## 11. Known-answer vectors

Made-up values: `localSid` `0x1234` (4660), `consoleSid` `0xabcd` (43981), `localHashedId` =
`00 01 02 … 13`, `consoleHashedId` = `a0 a1 … b3`, request ID `51 52 53 54 55`. Console candidates:
`STATIC 198.51.100.7:50123`, `LOCAL 192.168.0.30:9303`. Client: `LOCAL 192.168.1.20:50123`, first OFFER
candidate `STUN 203.0.113.5:40006`.

**[I]**: computed by an independent script from this text. **[C]**: the same bytes came out of a copy of the
reference's hole-punch code, driven by a harness in which every socket, DNS, HTTP and UPnP call was a stub
(no packet was sent).

### H1. Client request (88 bytes) [I][C]

```
06000000 000102030405060708090a0b0c0d0e0f10111213 000000000000000000000000
a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3 000000000000000000000000
1234 abcd 000000 5152535455 0000000000000000
```

Sent to `198.51.100.7:50123` and to `192.168.0.30:9303`, both from the hole's socket.

### H2. Client response to a console request with request ID `71 72 73 74 75`, from `198.51.100.7:50123` [I][C]

```
07000000 000102030405060708090a0b0c0d0e0f10111213 000000000000000000000000
a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3 000000000000000000000000
1234 abcd 000000 7172737475 d407 cfca d1ff 0000
```

`0x50`: `1234 ^ c633` (198.51); `0x52`: `abcd ^ 6407` (100.7); `0x54`: `1234 ^ c3cb` (port 50123).

### H3. Selection [C]

A console response (type `07`, request ID `51…55`) from `198.51.100.7:50123` selects the `STATIC`
candidate; the socket is connected to `198.51.100.7:50123`; the ACCEPT's candidate is
`{"type":"STATIC","addr":"198.51.100.7","mappedAddr":"203.0.113.5","port":50123,"mappedPort":40006}`
(full ACCEPT body: psn.md vector P7).

### H4. Candidate lists from STUN answers (public address `203.0.113.5`, LAN `192.168.1.20`) [I][C]

| STUN ports seen (4 servers) | `localPort` | `inc`, random | Candidates sent |
|---|---|---|---|
| 40000, 40002, 40004, 40006 | 50123 | 2, no | STUN 40008, 40010, 40012, 40014, 40016, 40018, 40020, 40022; STATIC 50123; LOCAL 50123 |
| 40000, 40001, 40007, 40003 | 50124 | 1, yes | 75 × STUN: 40003, 40004, 40002, 40005, 40001, 40006, 40000, 40007, 39999, … , 40040, 39966; STATIC 50124; LOCAL 50124 |
| 40000 ×4 | 40000 | 0, no | STATIC 40000; LOCAL 40000 |
| 61000 ×4 | 50500 | 0, no | STUN 61000; STATIC 50500; LOCAL 50500 |
| (UPnP: mapping OK, external `203.0.113.5`) | 50600 | – | STATIC 50600; LOCAL 50600 |

The UPnP row's mapping request was `AddPortMapping(ext 50600, int 50600, client 192.168.1.20, "UDP",
lease 0)` [C].

### H5. STUN parse [I][C]

RFC 5769 §2.2's sample IPv4 Binding Success response (80 bytes, with SOFTWARE, MESSAGE-INTEGRITY and
FINGERPRINT, transaction ID `b7e7a701bc34d686fa87dfae`) parses to `192.0.2.1:32853` with the rules of §3.2.
The request sent was `000100002112a442b7e7a701bc34d686fa87dfae`.
