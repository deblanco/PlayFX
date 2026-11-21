import { describe, expect, it } from "@effect/vitest"
import { Effect, Fiber, Layer, Option } from "effect"
import { TestClock } from "effect/testing"
import { StorageError } from "@/core/errors"
import { KeyValueStore, memoryStore, PreferencesLive } from "@/core/preferences"
import { UpdateDeferred, UpdaterError, type UpdateCheck } from "@/core/updater"
import { checkLine, checkPeriodically, dismissUpdate, installUpdate, loadDismissedUpdate, restartIntoUpdate, setPlaying } from "./selfUpdate"
import { fakeUpdater } from "./testing"

const upToDate: UpdateCheck = { status: "upToDate", currentVersion: "0.2.4" }
const available: UpdateCheck = { status: "available", version: "0.2.5", currentVersion: "0.2.4" }

describe("the background check", () => {
  it.effect("runs 5 s after launch, then every 6 hours, a failure waiting for the next", () =>
    Effect.gen(function* () {
      const updater = fakeUpdater()
      updater.state.check = upToDate
      const seen: UpdateCheck[] = []
      const fiber = yield* Effect.forkChild(checkPeriodically((check) => seen.push(check)).pipe(Effect.provide(updater.layer)))
      yield* TestClock.adjust("4999 millis")
      expect(updater.calls.checks).toEqual([])
      yield* TestClock.adjust("1 millis")
      expect(updater.calls.checks).toEqual([true]) // the background kind
      expect(seen).toEqual([upToDate])
      updater.state.checkError = "error sending request"
      yield* TestClock.adjust("5 hours")
      expect(updater.calls.checks).toHaveLength(1)
      yield* TestClock.adjust("1 hour")
      expect(updater.calls.checks).toHaveLength(2)
      expect(seen).toEqual([upToDate])
      updater.state.checkError = undefined
      updater.state.check = available
      yield* TestClock.adjust("6 hours")
      expect(seen).toEqual([upToDate, available])
      yield* Fiber.interrupt(fiber)
    }),
  )
})

describe("checkLine", () => {
  it("says what a check by hand found", () => {
    expect(checkLine(upToDate)).toBe("PlayFX is up to date (0.2.4)")
    expect(checkLine(available)).toBe("PlayFX 0.2.5 is available.")
    expect(checkLine({ status: "off", currentVersion: "0.2.4" })).toBe("Automatic update checks are off in this build (0.2.4)")
  })
})

describe("installUpdate", () => {
  it.effect("installs, reporting the progress, and doesn't restart on its own", () =>
    Effect.gen(function* () {
      const steps: string[] = []
      const updater = fakeUpdater({ install: (onProgress) => Effect.sync(() => { steps.push("install"); onProgress(100) }) })
      yield* installUpdate((percent) => steps.push(`${String(percent)}%`)).pipe(Effect.provide(updater.layer))
      expect(steps).toEqual(["install", "100%"])
      expect(updater.calls.restarts).toBe(0)
    }),
  )

  it.effect("says why it failed", () =>
    Effect.gen(function* () {
      const updater = fakeUpdater({ install: () => Effect.fail(new UpdaterError({ message: "Permission denied (os error 13)" })) })
      const error = yield* Effect.flip(installUpdate(() => undefined).pipe(Effect.provide(updater.layer)))
      expect(error.message).toBe("Permission denied (os error 13)")
    }),
  )
})

describe("restartIntoUpdate", () => {
  it.effect("says it's restarting, then restarts", () =>
    Effect.gen(function* () {
      const steps: string[] = []
      const updater = fakeUpdater({ restart: Effect.sync(() => { steps.push("restart") }) })
      yield* restartIntoUpdate(() => false, () => steps.push("restarting")).pipe(Effect.provide(updater.layer))
      expect(steps).toEqual(["restarting", "restart"])
    }),
  )

  it.effect("waits while the app is playing, without asking the native side", () =>
    Effect.gen(function* () {
      const updater = fakeUpdater()
      let restarting = false
      const error = yield* Effect.flip(restartIntoUpdate(() => true, () => { restarting = true }).pipe(Effect.provide(updater.layer)))
      expect(error).toEqual(new UpdateDeferred({ message: "Finish playing to update" }))
      expect(restarting).toBe(false)
      expect(updater.calls.restarts).toBe(0)
    }),
  )
})

describe("setPlaying", () => {
  it.effect("tells the updater", () =>
    Effect.gen(function* () {
      const updater = fakeUpdater()
      yield* setPlaying(true).pipe(Effect.provide(updater.layer))
      expect(updater.calls.playing).toEqual([true])
    }),
  )
})

describe("the version put off with Later", () => {
  it.effect("is saved and read back", () =>
    Effect.gen(function* () {
      yield* dismissUpdate("0.2.5")
      expect(yield* loadDismissedUpdate).toEqual(Option.some("0.2.5"))
    }).pipe(Effect.provide(PreferencesLive.pipe(Layer.provide(memoryStore())))),
  )

  it.effect("reads as none when storage fails", () => {
    const failing = Layer.succeed(KeyValueStore, {
      get: (key) => Effect.fail(new StorageError({ key, message: "denied" })),
      set: (key) => Effect.fail(new StorageError({ key, message: "denied" })),
      remove: (key) => Effect.fail(new StorageError({ key, message: "denied" })),
    })
    return Effect.gen(function* () {
      expect(yield* loadDismissedUpdate).toEqual(Option.none())
    }).pipe(Effect.provide(PreferencesLive.pipe(Layer.provide(failing))))
  })
})
