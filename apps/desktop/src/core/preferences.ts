import { Context, Effect, Layer, Option, Schema } from "effect"
import { StorageError } from "./errors"
import { defaultSettings, isAccountId, PairedConsoles, Settings, type PairedConsole } from "./schema"

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
  set: (key, value) =>
    Effect.try({
      try: () => {
        localStorage.setItem(key, value)
      },
      catch: storageError(key),
    }),
  remove: (key) =>
    Effect.try({
      try: () => {
        localStorage.removeItem(key)
      },
      catch: storageError(key),
    }),
}))

/** Where secrets live (pairing keys, the PSN account ID): the native store — the Keychain in release
 * builds, a 0600 file in development — never the webview's localStorage. Same shape as KeyValueStore. */
export class SecretStore extends Context.Service<SecretStore, KeyValueStore["Service"]>()("SecretStore") {}

export const memoryStore = (initial: Record<string, string> = {}) => {
  const data = new Map(Object.entries(initial))
  return Layer.succeed(KeyValueStore, {
    get: (key) => Effect.sync(() => Option.fromNullishOr(data.get(key))),
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
    readonly refreshAddresses: (seen: readonly { hostId: string; address: string }[]) => Effect.Effect<void, StorageError>
    readonly settings: Effect.Effect<Settings, StorageError>
    readonly saveSettings: (settings: Settings) => Effect.Effect<void, StorageError>
  }
>()("Preferences") {}

/** Secrets read from `secrets`; a value still in the old place (`legacy`, localStorage) moves over on
 * first read and is deleted there. */
export const migratingSecrets = (
  secrets: KeyValueStore["Service"],
  legacy: KeyValueStore["Service"],
): KeyValueStore["Service"] => ({
  get: (key) =>
    Effect.flatMap(secrets.get(key), (found) =>
      Option.isSome(found)
        ? Effect.succeed(found)
        : Effect.flatMap(legacy.get(key), (old) =>
            Option.match(old, {
              onNone: () => Effect.succeed(old),
              onSome: (value) =>
                secrets.set(key, value).pipe(
                  Effect.andThen(legacy.remove(key)),
                  Effect.tap(() => Effect.logInfo(`Moved ${key} out of the webview's storage`)),
                  Effect.as(old),
                ),
            }),
          ),
    ),
  set: (key, value) => Effect.andThen(secrets.set(key, value), legacy.remove(key)),
  remove: (key) => Effect.andThen(secrets.remove(key), legacy.remove(key)),
})

const makePreferences = (store: KeyValueStore["Service"], secret: KeyValueStore["Service"]) => {

    /** Reads JSON under `key` from `from`; missing or corrupt data yields `fallback`. */
    const read = <A>(schema: Schema.Codec<A, unknown>, key: string, fallback: A, from = store) =>
      from.get(key).pipe(
        Effect.map((raw) =>
          Option.match(raw, {
            onNone: () => fallback,
            onSome: (text) =>
              Option.getOrElse(Schema.decodeUnknownOption(Schema.fromJsonString(schema))(text), () => fallback),
          }),
        ),
      )

    const write = (key: string, value: unknown, to = store) => to.set(key, JSON.stringify(value))
    const writePaired = (value: PairedConsoles) => write(keys.consoles, value, secret)

    const paired = read(PairedConsoles, keys.consoles, {}, secret)

    /** A stored account ID that isn't a valid one (corrupt or hand-edited) reads as signed out. */
    const decodeAccountId = Schema.decodeUnknownOption(Schema.String.check(Schema.makeFilter((id: string) => isAccountId(id))))

    return {
      accountId: Effect.map(secret.get(keys.accountId), Option.flatMap(decodeAccountId)),
      setAccountId: (id) =>
        Option.match(id, { onNone: () => secret.remove(keys.accountId), onSome: (v) => secret.set(keys.accountId, v) }),
      paired,
      savePaired: (console) =>
        Effect.flatMap(paired, (all) => writePaired({ ...all, [console.hostId]: console })),
      forget: (hostId) =>
        Effect.flatMap(paired, (all) => {
          const { [hostId]: _removed, ...rest } = all
          return writePaired(rest)
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
          return writePaired(next)
        }),
      settings: read(Settings, keys.settings, defaultSettings),
      saveSettings: (settings) => write(keys.settings, settings),
    } satisfies Preferences["Service"]
}

/** Everything in one key-value store (tests). */
export const PreferencesLive = Layer.effect(
  Preferences,
  Effect.gen(function* () {
    const store = yield* KeyValueStore
    return makePreferences(store, store)
  }),
)

/** The app: settings in localStorage, secrets in the native store (moved there from localStorage once). */
export const SecurePreferencesLive = Layer.effect(
  Preferences,
  Effect.gen(function* () {
    const store = yield* KeyValueStore
    const secrets = yield* SecretStore
    return makePreferences(store, migratingSecrets(secrets, store))
  }),
)
