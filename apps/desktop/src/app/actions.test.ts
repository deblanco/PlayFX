import { describe, expect, it, vi } from "@effect/vitest"
import { Effect, Fiber, Layer, Option } from "effect"
import { TestClock } from "effect/testing"
import { CoreError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { defaultSettings } from "@/core/schema"
import * as actions from "./actions"
import { accountId, credentials, fakeCore, pairedPs5, prefsLayer, ps5, status, type StoredPrefs } from "./testing"

const setup = (core = fakeCore(), prefs: StoredPrefs = {}) => ({ core, layer: Layer.mergeAll(core.layer, prefsLayer(prefs)) })

describe("account", () => {
  it.effect("saves a valid pasted account ID and loads it back", () => {
    const { layer } = setup()
    return Effect.gen(function* () {
      expect(yield* actions.saveAccountId(`  ${accountId} `)).toBe(accountId)
      expect(yield* actions.loadAccount).toEqual(Option.some(accountId))
      yield* actions.signOut
      expect(yield* actions.loadAccount).toEqual(Option.none())
    }).pipe(Effect.provide(layer))
  })

  it.effect("rejects an invalid account ID", () => {
    const { layer } = setup()
    return Effect.gen(function* () {
      const error = yield* Effect.flip(actions.saveAccountId("nope"))
      expect(error._tag).toBe("ValidationError")
      expect(error.message).toMatch(/8 bytes/)
    }).pipe(Effect.provide(layer))
  })

  it.effect("opens PSN sign-in and handles its result", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.signIn
      expect(core.counts.psnLogin).toBe(1)
      expect(yield* actions.receivePsnAccount({ accountId })).toBe(accountId)
      const error = yield* Effect.flip(actions.receivePsnAccount({ error: "denied" }))
      expect(error).toEqual(new actions.SignInFailed({ message: "PSN sign-in failed: denied" }))
    }).pipe(Effect.provide(layer))
  })

  it.effect("subscribes to PSN events until interrupted", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const seen: unknown[] = []
      const fiber = yield* Effect.forkChild(actions.onPsnAccount((event) => seen.push(event)))
      yield* Effect.yieldNow
      expect(core.psnListeners()).toBe(1)
      core.emitPsn({ accountId })
      expect(seen).toEqual([{ accountId }])
      yield* Fiber.interrupt(fiber)
      expect(core.psnListeners()).toBe(0)
    }).pipe(Effect.provide(layer))
  })
})

describe("consoles", () => {
  it.effect("scans and refreshes saved addresses", () => {
    const { layer } = setup(fakeCore(), {
      paired: [{ ...pairedPs5, credentials: { ...credentials, address: "10.0.0.9" } }],
    })
    return Effect.gen(function* () {
      const result = yield* actions.scan
      expect(result.discovered).toEqual([ps5])
      expect(result.paired["HOST1"]?.credentials.address).toBe("192.168.0.40")
      expect(yield* actions.loadPaired).toEqual(result.paired)
    }).pipe(Effect.provide(layer))
  })

  it.effect("polls discovery every 5 s and reports failures", () => {
    let fail = false
    const core = fakeCore({
      discover: Effect.suspend(() =>
        fail ? Effect.fail(new CoreError({ command: "discover", message: "no network" })) : Effect.succeed([ps5]),
      ),
    })
    const { layer } = setup(core)
    return Effect.gen(function* () {
      const outcomes: actions.ScanOutcome[] = []
      const fiber = yield* Effect.forkChild(actions.pollDiscovery((outcome) => outcomes.push(outcome)))
      yield* Effect.yieldNow
      expect(outcomes).toHaveLength(1)
      expect(outcomes[0]).toMatchObject({ ok: true, discovered: [ps5] })
      fail = true
      yield* TestClock.adjust("5 seconds")
      expect(outcomes).toHaveLength(2)
      expect(outcomes[1]).toEqual({ ok: false, message: "Discovery failed: no network" })
      yield* Fiber.interrupt(fiber)
    }).pipe(Effect.provide(layer))
  })

  it.effect("pairs with the stored account and saves the console", () => {
    const { core, layer } = setup(fakeCore(), { accountId })
    return Effect.gen(function* () {
      const paired = yield* actions.pair(ps5, "12345678")
      expect(core.service.pair).toHaveBeenCalledWith({ console: ps5, accountId, pin: "12345678" })
      expect(paired["HOST1"]).toEqual(pairedPs5)
    }).pipe(Effect.provide(layer))
  })

  it.effect("names a paired console after the discovered name when it has no nickname", () => {
    const core = fakeCore({ pair: () => Effect.succeed({ ...credentials, nickname: "" }) })
    const { layer } = setup(core)
    return Effect.gen(function* () {
      const paired = yield* actions.pair(ps5, "12345678")
      expect(paired["HOST1"]?.name).toBe("Living Room")
    }).pipe(Effect.provide(layer))
  })

  it.effect("passes an empty account when signed out", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.pair(ps5, "12345678")
      expect(core.service.pair).toHaveBeenCalledWith({ console: ps5, accountId: "", pin: "12345678" })
    }).pipe(Effect.provide(layer))
  })

  it.effect("wakes a console and fails when the wake-up isn't sent", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.wake(pairedPs5)
      expect(core.service.wakeup).toHaveBeenCalledWith(credentials)
      vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
      const error = yield* Effect.flip(actions.wake(pairedPs5))
      expect(error.message).toBe("Wake-up failed")
    }).pipe(Effect.provide(layer))
  })

  it.effect("forgets a console", () => {
    const { layer } = setup(fakeCore(), { paired: [pairedPs5] })
    return Effect.gen(function* () {
      expect(yield* actions.forget("HOST1")).toEqual({})
    }).pipe(Effect.provide(layer))
  })
})

describe("settings", () => {
  it.effect("loads settings and applies the upscaler at startup", () => {
    const core = fakeCore()
    core.state.status = status({}, false)
    const saved = { ...defaultSettings, upscaler: "bilinear" as const }
    const { layer } = setup(core, { settings: saved })
    return Effect.gen(function* () {
      expect(yield* actions.startup).toEqual({ settings: saved, metalfxSupported: false })
      expect(core.service.setUpscaler).toHaveBeenCalledWith("bilinear")
    }).pipe(Effect.provide(layer))
  })

  it.effect("persists changes and only switches the upscaler when it changed", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fps30 = { ...defaultSettings, fps: 30 as const }
      yield* actions.changeSettings(defaultSettings, fps30)
      expect(core.service.setUpscaler).not.toHaveBeenCalled()
      const prefs = yield* Preferences
      expect(yield* prefs.settings).toEqual(fps30)
      yield* actions.changeSettings(fps30, { ...fps30, upscaler: "bilinear" })
      expect(core.service.setUpscaler).toHaveBeenCalledWith("bilinear")
    }).pipe(Effect.provide(layer))
  })
})

describe("streaming", () => {
  it.effect("starts and stops a stream", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.play(pairedPs5, defaultSettings)
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, {
        height: 1080,
        fps: 60,
        hevc: true,
        bitrate: 0,
        audio: true,
        autoDowngrade: true,
      })
      yield* actions.stop
      expect(core.counts.stopStream).toBe(1)
    }).pipe(Effect.provide(layer))
  })

  it.effect("validates and sends the login PIN", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const error = yield* Effect.flip(actions.submitLoginPin("12"))
      expect(error.message).toBe("The login PIN has 4 digits")
      yield* actions.submitLoginPin(" 1234 ")
      expect(core.service.setLoginPin).toHaveBeenCalledWith("1234")
    }).pipe(Effect.provide(layer))
  })

  it.effect("subscribes to stream events until interrupted", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const seen: unknown[] = []
      const fiber = yield* Effect.forkChild(actions.onStreamEvent((event) => seen.push(event)))
      yield* Effect.yieldNow
      core.emitStream({ type: "connected" })
      expect(seen).toEqual([{ type: "connected" }])
      yield* Fiber.interrupt(fiber)
      expect(core.streamListeners()).toBe(0)
    }).pipe(Effect.provide(layer))
  })

  it.effect("polls stats every second, computing fps and skipping failed polls", () => {
    let broken = false
    const core = fakeCore()
    const service = core.service
    const { layer } = setup(
      fakeCore({
        rendererStatus: Effect.suspend(() =>
          broken
            ? Effect.fail(new CoreError({ command: "renderer_status", message: "gone" }))
            : service.rendererStatus,
        ),
      }),
    )
    return Effect.gen(function* () {
      const reports: string[] = []
      core.state.status = status({ framesDecoded: 0, bytesReceived: 0, width: 1920, height: 1080 })
      const fiber = yield* Effect.forkChild(actions.pollStats((stats) => reports.push(stats)))
      yield* Effect.yieldNow
      expect(reports).toEqual(["1920×1080 · 0 fps · 0.0 Mbps · MetalFX"])
      core.state.status = status({ framesDecoded: 60, bytesReceived: 2_500_000, width: 1920, height: 1080 })
      yield* TestClock.adjust("1 second")
      expect(reports[1]).toBe("1920×1080 · 60 fps · 20.0 Mbps · MetalFX")
      broken = true
      yield* TestClock.adjust("1 second")
      expect(reports).toHaveLength(2)
      broken = false
      yield* TestClock.adjust("1 second")
      expect(reports).toHaveLength(3)
      yield* Fiber.interrupt(fiber)
    }).pipe(Effect.provide(layer))
  })
})
