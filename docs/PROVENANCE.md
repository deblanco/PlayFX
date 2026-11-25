# Provenance and risk

How PlayFX's Remote Play protocol code was written, and the legal risks that remain. This is a factual record
kept by the people (and AI agents) who did the work. It is **not legal advice**, and no lawyer has reviewed it.

## Summary

- Until 2026-11-24 PlayFX was AGPL-3.0 and used **libchiaki** (from the chiaki-ng fork, AGPL-3.0) for the Remote
  Play protocol. From commit `fc9603b` (2026-11-24) PlayFX is proprietary and contains no chiaki-ng code.
- The protocol is now implemented by `packages/playfxprotocol` (Swift, proprietary), written through a
  **clean-room process**: people who read chiaki-ng wrote down facts only (`docs/protocol`); different people,
  who never saw chiaki-ng, wrote the code from those facts.
- The clean room is **best effort**, not perfect (see "Limits of the clean room").

## The process

### Roles

| Role | Read chiaki-ng? | Wrote |
|---|---|---|
| Spec writers | Yes, read-only, at chiaki-ng commit `d8efd673bc93bbc16e9f646c5b24e0dee013abcc` | `docs/protocol`: facts only (wire formats, constants, tables, message text, state sequences, timeouts, error meanings), with known-answer vectors. No code, no pseudo-code mirroring chiaki-ng's functions, no identifiers or comments carried over. |
| Implementers | No | `packages/playfxprotocol` and `PlayFXEngine` (`packages/streamcore/Sources/StreamCore/PlayFXEngine*.swift`), from `docs/protocol` and an engine contract (`StreamEngine.swift`) alone. A missing fact went back to a spec writer as a "spec request". |
| Reviewers | No | Spec-only reviews of each implementation (findings fixed by the implementers). |
| Glue and removal | Saw PlayFX's own C shim over libchiaki (`psrp.c`, PlayFX code, AGPL at the time), not chiaki-ng's sources | The engine seam in StreamCore, and the removal of libchiaki. No protocol logic. |
| Coordinator | Did not read chiaki-ng's sources during the rewrite | Task briefs, verification, commits, PLAN.md. |

All roles were filled by AI agents (Anthropic's Claude) directed by the project owner, Daniel B.

### Rules the implementers followed

- Read only `docs/protocol` and the package being written (later also StreamCore's Swift, minus the libchiaki
  engine and the C shim). Never open `third_party/`, the main checkout (which had chiaki-ng), or any scratch
  folder that held chiaki-ng copies.
- chiaki-ng was never checked out in the worktree where implementation happened; libchiaki was used there only
  as prebuilt binaries and headers until it was removed.

### Verification

- Known-answer vectors in `docs/protocol` were computed by independent scripts written from the spec text, and
  where marked [C] compared with chiaki-ng's library run as a black box in throwaway test programs (built in a
  scratch folder outside the repository, with network calls stubbed; deleted afterwards).
- The implementation was tested against those vectors and, on 2026-11-23/24, against the owner's PS5:
  discovery, wake, pairing, session start, streams up to 22 Mbit/s, input, haptics, loss recovery.

### Known slips

- One implementer ran a search that touched `packages/streamcore/Sources` and printed one line of
  `PlayFXEngine.swift` (itself clean-room code, not chiaki-derived). Nothing from chiaki-ng was exposed.
- No implementer is known to have opened chiaki-ng or the C shim.

### Code reused from before

- PlayFX's own video reorder policy (the reorder wait and the 256-slot queue) had been written by the project
  for its chiaki-ng fork. It was re-specified as facts (`docs/protocol/takion.md`, "PlayFX's own reorder policy")
  and re-implemented from the spec, not copied.
- Third-party code now in the app: libsecp256k1 (MIT) and libopus 1.6.1 (BSD-3-Clause), both vendored unmodified, plus the
  Rust crates, web packages and fonts listed in `THIRD_PARTY_LICENSES`.

## Limits of the clean room

- **AI training data.** The models used were very likely trained on public code that includes chiaki and
  chiaki-ng. A clean room run by such models can't exclude that the implementers "remembered" structure or
  idioms from them. The separation of roles reduces this; it can't remove it.
- **Same organisation.** Spec writers and implementers were separate agent instances directed by one person,
  not separate companies with a documented wall.
- **Facts close to expression.** Some facts (e.g. exact JSON templates, constant tables) are reproduced
  verbatim because the protocol requires them; that is inherent to interoperability.

## Remaining risks (as seen by the authors; not legal advice)

1. **Copyright in chiaki-ng (AGPL).** Low if the clean room held: facts about a protocol and interoperability
   requirements are generally not protected expression. The limits above are the weak point.
2. **Old AGPL releases and history.** Versions of PlayFX released under AGPL-3.0 stay available under it to
   anyone who received them, and this repository's history contains AGPL code (including the chiaki-ng
   submodule). Relicensing affects new versions only.
3. **Sony's cryptographic constants** (`docs/protocol/data/`, used for pairing and session encryption). These
   originate from Sony's software. Shipping them in a commercial product could draw a complaint under copyright
   or anti-circumvention law (e.g. the US DMCA), independently of who wrote the code. Open-source clients have
   distributed them for years without that happening, which is not a guarantee. **This is the largest remaining
   risk.**
4. **Trademarks and terms.** "PlayStation", "PS5", "PS4" and "DualSense" are Sony trademarks: use them only to
   describe compatibility ("for PS5"), never in the app's name or icon; keep the "unofficial, not affiliated with
   Sony" notice. Sony's terms for PSN apply to the user's account; PSN sign-in goes through Sony's own page and
   PlayFX never sees the password.
5. **App Store review.** Apple may reject an app built around another company's service or trademarks, or
   remove it after a complaint from Sony.
