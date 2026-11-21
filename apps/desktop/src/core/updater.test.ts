import { describe, expect, it, vi } from "@effect/vitest"
import { Effect, Layer } from "effect"
import { CoreError } from "./errors"
import { TauriBridge } from "./tauri"
import { UpdateDeferred, Updater, UpdaterError, UpdaterLive } from "./updater"

type Reply = Effect.Effect<unknown, CoreError>

/** A TauriBridge answering from a table, letting tests fire events. */
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
  return { calls, emit, unlisten, layer: UpdaterLive.pipe(Layer.provide(bridge)) }
}

describe("UpdaterLive", () => {
  it.effect("checks, by hand or in the background, and decodes what it found", () => {
    const fake = fakeBridge({ update_check: Effect.succeed({ status: "available", version: "0.2.5", currentVersion: "0.2.4" }) })
    return Effect.gen(function* () {
      const updater = yield* Updater
      expect(yield* updater.check(false)).toEqual({ status: "available", version: "0.2.5", currentVersion: "0.2.4" })
      yield* updater.check(true)
      expect(fake.calls).toEqual([
        { command: "update_check", args: { automatic: false } },
        { command: "update_check", args: { automatic: true } },
      ])
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("reads up to date and off", () => {
    const replies = [
      { status: "upToDate", currentVersion: "0.2.4" },
      { status: "off", currentVersion: "0.2.4" },
    ]
    return Effect.forEach(replies, (reply) =>
      Effect.gen(function* () {
        expect(yield* (yield* Updater).check(true)).toEqual(reply)
      }).pipe(Effect.provide(fakeBridge({ update_check: Effect.succeed(reply) }).layer)),
    )
  })

  it.effect("turns the native reason, or a reply it can't read, into an UpdaterError", () =>
    Effect.gen(function* () {
      const failing = fakeBridge({ update_check: Effect.fail(new CoreError({ command: "update_check", message: "error sending request" })) })
      const failed = yield* Effect.flip(Effect.flatMap(Updater, (u) => u.check(false)).pipe(Effect.provide(failing.layer)))
      expect(failed).toEqual(new UpdaterError({ message: "error sending request" }))
      const odd = fakeBridge({ update_check: Effect.succeed({ status: "maybe" }) })
      const unreadable = yield* Effect.flip(Effect.flatMap(Updater, (u) => u.check(false)).pipe(Effect.provide(odd.layer)))
      expect(unreadable.message).toMatch(/^Unexpected reply/)
    }),
  )

  it.effect("installs, reporting the download's progress until it's done", () => {
    const percents: (number | undefined)[] = []
    const fake = fakeBridge({
      update_install: Effect.suspend(() => {
        fake.emit("update-progress", { percent: null })
        fake.emit("update-progress", { percent: 42 })
        fake.emit("update-progress", { percent: "lots" }) // not progress: dropped
        fake.emit("update-progress", { percent: 100 })
        return Effect.succeed(null)
      }),
    })
    return Effect.gen(function* () {
      yield* (yield* Updater).install((percent) => percents.push(percent))
      expect(percents).toEqual([undefined, 42, 100])
      expect(fake.calls).toEqual([{ command: "update_install", args: undefined }])
      expect(fake.unlisten).toHaveBeenCalledOnce()
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("stops listening when installing fails, and says why", () => {
    const fake = fakeBridge({ update_install: Effect.fail(new CoreError({ command: "update_install", message: "Permission denied (os error 13)" })) })
    return Effect.gen(function* () {
      const error = yield* Effect.flip((yield* Updater).install(() => undefined))
      expect(error).toEqual(new UpdaterError({ message: "Permission denied (os error 13)" }))
      expect(fake.unlisten).toHaveBeenCalledOnce()
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("tells a refusal during a stream (the update waits) from a failure", () => {
    const refused = (command: string) => Effect.fail(new CoreError({ command, message: "Finish playing to update" }))
    const fake = fakeBridge({ update_install: refused("update_install"), update_restart: refused("update_restart") })
    return Effect.gen(function* () {
      const updater = yield* Updater
      expect(yield* Effect.flip(updater.install(() => undefined))).toEqual(new UpdateDeferred({ message: "Finish playing to update" }))
      expect(yield* Effect.flip(updater.restart)).toEqual(new UpdateDeferred({ message: "Finish playing to update" }))
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("tells the native side whether the app is playing", () => {
    const fake = fakeBridge({ update_set_playing: Effect.succeed(null) })
    return Effect.gen(function* () {
      const updater = yield* Updater
      yield* updater.setPlaying(true)
      yield* updater.setPlaying(false)
      expect(fake.calls).toEqual([
        { command: "update_set_playing", args: { playing: true } },
        { command: "update_set_playing", args: { playing: false } },
      ])
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("doesn't install when it can't follow the progress", () => {
    const fake = fakeBridge({ update_install: Effect.succeed(null) }, new CoreError({ command: "listen:update-progress", message: "no IPC" }))
    return Effect.gen(function* () {
      expect(yield* Effect.flip((yield* Updater).install(() => undefined))).toEqual(new UpdaterError({ message: "no IPC" }))
      expect(fake.calls).toEqual([])
    }).pipe(Effect.provide(fake.layer))
  })

  it.effect("restarts, and opens a release's page", () => {
    const fake = fakeBridge({ update_restart: Effect.succeed(null), open_release_page: Effect.succeed(null) })
    return Effect.gen(function* () {
      const updater = yield* Updater
      yield* updater.restart
      yield* updater.openReleasePage("0.2.5")
      expect(fake.calls).toEqual([
        { command: "update_restart", args: undefined },
        { command: "open_release_page", args: { version: "0.2.5" } },
      ])
    }).pipe(Effect.provide(fake.layer))
  })
})
