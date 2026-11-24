# PlayFXProtocol

PlayFX's own implementation of the PlayStation Remote Play protocol in Swift, replacing libchiaki.
Proprietary; see LICENSE.

## Clean-room rule
Code here is written only from the specification in [`docs/protocol`](../../docs/protocol/README.md).
Never open, search or copy from `third_party/chiaki-ng` (or any other Remote Play implementation)
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

## Tests
- `scripts/test.sh` runs the tests (swift-testing); no console or network needed (recorded bytes in
  `Tests/PlayFXProtocolTests/Fixtures`).
- `scripts/coverage.sh` gates line and function coverage at 80%.
