import { Effect, Layer } from "effect"
import { Core } from "./core"
import { StorageError } from "./errors"
import { SecretStore } from "./preferences"

/** The secret store backed by StreamCore (Keychain in release builds, a 0600 file in development). */
export const NativeSecretStoreLive = Layer.effect(
  SecretStore,
  Effect.gen(function* () {
    const core = yield* Core
    const failed = (key: string) => (error: { readonly message: string }) => new StorageError({ key, message: error.message })
    return {
      get: (key) => Effect.mapError(core.secretGet(key), failed(key)),
      set: (key, value) => Effect.mapError(core.secretSet(key, value), failed(key)),
      remove: (key) => Effect.mapError(core.secretRemove(key), failed(key)),
    }
  }),
)
