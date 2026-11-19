import { Effect, Option, Schema } from "effect"
import { useEffect, useRef } from "react"
import { KeyValueStore } from "@/core/preferences"
import type { PairedConsole } from "@/core/schema"
import type { ConsoleRow } from "./format"

/// Dev-only E2E: once a ready, paired console appears, start streaming it automatically, so the
/// full Play path can be exercised without clicking. Inert unless `import.meta.env.DEV` and
/// `VITE_PSRP_AUTOPLAY` are set.
export const useDevAutoplay = (rows: readonly ConsoleRow[], onPlay: (console: PairedConsole) => void): void => {
  const fired = useRef(false)
  useEffect(() => {
    if (fired.current || !import.meta.env.DEV || import.meta.env["VITE_PSRP_AUTOPLAY"] !== "1") return
    const ready = rows.find((r) => r.status === "ready" && r.paired !== undefined)
    if (ready?.paired !== undefined) {
      fired.current = true
      onPlay(ready.paired)
    }
  }, [rows, onPlay])
}

const DevSeed = Schema.Struct({
  accountId: Schema.String,
  consoles: Schema.Record(Schema.String, Schema.Unknown),
  settings: Schema.optional(Schema.Unknown),
})

const toJson = Schema.encodeUnknownEffect(Schema.fromJsonString(Schema.Unknown))

/// Dev-only E2E helper: preloads the app's local storage so it starts already paired with a
/// real console, for testing the streaming path end to end without the pairing UI. Completely
/// inert unless BOTH `import.meta.env.DEV` and `VITE_PSRP_SEED` are set, so it never affects a
/// production build. The seed file is gitignored and holds private registration keys. Never fails:
/// a missing or malformed seed is logged and the app starts as usual.
export const seedDevStorage: Effect.Effect<void, never, KeyValueStore> = Effect.gen(function* () {
  if (!import.meta.env.DEV || import.meta.env["VITE_PSRP_SEED"] !== "1") return
  // A glob, not an import: the file only exists on a developer's Mac, and a clean checkout must build.
  const load = import.meta.glob<{ readonly default: unknown }>("./dev-seed.local.json")["./dev-seed.local.json"]
  if (load === undefined) return
  const module = yield* Effect.tryPromise({ try: load, catch: (error) => new Error(`dev seed: ${String(error)}`) })
  const seed = yield* Schema.decodeUnknownEffect(DevSeed)(module.default)
  const store = yield* KeyValueStore
  const put = (key: string, value: string) =>
    Effect.flatMap(store.get(key), Option.match({ onNone: () => store.set(key, value), onSome: () => Effect.void }))
  yield* put("psrp.accountId", seed.accountId)
  yield* put("psrp.consoles", yield* toJson(seed.consoles))
  if (seed.settings !== undefined) yield* put("psrp.settings", yield* toJson(seed.settings))
}).pipe(
  Effect.tapError((error) => Effect.logWarning(`Dev seed not applied: ${error.message}`)),
  Effect.ignore,
)
