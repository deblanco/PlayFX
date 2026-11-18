import { invoke } from "@tauri-apps/api/core"
import { afterEach, describe, expect, it } from "@effect/vitest"
import { vi } from "vitest"
import { Effect, Layer, Option } from "effect"
import { Core, CoreLive } from "./core"
import { memoryStore, Preferences, PreferencesLive } from "./preferences"
import { makeAppRuntime } from "./runtime"
import { TauriBridge } from "./tauri"

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }))
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }))

afterEach(() => {
  vi.resetAllMocks()
})

describe("makeAppRuntime", () => {
  it("wires Core to Tauri and Preferences to localStorage by default", async () => {
    vi.mocked(invoke).mockResolvedValue([])
    localStorage.setItem("psrp.accountId", "AAAAAAAAAAA=")
    const runtime = makeAppRuntime()
    const program = Effect.gen(function* () {
      const core = yield* Core
      const prefs = yield* Preferences
      return { consoles: yield* core.discover, accountId: yield* prefs.accountId }
    })
    const result = await runtime.runPromise(program)
    expect(result).toEqual({ consoles: [], accountId: Option.some("AAAAAAAAAAA=") })
    expect(vi.mocked(invoke)).toHaveBeenCalledWith("discover", undefined)
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
