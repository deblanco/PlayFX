import { afterEach, describe, expect, it, vi } from "@effect/vitest"
import { Effect, Layer, Option } from "effect"
import {
  KeyValueStore,
  LocalStorageLive,
  memoryStore,
  Preferences,
  PreferencesLive,
  renamedSettingKeys,
  SecretStore,
  SecurePreferencesLive,
} from "./preferences"
import { defaultSettings, type PairedConsole, type Settings } from "./schema"

const living: PairedConsole = {
  hostId: "A1B2",
  name: "Living room",
  credentials: {
    address: "192.168.0.40",
    ps5: true,
    nickname: "PS5-123",
    mac: "a1b2c3d4e5f6",
    registKey: "AAAAAAAAAAAAAAAAAAAAAA==",
    rpKey: "AAAAAAAAAAAAAAAAAAAAAA==",
    accountId: "AAAAAAAAAAA=",
  },
}

const bedroom: PairedConsole = {
  ...living,
  hostId: "C3D4",
  name: "Bedroom",
  credentials: { ...living.credentials, address: "192.168.0.41", ps5: false },
}

const withMemory = (initial: Record<string, string> = {}) => {
  const store = memoryStore(initial)
  return Layer.merge(PreferencesLive.pipe(Layer.provide(store)), store)
}

const rawGet = (key: string) => Effect.flatMap(KeyValueStore, (store) => store.get(key))

afterEach(() => {
  vi.restoreAllMocks()
})

describe("memoryStore", () => {
  it.effect("gets, sets and removes values", () =>
    Effect.gen(function* () {
      const store = yield* KeyValueStore
      expect(yield* store.get("a")).toEqual(Option.some("1"))
      expect(yield* store.get("b")).toEqual(Option.none())
      yield* store.set("b", "2")
      expect(yield* store.get("b")).toEqual(Option.some("2"))
      yield* store.remove("a")
      expect(yield* store.get("a")).toEqual(Option.none())
    }).pipe(Effect.provide(memoryStore({ a: "1" }))),
  )
})

describe("PreferencesLive (memory)", () => {
  describe("accountId", () => {
    it.effect("is empty by default, then saved and cleared", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.accountId).toEqual(Option.none())
        yield* prefs.setAccountId(Option.some("AAAAAAAAAAA="))
        expect(yield* prefs.accountId).toEqual(Option.some("AAAAAAAAAAA="))
        expect(yield* rawGet("psrp.accountId")).toEqual(Option.some("AAAAAAAAAAA="))
        yield* prefs.setAccountId(Option.none())
        expect(yield* prefs.accountId).toEqual(Option.none())
        expect(yield* rawGet("psrp.accountId")).toEqual(Option.none())
      }).pipe(Effect.provide(withMemory())),
    )

    it.effect("reads a stored value that isn't an account ID as signed out", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.accountId).toEqual(Option.none())
        expect(yield* rawGet("psrp.accountId")).toEqual(Option.some("abc"))
      }).pipe(Effect.provide(withMemory({ "psrp.accountId": "abc" }))),
    )
  })

  describe("paired consoles", () => {
    it.effect("is empty by default", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.paired).toEqual({})
      }).pipe(Effect.provide(withMemory())),
    )

    it.effect("saves consoles keyed by host ID, replacing an existing one", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        yield* prefs.savePaired(living)
        yield* prefs.savePaired(bedroom)
        yield* prefs.savePaired({ ...living, name: "Renamed" })
        expect(yield* prefs.paired).toEqual({ A1B2: { ...living, name: "Renamed" }, C3D4: bedroom })
      }).pipe(Effect.provide(withMemory())),
    )

    it.effect("reads what's already stored", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.paired).toEqual({ A1B2: living })
      }).pipe(Effect.provide(withMemory({ "psrp.consoles": JSON.stringify({ A1B2: living }) }))),
    )

    it.effect("forget removes one console and leaves the rest", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        yield* prefs.forget("A1B2")
        expect(yield* prefs.paired).toEqual({ C3D4: bedroom })
        // Forgetting an unknown console is a no-op.
        yield* prefs.forget("nope")
        expect(yield* prefs.paired).toEqual({ C3D4: bedroom })
      }).pipe(Effect.provide(withMemory({ "psrp.consoles": JSON.stringify({ A1B2: living, C3D4: bedroom }) }))),
    )

    it.effect("falls back to no consoles when the stored JSON is corrupt", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.paired).toEqual({})
        // ...and saving afterwards overwrites the corrupt value.
        yield* prefs.savePaired(living)
        expect(yield* prefs.paired).toEqual({ A1B2: living })
      }).pipe(Effect.provide(withMemory({ "psrp.consoles": "{not json" }))),
    )

    it.effect("falls back to no consoles when the stored JSON has the wrong shape", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.paired).toEqual({})
      }).pipe(Effect.provide(withMemory({ "psrp.consoles": JSON.stringify({ A1B2: { hostId: "A1B2" } }) }))),
    )
  })

  describe("refreshAddresses", () => {
    const initial = { "psrp.consoles": JSON.stringify({ A1B2: living, C3D4: bedroom }) }

    it.effect("updates the address of consoles seen at a new IP", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        yield* prefs.refreshAddresses([
          { hostId: "A1B2", address: "192.168.0.99" },
          { hostId: "C3D4", address: "192.168.0.41" }, // unchanged
          { hostId: "UNPAIRED", address: "192.168.0.50" }, // not paired: ignored
        ])
        const paired = yield* prefs.paired
        expect(paired["A1B2"]?.credentials.address).toBe("192.168.0.99")
        expect(paired["A1B2"]?.credentials.registKey).toBe(living.credentials.registKey)
        expect(paired["C3D4"]).toEqual(bedroom)
        expect(Object.keys(paired)).toEqual(["A1B2", "C3D4"])
      }).pipe(Effect.provide(withMemory(initial))),
    )

    it.effect("doesn't write when nothing moved", () => {
      const set = vi.fn()
      const spyStore = Layer.effect(
        KeyValueStore,
        Effect.map(KeyValueStore, (inner) => ({
          ...inner,
          set: (key: string, value: string) => Effect.andThen(
              Effect.sync(() => {
                set(key, value)
              }),
              inner.set(key, value),
            ),
        })),
      ).pipe(Layer.provide(memoryStore(initial)))
      return Effect.gen(function* () {
        const prefs = yield* Preferences
        yield* prefs.refreshAddresses([])
        yield* prefs.refreshAddresses([
          { hostId: "A1B2", address: "192.168.0.40" },
          { hostId: "UNPAIRED", address: "192.168.0.50" },
        ])
        expect(set).not.toHaveBeenCalled()
        yield* prefs.refreshAddresses([{ hostId: "C3D4", address: "10.0.0.2" }])
        expect(set).toHaveBeenCalledOnce()
      }).pipe(Effect.provide(PreferencesLive.pipe(Layer.provide(spyStore))))
    })
  })

  describe("settings", () => {
    it.effect("defaults when nothing is stored", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.settings).toEqual(defaultSettings)
      }).pipe(Effect.provide(withMemory())),
    )

    it.effect("round-trips saved settings as JSON", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        const next: Settings = { ...defaultSettings, height: 720, fps: 30, hevc: false, bitrate: 30000, upscaler: "bilinear" }
        yield* prefs.saveSettings(next)
        expect(yield* prefs.settings).toEqual(next)
        expect(yield* rawGet("psrp.settings")).toEqual(Option.some(JSON.stringify(next)))
      }).pipe(Effect.provide(withMemory())),
    )

    it.effect("fills settings added later from defaults, keeping the saved ones", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.settings).toEqual({ ...defaultSettings, height: 720, upscaler: "bilinear" })
      }).pipe(
        Effect.provide(
          withMemory({ "psrp.settings": JSON.stringify({ height: 720, fps: 60, hevc: true, upscaler: "bilinear" }) }),
        ),
      ),
    )

    it.effect("defaults when stored settings are corrupt or out of range", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.settings).toEqual(defaultSettings)
      }).pipe(Effect.provide(withMemory({ "psrp.settings": "]]" }))),
    )

    it.effect("defaults when stored settings hold an unsupported value", () =>
      Effect.gen(function* () {
        const prefs = yield* Preferences
        expect(yield* prefs.settings).toEqual(defaultSettings)
      }).pipe(Effect.provide(withMemory({ "psrp.settings": JSON.stringify({ ...defaultSettings, fps: 144 }) }))),
    )
  })
})

describe("LocalStorageLive", () => {
  const prefsLayer = PreferencesLive.pipe(Layer.provide(LocalStorageLive))

  it.effect("persists preferences in localStorage", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      yield* prefs.setAccountId(Option.some("AAAAAAAAAAA="))
      yield* prefs.savePaired(living)
      expect(localStorage.getItem("psrp.accountId")).toBe("AAAAAAAAAAA=")
      expect(yield* prefs.paired).toEqual({ A1B2: living })
      yield* prefs.setAccountId(Option.none())
      expect(localStorage.getItem("psrp.accountId")).toBeNull()
    }).pipe(Effect.provide(prefsLayer)),
  )

  it.effect("reads existing values and falls back on corrupt JSON", () =>
    Effect.gen(function* () {
      localStorage.setItem("psrp.settings", "{oops")
      localStorage.setItem("psrp.accountId", "AAAAAAAAAAA=")
      const prefs = yield* Preferences
      expect(yield* prefs.settings).toEqual(defaultSettings)
      expect(yield* prefs.accountId).toEqual(Option.some("AAAAAAAAAAA="))
    }).pipe(Effect.provide(prefsLayer)),
  )

  it.effect("turns a rejected write into a StorageError naming the key", () =>
    Effect.gen(function* () {
      vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new DOMException("The quota has been exceeded.", "QuotaExceededError")
      })
      const prefs = yield* Preferences
      const error = yield* Effect.flip(prefs.saveSettings(defaultSettings))
      expect(error._tag).toBe("StorageError")
      expect(error.key).toBe("psrp.settings")
      expect(error.message).toContain("The quota has been exceeded.")
    }).pipe(Effect.provide(prefsLayer)),
  )

  it.effect("turns a failed read or remove into a StorageError, stringifying non-Error throws", () =>
    Effect.gen(function* () {
      vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
        // eslint-disable-next-line @typescript-eslint/only-throw-error -- simulating a non-Error throw
        throw "storage disabled"
      })
      vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => {
        throw new Error("denied")
      })
      const prefs = yield* Preferences
      expect(yield* Effect.flip(prefs.accountId)).toMatchObject({ key: "psrp.accountId", message: "storage disabled" })
      expect(yield* Effect.flip(prefs.paired)).toMatchObject({ key: "psrp.consoles" })
      expect(yield* Effect.flip(prefs.setAccountId(Option.none()))).toMatchObject({
        key: "psrp.accountId",
        message: "denied",
      })
    }).pipe(Effect.provide(prefsLayer)),
  )
})

describe("SecurePreferencesLive", () => {
  const kvWith = (initial: Record<string, string>) => {
    const data = new Map(Object.entries(initial))
    const service: KeyValueStore["Service"] = {
      get: (key) => Effect.sync(() => Option.fromNullishOr(data.get(key))),
      set: (key, value) => Effect.sync(() => void data.set(key, value)),
      remove: (key) => Effect.sync(() => void data.delete(key)),
    }
    return { data, service }
  }

  it.effect("moves pairing keys and the account ID out of localStorage, and keeps settings there", () => {
    const paired = { [living.hostId]: living }
    const local = kvWith({ "psrp.consoles": JSON.stringify(paired), "psrp.accountId": "AQEBAQEBAQE=", "psrp.settings": "{}" })
    const secrets = kvWith({})
    const layer = SecurePreferencesLive.pipe(
      Layer.provide(Layer.merge(Layer.succeed(KeyValueStore, local.service), Layer.succeed(SecretStore, secrets.service))),
    )
    return Effect.gen(function* () {
      const prefs = yield* Preferences
      expect(yield* prefs.paired).toEqual(paired)
      expect(Option.getOrNull(yield* prefs.accountId)).toBe("AQEBAQEBAQE=")
      expect(secrets.data.has("psrp.consoles") && secrets.data.has("psrp.accountId")).toBe(true)
      expect(local.data.has("psrp.consoles") || local.data.has("psrp.accountId")).toBe(false) // gone from the webview
      expect(local.data.has("psrp.settings")).toBe(true)
      // New pairings go to the secret store only.
      yield* prefs.forget(living.hostId)
      expect(secrets.data.get("psrp.consoles")).toBe("{}")
      expect(local.data.has("psrp.consoles")).toBe(false)
      yield* prefs.setAccountId(Option.none())
      expect(secrets.data.has("psrp.accountId")).toBe(false)
    }).pipe(Effect.provide(layer))
  })
})

describe("settings saved before the rename to Frame interpolation", () => {
  const { frameInterpolation: _new, ...withoutNewKey } = defaultSettings
  const legacy = { ...withoutNewKey, fps: 30, smoothMotion: true }

  it.effect("keep Smooth motion's value, in settings and in profiles", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      expect((yield* prefs.settings).frameInterpolation).toBe(true)
      const [profile] = yield* prefs.profiles
      expect(profile?.settings.frameInterpolation).toBe(true)
      expect(profile?.name).toBe("Couch")
    }).pipe(Effect.provide(withMemory({
      "psrp.settings": JSON.stringify(legacy),
      "psrp.profiles": JSON.stringify([{ name: "Couch", settings: legacy }]),
    }))),
  )

  it.effect("still read a damaged profile list as none", () =>
    Effect.gen(function* () {
      expect(yield* (yield* Preferences).profiles).toEqual([])
    }).pipe(Effect.provide(withMemory({ "psrp.profiles": JSON.stringify(["not a profile"]) }))),
  )

  it("leaves new and unrelated JSON as it is", () => {
    expect(renamedSettingKeys({ frameInterpolation: false, smoothMotion: true })).toEqual({ frameInterpolation: false, smoothMotion: true })
    expect(renamedSettingKeys([1])).toEqual([1])
    expect(renamedSettingKeys(null)).toBe(null)
  })
})

describe("damaged stored data", () => {
  it.effect("keeps every setting that still decodes when one doesn't", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      const settings = yield* prefs.settings
      expect(settings.height).toBe(720) // kept
      expect(settings.fps).toBe(30) // kept
      expect(settings.bitrate).toBe(defaultSettings.bitrate) // 12345 isn't a bitrate this version offers
    }).pipe(
      Effect.provide(withMemory({ "psrp.settings": JSON.stringify({ ...defaultSettings, height: 720, fps: 30, bitrate: 12345 }) })),
    ),
  )

  it.effect("keeps the profiles that decode", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      const profiles = yield* prefs.profiles
      expect(profiles.map((p) => p.name)).toEqual(["Good"])
    }).pipe(
      Effect.provide(
        withMemory({
          "psrp.profiles": JSON.stringify([
            { name: "Good", settings: { ...defaultSettings, height: 720 } },
            { name: 42, settings: "broken" },
          ]),
        }),
      ),
    ),
  )

  it.effect("never drops a pairing that doesn't decode when saving another", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      expect(Object.keys(yield* prefs.paired)).toEqual([living.hostId])
      yield* prefs.savePaired(bedroom)
      const stored: unknown = JSON.parse(Option.getOrThrow(yield* rawGet("psrp.consoles")))
      expect(stored).toMatchObject({ ODD: { hostId: "ODD", credentials: "from a future version" } })
      expect(Object.keys(yield* prefs.paired).sort()).toEqual([bedroom.hostId, living.hostId].sort())
    }).pipe(
      Effect.provide(
        withMemory({
          "psrp.consoles": JSON.stringify({ [living.hostId]: living, ODD: { hostId: "ODD", credentials: "from a future version" } }),
        }),
      ),
    ),
  )

  it.effect("reads nothing usable as the defaults", () =>
    Effect.gen(function* () {
      const prefs = yield* Preferences
      expect(yield* prefs.settings).toEqual(defaultSettings)
      expect(yield* prefs.profiles).toEqual([])
      expect(yield* prefs.paired).toEqual({})
    }).pipe(Effect.provide(withMemory({ "psrp.settings": "not json", "psrp.profiles": "{}", "psrp.consoles": "[1]" }))),
  )
})
