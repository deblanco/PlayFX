import { Context, Effect, Layer, Option, Schema, Semaphore } from "effect"
import { StorageError } from "./errors"
import { defaultSettings, isAccountId, PairedConsole, type PairedConsoles, Profile, Settings } from "./schema"

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

const keys = {
  accountId: "psrp.accountId",
  consoles: "psrp.consoles",
  settings: "psrp.settings",
  profiles: "psrp.profiles",
  steadyWifi: "psrp.steadyWifi",
} as const

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
    /** Settings profiles the user saved (the built-in one isn't stored). */
    readonly profiles: Effect.Effect<readonly Profile[], StorageError>
    readonly saveProfiles: (profiles: readonly Profile[]) => Effect.Effect<void, StorageError>
    /** Whether the user last turned Steady Wi-Fi on (and not off since), to offer it again at the next stream. */
    readonly steadyWifi: Effect.Effect<boolean, StorageError>
    readonly saveSteadyWifi: (on: boolean) => Effect.Effect<void, StorageError>
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

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

/** Settings saved before a rename keep their values: "Smooth motion" became "Frame interpolation". */
export const renamedSettingKeys = (json: unknown): unknown => {
  if (!isRecord(json) || !("smoothMotion" in json) || "frameInterpolation" in json) return json
  const { smoothMotion, ...rest } = json
  return { ...rest, frameInterpolation: smoothMotion }
}

const parseJson = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Unknown))

/** The remembered Steady Wi-Fi choice; anything but `true` reads as off. */
const steadyWifiFrom = (json: unknown): boolean =>
  Option.getOrElse(Schema.decodeUnknownOption(Schema.Boolean)(json), () => false)

/** Stored settings, field by field: a value that doesn't decode (from another version, or hand-edited) falls
 * back to its default and the rest are kept. Decoding them as one let a single bad value reset everything,
 * and the next change saved the defaults over the user's settings. */
export const settingsFrom = (json: unknown): Settings => {
  const whole = Schema.decodeUnknownOption(Settings)(json)
  if (Option.isSome(whole) || !isRecord(json)) return Option.getOrElse(whole, () => defaultSettings)
  const merged: Record<string, unknown> = { ...defaultSettings }
  for (const [key, field] of Object.entries(Settings.fields)) {
    if (!(key in json)) continue
    const value = Schema.decodeUnknownOption(field)(json[key])
    if (Option.isSome(value)) merged[key] = value.value
  }
  return Option.getOrElse(Schema.decodeUnknownOption(Settings)(merged), () => defaultSettings)
}

/** Stored profiles, one by one: a profile that doesn't decode is left out, not the whole list. */
export const profilesFrom = (json: unknown): readonly Profile[] =>
  Array.isArray(json)
    ? json.flatMap((p: unknown) => {
        const migrated = isRecord(p) ? { ...p, settings: renamedSettingKeys(p["settings"]) } : p
        return Option.toArray(Schema.decodeUnknownOption(Profile)(migrated))
      })
    : []

/** Stored pairings, entry by entry: the ones that decode, and the ones that don't kept as they are, so a
 * write puts them back untouched. Decoding them as one lost every console's pairing keys for one bad entry,
 * and the next pairing saved over them. */
export const pairingsFrom = (json: unknown): { readonly valid: PairedConsoles; readonly unreadable: Readonly<Record<string, unknown>> } => {
  const valid: Record<string, PairedConsole> = {}
  const unreadable: Record<string, unknown> = {}
  if (isRecord(json)) {
    for (const [hostId, entry] of Object.entries(json)) {
      Option.match(Schema.decodeUnknownOption(PairedConsole)(entry), {
        onSome: (console) => { valid[hostId] = console },
        onNone: () => { unreadable[hostId] = entry },
      })
    }
  }
  return { valid, unreadable }
}

const makePreferences = (store: KeyValueStore["Service"], secret: KeyValueStore["Service"], pairing: Semaphore.Semaphore) => {

    /** The JSON stored under `key` in `from`, turned into a value by `decode`; nothing, or text that
     * isn't JSON gives `decode(undefined)`. */
    const read = <A>(key: string, decode: (json: unknown) => A, from = store) =>
      Effect.map(from.get(key), (raw) => decode(Option.getOrUndefined(Option.flatMap(raw, parseJson))))

    const write = (key: string, value: unknown, to = store) => to.set(key, JSON.stringify(value))

    const pairings = read(keys.consoles, pairingsFrom, secret)
    const paired = Effect.map(pairings, (p) => p.valid)
    /** Changes the pairings one change at a time (pairing, forgetting and the scan's address updates
     * read, change and write the whole set: interleaved, one would undo another), putting entries that
     * don't decode back untouched. */
    const changePaired = (change: (all: PairedConsoles) => Option.Option<PairedConsoles>) =>
      Semaphore.withPermit(
        pairing,
        Effect.flatMap(pairings, ({ valid, unreadable }) =>
          Option.match(change(valid), {
            onNone: () => Effect.void,
            onSome: (next) => write(keys.consoles, { ...unreadable, ...next }, secret),
          }),
        ),
      )

    /** A stored account ID that isn't a valid one (corrupt or hand-edited) reads as signed out. */
    const decodeAccountId = Schema.decodeUnknownOption(Schema.String.check(Schema.makeFilter((id: string) => isAccountId(id))))

    return {
      accountId: Effect.map(secret.get(keys.accountId), Option.flatMap(decodeAccountId)),
      setAccountId: (id) =>
        Option.match(id, { onNone: () => secret.remove(keys.accountId), onSome: (v) => secret.set(keys.accountId, v) }),
      paired,
      savePaired: (console) => changePaired((all) => Option.some({ ...all, [console.hostId]: console })),
      forget: (hostId) =>
        changePaired((all) => {
          const { [hostId]: _removed, ...rest } = all
          return Option.some(rest)
        }),
      refreshAddresses: (seen) =>
        changePaired((all) => {
          const moved = seen.filter((s) => {
            const p = all[s.hostId]
            return p !== undefined && p.credentials.address !== s.address
          })
          if (moved.length === 0) return Option.none()
          const next = { ...all }
          for (const s of moved) {
            const p = next[s.hostId]
            if (p) next[s.hostId] = { ...p, credentials: { ...p.credentials, address: s.address } }
          }
          return Option.some(next)
        }),
      settings: read(keys.settings, (json) => settingsFrom(renamedSettingKeys(json))),
      saveSettings: (settings) => write(keys.settings, settings),
      profiles: read(keys.profiles, profilesFrom),
      saveProfiles: (profiles) => write(keys.profiles, profiles),
      steadyWifi: read(keys.steadyWifi, steadyWifiFrom),
      saveSteadyWifi: (on) => write(keys.steadyWifi, on),
    } satisfies Preferences["Service"]
}

/** Everything in one key-value store (tests). */
export const PreferencesLive = Layer.effect(
  Preferences,
  Effect.gen(function* () {
    const store = yield* KeyValueStore
    return makePreferences(store, store, yield* Semaphore.make(1))
  }),
)

/** The app: settings in localStorage, secrets in the native store (moved there from localStorage once). */
export const SecurePreferencesLive = Layer.effect(
  Preferences,
  Effect.gen(function* () {
    const store = yield* KeyValueStore
    const secrets = yield* SecretStore
    return makePreferences(store, migratingSecrets(secrets, store), yield* Semaphore.make(1))
  }),
)
