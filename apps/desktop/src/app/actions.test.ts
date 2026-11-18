import { describe, expect, it, vi } from "@effect/vitest"
import { Effect, Fiber, Layer, Logger, Option } from "effect"
import { TestClock } from "effect/testing"
import { CoreError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { defaultSettings } from "@/core/schema"
import { makeLogger } from "@/core/logging"
import * as actions from "./actions"
import { accountId, credentials, fakeCore, pairedPs5, picture, prefsLayer, ps5, status, type StoredPrefs } from "./testing"

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

  it.effect("signing out also forgets the PSN sign-in kept for internet play", () => {
    const { core, layer } = setup()
    core.state.psnSignedIn = true
    return Effect.gen(function* () {
      expect(yield* actions.internetReady).toBe(true)
      yield* actions.signOut
      expect(yield* actions.internetReady).toBe(false)
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
  it.effect("loads settings and applies the picture settings at startup", () => {
    const core = fakeCore()
    core.state.status = status({}, false)
    const saved = { ...defaultSettings, upscaler: "bilinear" as const }
    const { layer } = setup(core, { settings: saved })
    return Effect.gen(function* () {
      expect(yield* actions.startup).toEqual({ settings: saved, capabilities: { metalfx: false, ml: false } })
      expect(core.service.setRenderParams).toHaveBeenCalledWith(picture({ upscaler: "bilinear", sharpness: 0.3, compare: false }))
    }).pipe(Effect.provide(layer))
  })

  it.effect("persists changes and applies the picture part to the renderer every time", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fps30 = { ...defaultSettings, fps: 30 as const }
      yield* actions.changeSettings(fps30)
      const prefs = yield* Preferences
      expect(yield* prefs.settings).toEqual(fps30)
      expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture())
      yield* actions.changeSettings({ ...fps30, sharpness: 1 })
      expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ sharpness: 1 }))
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
      }, undefined)
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
      const rows: (readonly { readonly label: string; readonly value: string }[])[] = []
      const fiber = yield* Effect.forkChild(
        actions.pollStats((stats) => {
          reports.push(stats.line)
          rows.push(stats.rows)
        }),
      )
      yield* Effect.yieldNow
      expect(reports).toEqual(["1920×1080 · 0 fps · 0.0 Mbps · MetalFX"])
      core.state.status = status({ framesDecoded: 60, bytesReceived: 2_500_000, width: 1920, height: 1080 })
      yield* TestClock.adjust("1 second")
      expect(reports[1]).toBe("1920×1080 · 60 fps · 20.0 Mbps · MetalFX")
      expect(rows[1]?.find((row) => row.label === "Bitrate")?.value).toBe("20.0 Mbps")
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

describe("reconnect", () => {
  it.effect("waits a stable minute before forgiving drops", () =>
    Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(actions.waitUntilStable)
      yield* TestClock.adjust("59 seconds")
      expect(fiber.pollUnsafe()).toBeUndefined()
      yield* TestClock.adjust("1 second")
      yield* Fiber.join(fiber)
    }),
  )

  const settings = { ...defaultSettings, height: 720 as const }

  /** Starts a reconnect in the background and lets it reach its first start_stream. */
  const begin = Effect.gen(function* () {
    const fiber = yield* Effect.forkChild(Effect.exit(actions.reconnect(pairedPs5, settings)))
    yield* Effect.yieldNow
    return fiber
  })

  it.effect("starts with the new settings (replacing the session) and finishes when connected", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      expect(core.counts.stopStream).toBe(0) // start replaces it, keeping the last frame up
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.objectContaining({ height: 720 }), undefined)
      core.emitStream({ type: "quit", reason: "Stopped", error: false, kind: "stopped" }) // the replaced session: ignored
      core.emitStream({ type: "connected" })
      expect((yield* Fiber.join(fiber))._tag).toBe("Success")
      expect(core.streamListeners()).toBe(0) // unsubscribed
    }).pipe(Effect.provide(layer))
  })

  it.effect("retries while the console is busy", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      core.emitStream({ type: "quit", reason: "Remote Play on Console is already in use", error: true, kind: "busy" })
      yield* Effect.yieldNow
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
      yield* TestClock.adjust(actions.reconnectRetryDelay)
      expect(core.service.startStream).toHaveBeenCalledTimes(2)
      core.emitStream({ type: "connected" })
      expect((yield* Fiber.join(fiber))._tag).toBe("Success")
    }).pipe(Effect.provide(layer))
  })

  it.effect("gives up when the console stays busy", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      for (let i = 0; i < 30; i++) {
        core.emitStream({ type: "quit", reason: "in use", error: true, kind: "busy" })
        yield* TestClock.adjust(actions.reconnectRetryDelay)
      }
      const exit = yield* Fiber.join(fiber)
      expect(exit).toMatchObject({ _tag: "Failure" })
      expect(String(exit)).toContain("The console is still busy")
    }).pipe(Effect.provide(layer))
  })

  it.effect("fails with the console's reason on an error quit", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      core.emitStream({ type: "quit", reason: "Version mismatch", error: true })
      const exit = yield* Fiber.join(fiber)
      expect(String(exit)).toContain("Reconnect failed: Version mismatch")
    }).pipe(Effect.provide(layer))
  })

  it.effect("counts a login PIN request as connected", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      core.emitStream({ type: "loginPin", incorrect: false })
      expect((yield* Fiber.join(fiber))._tag).toBe("Success")
    }).pipe(Effect.provide(layer))
  })

  it.effect("fails fast when the console goes to rest instead", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      core.emitStream({ type: "quit", reason: "Server shutting down", error: false, kind: "final" })
      expect(String(yield* Fiber.join(fiber))).toContain("Reconnect failed: Server shutting down")
    }).pipe(Effect.provide(layer))
  })

  it.effect("fails when the console doesn't answer", () => {
    const { layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* begin
      yield* TestClock.adjust(actions.reconnectAnswerTimeout)
      expect(String(yield* Fiber.join(fiber))).toContain("The console didn't answer")
    }).pipe(Effect.provide(layer))
  })

  it.effect("fails when the stream can't be started", () => {
    const { layer } = setup(fakeCore({ startStream: () => Effect.fail(new CoreError({ command: "start_stream", message: "busy" })) }))
    return Effect.gen(function* () {
      const fiber = yield* begin
      expect(String(yield* Fiber.join(fiber))).toContain("busy")
    }).pipe(Effect.provide(layer))
  })
})

describe("wakeUntilReady", () => {
  const asleep = [{ ...ps5, state: "standby" as const }]

  it.effect("returns at once when the console is already up", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.wakeUntilReady(pairedPs5)
      expect(core.service.wakeup).toHaveBeenCalledTimes(1)
    }).pipe(Effect.provide(layer))
  })

  it.effect("waits until discovery sees it ready, re-sending the wake-up every few checks", () => {
    const { core, layer } = setup()
    core.state.discovered = asleep
    return Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(actions.wakeUntilReady(pairedPs5))
      for (let i = 0; i < 6; i++) yield* TestClock.adjust(actions.wakePollInterval)
      expect(fiber.pollUnsafe()).toBeUndefined()
      expect(core.service.wakeup).toHaveBeenCalledTimes(2) // the first one, and again after 5 checks
      core.state.discovered = [ps5]
      yield* TestClock.adjust(actions.wakePollInterval)
      yield* Fiber.join(fiber)
    }).pipe(Effect.provide(layer))
  })

  it.effect("treats failed scans as not ready yet", () => {
    let calls = 0
    const core = fakeCore({
      discover: Effect.suspend(() =>
        ++calls === 1 ? Effect.fail(new CoreError({ command: "discover", message: "socket busy" })) : Effect.succeed([ps5]),
      ),
    })
    const { layer } = setup(core)
    return Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(actions.wakeUntilReady(pairedPs5))
      yield* TestClock.adjust(actions.wakePollInterval)
      yield* Fiber.join(fiber)
      expect(calls).toBe(2)
    }).pipe(Effect.provide(layer))
  })

  it.effect("gives up with advice when the console doesn't wake", () => {
    const { core, layer } = setup()
    core.state.discovered = asleep
    return Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(Effect.flip(actions.wakeUntilReady(pairedPs5)))
      yield* TestClock.adjust(actions.wakeTimeout)
      const error = yield* Fiber.join(fiber)
      expect(error.message).toBe(
          'Living Room didn\'t wake up. Check that "Stay connected to the internet" is on in its rest mode settings.',
      )
    }).pipe(Effect.provide(layer))
  })

  it.effect("fails when the wake-up can't be sent", () => {
    const { core, layer } = setup()
    vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
    return Effect.gen(function* () {
      expect((yield* Effect.flip(actions.wakeUntilReady(pairedPs5))).message).toBe("Wake-up failed")
    }).pipe(Effect.provide(layer))
  })

  it.effect("plays locally when the console wakes, even with PSN available", () => {
    const { layer } = setup()
    return Effect.gen(function* () {
      expect(yield* actions.wakeUntilReady(pairedPs5, "aa")).toEqual({ via: "local" })
    }).pipe(Effect.provide(layer))
  })

  it.effect("goes through PSN at once when the wake-up can't be sent on this network", () => {
    const { core, layer } = setup()
    vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
    return Effect.gen(function* () {
      expect(yield* actions.wakeUntilReady(pairedPs5, "aa")).toEqual({ via: "internet", psnDuid: "aa" })
    }).pipe(Effect.provide(layer))
  })

  it.effect("goes through PSN when the console doesn't answer the local wake-up in time", () => {
    const { core, layer } = setup()
    core.state.discovered = asleep
    vi.mocked(core.service.wakeup).mockReturnValue(Effect.succeed(true))
    return Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(actions.wakeUntilReady(pairedPs5, "aa"))
      for (let i = 0; i < 4; i++) yield* TestClock.adjust(actions.wakePollInterval)
      vi.mocked(core.service.wakeup).mockReturnValue(Effect.succeed(false)) // a failed resend keeps waiting
      yield* TestClock.adjust(actions.wakeFallbackAfter)
      expect(yield* Fiber.join(fiber)).toEqual({ via: "internet", psnDuid: "aa" })
      vi.mocked(core.service.wakeup).mockReturnValue(Effect.succeed(true))
    }).pipe(Effect.provide(layer))
  })
})

describe("psnReachable", () => {
  it.effect("finds paired consoles on the PSN account when signed in for internet play", () => {
    const { core, layer } = setup()
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    return Effect.gen(function* () {
      expect(yield* actions.psnReachable({ HOST1: pairedPs5 })).toEqual({}) // not signed in: not even asked
      core.state.psnSignedIn = true
      expect(yield* actions.psnReachable({ HOST1: pairedPs5 })).toEqual({ HOST1: "aa" })
    }).pipe(Effect.provide(layer))
  })

  it.effect("is empty when PSN can't be reached", () => {
    const core = fakeCore({ psnConsoles: Effect.fail(new CoreError({ command: "psn_consoles", message: "offline" })) })
    core.state.psnSignedIn = true
    const { layer } = setup(core)
    return Effect.gen(function* () {
      expect(yield* actions.psnReachable({ HOST1: pairedPs5 })).toEqual({})
    }).pipe(Effect.provide(layer))
  })
})

describe("internet play", () => {
  it.effect("plays over the internet with the console's PSN device ID", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      yield* actions.play(pairedPs5, defaultSettings, "aa")
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), "aa")
    }).pipe(Effect.provide(layer))
  })

  it.effect("polls which consoles PSN can reach every minute", () => {
    const { core, layer } = setup()
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    return Effect.gen(function* () {
      const reports: Readonly<Record<string, string>>[] = []
      const fiber = yield* Effect.forkChild(actions.pollPsnReachable({ HOST1: pairedPs5 }, (r) => reports.push(r)))
      yield* Effect.yieldNow
      expect(reports).toEqual([{ HOST1: "aa" }])
      yield* TestClock.adjust(actions.psnPollInterval)
      expect(reports).toHaveLength(2)
      yield* Fiber.interrupt(fiber)
    }).pipe(Effect.provide(layer))
  })

  it.effect("reconnects over the internet with a longer wait for the answer", () => {
    const { core, layer } = setup()
    return Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(Effect.exit(actions.reconnect(pairedPs5, defaultSettings, "aa")))
      yield* Effect.yieldNow
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), "aa")
      yield* TestClock.adjust(actions.reconnectAnswerTimeout) // the LAN wait has passed: still waiting
      expect(fiber.pollUnsafe()).toBeUndefined()
      core.emitStream({ type: "connected" })
      expect((yield* Fiber.join(fiber))._tag).toBe("Success")
    }).pipe(Effect.provide(layer))
  })
})

describe("logging", () => {
  it.effect("logs what the app does, including stream events from their callback", () => {
    const lines: string[] = []
    const { core, layer } = setup()
    const logged = Logger.layer([makeLogger((level, line) => lines.push(`${level} ${line}`))])
    return Effect.gen(function* () {
      yield* actions.play(pairedPs5, defaultSettings, "aa")
      const fiber = yield* Effect.forkChild(actions.onStreamEvent(() => undefined))
      yield* Effect.yieldNow
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
      yield* Effect.yieldNow
      yield* Fiber.interrupt(fiber)
      expect(lines).toContain("Info Play Living Room over the internet: 1080p60 HEVC, auto bitrate")
      expect(lines).toContain("Warn Stream ended: Stream Connection Unknown (dropped)")
    }).pipe(Effect.provide(Layer.merge(layer, logged)))
  })
})

describe("diagnostics", () => {
  it.effect("applies saved detailed logs at startup, then only when the setting changes", () => {
    const { core, layer } = setup(fakeCore(), { settings: { ...defaultSettings, detailedLogs: true } })
    return Effect.gen(function* () {
      yield* actions.startup
      expect(core.service.setDetailedLogs).toHaveBeenCalledWith(true)
      yield* actions.changeSettings({ ...defaultSettings, detailedLogs: true, sharpness: 0.5 })
      expect(core.service.setDetailedLogs).toHaveBeenCalledTimes(1) // unchanged: no call
      yield* actions.changeSettings({ ...defaultSettings, detailedLogs: false })
      expect(core.service.setDetailedLogs).toHaveBeenLastCalledWith(false)
    }).pipe(Effect.provide(layer))
  })

  it("builds a report with versions, renderer, settings and the recent log", () => {
    const report = actions.diagnosticsReport(
      { appVersion: "0.1.0", os: "macOS 27.2", logFolder: "/logs", recentLog: "[INFO] hello" },
      { ...status(), mlSupported: true },
      defaultSettings,
    )
    expect(report).toContain("PS Remote Play 0.1.0 on macOS 27.2")
    expect(report).toContain("Renderer: MetalFX yes, ML super-resolution yes")
    expect(report).toContain('"upscaler":"metalfx"')
    expect(report.endsWith("Recent log:\n[INFO] hello")).toBe(true)
  })

  it.effect("copies the report to the clipboard, or says it couldn't", () => {
    const { layer } = setup()
    const writeText = vi.fn((_text: string) => Promise.resolve())
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true })
    return Effect.gen(function* () {
      yield* actions.copyDiagnostics(defaultSettings)
      expect(writeText.mock.calls[0]?.[0]).toContain("PS Remote Play 0.1.0")
      writeText.mockImplementationOnce(() => Promise.reject(new Error("denied")))
      const error = yield* Effect.flip(actions.copyDiagnostics(defaultSettings))
      expect(error).toMatchObject({ _tag: "ClipboardFailed" })
    }).pipe(Effect.provide(layer))
  })
})

