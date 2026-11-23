# Stream connection: handshake, launch spec, messages and controller input

Status: draft 1 (clean-room spec, facts only). LAN path. Covers everything carried **inside** the Takion
transport on the console's UDP ports 9297 (network probe) and 9296 (stream connection): the protobuf message
set, the ECDH handshake, the launch spec, what is exchanged during the stream, the meaning of the controller
values, and how the stream ends.

Related documents and boundaries:

| Document | Owns | This document's side |
|---|---|---|
| `session.md` | Session init, `sessionAesKey` / `sessionIvSeed`, `streamHandshakeKey`, presets (§12) | Uses its §12 outputs; Appendix A's crypto facts are restated and completed in §6 here. |
| `ctrl.md` | The TCP ctrl channel (heartbeats, session ID, mic and keyboard ctrl messages) | Ctrl keeps running during the stream. The mic needs ctrl `0x30`/`0x36` (§9.10). The keyboard is entirely on ctrl. |
| `rpcrypt.md` | The AES-CFB cipher and its keystream-only form (§2.3) | Used once here: the launch spec (§7.3). |
| `takion.md` | The UDP transport: packet types, the handshake of the transport itself, data messages and their **channel**, **data type**, **chunk flags**, acks, retransmission, GKCrypt (stream keys, key positions, GMAC), congestion packets, and the **outer layout** of the feedback-state and feedback-history packets | This document says which channel and data type each message uses (§2), how the client splits a long message (§2.3), what feeds GKCrypt (§6.5), and what each **value** inside a feedback packet means (§10). "takion.md specifies the packet layout; §10 specifies the meaning of each value." |
| `av.md` | Video/audio/haptics AV packets, FEC, frame assembly, codecs, the 14-byte audio header's use | The AV stream starts once the console has the client's stream-info acknowledgement (§6.7); see av.md. This document gives the StreamInfo message that announces the profiles and audio header (§8), the IDR / corrupt-frame messages (§9.3, §9.4), and the client-built microphone packet (§9.10). |

Conventions are those of `README.md`: big-endian unless stated, hex byte strings, "client choice (observed)" for
behaviour of an existing client that the console isn't known to require. All message, field and enum names
here are this spec's own.

---

## 1. Overview and order

After ctrl start-up (`session.md` §8, a session ID is in hand) the client runs two Takion connections, one
after the other, to the same console address:

| # | Step | UDP port | Takion version (takion.md) | Crypto | Lifetime |
|---|---|---|---|---|---|
| 1 | **Network probe**: RTT and MTU measurement (§5) | 9297 | 7 | none | Closed when done. |
| 2 | Client makes `streamHandshakeKey` (16 random bytes) and a fresh secp256k1 key pair (`session.md` §6.3, Appendix A) | – | – | – | – |
| 3 | **Stream connection**: Takion handshake (takion.md), then Hello → HelloReply, StreamInfo → StreamInfoAck, ControllerConnection, mic StreamInfo (§6) | 9296 | PS5: 12, PS4: 9 | GKCrypt from HelloReply on | Whole session. |
| 4 | Streaming: AV packets (av.md), feedback packets (takion.md + §10), heartbeats and other messages (§9) | 9296 | | | |
| 5 | End: client sends Disconnect and closes (§11) | 9296 | | | |

The ctrl TCP connection stays open in parallel for the whole time and must keep answering ctrl heartbeats
(`ctrl.md` §7).

```
client                                                   console
  |== Takion handshake on :9297 (version 7, no crypto) ==>|          network probe (§5)
  |-- TransportVersionRequest [9] ------------------------>|
  |<- TransportVersionAck ---------------------------------|
  |-- Hello (empty strings, version 9) ------------------->|
  |<- HelloReply ------------------------------------------|
  |-- Probe echo on / pings / echo off / MTU in / MTU out ->|
  |-- Disconnect, close ---------------------------------->|
  |                                                         |
  |== Takion handshake on :9296 (version 12 or 9) ========>|          stream connection (§6)
  |-- Hello (session ID, launch spec, ECDH key + sig) ---->|   unencrypted (no keys yet)
  |<- HelloReply (accepted flags, console ECDH key + sig) -|
  |   ECDH → secret; GKCrypt index 2 (send), 3 (receive)   |   takion.md
  |<- StreamInfo (resolutions + video headers, audio hdr) -|
  |-- StreamInfoAck [channel 9] -------------------------->|
  |-- ControllerConnection (DualSense / DualShock 4) ----->|
  |-- StreamInfo (microphone audio header) --------------->|
  |<=========== video / audio / haptics AV packets ========|   av.md
  |== feedback state / history packets, mic AV packets ===>|   takion.md, §10, §9.10
  |-- Heartbeat every 1 s -------------------------------->|
  |<- ConnectionQuality, pad info, rumble, triggers ... ---|
  |-- Disconnect "Client Disconnecting", close ----------->|   §11
```

---

## 2. How messages ride on Takion

### 2.1 Data messages

Every message in this document except the AV and feedback packets travels as a reliable Takion **data
message** (takion.md: sequence number, channel, data type, chunk flags, acknowledgement). Two values in each
data message matter here:

- **Channel** (16-bit). Values the client uses:

| Channel | Client sends on it |
|---|---|
| 1 | Hello, Heartbeat, Disconnect, ControllerConnection, the mic StreamInfo; on the probe also TransportVersionRequest, Hello and Disconnect |
| 2 | CorruptFrame, IdrRequest |
| 8 | Probe commands (network probe only) |
| 9 | StreamInfoAck |

  The channels the console uses aren't checked by existing clients (§14).

- **Data type** (one byte in the data message's header, right before the message bytes; takion.md gives its
  offset). It selects how the message bytes are read:

| Data type | Body | Direction | Section |
|---|---|---|---|
| 0 | A protobuf message wrapper (§3) | both | §3–§9 |
| 7 | Rumble levels (raw bytes) | console → client | §9.6 |
| 9 | Pad info: light-bar colour, player index, motion reset, DualSense intensities (raw bytes) | console → client | §9.8 |
| 11 | Adaptive-trigger effects (raw bytes) | console → client | §9.7 |

  Everything the client sends uses data type 0. Received data messages with other data types are ignored
  (but still acknowledged at the Takion level).

### 2.2 Encryption

The client's first stream message (Hello) is sent before any stream keys exist, so it goes out unencrypted with
key position 0 (takion.md). Everything after the HelloReply is protected with GKCrypt (takion.md, inputs in
§6.5). The network probe never uses encryption.

### 2.3 Splitting a long message (client side)

Only the Hello can be longer than a datagram. Let

```
M = min(mtuIn, mtuOut) − 50          (mtuIn, mtuOut from the probe, §5.6; 1454 if it failed)
L = length of the encoded wrapper (§3)
```

- If `L + 26 ≤ M`: one ordinary data message with chunk flags `1`.
- Otherwise the encoded bytes are cut into pieces, in order:
  - piece 1: the first `M − 26` bytes, in an ordinary data message (with the data-type byte) and chunk flags `0`;
  - then, while more than `M − 25` bytes remain: a piece of exactly `M − 25` bytes in a **continuation** data
    message (takion.md: the same header without the data-type byte), chunk flags `0`;
  - the last piece: the remaining 1..`M − 25` bytes, in a continuation data message with chunk flags `1`.

  (The reference client also sends a remainder of exactly `M − 25` bytes as a non-final piece and then has
  nothing left to flag as final; that corner is a client bug, not protocol.)

The constants 26 and 25 are the datagram overhead of an ordinary and a continuation data message (1 + 16 + 9
and 1 + 16 + 8 bytes, takion.md). Each piece takes its own Takion sequence number and is acknowledged on its
own. Worked numbers: with `mtuIn = mtuOut = 1454`, `M = 1404`, so only a Hello of at most 1378 bytes fits in
one message. A typical PS5 Hello is about 1409 bytes (V-ST4) and is **split** into 1378 + 31 bytes even on a
plain LAN, so an implementation needs this path from day one.

How the console splits long messages to the client (e.g. a StreamInfo with large video headers) is takion.md's
reassembly.

---

## 3. Protobuf conventions and the message wrapper

### 3.1 Encoding

All protobuf payloads are standard protobuf **proto2** wire format (public spec:
https://protobuf.dev/programming-guides/encoding/). Field tables below give: number, wire type (`varint`,
`len` = length-delimited, `fixed32`, `fixed64`), this spec's name, and `req`/`opt`/`rep`.

- Senders here write fields in ascending field-number order, write every `req` field (even when it is 0,
  false or empty), and write an `opt` field only when it has a value. That order is what makes the vectors
  byte-exact; a receiver must accept any order and skip unknown fields, as protobuf requires.
- `uint32`, `int32`, `uint64`, `bool` and enums are varints (`bool`: 0 or 1). `float` is fixed32
  little-endian IEEE 754, `double` fixed64 little-endian.
- `rep` scalar fields are **not packed**: one tag per element.
- A tag is the varint `(fieldNumber << 3) | wireType` (`varint` = 0, `fixed64` = 1, `len` = 2, `fixed32` = 5).
  Fields 16 and above take a two-byte tag (e.g. field 22, `len`: `b2 01`).

### 3.2 Wrapper

Every protobuf message is one **wrapper** (data type 0):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint | `type` | req | Message type, table below |
| 2..32 | len | one payload | opt | The payload for `type` (column "Payload field"), absent for types without one |

| Type | Name (this spec) | Payload field | Direction | Used by clients |
|---:|---|---:|---|---|
| 0 | Hello | 2 | C→S | yes (§5.3, §6.2) |
| 1 | HelloReply | 3 | S→C | yes (§6.3) |
| 2 | Info | 4 | ? | no |
| 3 | Heartbeat | – | C→S | yes (§9.1) |
| 4 | PacketLoss | 5 | ? | no |
| 5 | CorruptFrame | 6 | C→S (S→C seen logged) | yes (§9.4) |
| 6 | Cursor | 8 | S→C | no |
| 7 | Timer | 9 | S→C | no |
| 8 | Disconnect | 10 | both | yes (§11) |
| 9 | Log | 11 | ? | no |
| 10 | HeaderRequest | 12 | ? | no |
| 11 | Debug | 13 | ? | no |
| 12 | Probe | 14 | both | yes (§5) |
| 13 | StreamInfo | 15 | both | yes (§8, §9.10) |
| 14 | StreamInfoAck | – | both | yes (§6.7) |
| 15 | HomeMenuCommand | 16 | ? | no |
| 16 | ConnectionQuality | 17 | S→C | yes (§9.2) |
| 17 | ClientMetric | 18 | C→S | no |
| 18 | PlayTimeLeft | 19 | S→C | no |
| 19 | ServerMessage | 20 | S→C | no |
| 20 | FpsChange | 21 | ? | no |
| 21 | ControllerConnection | 22 | C→S | yes (§6.8) |
| 22 | ClientInfo | 23 | ? | no |
| 23 | VideoCapture | 24 | ? | no |
| 24 | AudioCapture | 25 | ? | no |
| 25 | IdrRequest | – | C→S | yes (§9.3) |
| 26 | CryptoTrace | 26 | ? | no |
| 27 | PeriodicTimestamp | 27 | ? | no |
| 28 | ServerSettings | 28 | ? | no |
| 29 | DirectMessage | 29 | ? | no |
| 30 | MicConnection | 30 | ? | no |
| 31 | TransportVersionRequest | 31 | C→S | yes, probe only (§5.2) |
| 32 | TransportVersionAck | 32 | S→C | yes, probe only (§5.2) |

There is no payload field 7. Types 3, 14 and 25 carry no payload: their wrapper is just the type
(`08 03`, `08 0e`, `08 19`).

"Used by clients: no" means existing clients neither send nor act on it; the layout is still given (§4.3) so
an implementation can decode and log it.

---

## 4. Payload messages

### 4.1 Messages that are used

**Hello** (payload field 2):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint | `clientVersion` | req | Takion version the client speaks: 12 (PS5) or 9 (PS4) on the stream; 9 on the probe |
| 2 | len (string) | `sessionKey` | req | The ctrl `sessionId` (`session.md` §12), ASCII, no terminator. Empty on the probe |
| 3 | len (string) | `launchSpec` | req | The base64 text of §7. Empty on the probe |
| 4 | len (bytes) | `encryptedKey` | req | Stream: 4 zero bytes `00000000`. Probe: empty |
| 5 | len (bytes) | `ecdhPublicKey` | opt | Stream only: 65-byte uncompressed secp256k1 point (§6.4) |
| 6 | len (bytes) | `ecdhSignature` | opt | Stream only: 32-byte HMAC-SHA256 (§6.4) |

**HelloReply** (payload field 3):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint | `serverVersion` | req | Console's version number (meaning not used) |
| 2 | varint | `token` | req | Unknown, not used |
| 3 | varint (bool) | `keyAccepted` | req | Must be true (the Hello's `encryptedKey` accepted) |
| 4 | varint (bool) | `versionAccepted` | req | Must be true (the Hello's `clientVersion` accepted) |
| 5 | len (string) | `sessionKey` | req | Unknown, not used |
| 6 | len | `extendedInfo` | opt | An EventInfo message (below) |
| 7 | len (string) | `serverVersionText` | opt | Not used |
| 8 | len (bytes) | `ecdhPublicKey` | opt | Stream: console's 65-byte public key (§6.4). Required in practice |
| 9 | len (bytes) | `ecdhSignature` | opt | Stream: console's 32-byte signature (§6.4). Required in practice |

**EventInfo** (inside HelloReply field 6 and Disconnect field 2):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | len (string) | `code` | req | Event code text |
| 2 | len (string) | `name` | opt | |
| 3 | len (string) | `description` | opt | |

**Disconnect** (payload field 10):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | len (string) | `reason` | req | Human-readable reason. Client sends `Client Disconnecting`. See §11 for the console's |
| 2 | len | `extendedInfo` | opt | EventInfo |

**CorruptFrame** (payload field 6):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint | `firstFrame` | req | First bad video frame index (16-bit frame counter of av.md, as an unsigned value) |
| 2 | varint | `lastFrame` | req | Last bad video frame index, inclusive |

**StreamInfo** (payload field 15):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | len | `videoProfile` | rep | One VideoProfile per resolution the console may send (§8) |
| 2 | len (bytes) | `audioHeader` | req | 14-byte audio header (§8.2) |
| 3 | varint | `startTimeout` | opt | Not used |
| 4 | varint | `idleTimeout` | opt | Not used |
| 5 | varint | `idleTimeoutDisconnect` | opt | Not used |
| 6 | varint | `congestionInterval` | opt | Not used |
| 7 | len | `audioChannel` | rep | AudioChannel (below), not used |

**VideoProfile** (inside StreamInfo field 1):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint | `width` | req | Pixels |
| 2 | varint | `height` | req | Pixels |
| 3 | len (bytes) | `videoHeader` | req | Codec header for this profile (av.md) |

**AudioChannel** (inside StreamInfo field 7): 1 varint `channelType` req; 2 bytes `audioHeader` req; 3 bool
`rawPcm` opt.

**ConnectionQuality** (payload field 17), console → client, all optional:

| # | Wire | Name | Meaning |
|---|---|---|---|
| 1 | varint | `targetBitrate` | Bitrate the console's encoder now aims for (§9.2) |
| 2 | varint | `upstreamBitrate` | |
| 3 | fixed32 (float) | `upstreamLoss` | |
| 4 | varint (bool) | `disableUpstreamAudio` | Possibly: stop sending microphone audio (unverified) |
| 5 | fixed64 (double) | `rtt` | Round-trip time (unit unknown) |
| 6 | varint (uint64) | `loss` | |

**ControllerConnection** (payload field 22):

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint (int32) | `controllerId` | opt | Not sent by existing clients |
| 2 | varint (bool) | `connected` | opt | Client sends true |
| 3 | varint (enum) | `controllerType` | opt | 0 not set, 1 DualShock 3, 2 DualShock 4, 3 Vita, 4 XInput, 5 mobile, 6 DualSense, 7 VR2 Sense controller |

**Probe** (payload field 14), network probe only:

| # | Wire | Name | Req | Meaning |
|---|---|---|---|---|
| 1 | varint (enum) | `command` | req | 0 echo, 1 MTU, 3 bandwidth, 4 client MTU |
| 2 | len | `echo` | opt | ProbeEcho |
| 3 | len | `mtu` | opt | ProbeMtu |
| 4 | len | `bandwidth` | opt | ProbeBandwidth (not used) |
| 5 | len | `clientMtu` | opt | ProbeClientMtu |

- **ProbeEcho**: 1 bool `enabled` req.
- **ProbeMtu**: 1 uint32 `id` req; 2 uint32 `requestedMtu` req; 3 uint32 `sentMtu` opt; 4 uint32 `count` opt;
  5 uint32 `sendDelay` opt; 6 uint32 `delta` opt. Clients send only fields 1 and 2.
- **ProbeClientMtu**: 1 uint32 `id` req; 2 uint32 `requestedMtu` req; 3 bool `active` req; 4 uint32
  `downstreamMtu` opt.
- **ProbeBandwidth**: 1 uint32 `id` req; 2 uint32 `time` req; 3 `bandwidth`, 4 `fps`, 5 `mtu`, 6 `naluCount`,
  7 `totalSent` (uint32, opt); 8 bool `upstream` opt; 9 double `loss` opt.

**TransportVersionRequest** (payload field 31): 1 uint32 `supportedVersions` rep (unpacked).
**TransportVersionAck** (payload field 32): 1 uint32 `version` opt.

### 4.2 Fields of the wrapper's unused payloads

For decoding and logging only. `u32` = uint32 varint, `i32` = int32 varint, `str` = string, `b` = bytes.

| Payload (field) | Fields |
|---|---|
| Info (4) | all req u32: 1 effectiveBandwidth, 2 bitrate, 3 minBitrate, 4 targetBitrate, 5 corruptFrameFrequency, 6 mtu, 7 fps, 8 monitorInterval, 9 externalOverhead, 10 internalOverhead, 11 timeoutInterval, 12 minResumeQuality, 13 minFps |
| PacketLoss (5) | req u32: 1 first, 2 last, 3 packetsReceived |
| Cursor (8) | req u32: 1 id, 2 width, 3 height, 4 hotspotX, 5 hotspotY; 6 b pixels opt |
| Timer (9) | req u32: 1 secondsLeft, 2 totalSeconds |
| Log (11) | 1 rep LogEntry: {1 int64 timestamp req; 2 enum level req (0 critical, 1 error, 2 warning, 3 info, 4 debug, 5 trace); 3 str component req; 4 str message req; 5 double timestampSeconds opt} |
| HeaderRequest (12) | 1 enum req: 0 audio, 1 video |
| Debug (13) | 1 enum req (0 overlay, 1 bitrate); 2 Overlay {1 bool enable, 2 bool toggle, 3 enum corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right), 4 u32 level}; 3 Bitrate {1 bool toggle, 2 float change} |
| HomeMenuCommand (16) | 1 enum req: 0 off, 1 on, 2 toggle; 2 u32 playerId opt |
| ClientMetric (18) | 1 rep Metric {1 enum category req (0..20), 2 i32 firstFrame, 3 i32 lastFrame, 5 i32 count, 6 float average, 7 float stdDev, 8 float min, 9 float max, all req} |
| PlayTimeLeft (19) | 1 u32 timeLeft opt; 2 str reason opt |
| ServerMessage (20) | 1 str text opt |
| FpsChange (21) | 1 u32 fps req |
| ClientInfo (23) | 1 str sessionKey req; 2 u32 gcmTag opt; 3 u32 keyPosition opt |
| VideoCapture (24) | 1 bool serverSide opt (default false); 2 u32 idrPeriod opt (default 0) |
| AudioCapture (25) | 1 bool serverSide opt |
| CryptoTrace (26) | req u32: 1 sequence, 2 gcmTag, 3 keyPosition |
| PeriodicTimestamp (27) | 1 b info req; 2 u32 version req |
| ServerSettings (28) | 1 u32 idrPeriod opt; 2 bool sendPeriodicTimestamp opt |
| DirectMessage (29) | 1 enum kind req (0 deep link, 1 mic info); 2 enum destination req (1000 controller service, 1001 client); 3 b data opt |
| MicConnection (30) | 1 i32 controllerId req; 2 bool connected req; 3 bool result opt |

ClientMetric categories 0..20 are video, graphics and audio
pipeline timings; their individual meanings aren't needed.

Two further message shapes exist in the reference schema without a wrapper field, presumably carried inside
DirectMessage `data`: a deep-link message and a mic-info message (1 enum kind req: 0 connect, 1 mute; 2 u32
controllerId; 3 bool connected; 4 bool muted; 5 bool result). Neither is used by existing clients.

---

## 5. Network probe (UDP 9297)

Purpose: measure the round-trip time and the largest datagram that gets through in each direction, for the
launch spec (§7) and the Hello split (§2.3). It is optional in the sense that a client which skips it or sees
it fail uses `mtuIn = mtuOut = 1454` and `rtt = 1 ms` (and lets the IP layer fragment): client choice
(observed).

### 5.1 Connection

Takion to `consoleAddress:9297`, Takion **version 7**, no encryption, and the IP don't-fragment flag set on
outgoing datagrams (needed for the MTU test to mean anything). Takion connect timeout: 30 s (client choice,
observed).

### 5.2 Version request

Client → channel 1: TransportVersionRequest with one entry, 9. Wrapper bytes: `08 1f fa 01 02 08 09`.
The console answers with a TransportVersionAck; the client waits up to 5 s for it and doesn't check its
content.

### 5.3 Hello

Client → channel 1: a Hello with `clientVersion` 9, and `sessionKey`, `launchSpec`, `encryptedKey` all empty,
no ECDH fields. Wrapper bytes: `08 00 12 08 08 09 12 00 1a 00 22 00`. The console answers with a HelloReply;
the client waits up to 5 s and doesn't check its content.

### 5.4 RTT test

1. Client → channel 8: Probe {command 0, echo {enabled true}} (`08 0c 72 06 08 00 12 02 08 01`), and waits up
   to 5 s for the Takion acknowledgement of that data message.
2. Ten pings, `i = 0..9`, one at a time. Each ping is one raw datagram of **548 bytes** (not a data message):

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `03` (audio AV packet type, takion.md) |
| 1 | 2 | `0000` (packet index) |
| 3 | 2 | `0000` (frame index = test number 0) |
| 5 | 4 | BE32 of `(0x7ff << 10) \| (i << 21)` (the version-7 AV unit word: FEC count 0, unit count − 1 = 0x7ff, unit index `i`) |
| 9 | 1 | `ff` (codec byte) |
| 10 | 4 | `00000000` |
| 14 | 4 | `00000000` (key position) |
| 18 | 4 | `00000000` |
| 22 | 4 | `tag`: BE32 random value, new for each ping |
| 26 | 522 | zero |

3. The console's pong is an audio-type AV packet in the version-7 layout (byte 0 low nibble 3; unit word at
   offset 5 with the unit index in bits 21..31 (11 bits), frame index at offset 3; data after an 18-byte
   header, 21 if byte 0 has bit `0x10` set). It matches when frame index = 0, unit index = `i`, data is at
   least 8 bytes and data bytes 4..7 equal `tag`. RTT sample = time from sending the ping to receiving the
   matching pong. Up to 1 s per ping; a ping without a pong is skipped.
4. Client → channel 8: Probe {command 0, echo {enabled false}} (`08 0c 72 06 08 00 12 02 08 00`), waits for
   its Takion acknowledgement.
5. `rtt` = mean of the successful samples (µs). No pong at all: the probe fails.

### 5.5 MTU test

`T = clamp(5 × rtt, 5 ms, 500 ms)` is the wait per attempt. Both searches are a bisection over
`[576, 1454]` with up to 3 attempts per size (client choices, observed).

**Inbound MTU** (console → client), sizes are IP packet sizes:

1. `lo = 576, hi = 1454, size = 1454, id = 0`.
2. While `hi − lo > 1`: up to 3 attempts, each with `id = id + 1`: send on channel 8 Probe {command 1, mtu {id,
   requestedMtu = size}}, then wait `T` for a **video**-type AV packet whose frame index (offset 3) equals `id`.
   Any attempt seen → `lo = size`, else `hi = size`. Then `size = lo + (hi − lo) / 2` (integer division).
3. `mtuIn = lo`.

**Outbound MTU** (client → console):

1. Send on channel 8 Probe {command 4, clientMtu {id 1, requestedMtu = mtuIn, active true, downstreamMtu =
   mtuIn}} (no wait for the Takion acknowledgement). Wait up to 5 s for a console Probe {command 4} whose
   `clientMtu.id` is 1. Console Probe messages with command 1 may arrive meanwhile and are ignored.
2. `lo = 576, hi = 1454, size = mtuIn`. While `hi − lo > 1`: up to 3 attempts `a = 0, 1, 2`, each sending one
   datagram of `size − 28` bytes (28 = IPv4 + UDP headers): the ping layout of §5.4 with unit index `a`, new
   random `tag` at offset 22, and any filler after offset 26. Wait `T` for the matching pong (§5.4 rule with
   unit index `a`). Seen → `lo = size`, else `hi = size`; then `size = lo + (hi − lo) / 2`.
3. `mtuOut = lo`.
4. Send on channel 8 Probe {command 4, clientMtu {id 2, requestedMtu = hi, active false, downstreamMtu =
   mtuIn}}, and wait up to 5 s for its Takion acknowledgement.

### 5.6 End

Client → channel 1: Disconnect "Client Disconnecting" (§11), then close the probe's Takion (no further wait).
Outputs: `rtt` (µs), `mtuIn`, `mtuOut`.

---

## 6. Stream handshake (UDP 9296)

### 6.1 Takion

Takion to `consoleAddress:9296`, Takion version 12 for a PS5, 9 for a PS4, encryption enabled (keys installed
after §6.5). Wait up to 5 s for the Takion handshake (takion.md).

### 6.2 Hello (client → console, channel 1)

Wrapper `{type 0, hello {...}}` with:

| Field | Value |
|---|---|
| `clientVersion` | 12 (PS5) or 9 (PS4): the Takion version of §6.1 |
| `sessionKey` | The ctrl `sessionId` text |
| `launchSpec` | §7, base64 text |
| `encryptedKey` | `00000000` |
| `ecdhPublicKey` | Client's public key, 65 bytes (§6.4) |
| `ecdhSignature` | HMAC-SHA256(`streamHandshakeKey`, client public key), 32 bytes |

Byte layout (all lengths are varints; for the usual sizes they take two bytes):

```
08 00                                   type = 0
12 <len>                                payload field 2
   08 <clientVersion>
   12 <len> <sessionId ASCII>
   1a <len> <launch spec base64 ASCII>
   22 04 00 00 00 00
   2a 41 <65-byte public key>
   32 20 <32-byte signature>
```

Split as in §2.3 if long. Then wait up to 5 s for the HelloReply.

While waiting:

- A **StreamInfo** that arrives before the HelloReply is kept (the first one only) and handled right after the
  HelloReply (§6.6).
- A **Disconnect** ends the session as a remote disconnect (§11).
- Anything else is ignored.

### 6.3 HelloReply checks (client side)

The session fails (end reason `streamFailed`, §11.2) unless all hold:

1. The wrapper decodes, `type` = 1 and payload field 3 is present.
2. `versionAccepted` is true.
3. `keyAccepted` is true.
4. `ecdhPublicKey` is present and non-empty (existing clients accept at most 128 bytes).
5. `ecdhSignature` is present and non-empty (existing clients accept at most 32 bytes).
6. The public key decodes to a point on secp256k1 and ECDH succeeds (§6.4).

The console's signature is **not** verified by existing clients (§14).

### 6.4 ECDH

- Curve: **secp256k1** (SEC 2, https://www.secg.org/sec2-v2.pdf), confirmed. Not NIST P-256.
- Key pair: fresh per session, made before the stream connection (private key: a uniformly random scalar
  in `[1, n−1]`).
- Public key encoding: SEC1 uncompressed point, 65 bytes: `04 || X (32, big-endian) || Y (32, big-endian)`.
  Clients send this form; the console's key in observed traffic has the same 65-byte form. Accepting a
  33-byte compressed point as well costs nothing.
- Client signature: `HMAC-SHA256(key = streamHandshakeKey (16 bytes), message = the 65-byte client public key)`.
- Shared secret `ecdhSecret`: the 32-byte big-endian **X coordinate** of `clientPrivate × consolePublic`. No
  hashing, no KDF (`session.md` Appendix A).

### 6.5 Stream keys

From `streamHandshakeKey` and `ecdhSecret` the client builds two GKCrypt instances (takion.md):

| Instance | Index | Use |
|---|---|---|
| send | 2 | Everything the client sends from now on (data messages, feedback, mic) |
| receive | 3 | Everything the console sends from now on (AV packets, data messages) |

The derivation from (index, `streamHandshakeKey`, `ecdhSecret`) is in takion.md. They are installed as soon as
the HelloReply has been checked.

### 6.6 StreamInfo (console → client)

Wait up to 5 s (after the HelloReply) for a wrapper with `type` 13 and payload field 15. A Disconnect meanwhile
ends the session as a remote disconnect; other messages are ignored. Then:

- `audioHeader` must be exactly 14 bytes, or the session fails.
- Each `videoProfile` is one resolution the console may stream, in order: list index 0, 1, ….
  Existing clients keep at most 8 and pass each header to the decoder side (§8.1, av.md).

### 6.7 Client's answers, in this order

1. **StreamInfoAck** on **channel 9**: `08 0e`.
2. **ControllerConnection** on channel 1: `{connected true, controllerType 6}` (DualSense) when DualSense
   features are on (`ctrl.md` §6.4; existing clients: PS5), else `controllerType 2` (DualShock 4). Bytes:
   `08 15 b2 01 04 10 01 18 06` (DualSense) or `08 15 b2 01 04 10 01 18 02`.
3. **StreamInfo (microphone)** on channel 1: a StreamInfo with no profiles and the client's microphone audio
   header (§9.10). Bytes: `08 0d 7a 10 12 0e 01 10 0000bb80 000001e0 00000001`.

Then the stream is up: the client starts the feedback packets (§10, takion.md), the 1 s Heartbeat (§9.1), and
the app sees "connected". The AV stream (av.md) is underway by then or starts right after.

---

## 7. Launch spec

### 7.1 JSON text

A single line of JSON, **byte-exact** as below (no spaces or newlines except the one space noted), followed by
one zero byte. `{W}` etc. are decimal integers with no leading zeros or sign.

```
{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":{W},"height":{H}},"maxFps":{F},"score":10}],"network":{"bwKbpsSent":{B},"bwLoss":0.001000,"mtu":{MTU},"rtt":{RTT},"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1"{ADAPT}},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},{CODEC}{RANGE}"handshakeKey":"{HK}"}
```

| Placeholder | Value |
|---|---|
| `{W}`, `{H}` | Requested width and height in pixels (§7.2) |
| `{F}` | Requested maximum frame rate: 30 or 60 |
| `{B}` | Requested bitrate in kbit/s |
| `{MTU}` | `mtuIn` from the probe (§5), bytes (1454 if the probe failed) |
| `{RTT}` | Probe `rtt` in **milliseconds**, `floor(rtt_µs / 1000)` (1 if the probe failed; 0 is possible on a fast LAN) |
| `{ADAPT}` | PS5: `,"adaptiveStreamMode": "resize"` (note the single space after the colon). PS4: empty |
| `{CODEC}` | PS5: `"videoCodec":"avc",` for H.264 or `"videoCodec":"hevc",` for H.265 (with the trailing comma). PS4: empty |
| `{RANGE}` | PS5: `"dynamicRange":"SDR",` or `"dynamicRange":"HDR",` (HDR only with H.265). PS4: empty |
| `{HK}` | Base64 (standard, padded) of `streamHandshakeKey`: 24 characters |

Facts about the fixed parts:

- `sessionId` is the literal `sessionId4321`, not the ctrl session ID (that one goes in Hello `sessionKey`).
- `bwLoss` is written `0.001000` (six decimals).
- The other keys and values are literal constants as shown. Which of them the console reads isn't known; send
  them unchanged.
- The PS5 keys apply to `negotiatedVersion` PS5 1.0. On PS4 (any version) none of them is written: PS4 streams
  are H.264 SDR.
- Existing clients keep the JSON under 1024 bytes.

### 7.2 From user settings to values

Existing clients' presets (client choice, observed):

| Resolution setting | `{W}` × `{H}` | Default `{B}` (kbit/s) |
|---|---|---|
| 360p | 640 × 360 | 2000 |
| 540p | 960 × 540 | 6000 |
| 720p | 1280 × 720 | 10000 |
| 1080p | 1920 × 1080 | 15000 |

- Frame rate: 30 or 60 → `{F}`.
- Bitrate: a user value (kbit/s) replaces the preset's default.
- Codec (PS5): H.264 → `avc`/`SDR`, ctrl `RP-StreamingType` 1; H.265 → `hevc`/`SDR`, type 2; H.265 HDR →
  `hevc`/`HDR`, type 3 (`ctrl.md` §3.1). The codec is announced twice (ctrl and launch spec) and the two must
  agree.
- Server type from ctrl (`ctrl.md` §3.2), applied before the launch spec is built:
  - base PS4 (0) with 1080p and **auto-downgrade** on → the 720p preset at the same frame rate. Note: this
    applies the preset whole, so the bitrate becomes 10000 kbit/s even if the user had set another.
  - PS4 or PS4 Pro (0, 1) → H.264.
- "Auto-downgrade" has no other effect in existing clients. Resolution changes **during** a PS5 stream come
  from `adaptiveStreamMode` "resize", which is always requested on PS5 (§8.1).

### 7.3 Encoding

```
plain   = UTF-8 (ASCII) bytes of the JSON text || 00
ks      = rpcrypt keystream-only form at counter 0 (rpcrypt.md §2.3), length len(plain),
          context: K = sessionAesKey, S = sessionIvSeed, H = K_hmac[negotiatedVersion]
cipher  = plain XOR ks
launchSpec field = base64(cipher)       (standard alphabet, = padding, no line breaks)
```

- Counter 0 is used even though ctrl has used counter 0 too: the launch spec has its own use of the context,
  independent of the ctrl counters (`session.md` §12).
- The keystream-only form is **not** AES-CFB of the plaintext beyond the first 16 bytes; it is CFB encryption
  of zeros (which equals AES-OFB) XORed onto the text.

---

## 8. Stream info: profiles and the audio header

### 8.1 Video profiles

The console announces, in the StreamInfo it sends (§6.6), the list of resolutions ("profiles") it may encode,
each with its codec header. The client doesn't pick one: every video AV packet names the profile its frame
uses by list index (the "adaptive stream index", av.md). When that index changes, the client switches to that
profile's resolution and header (av.md). The client's only say is the single resolution in the launch spec;
with `adaptiveStreamMode` "resize" (PS5) the console may step down to other listed resolutions when the network
can't keep up.

### 8.2 Audio header (14 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `channels` |
| 1 | 1 | `bitsPerSample` |
| 2 | 4 | `sampleRate` (Hz), BE32 |
| 6 | 4 | `frameSize` (samples per channel per audio frame), BE32 |
| 10 | 4 | unknown, BE32. The client's own header writes 1 |

The console's header describes the game audio stream (decoded per av.md). The client sends its own for the
microphone (§9.10).

---

## 9. During the stream

### 9.1 Heartbeat

The client sends a Heartbeat wrapper (`08 03`) on channel 1 every **1 s** from the end of §6.7 until it stops
(client choice, observed). Nothing answers it at this level (Takion acknowledges the data message). This is
separate from the ctrl heartbeat (`ctrl.md` §6.1), which must keep being answered too.

### 9.2 ConnectionQuality (console → client)

Sent from time to time by the console. Existing clients only keep `targetBitrate` as the console's current
encoder target, for display; PlayFX shows it as bit/s (unit unconfirmed, §14). No answer is expected.

### 9.3 IdrRequest (client → console, channel 2)

Wrapper `08 19`. Asks the console to send an IDR (key) frame soon. When to send (client choices, observed):

- when a video frame can't be repaired by FEC (av.md), if no IDR request is already outstanding;
- while an IDR is outstanding and frames keep arriving that aren't I-frames, again at most once per **1 s**;
- when the app's decoder rejects a frame.

"Outstanding" ends when an I-frame arrives (av.md tells frame types apart).

### 9.4 CorruptFrame (client → console, channel 2)

Wrapper `{type 5, corruptFrame {firstFrame, lastFrame}}`. Tells the console which video frames the client lost,
inclusive. Sent (client choices, observed):

- when a new video frame index `f` arrives and frames between the last complete one and `f` never completed:
  range `[lastComplete + 1, f − 1]` (not for frame 1 at the very start);
- when frame `f` fails FEC: range `[lastComplete + 1, f]`.

Frame indices are av.md's 16-bit frame counter. Example `{100, 105}`: `08 05 32 04 08 64 10 69`.

A CorruptFrame **from** the console has been seen logged by existing clients; its meaning there is unknown.

### 9.5 Disconnect

See §11.

### 9.6 Rumble (data type 7, console → client)

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | unknown |
| 1 | 1 | left (heavy, low-frequency) motor strength, 0..255 |
| 2 | 1 | right (light, high-frequency) motor strength, 0..255 |

Bodies shorter than 3 bytes are ignored. A level holds until the next rumble message (0 = stop).

### 9.7 Adaptive-trigger effects (data type 11, console → client, PS5)

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | unknown |
| 1 | 1 | left (L2) trigger effect mode |
| 2 | 1 | right (R2) trigger effect mode |
| 3 | 2 | unknown |
| 5 | 10 | left trigger effect parameters |
| 15 | 10 | right trigger effect parameters |

Bodies shorter than 25 bytes are ignored. Mode + 10 parameter bytes per trigger are the DualSense
controller's own adaptive-trigger format (the trigger blocks of its HID output report, which the DualSense
reverse-engineering community documents publicly; not reproduced or checked here). Modes seen by PlayFX on a PS5: `0x25` (weapon) and `0x26` (vibration). Without the ctrl
header `RP-PadProcNo: 3` (`ctrl.md` §3.1) a PS5 was seen sending some effects in a form the controller doesn't
apply.

### 9.8 Pad info (data type 9, console → client)

Two body sizes are known; other sizes are ignored.

25-byte form:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 2 | BE16: sequence number of the feedback packet this answers (assumed) |
| 2 | 2 | unknown |
| 4 | 4 | BE32: a time stamp (assumed: seconds since the stream began) |
| 8 | 1 | player index, 0 = player 1 |
| 9 | 3 | light-bar colour R, G, B (0..255 each) |
| 12 | 1 | motion reset: non-zero = take the controller's current orientation as the new origin |
| 13 | 7 | unknown |
| 20 | 1 | haptics intensity (below) |
| 21 | 1 | adaptive-trigger intensity (below) |
| 22 | 3 | unknown |

17-byte form:

| Offset | Size | Meaning |
|---|---|---|
| 0 | 1 | player index |
| 1 | 3 | light-bar colour R, G, B |
| 4 | 1 | motion reset |
| 5 | 7 | unknown |
| 12 | 1 | haptics intensity |
| 13 | 1 | adaptive-trigger intensity |
| 14 | 3 | unknown |

Intensity values (the console's DualSense vibration/trigger strength setting): `0` off, `1` strong, `2` medium,
`3` weak. Existing clients start from "strong" and the colour from `000000`, and report each value when it
changes. Which console or version sends which form isn't recorded (§14).

### 9.9 Haptics audio (PS5)

PS5 games drive the DualSense's voice-coil actuators with a separate **haptics stream**, delivered as audio AV
packets marked as haptics (av.md). Its payload is uncompressed PCM: 2 channels (left actuator, right actuator),
interleaved, signed 16-bit (little-endian as consumed by PlayFX, which plays it correctly), **3000 Hz**. When an
effect ends the console stops sending haptics packets; it doesn't send silence. A client without a way to play
it on the pad may turn it into rumble (client choice: PlayFX takes the mean absolute value per channel per
frame, treats small values as zero and scales to 0..255).

### 9.10 Microphone (client → console)

Set-up:

1. During §6.7 the client always sends its microphone StreamInfo (audio header below).
2. When the user first turns the mic on: ctrl `0x0030` "mic connect" (`ctrl.md` §6.6).
3. Mute state on ctrl `0x0036` `00 01 XX 59`: existing clients write `XX = 01` for **unmuted** and `00` for
   muted.

Client's audio header (§8.2) as sent: `01 10 0000bb80 000001e0 00000001`: 1 channel, 16 bits, 48000 Hz, 480
samples per frame (10 ms), unknown = 1.

Audio: **Opus** (RFC 6716), 48 kHz, 480-sample (10 ms) frames, constant bitrate 32 kbit/s so that every encoded
frame is **exactly 40 bytes**; frames of any other size are not sent. Encoder settings used by PlayFX (client
choices): restricted-low-delay application, music signal type, phase inversion disabled, **2 channels** (the
header says 1; a mono or stereo Opus stream decodes either way, see §14).

Each 10 ms frame `N` goes up as one raw Takion datagram (not a data message, no channel) on the stream
connection:

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `03` (audio AV packet type) |
| 1 | 2 | BE16 packet index `p` (0 for the first packet, +1 per packet, 65535 wraps to 0) |
| 3 | 2 | BE16 frame index `p + 1` (mod 65536) |
| 5 | 4 | `00 02 28 21`: unit index 0, 3 units in the packet (value 2 = count − 1), then `2821` = 40-byte units, 2 FEC units, 1 source unit (av.md's audio unit word) |
| 9 | 1 | `05` (codec byte: Opus) |
| 10 | 4 | GMAC tag (takion.md) |
| 14 | 4 | BE32 key position (takion.md) |
| 18 | 1 | `00` |
| 19 | 1 | `00`: **PS5 only** (PS4 packets have no such byte; the payload starts at 19) |
| 19 or 20 | 120 | Payload: frame `N`, frame `N−2`, frame `N−1`, 40 bytes each, encrypted |

- For the first packet, frames `N−1` and `N−2` are copies of frame `N`; for the second, `N−2` is a copy of the
  first frame.
- Encryption: the payload (only) is encrypted with the send GKCrypt at key position `k + 16`, the key position
  field holds `k`, and the GMAC is computed over the whole datagram at `k`, as for the feedback packets
  (takion.md).

### 9.11 Keyboard

The text keyboard is entirely on ctrl (`ctrl.md` §6.5). Nothing on the stream connection.

### 9.12 PS5 / DualSense differences on the stream

| Item | PS5 | PS4 |
|---|---|---|
| Takion version, Hello `clientVersion` | 12 | 9 |
| Launch-spec codec/range/adaptive keys | yes | no |
| ControllerConnection type | 6 DualSense (with DualSense features) | 2 DualShock 4 |
| Feedback-state body | 28 bytes (§10.3) | 25 bytes |
| Trigger effects (§9.7), haptics stream (§9.9), intensities (§9.8) | yes | not seen |
| Mic packet extra byte at offset 19 | yes | no |

---

## 10. Controller input: meaning of the feedback values

takion.md specifies the feedback-state and feedback-history packets (type byte, sequence numbers, event
count, key position, GMAC, encryption, which events a packet carries and how the console applies them). This
section specifies the body bytes and the meaning of each value.

### 10.1 Controller state (client-side model)

A neutral representation the client keeps and turns into packets (names and bit values are PlayFX's own API,
not wire values):

| Bit | Button | Bit | Button |
|---:|---|---:|---|
| 0 | Cross | 8 | L1 |
| 1 | Circle | 9 | R1 |
| 2 | Square | 10 | L3 (left stick click) |
| 3 | Triangle | 11 | R3 |
| 4 | D-pad left | 12 | Options |
| 5 | D-pad right | 13 | Share / Create |
| 6 | D-pad up | 14 | Touchpad click |
| 7 | D-pad down | 15 | PS |

Analog values:

| Value | Range | Wire |
|---|---|---|
| L2, R2 | 0 (released) .. 255 (fully pressed) | history events (§10.2) |
| Left/right stick X, Y | int16, −32768..32767, 0 = centre; X: negative = left; Y: **negative = up, positive = down** | feedback state (§10.3) |
| Touches | up to 2, each `{id, x, y}` or "no finger" | history events (§10.2) |
| Gyro | rad/s, 3 axes | feedback state |
| Accelerometer | g (gravity included), 3 axes | feedback state |
| Orientation | unit quaternion (x, y, z, w) | feedback state |

Idle state: no buttons, triggers 0, sticks 0, no touches, gyro (0, 0, 0), accelerometer (0, 1, 0) g,
orientation (0, 0, 0, 1).

### 10.2 History events (buttons, L2/R2, touch)

The feedback-history packet body is a list of events, newest first (takion.md). Event encodings:

**Digital button with a state byte** (3 bytes): `80 <code> <state>`, `state` = `ff` pressed, `00` released.

| Button | Code |
|---|---|
| D-pad up | `80` |
| D-pad down | `81` |
| D-pad left | `82` |
| D-pad right | `83` |
| L1 | `84` |
| R1 | `85` |
| Cross | `88` |
| Circle | `89` |
| Square | `8a` |
| Triangle | `8b` |

**Analog trigger** (3 bytes): `80 86 <value>` for L2, `80 87 <value>` for R2, value 0..255. One event per value
change.

**Button with separate press/release codes** (2 bytes): `80 <code>`.

| Button | Pressed | Released |
|---|---|---|
| Options | `ac` | `8c` |
| Share / Create | `ad` | `8d` |
| PS | `ae` | `8e` |
| L3 | `af` | `8f` |
| R3 | `b0` | `90` |
| Touchpad click | `b1` | `91` |

**Touch** (5 bytes): `<kind> <id> <x_hi> <x_lo|y_hi> <y_lo>`:

| Byte | Value |
|---|---|
| 0 | `d0` finger down or moved; `c0` finger lifted |
| 1 | touch id, 0..127 (7 bits) |
| 2 | `x >> 4` |
| 3 | `((x & 0x0f) << 4) \| (y >> 8)` |
| 4 | `y & 0xff` |

- `x`, `y` are 12-bit touchpad coordinates, origin top-left: `x` 0..1919, `y` 0..1079 on a DualSense (PlayFX
  sends this range); a DualShock 4's pad is 1920 × 942.
- A lifted finger's event carries its last position.
- Touch ids: each new touch takes the next id, `(previous + 1) mod 128`, starting at 0 for the session; the id
  stays the same while that finger is down. The console tells a swipe from two taps by the id.

When one state change involves several events, existing clients emit them in this order: button releases
(in bit order of §10.1), then touch changes per touch slot 0, 1, then button presses (bit order), then L2,
then R2. Per slot: if the slot had a finger before and its id is now different (another id or none), a lift
event with the old id and old position; otherwise, if the slot has a finger now and its id or position
changed, a down/move event with the new values. (So a slot whose id changes from one finger to another in a
single step sends only the lift; the new finger's event follows with the next change.) Each event goes out
in a history packet of its own (takion.md).

### 10.3 Feedback-state body (sticks and motion)

25 bytes (PS4, Takion 9) or 28 bytes (PS5, Takion 12). **Note the mixed byte order.**

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `a0` |
| 1 | 2 | gyro X, **little-endian** `U16(g, 30)` |
| 3 | 2 | gyro Y, LE `U16(g, 30)` |
| 5 | 2 | gyro Z, LE `U16(g, 30)` |
| 7 | 2 | accel X, LE `U16(a, 5)` |
| 9 | 2 | accel Y, LE `U16(a, 5)` |
| 11 | 2 | accel Z, LE `U16(a, 5)` |
| 13 | 4 | orientation, **little-endian** uint32 `Q(q)` (§10.4) |
| 17 | 2 | left stick X, **big-endian** int16 (two's complement) |
| 19 | 2 | left stick Y, BE int16 |
| 21 | 2 | right stick X, BE int16 |
| 23 | 2 | right stick Y, BE int16 |
| 25 | 3 | PS5 only: `00 00 01` |

```
U16(v, R) = trunc( 65535 × (v + R) / (2R) )        computed in IEEE single precision,
                                                   v clamped to [−R, R] first (see note)
```

- Gyro: `R = 30` rad/s. Accelerometer: `R = 5` g. So 0 rad/s → `7fff` (bytes `ff 7f`), 1 g → `U16(1,5)` =
  `9999` (bytes `99 99`).
- Note: existing clients don't clamp, and out-of-range values then wrap or are undefined. Clamping is the safe
  reading.
- Sticks are sent only here, buttons and triggers only in history events.

When to send (client choices, observed): a state packet whenever sticks or motion values change, and at
least every 200 ms otherwise.

### 10.4 Orientation quaternion compression `Q(q)`

Input `q = (q0, q1, q2, q3) = (x, y, z, w)`, a unit quaternion.

1. `L` = index of the component with the largest absolute value (the first such index on a tie).
2. Bit 0 = 1 if `q_L < 0`, else 0. Bits 1..2 = `L`.
3. The other three components, in index order skipping `L`, are `c_0, c_1, c_2`. For each `j`:
   `v = clamp(c_j, −1/√2, 1/√2)`, `u_j = trunc( (v + 1/√2) × 511 / √2 )` (9 bits, 0..511), stored at bits
   `3 + 9j .. 11 + 9j`.
4. Bits 30..31 are 0.

`Q(identity (0, 0, 0, 1))`: `L = 3`, sign 0, three components 0 → `u = trunc(255.5) = 255` each →
`0x1feff7fe`, sent as bytes `fe f7 ef 1f`.

Precision: existing clients do this in single precision (`v` and the products are rounded to IEEE float after
each step; the constant `511 / √2` is double). Values that land within ~1e-5 of an integer step can come out one
step apart in other arithmetic; that is harmless, but byte-exact tests should avoid such inputs.

The largest component isn't sent; a receiver rebuilds it as `±sqrt(1 − c_0² − c_1² − c_2²)` with the sign from
bit 0 (this is the "smallest three" scheme, e.g. https://github.com/jpreiss/quatcompress).

### 10.5 Where the orientation comes from (client side)

The console takes the orientation as given; how the client estimates it is the client's choice. For
reference, what existing clients do (PlayFX included):

- Axes: the controller's own sensor axes as reported by the pad, with gravity reading `(0, +1, 0)` g when the
  pad rests flat (the idle values of §10.1). PlayFX feeds macOS GameController's rotation rate (rad/s) and
  gravity + user acceleration (g) unchanged; whether every axis sign matches what the console expects is
  unverified (§14).
- Estimator: Madgwick's IMU (gyro + accelerometer) gradient-descent filter (S. Madgwick, "An efficient
  orientation filter for inertial and inertial/magnetic sensor arrays", 2010), run in a frame rotated by +90°
  about X. Its state starts at `r = (w, x, y, z) = (cos 45°, sin 45°, 0, 0)`; the sent quaternion is
  `p ⊗ r` with `p = (cos(−45°), sin(−45°), 0, 0)` (a −90° rotation about X), so the first sent value is the
  identity.
- Gain β = 20 for the first 29 updates, 0.05 afterwards. Time step from the samples' microsecond time stamps
  (a 32-bit counter that may wrap); the very first sample only sets the time.
- A per-component smoothing on the filter output, with `f = 0.0007` and `d = |new − old|`: `d < f/2` keep the
  old value; `d < f` old ← 0.75·old + 0.25·new; `d < 2f` old ← 0.6·old + 0.4·new; else old ← new.
- When the console sends a motion reset (§9.8) the client should take the current orientation as the new
  origin.

---

## 11. End of the stream and end reasons

### 11.1 Ending it

**Client ends the stream**: send a Disconnect on channel 1 with reason `Client Disconnecting`
(`08 08 52 16 0a 14 436c69656e7420446973636f6e6e656374696e67`), then close the Takion connection right away
(no wait for an acknowledgement or answer), then close ctrl (`ctrl.md` §9). The client sends the same
Disconnect when a handshake step fails after the Hello was sent.

**Console ends the stream**: a Disconnect wrapper from the console, with `reason` text (existing clients keep
up to 255 bytes). Known reason texts:

| Reason text | Meaning |
|---|---|
| `Server shutting down` | The console is going into rest mode or shutting down Remote Play. Also seen when the keyboard was enabled on a PS5 (`ctrl.md` §6.5) |
| anything else | The console ended the stream on purpose (e.g. another device took over); show the text |

The client then sends its own Disconnect and closes as above.

**Lost connection**: Takion-level failure or silence (takion.md), or the ctrl connection dropping
(`ctrl.md` §9), without a Disconnect.

### 11.2 End reasons (client side, not on the wire)

The wire carries only the Disconnect text. The numbers below are PlayFX's end-reason codes (shown to the user
with a message, and used for the retry policy). They continue `session.md` §10's names.

| Code | Name (session.md §10) | When | Error? | Retry class |
|---:|---|---|---|---|
| 0 | `unknown` | No reason recorded | yes | final |
| 1 | `stoppedByClient` | The app stopped the session, or the stream ended normally | no | stopped |
| 2 | `sessionInitUnknown` | Session init failed without a specific reason | yes | final |
| 3 | `sessionInitRefused` | TCP refused on 9295 at session init | yes | final |
| 4 | `consoleBusy` | `RP-Application-Reason` `80108b10` | yes | busy (retry soon) |
| 5 | `remotePlayCrashed` | `80108b15` | yes | final |
| 6 | `versionMismatch` | Version negotiation failed | yes | final |
| 7 | `ctrlFailed` | Ctrl failed or was lost, no session ID, PIN after session ID | yes | dropped (reconnect) |
| 8 | `ctrlConnectFailed` | Ctrl TCP connect failed | yes | final |
| 9 | `ctrlRefused` | Ctrl TCP connect refused | yes | final |
| 10 | `streamFailed` | Any stream-stage failure without a console Disconnect: probe/Takion/handshake failure, timeouts, bad HelloReply, lost Takion | yes | dropped (reconnect) |
| 11 | `streamRemoteDisconnected` | Console Disconnect with any reason other than `Server shutting down`; show the reason text | yes | final |
| 12 | `streamRemoteShutdown` | Console Disconnect `Server shutting down` | no | final |
| 13 | `psnRegistrationFailed` | (PSN path) registration refused | yes | final |
| 14 | `psnRegistrationUnanswered` | (PSN path) the console never answered the registration | yes | final |

Retry classes are PlayFX's: final = don't retry automatically; busy = retry after a few seconds (the console
stays busy about 9 s after a session); dropped = worth reconnecting; stopped = nothing to do.

---

## 12. Timing summary

All client choices (observed) unless marked.

| What | Value |
|---|---|
| Probe Takion connect | 30 s |
| Probe version ack, probe HelloReply | 5 s each |
| Probe echo-command acknowledgements | 5 s each |
| Probe pings | 10, up to 1 s each, sequential |
| MTU attempt wait | `clamp(5 × rtt, 5 ms, 500 ms)`, up to 3 attempts per size, bisection 576..1454 |
| Probe client-MTU answer | 5 s |
| Probe fallback | mtuIn = mtuOut = 1454, rtt 1 ms |
| Stream Takion connect | 5 s |
| HelloReply after Hello | 5 s |
| StreamInfo after HelloReply | 5 s |
| Stream Heartbeat | every 1 s |
| Feedback state | on change, and at least every 200 ms |
| Feedback history | per event; resend schedule in takion.md |
| IDR re-request while waiting for an I-frame | at most every 1 s |
| Ctrl heartbeat replies | must continue throughout (console ends the session after ~30 s without, `ctrl.md` §7) |
| After client Disconnect | close at once |

---

## 13. Observed on a real console (PlayFX, through the reference library, PS5)

Not new captures; facts already recorded in `PLAN.md`:

- Rumble levels (§9.6), trigger effects with modes `0x25`/`0x26` (§9.7), the haptics stream at 3 kHz stereo
  (§9.9) and light-bar colours (§9.8, e.g. `ff74a6`) all arrived and were applied on a DualSense in a game
  (2026-11-19/20).
- A haptics effect ends with packets stopping, not with silence.
- Enabling the ctrl keyboard on a PS5 ends the stream with `Server shutting down`.
- The microphone path (§9.10) was exercised (capture, encode, send, the stream stays clean); hearing it on the
  console wasn't checked.

## 14. Open questions

1. Whether the console's HelloReply signature is HMAC-SHA256(`streamHandshakeKey`, console public key), and
   whether a client should reject a mismatch. Existing clients don't check it.
2. Meaning of HelloReply `serverVersion`, `token` and `sessionKey`, and of Hello `encryptedKey` (always 4 zero
   bytes).
3. Which channels the console uses for its messages, and whether it cares which channel the client uses.
4. Whether the console sends its own heartbeats on the stream connection, and its stream-level timeout if the
   client's stop.
5. Which launch-spec keys the console reads (only resolution, fps, bitrate, codec, range and the handshake key
   are known to matter), and whether `adaptiveStreamMode` works on PS4 (an existing client's note suggests
   maybe for newer PS4 versions).
6. Unit of ConnectionQuality `targetBitrate` (kbit/s or bit/s) and `rtt`; the meaning of
   `disableUpstreamAudio`.
7. Pad-info: when the 17-byte vs 25-byte form is sent; the unknown bytes; the time stamp's unit.
8. Rumble byte 0 and trigger-effect bytes 0, 3 and 4.
9. Microphone: the header says 1 channel while PlayFX encodes 2-channel Opus; whether the console prefers mono.
   Also the exact meaning of the unit word and the frame-order `[N, N−2, N−1]` (taken as is from existing
   clients, which work).
10. The motion axes and signs the console expects relative to macOS GameController's (unverified on hardware).
11. The console's split of long messages to the client (takion.md). The client's split Hello (§2.3) is what
    existing clients send on every PS5 LAN session, so the console accepts at least the 1378 + 31 form.
12. Whether `CorruptFrame` from the console means anything.
13. Haptics PCM byte order (little-endian assumed from working playback).

---

## 15. Known-answer vectors

Made-up keys only. Markers:

- **[I]**: computed by an independent Python script written from this document's text (session scratchpad,
  not in the repo).
- **[C]**: the same bytes came out of a C harness built in the scratchpad against the reference library's own
  sources (its message builders and parsers, launch-spec formatter, ECDH, feedback formatter, quaternion
  compression, mic packet builder), with the Takion send functions replaced by capture stubs. Nothing was
  sent on a network.

Shared inputs (from `session.md` §14 and `ctrl.md` §12):

| Name | Value |
|---|---|
| `sessionAesKey` / `sessionIvSeed` PS5 1.0 | `598fa9a031d01820db25cab6e90bb19b` / `ac7d50f394ea6588f0488f76e4170c8a` |
| `sessionAesKey` / `sessionIvSeed` PS4 10.0 | `f7e760687cea0ce70c1c129f67c087c8` / `e978b89a1098296fb32415b9b5713be0` |
| `sessionId` | 74 characters: `A`–`Z`, `a`–`z`, `0`–`9`, then `ABCDEFGHIJKL` (ctrl.md V-C7) |
| `streamHandshakeKey` | `404142434445464748494a4b4c4d4e4f` (base64 `QEFCQ0RFRkdISUpLTE1OTw==`) |
| client private key A, console private key B | `session.md` Vector A-1 |
| probe results | `mtuIn = mtuOut = 1454`, `rtt = 1000 µs` (→ `{RTT}` = 1) |

### V-ST1. ECDH and signatures [I][C]

| Value | Hex |
|---|---|
| client public key A | `0484bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b08cc43d63b2859d469fee15f31c9edb5324266e6fd0407e87382d60fc4511acd8` |
| client signature = HMAC-SHA256(handshake key, A) | `2fe2ebd67dac0d482eec54294c0e5df4408fbbce5404ded3215798fac833e53c` |
| console public key B | `04a36b48691898f4c058cd18442495b9202f859f28c9400190be3b04f5f0655c94d0b245e8ed621cdb21d24fc8b6db2309fa38dcd8b1da0c5b11786e04fc66a526` |
| console signature (same rule, made up) | `f1cdeeb1a7b99337b684d4462b7fce83b07eb77a2bbc24d4327a0d992cf8bccc` [I] |
| `ecdhSecret` | `0c1fbe7f56ae330d92c6b86cd82e0879addd6822fe20f2419176352093908297` |

[C]: the reference library, loaded with private key A, produced the same public key and signature inside the
Hello (V-ST4), and derived the same secret when fed the HelloReply of V-ST5.

### V-ST2. Launch spec, PS5 1.0, 1080p, 60 fps, 15000 kbit/s, H.265 SDR [I][C]

JSON (911 characters; then one `00` byte, 912 bytes encrypted):

```
{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":1920,"height":1080},"maxFps":60,"score":10}],"network":{"bwKbpsSent":15000,"bwLoss":0.001000,"mtu":1454,"rtt":1,"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1","adaptiveStreamMode": "resize"},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},"videoCodec":"hevc","dynamicRange":"SDR","handshakeKey":"QEFCQ0RFRkdISUpLTE1OTw=="}
```

- SHA-256 of the 912 plaintext bytes (JSON + `00`): `c06eab387caf8716f15376fd51658aff59c5cafc9e7f957b2e47384845b13b7c`.
- Encrypted (PS5 session keys, counter 0, keystream form), first 32 bytes:
  `49ce25f347ff5c4ef1016cda812c2a8f773af48d1037bf5a6da554360de16d0b`; SHA-256 of all 912 encrypted bytes:
  `527d0e8e65b7cd238c50de738da8909f452b050ca89d3f2182ddc4b2a849d9f5`.
- Base64 text: 1216 characters, starting `Sc4l80f/XE7xAWzagSwqj3c69I0QN79abaVUNg3hbQt9dx1g+xV6yvfIL7BqtP6K` and ending
  `vVe8wrnOWkaLMbWeuGsl5cDi2/7cXp+JTpfvkOukOZaLFwOucoYbNvNNPzc6ad+H`. The full text is inside V-ST4's Hello.
- The same settings with H.265 HDR differ only in `"dynamicRange":"HDR"` [I][C].

[C]: the reference formatter produced the identical JSON for these settings, and its Hello carried the
identical base64 text.

### V-ST3. Launch spec, PS4 10.0, 720p, 60 fps, 10000 kbit/s, H.264 [I][C]

JSON (838 characters, no PS5 keys):

```
{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":1280,"height":720},"maxFps":60,"score":10}],"network":{"bwKbpsSent":10000,"bwLoss":0.001000,"mtu":1454,"rtt":1,"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1"},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},"handshakeKey":"QEFCQ0RFRkdISUpLTE1OTw=="}
```

Base64 of the encrypted 839 bytes (PS4 10.0 session keys), 1120 characters:

```
fKGj+lq5/XUOISpFnVaZvO626XHSDF3/iZcPRLiJXvRoZL2XP++LRvefGQL5KXTdDWETnEdzp5n9kkSZt7xA/Zalfm6Mlvr4gd2iQUFwsDb9
ZnHI3R2uy1FPnh4LGHsNF+Tw8Bf5Y36Rf3IsL8Lf72uf4iufVz9oFqYZ+Eoz5oSRb9/DhWNt8jQpy3WncfvedofzuYymd4n5/gPrLxLT8rzf
wC3wDM2UZDY5qmSMP3oef0miB++2rioPCg7rDxlmqEtUFjY9ASwGeCGV9glMTJ/JOvT2mPt51PfnVyqoG/qpy0Bi+5WxqSwGTfHlysXT0SEf
nDHK7ygYXp4r01zN26WJei9MeRtCDLBQqLf3SGGcxWjS42qI9+l6TQZYm5LrbdWdsNsT6ssNXN3g79LfLxZ70VgTf2PqcXGDRtlEQ1+pWJrT
2QckK/r36djHuVm6oAEwmCRE+3ALzaW4JzuRvaymQfaYNChwRdLnp/I2EbHDpxfKFstd+auG6VmU6SbnVQenAenKIn5hEQJeJO3NoVBb/hpc
PKJ3fPU3bdRUDePitKkVLDMCCXdZRqrzTuHY4OfmYnNesWk04aW7MzILzIM0NBVHI/WdFBSJY0B8vjTMWKmLcxH7IqCH/qoPDTL49UbPV31D
DCSat4EF5ikjXI70VQUIdMA5dqmkfd+1pn1G7e53/OF2xG0L8IZg9kRLF0BKg++72pSHK0Xr9UcRRS4duZ80KUukA3bJgbEK3R2wxKR/QZED
zZ/doTXlfTc1OiMXoiezMvmOFbYg+zr7nZHUzzv3XddDM3L12r3PVXLdB1if2FoCMhZTYIZ+vPMzoMhZs2awPL4E2Nr+EDg8/fsqCZ7PwMC6
qZ8pSnZq3jQMtLzGJxYcuRXbnzPeMTNePzEeU+KkT32aHZZJUyaSxtxkIDxUyQsXOyNkNdT3IRIi8Znaudij0m03KwkrEB5mHYzqe+4k6sPp
GP8zlI/hmO1zoQErpDrbgioIh4YWUe+55QigiuZJbYwPyRM8rlFexP2KyYLMkyVcx8Kps8uVmIUSggdtmFI60/APuMkEYMmtcJ2omJRiMAhp
L14mAtHPCvqqeHMrnpRwdr5ORMovFCT6mzntiMw=
```

(line breaks are layout only). [C]: the reference library's PS4 10.0 Hello (`clientVersion` 9, 1313 bytes, one
unsplit message) was byte-identical to one built by the script from this text, the same keys and V-ST1.

### V-ST4. Hello, PS5 1.0 [I][C]

The wrapper built from the shared inputs, V-ST1 and V-ST2 is **1409 bytes**, SHA-256
`01a67a5af27f022fa63a6e91cc0c96202ec509e4cff85c9d029820e1c2ad308c`; full hex in
[`data/vectors/stream-hello-ps5-1.hex`](data/vectors/stream-hello-ps5-1.hex) (32 bytes per line). It starts

```
08 00 12 fc0a                      type 0, payload field 2, length 1404
08 0c                              clientVersion 12
12 4a 4142…4b4c                    sessionKey, 74 bytes
1a c009 5363346c…                  launchSpec, 1216 bytes of base64 text
```

and ends `22 04 00000000  2a 41 <public key A>  32 20 <signature A>`.

Split (§2.3), `mtuIn = mtuOut = 1454`: piece 1 = bytes 0..1377 (1378 bytes, ordinary data message, chunk
flags 0, channel 1), piece 2 = bytes 1378..1408 (31 bytes, continuation, chunk flags 1). With `mtuIn = 1200`,
`mtuOut = 1300` (so the launch spec says `"mtu":1200`): 1124 + 285 bytes. [C]: the reference library emitted
exactly these pieces, flags and channel in both cases.

Probe Hello (§5.3): `08001208080912001a002200` [I][C].

### V-ST5. HelloReply decoded [I][C]

Built by the script from §4.1 (`serverVersion` 12, `token` 0x12345678, both accepted flags true, empty
`sessionKey`, console key B and signature B):

```
0801 1a73 080c 10f8acd19101 1801 2001 2a00
4241 04a36b48691898f4c058cd18442495b9202f859f28c9400190be3b04f5f0655c94d0b245e8ed621cdb21d24fc8b6db2309fa38dcd8b1da0c5b11786e04fc66a526
4a20 f1cdeeb1a7b99337b684d4462b7fce83b07eb77a2bbc24d4327a0d992cf8bccc
```

[C]: the reference library's handler accepted it, derived `ecdhSecret` =
`0c1fbe7f…93908297` (V-ST1) and installed both GKCrypt instances. With `versionAccepted` = 0 (`2000` in place of
`2001`) it rejected the reply.

### V-ST6. StreamInfo from the console decoded [I][C]

```
080d 7a35
  0a11 08800f 10b808 1a09 000000014201010160      profile 0: 1920 × 1080, 9-byte header
  0a10 08800a 10d005 1a08 0000000142010101        profile 1: 1280 × 720, 8-byte header
  120e 02 10 0000bb80 000001e0 00000001           audio header: 2 ch, 16 bit, 48000 Hz, 480, 1
```

(The video headers are dummies.) [C]: the reference library decoded two profiles with exactly these sizes and
headers, the audio header as 2 channels, 16 bits, 48000 Hz, frame size 480, unknown 1, and then sent, in
order: `080e` on channel 9, ControllerConnection on channel 1, and `080d7a10120e01100000bb80000001e000000001`
(the mic StreamInfo) on channel 1.

### V-ST7. Small client messages [I][C]

| Message | Channel | Bytes |
|---|---:|---|
| Heartbeat | 1 | `0803` |
| StreamInfoAck | 9 | `080e` |
| IdrRequest | 2 | `0819` |
| CorruptFrame {100, 105} | 2 | `0805320408641069` |
| ControllerConnection DualSense | 1 | `0815b2010410011806` |
| ControllerConnection DualShock 4 | 1 | `0815b2010410011802` |
| Mic StreamInfo | 1 | `080d7a10120e01100000bb80000001e000000001` |
| Disconnect "Client Disconnecting" | 1 | `080852160a14436c69656e7420446973636f6e6e656374696e67` |
| Probe: TransportVersionRequest [9] | 1 | `081ffa01020809` |
| Probe: echo on | 8 | `080c7206080012020801` |
| Probe: echo off | 8 | `080c7206080012020800` |
| Probe: MTU {id 1, 1454} | 8 | `080c720908011a05080110ae0b` |
| Probe: client MTU {id 1, 1454, active, down 1454} | 8 | `080c720e08042a0a080110ae0b180120ae0b` |
| Probe: client MTU {id 2, 1454, inactive, down 1454} | 8 | `080c720e08042a0a080210ae0b180020ae0b` |

All with chunk flags 1. [C]: each came out of the reference library's own message builders.

Probe ping `i = 3`, `tag = 0xdeadbeef`, first 26 of 548 bytes [I][C, the library's version-7 AV header writer]:
`0300000000007ffc00ff000000000000000000000000deadbeef`.

### V-ST8. Console bodies with raw data types, decoded [I][C]

| Data type | Body | Decoded by the reference library |
|---:|---|---|
| 0 | `080852160a14536572766572207368757474696e6720646f776e` | Disconnect, reason `Server shutting down` (remote shutdown) |
| 7 | `008040` | rumble: left 128, right 64 |
| 11 | `00 25 26 0000 0102030405060708090a 1112131415161718191a` | left mode 0x25, params `01..0a`; right mode 0x26, params `11..1a` |
| 9 | `0102 0000 00000007 01 ff74a6 01 00000000000000 02 03 000000` (25 bytes) | player index 1, colour `ff74a6`, motion reset, haptics intensity 2 (medium), trigger intensity 3 (weak) |
| 9 | `02 0000ff 00 00000000000000 03 00 000000` (17 bytes) | player index 2, colour `0000ff`, no reset, haptics 3 (weak), triggers 0 (off) |

### V-ST9. Feedback-state bodies [I][C]

| Input | Body |
|---|---|
| Idle (§10.1), PS5 | `a0 ff7f ff7f ff7f ff7f 9999 ff7f fef7ef1f 0000 0000 0000 0000 000001` |
| gyro (0.5, −1.25, 3.0) rad/s; accel (0.1, 0.95, −0.2) g; orientation (x, y, z, w) = (0.1025978, −0.2051957, 0.3077935, 0.9233805) (float32 of (0.1, −0.2, 0.3, 0.9) normalised); sticks (12345, −32768, 32767, −100); PS5 | `a0 2182 aa7a cc8c 8e82 5198 e07a 2659cb2d 3039 8000 7fff ff9c 000001` |
| same, PS4 | the same without the last 3 bytes |

`Q((0, −0.8, 0.6, 0))` = `0x1ffd87fb` (largest |·| is y, negative) [I][C].

### V-ST10. History events [I][C]

| Event | Bytes |
|---|---|
| Cross pressed / released | `8088ff` / `808800` |
| R3 pressed / released | `80b0` / `8090` |
| L2 at 128 | `808680` |
| Touch down/move, id 5, (1000, 500) | `d0053e81f4` |
| Touch lifted, id 127, (1919, 1079) | `c07f77f437` |

The full code tables of §10.2 were produced by the reference library for all 16 buttons and both triggers and
match.

### V-ST11. Microphone packets [I][C]

Opus frames `F0 = 10×40`, `F1 = 11×40`, `F2 = 12×40` (40 bytes each of `10`, `11`, `12`; real frames are
Opus). Before encryption, the GMAC and key-position fields zero:

| Packet | Header | Payload order |
|---|---|---|
| PS5, first | `03 0000 0001 00022821 05 00000000 00000000 00 00` (20 bytes) | F0, F0, F0 |
| PS5, second | `03 0001 0002 00022821 05 …` | F1, F0, F0 |
| PS5, third | `03 0002 0003 00022821 05 …` | F2, F0, F1 |
| PS4, third | `03 0002 0003 00022821 05 00000000 00000000 00` (19 bytes) | F2, F0, F1 |

Sizes 140 (PS5) and 139 (PS4). A 39-byte frame produced no packet. [C]: the reference packet builder, with the
encrypting send replaced by a capture.

### Not vectored

The Madgwick estimator (§10.5) is a client choice and float-sensitive; only its starting point is checked:
the first sent orientation is exactly (0, 0, 0, 1) [C]. The network probe's timing and bisection (§5.5) and the
heartbeat/feedback cadences are behaviour, not bytes. GKCrypt keys from V-ST1's secret belong to takion.md.

---

## Sources

- chiaki-ng (AGPL-3.0), read for facts only, at the submodule commit this repository records; verification
  through a C harness run against its sources as a black box (§15).
- PlayFX's own shim and notes: `packages/streamcore/Sources/CChiaki/include/psrp.h` (events and commands the
  app needs), `PLAN.md` (hardware observations in §13).
- Protobuf encoding: https://protobuf.dev/programming-guides/encoding/.
- secp256k1: SEC 2 v2, https://www.secg.org/sec2-v2.pdf. HMAC: RFC 2104; SHA-256: FIPS 180-4.
- Opus: RFC 6716.
- Madgwick, S. (2010), "An efficient orientation filter for inertial and inertial/magnetic sensor arrays",
  University of Bristol report (public).
- Smallest-three quaternion compression: https://github.com/jpreiss/quatcompress (public).
