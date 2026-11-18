import { invoke } from "@tauri-apps/api/core"
import { listen, type EventCallback } from "@tauri-apps/api/event"
import { afterEach, describe, expect, it } from "@effect/vitest"
import { vi } from "vitest"
import { Effect } from "effect"
import { CoreError } from "./errors"
import { TauriBridge, TauriBridgeLive } from "./tauri"

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }))
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }))

const invokeMock = vi.mocked(invoke)
const listenMock = vi.mocked(listen)

afterEach(() => {
  vi.resetAllMocks()
})

const withBridge = <A, E>(f: (bridge: TauriBridge["Service"]) => Effect.Effect<A, E>) =>
  Effect.flatMap(TauriBridge, f).pipe(Effect.provide(TauriBridgeLive))

describe("TauriBridgeLive", () => {
  it.effect("invoke forwards command and args and returns the reply", () =>
    Effect.gen(function* () {
      invokeMock.mockResolvedValue({ ok: true })
      const reply = yield* withBridge((bridge) => bridge.invoke("start_stream", { request: 1 }))
      expect(reply).toEqual({ ok: true })
      expect(invokeMock).toHaveBeenCalledWith("start_stream", { request: 1 })
    }),
  )

  it.effect("invoke maps an Error rejection to CoreError", () =>
    Effect.gen(function* () {
      invokeMock.mockRejectedValue(new Error("boom"))
      const error = yield* Effect.flip(withBridge((bridge) => bridge.invoke("discover")))
      expect(error).toEqual(new CoreError({ command: "discover", message: "boom" }))
    }),
  )

  it.effect("invoke maps a string rejection (Tauri's Err(String)) to CoreError", () =>
    Effect.gen(function* () {
      invokeMock.mockRejectedValue("Registration failed")
      const error = yield* Effect.flip(withBridge((bridge) => bridge.invoke("register_console")))
      expect(error).toEqual(new CoreError({ command: "register_console", message: "Registration failed" }))
    }),
  )

  it.effect("listen passes payloads to the handler and returns the unlisten function", () =>
    Effect.gen(function* () {
      const unlisten = vi.fn()
      let registered: EventCallback<unknown> | undefined
      listenMock.mockImplementation((_event, handler) => {
        registered = handler
        return Promise.resolve(unlisten)
      })
      const payloads: unknown[] = []
      const stop = yield* withBridge((bridge) => bridge.listen("stream-event", (p) => payloads.push(p)))
      expect(listenMock).toHaveBeenCalledWith("stream-event", expect.any(Function))
      registered?.({ event: "stream-event", id: 1, payload: { type: "connected" } })
      expect(payloads).toEqual([{ type: "connected" }])
      stop()
      expect(unlisten).toHaveBeenCalledOnce()
    }),
  )

  it.effect("listen maps a rejection to CoreError", () =>
    Effect.gen(function* () {
      listenMock.mockRejectedValue(new Error("no IPC"))
      const error = yield* Effect.flip(withBridge((bridge) => bridge.listen("psn-account", () => undefined)))
      expect(error).toEqual(new CoreError({ command: "listen:psn-account", message: "no IPC" }))
    }),
  )
})
