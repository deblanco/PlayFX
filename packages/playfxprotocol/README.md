# PlayFXProtocol

PlayFX's own implementation of the PlayStation Remote Play protocol in Swift, replacing libchiaki.
Proprietary; see LICENSE.

## Clean-room rule
Code here is written only from the specification in [`docs/protocol`](../../docs/protocol/README.md).
Never open, search or copy from `third_party/chiaki-ng` (or any other Remote Play implementation)
while working on this package. If the spec is missing a fact, ask for a spec addition.

## Tests
- `scripts/test.sh` runs the tests (swift-testing); no console or network needed (recorded bytes in
  `Tests/PlayFXProtocolTests/Fixtures`).
- `scripts/coverage.sh` gates line and function coverage at 80%.
