import { describe, expect, it } from "@effect/vitest"
import { Effect, Layer, Option } from "effect"
import { fakeCore } from "@/app/testing"
import { Core } from "./core"
import { CoreError } from "./errors"
import { SecretStore } from "./preferences"
import { NativeSecretStoreLive } from "./secrets"

describe("NativeSecretStoreLive", () => {
  it.effect("goes through Core, turning its failures into storage errors", () => {
    const saved = new Map<string, string>()
    const core = fakeCore({
      secretGet: (key) => Effect.succeed(Option.fromNullishOr(saved.get(key))),
      secretSet: (key, value) => Effect.sync(() => void saved.set(key, value)),
      secretRemove: (key) =>
        key === "locked" ? Effect.fail(new CoreError({ command: "secret_remove", message: "Keychain locked" })) : Effect.sync(() => void saved.delete(key)),
    })
    const layer = NativeSecretStoreLive.pipe(Layer.provide(Layer.succeed(Core, core.service)))
    return Effect.gen(function* () {
      const secrets = yield* SecretStore
      yield* secrets.set("k", "v")
      expect(yield* secrets.get("k")).toEqual(Option.some("v"))
      yield* secrets.remove("k")
      expect(yield* secrets.get("k")).toEqual(Option.none())
      const error = yield* Effect.flip(secrets.remove("locked"))
      expect(error).toMatchObject({ _tag: "StorageError", key: "locked", message: "Keychain locked" })
    }).pipe(Effect.provide(layer))
  })
})
