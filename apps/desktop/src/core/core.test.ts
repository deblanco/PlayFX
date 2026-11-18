import { describe, expect, it, vi } from "@effect/vitest"
import { Effect, Exit, Layer } from "effect"
import { Core, CoreLive } from "./core"
import { CoreError } from "./errors"
import type { Credentials, DiscoveredConsole, PsnAccountEvent, RenderParams, StreamEvent, StreamOptions } from "./schema"
import { TauriBridge } from "./tauri"

type Reply = Effect.Effect<unknown, CoreError>

/** A TauriBridge that answers from a table and lets tests fire events. */
const fakeBridge = (replies: Partial<Record<string, Reply>> = {}, listenFailure?: CoreError) => {
  const calls: { command: string; args: Record<string, unknown> | undefined }[] = []
  const handlers = new Map<string, (payload: unknown) => void>()
  const unlisten = vi.fn()
  const bridge = Layer.succeed(TauriBridge, {
    invoke: (command, args) =>
      Effect.suspend(() => {
        calls.push({ command, args })
        return replies[command] ?? Effect.fail(new CoreError({ command, message: "not stubbed" }))
      }),
    listen: (event, handler) =>
      listenFailure
        ? Effect.fail(listenFailure)
        : Effect.sync(() => {
            handlers.set(event, handler)
            return unlisten
          }),
  })
  const emit = (event: string, payload: unknown) => {
    handlers.get(event)?.(payload)
  }
  return { calls, emit, unlisten, layer: CoreLive.pipe(Layer.provide(bridge)) }
}

const console5: DiscoveredConsole = {
  address: "192.168.0.40",
  name: "PS5-123",
  hostId: "A1B2C3D4E5F6",
  systemVersion: "09060008",
  ps5: true,
  state: "standby",
}

const credentials: Credentials = {
  address: "192.168.0.40",
  ps5: true,
  nickname: "PS5-123",
  mac: "a1b2c3d4e5f6",
  registKey: "AAAAAAAAAAAAAAAAAAAAAA==",
  rpKey: "AAAAAAAAAAAAAAAAAAAAAA==",
  accountId: "AAAAAAAAAAA=",
}

const picture: RenderParams = {
  upscaler: "bilinear",
  sharpness: 0,
  deblock: 0.5,
  deband: 1,
  mlUpscale: true,
  compare: true,
  colorMatrix: "bt601",
  colorRange: "full",
  chroma: "bilinear",
  accurateColor: false,
}

const options: StreamOptions = { height: 1080, fps: 60, hevc: true, bitrate: 15000, audio: true, autoDowngrade: true }

describe("CoreLive", () => {
  describe("discover", () => {
    it.effect("decodes the console list", () => {
      const fake = fakeBridge({ discover: Effect.succeed([console5]) })
      return Effect.gen(function* () {
        const core = yield* Core
        expect(yield* core.discover).toEqual([console5])
        expect(fake.calls).toEqual([{ command: "discover", args: undefined }])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("passes through an invoke failure", () => {
      const failure = new CoreError({ command: "discover", message: "socket failed" })
      const fake = fakeBridge({ discover: Effect.fail(failure) })
      return Effect.gen(function* () {
        const core = yield* Core
        expect(yield* Effect.flip(core.discover)).toBe(failure)
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("turns a malformed reply into a CoreError naming the command", () => {
      const fake = fakeBridge({ discover: Effect.succeed([{ ...console5, state: "busy" }]) })
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.discover)
        expect(error).toBeInstanceOf(CoreError)
        expect(error.command).toBe("discover")
        expect(error.message).toMatch(/^Unexpected reply: /)
      }).pipe(Effect.provide(fake.layer))
    })
  })

  describe("pair", () => {
    it.effect("registers with a normalized PIN and returns the credentials", () => {
      const fake = fakeBridge({ register_console: Effect.succeed(credentials) })
      return Effect.gen(function* () {
        const core = yield* Core
        const result = yield* core.pair({ console: console5, accountId: "AAAAAAAAAAA=", pin: " 1234-5678 " })
        expect(result).toEqual(credentials)
        expect(fake.calls).toEqual([
          {
            command: "register_console",
            args: { request: { address: "192.168.0.40", ps5: true, accountId: "AAAAAAAAAAA=", pin: "12345678" } },
          },
        ])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rejects a short PIN without calling the console", () => {
      const fake = fakeBridge()
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.pair({ console: console5, accountId: "AAAAAAAAAAA=", pin: "1234" }))
        expect(error._tag).toBe("ValidationError")
        expect(error.message).toBe("The PIN has 8 digits")
        expect(fake.calls).toEqual([])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rejects a PIN with too many digits", () => {
      const fake = fakeBridge()
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.pair({ console: console5, accountId: "AAAAAAAAAAA=", pin: "123456789" }))
        expect(error._tag).toBe("ValidationError")
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rejects a missing PSN account without calling the console", () => {
      const fake = fakeBridge()
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.pair({ console: console5, accountId: "", pin: "12345678" }))
        expect(error._tag).toBe("ValidationError")
        expect(error.message).toBe("Sign in to PlayStation first")
        expect(fake.calls).toEqual([])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("turns the native error into a CoreError", () => {
      const fake = fakeBridge({
        register_console: Effect.fail(new CoreError({ command: "register_console", message: "Registration failed" })),
      })
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.pair({ console: console5, accountId: "AAAAAAAAAAA=", pin: "12345678" }))
        expect(error).toEqual(new CoreError({ command: "register_console", message: "Registration failed" }))
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rejects incomplete credentials", () => {
      const { rpKey: _missing, ...partial } = credentials
      const fake = fakeBridge({ register_console: Effect.succeed(partial) })
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.pair({ console: console5, accountId: "AAAAAAAAAAA=", pin: "12345678" }))
        expect(error._tag).toBe("CoreError")
      }).pipe(Effect.provide(fake.layer))
    })
  })

  describe("commands", () => {
    it.effect("wakeup sends the credentials and decodes the boolean", () => {
      const fake = fakeBridge({ wakeup: Effect.succeed(true) })
      return Effect.gen(function* () {
        const core = yield* Core
        expect(yield* core.wakeup(credentials)).toBe(true)
        expect(fake.calls).toEqual([{ command: "wakeup", args: { credentials } }])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("wakeup rejects a non-boolean reply", () => {
      const fake = fakeBridge({ wakeup: Effect.succeed("yes") })
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.wakeup(credentials))
        expect(error.command).toBe("wakeup")
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("startStream sends credentials and options, and requires ok: true", () => {
      const fake = fakeBridge({ start_stream: Effect.succeed({ ok: true }) })
      return Effect.gen(function* () {
        const core = yield* Core
        yield* core.startStream(credentials, options)
        expect(fake.calls).toEqual([{ command: "start_stream", args: { request: { credentials, options } } }])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("startStream fails on an unexpected reply", () => {
      const fake = fakeBridge({ start_stream: Effect.succeed({ ok: false }) })
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.startStream(credentials, options))
        expect(error.command).toBe("start_stream")
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("toggleFullscreen decodes the new state", () => {
      const fake = fakeBridge({ toggle_fullscreen: Effect.succeed(true) })
      return Effect.gen(function* () {
        const core = yield* Core
        expect(yield* core.toggleFullscreen).toBe(true)
        expect(fake.calls).toEqual([{ command: "toggle_fullscreen", args: undefined }])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("void commands accept any reply and forward their arguments", () => {
      const fake = fakeBridge({
        psn_login: Effect.succeed(null),
        stop_stream: Effect.succeed(null),
        set_login_pin: Effect.succeed(null),
        set_render_params: Effect.succeed(null),
      })
      return Effect.gen(function* () {
        const core = yield* Core
        yield* core.psnLogin
        yield* core.stopStream
        yield* core.setLoginPin("1234")
        yield* core.setRenderParams(picture)
        expect(fake.calls).toEqual([
          { command: "psn_login", args: undefined },
          { command: "stop_stream", args: undefined },
          { command: "set_login_pin", args: { pin: "1234" } },
          { command: "set_render_params", args: { params: picture } },
        ])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("void commands still surface invoke failures", () => {
      const fake = fakeBridge({
        set_render_params: Effect.fail(new CoreError({ command: "set_render_params", message: "invalid picture settings" })),
      })
      return Effect.gen(function* () {
        const core = yield* Core
        const exit = yield* Effect.exit(core.setRenderParams(picture))
        expect(Exit.isFailure(exit)).toBe(true)
        // psn_login isn't stubbed: the fake fails it.
        expect((yield* Effect.flip(core.psnLogin)).command).toBe("psn_login")
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rendererStatus decodes the status", () => {
      const status = { metalfxSupported: true, activeMode: "metalfx", gpuMs: 1.25, mlSupported: true, mlActive: false, stream: { active: true, framesDecoded: 10 } }
      const fake = fakeBridge({ renderer_status: Effect.succeed(status) })
      return Effect.gen(function* () {
        const core = yield* Core
        expect(yield* core.rendererStatus).toEqual(status)
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("rendererStatus fails when the host couldn't read stats (stream: null)", () => {
      const fake = fakeBridge({
        renderer_status: Effect.succeed({ metalfxSupported: true, activeMode: "none", gpuMs: 0, mlSupported: false, mlActive: false, stream: null }),
      })
      return Effect.gen(function* () {
        const core = yield* Core
        expect((yield* Effect.flip(core.rendererStatus)).command).toBe("renderer_status")
      }).pipe(Effect.provide(fake.layer))
    })
  })

  describe("events", () => {
    it.effect("onStreamEvent delivers valid events and drops bad payloads", () => {
      const fake = fakeBridge()
      return Effect.gen(function* () {
        const core = yield* Core
        const received: StreamEvent[] = []
        const unlisten = yield* core.onStreamEvent((event) => received.push(event))
        fake.emit("stream-event", { type: "connected" })
        fake.emit("stream-event", { type: "bogus" })
        fake.emit("stream-event", null)
        fake.emit("stream-event", { type: "quit", reason: "Connection lost" })
        fake.emit("stream-event", { type: "quit", reason: "Connection lost", error: true })
        expect(received).toEqual([{ type: "connected" }, { type: "quit", reason: "Connection lost", error: true }])
        unlisten()
        expect(fake.unlisten).toHaveBeenCalledOnce()
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("onPsnAccount delivers the account ID or the error", () => {
      const fake = fakeBridge()
      return Effect.gen(function* () {
        const core = yield* Core
        const received: PsnAccountEvent[] = []
        yield* core.onPsnAccount((event) => received.push(event))
        fake.emit("psn-account", { accountId: "AAAAAAAAAAA=" })
        fake.emit("psn-account", { error: "denied" })
        fake.emit("psn-account", "garbage")
        fake.emit("psn-account", {})
        expect(received).toEqual([{ accountId: "AAAAAAAAAAA=" }, { error: "denied" }])
      }).pipe(Effect.provide(fake.layer))
    })

    it.effect("subscription failures surface as CoreError", () => {
      const fake = fakeBridge({}, new CoreError({ command: "listen:stream-event", message: "no IPC" }))
      return Effect.gen(function* () {
        const core = yield* Core
        const error = yield* Effect.flip(core.onStreamEvent(() => undefined))
        expect(error.command).toBe("listen:stream-event")
      }).pipe(Effect.provide(fake.layer))
    })
  })
})
