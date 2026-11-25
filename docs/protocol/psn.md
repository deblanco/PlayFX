# PSN: the web APIs behind internet play

Status: draft 1 (clean-room spec, facts only). Describes what the reference client sends to and reads from
PlayStation Network to list consoles and to set up an internet Remote Play session. PSN's own API
documentation is not public; field meanings beyond what the client uses are unknown and marked so.

Internet play needs PSN for three things:

1. **Finding the console:** the account's consoles and their PSN device IDs (§4).
2. **A rendezvous:** a "remote play session" on PSN's session manager that the client creates and the
   console is asked to join (§6), with a push-notification WebSocket on which PSN tells the client what
   happens in it (§5).
3. **Signalling:** session messages relayed between the client and the console, which carry the
   hole-punching candidates (§7, holepunch.md).

After that, the console and the client talk directly (holepunch.md, rudp.md). PSN carries no Remote Play
data.

Related: holepunch.md, rudp.md, registration.md §8 (registration through PSN, which uses `data1`, `data2`
and `customData1` from here), rpcrypt.md §7. Conventions as in README.md. All tokens, IDs and addresses here
are made up.

---

## 1. Hosts and common HTTP rules

| Host | Used for |
|---|---|
| `web.np.playstation.com` | device list, session manager, start command (`/api/...`) |
| `mobile-pushcl.np.communication.playstation.net` | the push server's address (§5.1) |
| `<fqdn from §5.1>` | the push WebSocket (§5.2) |
| `asm.np.community.playstation.net` | PS4 only: the user-profile base URL (§6.4) |
| `auth.api.sonyentertainmentnetwork.com` | OAuth (§2; already implemented in PlayFX's `PSNAuth.swift`) |

- HTTPS everywhere, normal certificate checks.
- Every request carries `Authorization: Bearer <access token>`.
- Request bodies are JSON sent with `Content-Type: application/json; charset=utf-8` (exceptions noted).
- The reference treats any HTTP status of 400 or more, or a transport error, as failure of that step and
  doesn't read error bodies (§9). The device list must answer exactly 200; elsewhere any status below 400
  counts as success (and a body that isn't the expected JSON then fails the step).
- Each request has its own timeout (§10).
- **Byte-exact JSON.** The reference writes every request body as text from fixed templates, not with a JSON
  library. Values are inserted as they are: base64 values keep `/` and `+` unescaped (never `\/`), and
  nothing else is escaped. The only escaping is the `\"` of a JSON text nested inside a string
  (`initialParams` in §6.3, the message in §7.1's `payload`). No whitespace is added except where a
  template shows it (`"roomId": 0` in §6.4, `"adaptiveStreamMode": "resize"` is the launch spec's, not
  PSN's). The vectors of §12 are byte-exact under these rules. Whether PSN would also accept other valid
  JSON spellings (`\/`, other key orders, spaces) is unknown (§11).

---

## 2. Access token requirements

The access token is an ordinary PSN OAuth access token (authorization-code grant, refreshed with the
refresh token). PlayFX already obtains and refreshes it (`PSNAuth.swift`, `PSNAccount.swift`). For internet
play it must satisfy all of these (as the reference documents them):

- **Scopes:** `psn:clientapp`, `referenceDataService:countryConfig.read`,
  `pushNotification:webSocket.desktop.connect`, `sessionManager:remotePlaySession.system.update`.
  (The device list needs `psn:clientapp`.)
- **Created with a client device ID:** the authorization request carried a `duid` parameter (§3.1). PlayFX
  makes a new one for each sign-in. A token without it isn't accepted for session setup (as the reference
  states; the failure's form isn't recorded).
- **Fresh:** the reference refreshes it shortly before use; PlayFX refreshes a minute before expiry and
  retries the device list once with a forced refresh when PSN rejects the token (PlayFX choice).

The account ID of the token's user (PlayFX: `user_id` from the token-info endpoint) is the one the console
must know (registration.md §1); PSN also returns it in §6.1.

---

## 3. Identifiers

### 3.1 The client's device ID

48 lowercase hex characters: the fixed prefix `0000000700410080` followed by 16 random bytes in hex. Used
only as the `duid` of the OAuth authorization request (§2). Example: `0000000700410080` +
`0f1e2d3c4b5a69788796a5b4c3d2e1f0`.

### 3.2 The console's device ID ("DUID")

**64 lowercase hex characters = 32 bytes**, as listed by §4 (`duid`) and as the console's `deviceUniqueId`
in session notifications (§6.3). The client stores it as text and sends it as text (lowercase); the reference
converts it to 32 bytes and back. Nothing about its inner structure is known.

### 3.3 Session IDs

- `sessionId`: a 36-character UUID string chosen by PSN (§6.1), e.g. `2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c`.
- `pushContextId`: a UUID (version 4, lowercase, 36 characters) the client makes up for each session
  (§6.1). The reference uses a weak random generator for it; any random UUIDv4 works.

### 3.4 `data1`, `data2`, `customData1`

| Name | Size | Made by | Sent / received |
|---|---|---|---|
| `data1` | 16 bytes | client, cryptographically random, once per PSN session | base64 in the start command (§6.3, §6.4) |
| `data2` | 16 bytes | client, as above | same |
| `customData1` | 16 bytes | console | received in a notification, double base64 (§6.5) |

They key the registration through PSN (registration.md §8, rpcrypt.md §7: `D1`, `D2`, `CD`).

---

## 4. Listing the account's consoles

```
GET https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients?platform=PS5&includeFields=device&limit=10&offset=0
Accept-Language: jp
Authorization: Bearer <token>
```

- `platform=PS5`: the reference lists PS5s only (it refuses to list PS4s; a PS4 is reached differently,
  §6.4). Whether `platform=PS4` works here is unknown.
- `limit=10&offset=0`: the reference asks for one page of 10 and doesn't page further.
- `Accept-Language: jp` is what the reference sends; its effect is unknown.
- Timeout 5 s (client choice). Success = HTTP 200.

Response (only the fields the client reads; real responses contain more):

```json
{
  "clients": [
    {
      "duid": "e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee",
      "device": {
        "name": "PS5-TEST",
        "enabledFeatures": ["remotePlay"]
      }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `clients` | array, one entry per console |
| `clients[].duid` | the console's DUID (§3.2) |
| `clients[].device.name` | the console's name (its nickname as set on the console; PlayFX matches it with the paired console's nickname) |
| `clients[].device.enabledFeatures` | array of strings; contains `"remotePlay"` when Remote Play is enabled on the console |

The reference fails the whole list when an entry lacks `duid`, `device`, `device.enabledFeatures` or
`device.name` (client choice; skipping such an entry is friendlier). Whether consoles that are switched
off are listed isn't recorded; whether a console can be reached shows only at §6.3.

---

## 5. The push-notification channel

PSN reports everything that happens in the session (members joining, the console's data, session
messages) as push notifications over a WebSocket. It must be open **before** the session is created
(§6.1 names it by its `pushContextId`), and stay open until the session is left (§8).

### 5.1 The push server's address

```
GET https://mobile-pushcl.np.communication.playstation.net/np/serveraddr?version=2.1&fields=keepAliveStatus&keepAliveStatusType=3
Authorization: Bearer <token>
```

Response: `{"fqdn": "<host name>"}` (other fields ignored). Timeout 10 s (client choice).

### 5.2 Opening the WebSocket

`wss://<fqdn>/np/pushNotification`, a standard WebSocket (RFC 6455) upgrade with these request headers, as
the reference sends them:

```
Authorization: Bearer <token>
Sec-WebSocket-Protocol: np-pushpacket
User-Agent: WebSocket++/0.8.2
X-PSN-APP-TYPE: REMOTE_PLAY
X-PSN-APP-VER: RemotePlay/1.0
X-PSN-KEEP-ALIVE-STATUS-TYPE: 3
X-PSN-OS-VER: Windows/10.0
X-PSN-PROTOCOL-VERSION: 2.1
X-PSN-RECONNECTION: false
```

(plus the usual `Host`, `Upgrade`, `Connection`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`).
Connect timeout 30 s, and the session isn't created until the WebSocket is open, waiting up to 30 s (client
choices). Which of the `X-PSN-*` headers the server requires is unknown; send all of them.

### 5.3 Keeping it open (client choice, observed)

- The client sends a WebSocket **ping** (empty payload) every 5 s; if no **pong** has come 5 s after a ping,
  it treats the channel as dead.
- It answers every ping from the server with a pong carrying the same payload.
- A close frame, a receive error or a dead channel ends the notifications. During setup the step waiting
  for one then times out (30 s); a session that is already streaming isn't affected. The reference skips
  the DELETE of §8 when the WebSocket is no longer open at the end (client choice; sending it anyway is
  harmless).

### 5.4 Notifications

Each text or binary frame carries one JSON object. The client dispatches on `dataType`:

| `dataType` | Meaning | Fields the client reads (JSON pointers) |
|---|---|---|
| `psn:sessionManager:sys:remotePlaySession:created` | the session exists | `/to/onlineId` (string): the user's online ID (needed for PS4, §6.4) |
| `psn:sessionManager:sys:rps:members:created` | a member joined (first the client itself, later the console) | `/body/data/members/0/deviceUniqueId` (string) |
| `psn:sessionManager:sys:rps:customData1:updated` | the console set its data | `/body/data/customData1` (string, 32 characters) |
| `psn:sessionManager:sys:rps:sessionMessage:created` | a session message arrived (§7) | `/body/data/sessionMessage/payload` (string) |
| `psn:sessionManager:sys:rps:members:deleted` | a member left | – |
| `psn:sessionManager:sys:remotePlaySession:deleted` | the session ended | `/body/data/sessionId` (string) |

**Which `members:created` is which (client choice, observed).** The reference never reads the content of
the client's own `members:created`: during the create step (§6.1) it takes the first `members:created` to
arrive as "the client joined", whatever it says. What PSN puts in the client's own notification (its device
ID, `"me"`, or something else) is not recorded (§11). The console's is the first `members:created` the
reference takes **after** the create step, i.e. after the start command; it must carry the console's DUID at
`/body/data/members/0/deviceUniqueId`, and a different value fails the start (PS5) instead of being skipped.
A sturdier rule, compatible with everything known: treat a `members:created` as the console's only when that
field equals the console's DUID, and ignore any other.

Other `dataType` values are ignored. Frames that aren't JSON are ignored. Notifications can arrive before
the step that wants them is reached (for example the console's first OFFER during the start step): the
reference keeps every notification in arrival order and each step takes the first one of the type it waits
for (client choice; an implementation must buffer them too).

A `remotePlaySession:deleted` whose `/body/data/sessionId` is another session's is ignored; one for this
session (or without an ID) means the session is gone, and the reference stops reading notifications (a
step still waiting then times out).

Illustrative frames (only the fields above are known; the rest of the shape is a guess):

```json
{"dataType":"psn:sessionManager:sys:remotePlaySession:created","to":{"onlineId":"playfx-tester"},"body":{"data":{"sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c"}}}
{"dataType":"psn:sessionManager:sys:rps:members:created","body":{"data":{"members":[{"deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee"}]}}}
{"dataType":"psn:sessionManager:sys:rps:customData1:updated","body":{"data":{"customData1":"TURFeU16UTFOamM0T1RvN1BEMCtQdz09"}}}
```

---

## 6. The session

### 6.1 Create

Sent once the WebSocket is open.

```
POST https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8

{"remotePlaySessions":[{"members":[{"accountId":"me","deviceUniqueId":"me","platform":"me","pushContexts":[{"pushContextId":"<pushContextId>"}]}]}]}
```

The literal `"me"` values are what the reference sends. Timeout 10 s.

Response (fields read):

```json
{"remotePlaySessions":[{"sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c","members":[{"accountId":"1234567890123456789"}]}]}
```

| Pointer | Use |
|---|---|
| `/remotePlaySessions/0/sessionId` | must be a 36-character string; the session's ID from now on |
| `/remotePlaySessions/0/members/0/accountId` | the user's account ID, a string or a number; kept as an unsigned 64-bit integer (`accountId` below) |

Then wait (up to 30 s for each, client choice) for two notifications: `remotePlaySession:created` (keep
`/to/onlineId`) and `rps:members:created` (the client joined). Each may come first.

### 6.2 Inspect (optional)

The reference reads the session back after some steps, for its logs only:

```
GET https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions?view=v1.0     (or without ?view=v1.0)
Authorization: Bearer <token>
X-PSN-SESSION-MANAGER-SESSION-IDS: <sessionId>
```

Nothing in the answer is used. A client may skip it. `X-PSN-SESSION-MANAGER-SESSION-IDS` is sent on these
inspect requests **only**; the reference builds the header from the create response (§6.1) but no other
request carries it (not the start command, session messages or the DELETE).

### 6.3 Start (PS5): ask the console to join

```
POST https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/commands
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
User-Agent: RpNetHttpUtilImpl

{"commandDetail":{"commandType":"remotePlay","duid":"<console DUID>","messageDestination":"SQS","parameters":{"initialParams":"<initialParams>"},"platform":"PS5"}}
```

`initialParams` is a JSON object written as a **string** (so its quotes are escaped with `\` inside the
body):

```
{"accountId":<accountId as a JSON number>,"roomId":0,"sessionId":"<sessionId>","clientType":"Windows","data1":"<base64 data1>","data2":"<base64 data2>"}
```

Key order and the absence of spaces are as the reference writes them (vector P2 has the exact bytes).
Timeout 10 s. The response body isn't used.

Then wait (up to 30 s each, client choice) for:

1. `rps:members:created` whose `/body/data/members/0/deviceUniqueId` is 64 characters and equals the
   console's DUID (compared as bytes). A different DUID fails the start (client choice). This is the console
   joining (presumably after waking from rest mode if it was resting).
2. `rps:customData1:updated` with a 32-character `/body/data/customData1` (§6.5).

Either may come first. If the 30 s pass, the reference reports "host down" (likely causes: the console is
off, in rest mode without its internet connection kept, signed in with another account, or has Remote Play
off).

### 6.4 Start (PS4): wake the primary PS4

The reference reaches a PS4 only as the account's **primary** PS4, through a different call, and learns
its DUID from the members notification.

1. `GET https://asm.np.community.playstation.net/asm/v1/apps/me/baseUrls/userProfile` with headers
   `Authorization`, `Host: asm.np.community.playstation.net`, `Connection: Keep-Alive`,
   `Content-Type: application/json; charset=utf-8`, `User-Agent: RpNetHttpUtilImpl`. Response:
   `{"url": "<base URL>"}`.
2. `POST <base URL>/v1/users/<onlineId>/remoteConsole/wakeUp?platform=PS4` with the same headers except
   `Host: <host part of the base URL>`, body (exact text, note the space after `"roomId":`):

   ```
   {"data":{"clientType":"Windows","data1":"<base64 data1>","data2":"<base64 data2>","roomId": 0,"protocolVer":"10.0","sessionId":"<sessionId>"},"dataTypeSuffix":"remotePlay"}
   ```

   HTTP 404 here means the PS4 isn't the primary PS4 of this account or can't be reached.
3. Wait as in §6.3, but take the console's DUID from the members notification instead of comparing it.

`<onlineId>` is from §6.1's notification. Timeouts 10 s. This path is untested by PlayFX (PS5 only).

### 6.5 `customData1`

The 32-character value is **base64 of base64**: decoding it gives 24 ASCII characters, and decoding those
gives the 16-byte `customData1` (`CD` in rpcrypt.md §7). The reference accepts up to 4 extra bytes after the
16 and ignores them, and fails on fewer than 16 (client choice).

---

## 7. Session messages (signalling)

### 7.1 Sending

```
POST https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/<sessionId>/sessionMessage
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8

{"channel":"remote_play:1","payload":"ver=1.0, type=text, body=<message>","to":[{"accountId":"<accountId>","deviceUniqueId":"<console DUID>","platform":"PS5"}]}
```

- `<message>` is the JSON message of §7.2 written into the `payload` string, so its quotes appear as `\"`.
- `accountId` is the decimal account ID **as a string** here (a number in §6.3). The reference prints it
  signed, so an account ID above 2^63 − 1 would come out negative; send the unsigned decimal.
- `platform`: `PS5` or `PS4`.
- Timeout 10 s; the response body isn't used.

### 7.2 Message

```
{"action":"<ACTION>","reqId":<integer>,"error":<integer>,"connRequest":<connRequest>}
```

| Field | Values |
|---|---|
| `action` | `OFFER`, `ACCEPT`, `RESULT`, `TERMINATE` |
| `reqId` | request number; a `RESULT` repeats the `reqId` of the message it confirms |
| `error` | `0` in everything the client sends; non-zero values from the console aren't interpreted |
| `connRequest` | `{}` for `RESULT`; for `OFFER` and `ACCEPT` an object (§7.3) |

### 7.3 `connRequest`

Exactly this key order, as the reference writes it:

| Key | Type | Client's OFFER | Client's ACCEPT |
|---|---|---|---|
| `sid` | integer | `localSid` | `localSid` |
| `peerSid` | integer | console's sid if known, else 0 | console's current sid |
| `skey` | string, base64 of 16 bytes | 16 zero bytes | 16 zero bytes |
| `natType` | integer | 2 | 0 |
| `candidate` | array of candidates (§7.4) | the client's candidates (holepunch.md §4) | one: the selected pair (holepunch.md §6) |
| `defaultRouteMacAddr` | string, `xx:xx:xx:xx:xx:xx` lowercase or empty | `""` | `""` |
| `localPeerAddr` | object `{"accountId":"<decimal>","platform":"<p>"}`; may be **missing its value** in console messages (§7.5) | `{"accountId":"<accountId>","platform":"REMOTE_PLAY"}` | same |
| `localHashedId` | string, base64 of 20 bytes, or `""` | base64 of `localHashedId` | `""` |

`platform` in `localPeerAddr` is `REMOTE_PLAY` for the client, for a PS4 as for a PS5. The reference's notes
say a PS5 puts `PROSPERO` there and a PS4 `ORBIS`; the client never sends either value and never reads the
console's `localPeerAddr`. The only per-console platform value the client sends is the envelope's
`to[].platform` (`PS4` or `PS5`, §7.1) and the start command's `platform` (§6.3).

**`sid` width.** The client's own `sid` is 16-bit (0–65535). The console's `sid` arrives as a JSON integer;
the reference keeps only its **low 16 bits** (for `peerSid` and in the probe packets, holepunch.md §5.1),
and parses it as a signed 32-bit integer. Every value seen in the reference's development fitted in 16 bits
(the probe packets have 16-bit fields for it), but no statement that the console's `sid` is always below
65536 exists (§11).

### 7.4 Candidate

```
{"type":"<TYPE>","addr":"<IP>","mappedAddr":"<IP>","port":<integer>,"mappedPort":<integer>}
```

`type`: `STATIC`, `LOCAL`, `STUN` or `DERIVED` (holepunch.md §4, §5.4). Addresses are dotted IPv4 text.
Unknown types from the console are read as `STATIC` by the reference.

### 7.5 Receiving

A `rps:sessionMessage:created` notification carries the message at `/body/data/sessionMessage/payload`,
a string of the same form as §7.1's `payload`. The message JSON is everything after the first `body=`.

The console's messages are not always valid JSON: `"localPeerAddr":` can be followed directly by `,` (no
value). Before parsing, insert `{}` there when the character after `"localPeerAddr":` isn't `{`.

Fields the client takes from a console OFFER: `reqId`, `sid`, `localHashedId` (20 bytes), and the
`candidate` array; `peerSid`, `skey`, `natType` and `defaultRouteMacAddr` are parsed but not used. The
reference requires `action` (string), `reqId`, `error` (integers) and `connRequest` (object), and,
when `connRequest` isn't `{}`, every key of §7.3 except `localPeerAddr` with the right JSON type, and in
each candidate all five keys (client choice).

### 7.6 The exchange per hole

reqIds are the client's own counter, starting at 1 for the session and **shared by both holes**. What the
reference sends (client choice, observed; only "RESULT repeats the reqId it confirms" is known to matter):

| # | Who | Message | reqId (reference) |
|---|---|---|---|
| 1 | console | OFFER (its candidates) | console's |
| 2 | client | RESULT for 1 | = 1's |
| 3 | client | OFFER (client candidates) | ctrl hole 2, data hole 5 |
| 4 | console | RESULT for 3 | = 3's (the client waits for exactly this reqId; other RESULTs are skipped) |
| 5 | – | probes (holepunch.md §5) | – |
| 6 | client | ACCEPT (selected pair) | ctrl hole 3, data hole 6 |
| 7 | console | ACCEPT | console's |
| 8 | client | RESULT for 7 | = 7's |

(The reference numbers its OFFER when building it and renumbers it when sending, which skips 1 and 4.)

Rules (client choice, observed):

- While waiting for a message of one action, messages of other actions are dropped, except `TERMINATE`,
  which ends the setup ("canceled").
- Further console OFFERs after the first of a hole (retransmissions) are answered with a RESULT and
  otherwise ignored, from the moment the hole's first OFFER is in until that hole is established, and for
  the rest of the session once the data hole's OFFER is in.
- Each wait is up to 30 s.

### 7.7 Aborting

The reference **never sends `TERMINATE`** (nor any other session message) to abort. To give up on a hole, or
on the whole setup, it stops waiting, closes its sockets and leaves the PSN session with the DELETE of §8
(sent only if the push WebSocket is still open, §5.3). Its message writer can spell `"action":"TERMINATE"`
with the same full `connRequest` form as an OFFER, but no code path uses it, so what a client `TERMINATE`
should contain (and whether the console reacts to one) is unknown (§11). A console `TERMINATE` received while
waiting ends the client's setup ("canceled", §7.6).

---

## 8. Leaving the session

At the end of the session (after the stream, or when setup fails after the session was created):

```
DELETE https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/<sessionId>/members/me
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
```

Then wait up to 3 s for `rps:members:deleted` or `remotePlaySession:deleted` (client choice), close the
WebSocket, and remove the UPnP mappings (holepunch.md §3.1). A failed DELETE is logged and ignored. After a
session the console can refuse a new one as busy for several seconds (session.md §5.4); PlayFX waits 10 s
before reconnecting through PSN.

---

## 9. Errors and what they mean

| Where | Symptom | Likely meaning (inferred from the step that failed; PSN's codes aren't recorded) |
|---|---|---|
| any call | HTTP 401/403 | token expired, revoked or lacking a scope (§2). PlayFX retries the device list once with a refreshed token; the reference doesn't retry |
| device list | empty `clients`, or no console with `remotePlay` | no PS5 on the account, or Remote Play off |
| WebSocket | can't open / closes | push service unreachable, token not valid for `pushNotification:webSocket.desktop.connect` |
| create | non-2xx or bad JSON | session manager refused (scope `sessionManager:remotePlaySession.system.update`, or a token made without `duid`) |
| start (PS5) | HTTP error | the command was refused (wrong DUID, not this account's console) |
| start | no member/`customData1` within 30 s | the console didn't join: off, not in rest mode with internet kept, Remote Play off, or another account on the console |
| start | member DUID ≠ requested | another console joined (shouldn't happen) |
| PS4 wake | HTTP 404 | not the primary PS4 of the account, or unreachable |
| signalling | `TERMINATE` | the console gave up (meaning of its `error` codes unknown) |
| signalling | no OFFER / RESULT / ACCEPT within 30 s | console stalled; restart the session |
| any time | `remotePlaySession:deleted` for this session | PSN or the console ended it |

The exact HTTP status codes and error bodies PSN returns are not recorded in the reference (§11).

---

## 10. Timeouts (client choices, observed)

| Step | Limit |
|---|---|
| Device list | 5 s |
| Push server address, create, start, PS4 profile, PS4 wake, session message, DELETE, inspect | 10 s each |
| WebSocket connect; wait for it to open | 30 s; 30 s |
| WebSocket ping interval / pong deadline | 5 s / 5 s |
| Each wait for a notification or session message | 30 s |
| Wait for the deletion notification | 3 s |
| Whole setup through PSN, as measured by PlayFX on a real PS5 | about 27–28 s |

---

## 11. Open questions

1. PSN's error responses: status codes and bodies for an expired token, a missing scope, a token made
   without `duid`, an unknown DUID, a console that is off.
2. Whether `Accept-Language`, `User-Agent: RpNetHttpUtilImpl`, the `X-PSN-*` WebSocket headers and the
   literal `"me"` values are required.
3. Whether the device list pages (more than 10 consoles) and whether `platform=PS4` lists PS4s.
4. The full shape of the notification frames (only the pointers in §5.4 are known).
5. What `roomId`, `messageDestination: "SQS"`, `natType`, `skey`, `error` (non-zero) and `TERMINATE`'s reasons
   mean.
6. Whether a non-primary PS4 can be reached at all.
7. How long PSN keeps an abandoned session (one whose client vanished without the DELETE), and whether
   that blocks the next one.
8. Whether the console checks `localPeerAddr` or `defaultRouteMacAddr` in the client's messages.
9. What PSN puts in the client's own `members:created` (§5.4).
10. Whether the console's `sid` can exceed 16 bits (§7.3).
11. The form and effect of a client-sent `TERMINATE` (§7.7); the reference never sends one.
12. Whether PSN accepts JSON spelled differently from the reference's templates (escaped `\/`, spaces, other
    key orders) (§1).

---

## 12. Known-answer vectors

Made-up inputs: token `TOKEN-MADE-UP`; `pushContextId` `9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d`; `sessionId`
`2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c`; `accountId` 1234567890123456789; console DUID
`e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee`; `data1` = `10 11 … 1f`; `data2` = `20 21 … 2f`
(the `D1`/`D2` of test-vectors.md); `localSid` 4660; `localHashedId` `00 01 … 13`.

**[I]**: produced by an independent script from this text. **[C]**: the same bytes came out of a copy of the
reference's PSN code with the HTTP library replaced by a stub that printed each request instead of sending it.

### P1. Create session body [I][C]

```
{"remotePlaySessions":[{"members":[{"accountId":"me","deviceUniqueId":"me","platform":"me","pushContexts":[{"pushContextId":"9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"}]}]}]}
```

The stubbed reply `{"remotePlaySessions":[{"sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c","members":[{"accountId":"1234567890123456789",…}]}]}`
gave `sessionId` as above and `accountId` 1234567890123456789 (from a string) [C]. From then on the
reference holds the header line `X-PSN-SESSION-MANAGER-SESSION-IDS: 2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c`
for the inspect requests of §6.2 (the create request itself doesn't carry it; its headers are only
`Authorization` and `Content-Type`) [C].

### P2. Start command body (PS5) [I][C]

```
{"commandDetail":{"commandType":"remotePlay","duid":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","messageDestination":"SQS","parameters":{"initialParams":"{\"accountId\":1234567890123456789,\"roomId\":0,\"sessionId\":\"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c\",\"clientType\":\"Windows\",\"data1\":\"EBESExQVFhcYGRobHB0eHw==\",\"data2\":\"ICEiIyQlJicoKSorLC0uLw==\"}"},"platform":"PS5"}}
```

Headers: `Authorization: Bearer TOKEN-MADE-UP`, `Content-Type: application/json; charset=utf-8`,
`User-Agent: RpNetHttpUtilImpl`.

### P3. `customData1` [I][C]

`TURFeU16UTFOamM0T1RvN1BEMCtQdz09` → `MDEyMzQ1Njc4OTo7PD0+Pw==` → `303132333435363738393a3b3c3d3e3f` (the `CD` of
test-vectors.md, so test-vectors.md §3's PSN-mode `E`, `K` and masked seed, and the PSN registration bodies,
follow from this session's values).

### P4. A console OFFER as received [C]

Notification (one line in reality):

```
{"dataType":"psn:sessionManager:sys:rps:sessionMessage:created","body":{"data":{"sessionMessage":{"payload":
"ver=1.0, type=text, body={\"action\":\"OFFER\",\"reqId\":1,\"error\":0,\"connRequest\":{\"sid\":43981,\"peerSid\":0,
\"skey\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"natType\":2,\"candidate\":[{\"type\":\"STATIC\",\"addr\":\"198.51.100.7\",
\"mappedAddr\":\"0.0.0.0\",\"port\":50123,\"mappedPort\":0},{\"type\":\"LOCAL\",\"addr\":\"192.168.0.30\",
\"mappedAddr\":\"0.0.0.0\",\"port\":9303,\"mappedPort\":0}],\"defaultRouteMacAddr\":\"0a:1b:2c:3d:4e:5f\",
\"localPeerAddr\":,\"localHashedId\":\"oKGio6SlpqeoqaqrrK2ur7CxsrM=\"}}"}}}}
```

Parsed (after the `localPeerAddr` repair): action OFFER, reqId 1, error 0, sid 43981, peerSid 0, natType 2,
MAC `0a:1b:2c:3d:4e:5f`, hashed ID `a0a1…b3`, candidates `STATIC 198.51.100.7:50123` and
`LOCAL 192.168.0.30:9303`.

### P5. RESULT for the console's reqId 1 [I][C]

```
POST https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c/sessionMessage
```

```
{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"RESULT\",\"reqId\":1,\"error\":0,\"connRequest\":{}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}
```

### P6. Client OFFER, reqId 2, candidates STUN/STATIC/LOCAL [I][C]

```
{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"OFFER\",\"reqId\":2,\"error\":0,\"connRequest\":{\"sid\":4660,\"peerSid\":0,\"skey\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"natType\":2,\"candidate\":[{\"type\":\"STUN\",\"addr\":\"203.0.113.5\",\"mappedAddr\":\"0.0.0.0\",\"port\":40006,\"mappedPort\":0},{\"type\":\"STATIC\",\"addr\":\"203.0.113.5\",\"mappedAddr\":\"0.0.0.0\",\"port\":50123,\"mappedPort\":0},{\"type\":\"LOCAL\",\"addr\":\"192.168.1.20\",\"mappedAddr\":\"0.0.0.0\",\"port\":50123,\"mappedPort\":0}],\"defaultRouteMacAddr\":\"\",\"localPeerAddr\":{\"accountId\":\"1234567890123456789\",\"platform\":\"REMOTE_PLAY\"},\"localHashedId\":\"AAECAwQFBgcICQoLDA0ODxAREhM=\"}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}
```

### P7. Client ACCEPT, reqId 3, after selecting the console's STATIC candidate (holepunch.md H3) [I][C]

```
{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"ACCEPT\",\"reqId\":3,\"error\":0,\"connRequest\":{\"sid\":4660,\"peerSid\":43981,\"skey\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"natType\":0,\"candidate\":[{\"type\":\"STATIC\",\"addr\":\"198.51.100.7\",\"mappedAddr\":\"203.0.113.5\",\"port\":50123,\"mappedPort\":40006}],\"defaultRouteMacAddr\":\"\",\"localPeerAddr\":{\"accountId\":\"1234567890123456789\",\"platform\":\"REMOTE_PLAY\"},\"localHashedId\":\"\"}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}
```

### P8. Leave [I][C]

```
DELETE https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c/members/me
```

### P9. PS4 wake body [I]

With the same `data1`, `data2`, `sessionId`:

```
{"data":{"clientType":"Windows","data1":"EBESExQVFhcYGRobHB0eHw==","data2":"ICEiIyQlJicoKSorLC0uLw==","roomId": 0,"protocolVer":"10.0","sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c"},"dataTypeSuffix":"remotePlay"}
```
