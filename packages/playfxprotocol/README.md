# PlayFXProtocol

PlayFX's own implementation of the PlayStation Remote Play protocol in Swift (it replaced libchiaki in 2026-11).
Proprietary; see LICENSE.

## Clean-room rule
Code here is written only from the specification in [`docs/protocol`](../../docs/protocol/README.md).
Never open, search or copy from chiaki-ng (or any other Remote Play implementation)
while working on this package. If the spec is missing a fact, ask for a spec addition.

## pfxp (hardware checks)
`swift build --product pfxp`, then `.build/debug/pfxp discover | wake | pair | session | stream` against a real console, side by
side with `psrp`. Only with the user's go-ahead. `wake` uses the pairing in `~/.config/psrp/config.json` (or
`--new` for one made by `pfxp pair`, kept in `~/.config/playfx-protocol/config.json`, 0600). Keys are never printed.

`pfxp stream` also takes `--press SCRIPT` (timed inputs from `connected`, e.g. `ps@2,circle@4,cross+up@7:300,ly=-1@9:2000`:
`BUTTONS@SECONDS[:HOLD_MS]` or `AXIS=VALUE@SECONDS[:HOLD_MS]`, hold 150 ms by default) and, for testing only,
`--drop PERCENT [--drop-burst N]` (drops that share of the datagrams received once the stream is up; the per-second line
shows `simDrop`). `--trace-input` prints every controller state actually sent, when it changes. It prints the video
header's `codec` byte and the pad-info form (17 or 25 bytes) when it first sees them.

## Internet play (through PSN)
```swift
let remote = PSNRemote(accessToken: token, consoleDUID: duid)   // duid from PSNClient.consoles()
var internet = InternetOptions()
internet.progress = { stage in /* .linkingPSN, .wakingConsole, .ctrlHole, .registering, .sessionInit, .ctrl,
                                   .dataHole, .probing, .streamConnecting, .connected */ }
let session = try await StreamSession.start(remote: remote, settings: settings, internet: internet) { event, session in ... }
// PIN-less pairing: the same PairingResult as a PIN pairing, from the same inputs.
let pairing = try await Registration.registerThroughPSN(remote: remote)
```
Both throw `InternetStartError` (`userMessage(console:)`, `endReason`, `retryClass`). Every internet session registers first and
uses the keys that registration returns, so no pairing record is needed; the account ID comes from PSN. `StreamSession.stopAndWait()` waits for that
leaving (use it on quit); `InternetOptions.probeIdentity = .logOnly` relaxes the probe identity check for a first hardware
round. `InternetOptions.log` lines can contain public addresses (the default writes them `.private`). Whatever way a
start or a stream ends, the PSN session is left and the UPnP mappings removed; wait about 10 s before the next start (the
console can answer busy). It takes about 30 s on a real PS5. `InternetOptions.log` has one line per step for diagnosing a
first run. See DESIGN.md "Internet play". No test or build step contacts PSN, a STUN server, a router or a console: the
tests use fakes on loopback.

## Tests
- `scripts/test.sh` runs the tests (swift-testing); no console or network needed (recorded bytes in
  `Tests/PlayFXProtocolTests/Fixtures`).
- `scripts/coverage.sh` gates line and function coverage at 80%.
- `PlayFXProtocolTestSupport` (`Sources/PlayFXProtocolTestSupport`) is a test-only library product: the fake console
  (session init, ctrl, probe and stream over loopback), the Takion fakes, the spec vectors and `Fixtures`. This package's
  tests and StreamCore's (the PlayFX engine) both use it. It imports PlayFXProtocol with `@testable`, so it builds in
  debug or with `-Xswiftc -enable-testing` (a plain `swift build -c release` of every target fails on it; build the
  products, e.g. `--product PlayFXProtocol`).
