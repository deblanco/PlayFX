import { invoke } from "@tauri-apps/api/core"
import { afterEach, describe, expect, it } from "@effect/vitest"
import { vi } from "vitest"
import { Effect, Layer, Option } from "effect"
import { Core, CoreLive } from "./core"
import { memoryStore, Preferences, PreferencesLive } from "./preferences"
import { makeAppRuntime } from "./runtime"
import { TauriBridge } from "./tauri"
import { Updater, UpdaterLive } from "./updater"

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }))
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }))

afterEach(() => {
  vi.resetAllMocks()
})

describe("makeAppRuntime", () => {
  it("wires Core to Tauri, settings to localStorage and secrets to the native store", async () => {
    const replies: Record<string, unknown> = { discover: [], secret_get: { value: null }, secret_set: { ok: true } }
    vi.mocked(invoke).mockImplementation((command: string) => Promise.resolve(replies[command] ?? null))
    localStorage.setItem("psrp.accountId", "AAAAAAAAAAA=") // an older build kept it here
    const runtime = makeAppRuntime()
    const program = Effect.gen(function* () {
      const core = yield* Core
      const prefs = yield* Preferences
      const updater = yield* Updater
      return { consoles: yield* core.discover, accountId: yield* prefs.accountId, update: yield* updater.check(false) }
    })
    replies["update_check"] = { status: "upToDate", currentVersion: "0.2.4" }
    const result = await runtime.runPromise(program)
    expect(result).toEqual({
      consoles: [],
      accountId: Option.some("AAAAAAAAAAA="),
      update: { status: "upToDate", currentVersion: "0.2.4" },
    })
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("update_check", { automatic: false })
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("discover", undefined)
    // Moved to the native store and gone from the webview.
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("secret_set", { key: "psrp.accountId", value: "AAAAAAAAAAA=" })
    expect(localStorage.getItem("psrp.accountId")).toBeNull()
    await runtime.dispose()
  })

  it("accepts a replacement layer for tests", async () => {
    const bridge = Layer.succeed(TauriBridge, {
      invoke: () => Effect.succeed(true),
      listen: () => Effect.succeed(() => undefined),
    })
    const layer = Layer.mergeAll(
      CoreLive.pipe(Layer.provide(bridge)),
      PreferencesLive.pipe(Layer.provide(memoryStore())),
      UpdaterLive.pipe(Layer.provide(bridge)),
    )
    const runtime = makeAppRuntime(layer)
    const woke = await runtime.runPromise(
      Effect.flatMap(Core, (core) =>
        core.wakeup({
          address: "192.168.0.40",
          ps5: true,
          nickname: "PS5",
          mac: "00",
          registKey: "k",
          rpKey: "r",
          accountId: "AAAAAAAAAAA=",
        }),
      ),
    )
    expect(woke).toBe(true)
    expect(vi.mocked(invoke)).not.toHaveBeenCalled()
    await runtime.dispose()
  })
})
