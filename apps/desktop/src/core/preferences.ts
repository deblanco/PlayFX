import { Context, Effect, Layer, Option, Schema } from "effect"
import { StorageError } from "./errors"
import { defaultSettings, PairedConsoles, Settings, type PairedConsole } from "./schema"

/** String key/value storage (localStorage in the app, a Map in tests). */
export class KeyValueStore extends Context.Service<
  KeyValueStore,
  {
    readonly get: (key: string) => Effect.Effect<Option.Option<string>, StorageError>
    readonly set: (key: string, value: string) => Effect.Effect<void, StorageError>
    readonly remove: (key: string) => Effect.Effect<void, StorageError>
  }
>()("KeyValueStore") {}

const storageError = (key: string) => (error: unknown) =>
  new StorageError({ key, message: error instanceof Error ? error.message : String(error) })

export const LocalStorageLive = Layer.sync(KeyValueStore, () => ({
  get: (key) =>
    Effect.try({ try: () => Option.fromNullishOr(localStorage.getItem(key)), catch: storageError(key) }),
  set: (key, value) => Effect.try({ try: () => localStorage.setItem(key, value), catch: storageError(key) }),
  remove: (key) => Effect.try({ try: () => localStorage.removeItem(key), catch: storageError(key) }),
}))

export const memoryStore = (initial: Record<string, string> = {}) => {
  const data = new Map(Object.entries(initial))
  return Layer.succeed(KeyValueStore, {
    get: (key) => Effect.succeed(Option.fromNullishOr(data.get(key))),
    set: (key, value) => Effect.sync(() => void data.set(key, value)),
    remove: (key) => Effect.sync(() => void data.delete(key)),
  })
}

const keys = { accountId: "psrp.accountId", consoles: "psrp.consoles", settings: "psrp.settings" } as const

/** What the user keeps on this machine: PSN account ID, pairing keys, stream settings. */
export class Preferences extends Context.Service<
  Preferences,
  {
    readonly accountId: Effect.Effect<Option.Option<string>, StorageError>
    readonly setAccountId: (id: Option.Option<string>) => Effect.Effect<void, StorageError>
    readonly paired: Effect.Effect<PairedConsoles, StorageError>
    readonly savePaired: (console: PairedConsole) => Effect.Effect<void, StorageError>
    readonly forget: (hostId: string) => Effect.Effect<void, StorageError>
    /** Updates saved addresses when a paired console shows up at a new IP. */
    readonly refreshAddresses: (seen: ReadonlyArray<{ hostId: string; address: string }>) => Effect.Effect<void, StorageError>
    readonly settings: Effect.Effect<Settings, StorageError>
    readonly saveSettings: (settings: Settings) => Effect.Effect<void, StorageError>
  }
>()("Preferences") {}

export const PreferencesLive = Layer.effect(
  Preferences,
  Effect.gen(function* () {
    const store = yield* KeyValueStore

    /** Reads JSON under `key`; missing or corrupt data yields `fallback`. */
    const read = <A>(schema: Schema.Codec<A, unknown>, key: string, fallback: A) =>
      store.get(key).pipe(
        Effect.map((raw) =>
          Option.match(raw, {
            onNone: () => fallback,
            onSome: (text) =>
              Option.getOrElse(Schema.decodeUnknownOption(Schema.fromJsonString(schema))(text), () => fallback),
          }),
        ),
      )

    const write = <A>(key: string, value: A) => store.set(key, JSON.stringify(value))

    const paired = read(PairedConsoles, keys.consoles, {})

    return {
      accountId: store.get(keys.accountId),
      setAccountId: (id) =>
        Option.match(id, { onNone: () => store.remove(keys.accountId), onSome: (v) => store.set(keys.accountId, v) }),
      paired,
      savePaired: (console) =>
        Effect.flatMap(paired, (all) => write(keys.consoles, { ...all, [console.hostId]: console })),
      forget: (hostId) =>
        Effect.flatMap(paired, (all) => {
          const { [hostId]: _removed, ...rest } = all
          return write(keys.consoles, rest)
        }),
      refreshAddresses: (seen) =>
        Effect.flatMap(paired, (all) => {
          const moved = seen.filter((s) => {
            const p = all[s.hostId]
            return p !== undefined && p.credentials.address !== s.address
          })
          if (moved.length === 0) return Effect.void
          const next = { ...all }
          for (const s of moved) {
            const p = next[s.hostId]
            if (p) next[s.hostId] = { ...p, credentials: { ...p.credentials, address: s.address } }
          }
          return write(keys.consoles, next)
        }),
      settings: read(Settings, keys.settings, defaultSettings),
      saveSettings: (settings) => write(keys.settings, settings),
    }
  }),
)
