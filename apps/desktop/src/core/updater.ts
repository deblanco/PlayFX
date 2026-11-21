import { Context, Effect, Layer, Schema } from "effect"
import { TauriBridge } from "./tauri"

// Updates through GitHub Releases (see src-tauri/src/updates.rs): the native side checks the latest release,
// downloads its signed update, verifies and installs it, and restarts into it.

/** Checking, downloading or installing an update failed; the message says what happened. */
export class UpdaterError extends Schema.TaggedError<UpdaterError>()("UpdaterError", {
  message: Schema.String,
}) {}

/** What a check found. "off": the background check in a development build, which asks nothing. */
export const UpdateCheck = Schema.Union([
  Schema.Struct({ status: Schema.Literal("available"), version: Schema.String, currentVersion: Schema.String }),
  Schema.Struct({ status: Schema.Literals(["upToDate", "off"]), currentVersion: Schema.String }),
])
export type UpdateCheck = typeof UpdateCheck.Type

/** A download's progress: the whole percentage, null while the size isn't known. */
export const UpdateProgress = Schema.Struct({ percent: Schema.NullOr(Schema.Number) })

export class Updater extends Context.Service<
  Updater,
  {
    /** Asks for a newer release; `automatic` is the background check. */
    readonly check: (automatic: boolean) => Effect.Effect<UpdateCheck, UpdaterError>
    /** Downloads, verifies and installs the release the last check found; `onProgress` gets the percentage
     * (undefined while the size isn't known). Refused while a stream runs. */
    readonly install: (onProgress: (percent: number | undefined) => void) => Effect.Effect<void, UpdaterError>
    /** Quits and opens the installed update. Refused while a stream runs. */
    readonly restart: Effect.Effect<void, UpdaterError>
    /** Opens a release's page on GitHub in the browser. */
    readonly openReleasePage: (version: string) => Effect.Effect<void, UpdaterError>
  }
>()("Updater") {}

export const UpdaterLive = Layer.effect(
  Updater,
  Effect.gen(function* () {
    const tauri = yield* TauriBridge
    const failed = (error: { readonly message: string }) => new UpdaterError({ message: error.message })

    const call = <S extends Schema.Top & { readonly DecodingServices: never }>(
      schema: S,
      command: string,
      args?: Record<string, unknown>,
    ): Effect.Effect<S["Type"], UpdaterError> =>
      tauri.invoke(command, args).pipe(
        Effect.mapError(failed),
        Effect.flatMap((reply) =>
          Schema.decodeUnknownEffect(schema)(reply).pipe(
            Effect.mapError((error) => new UpdaterError({ message: `Unexpected reply: ${error.message}` })),
          ),
        ),
      )

    return {
      check: (automatic) => call(UpdateCheck, "update_check", { automatic }),
      install: (onProgress) =>
        Effect.scoped(
          Effect.gen(function* () {
            yield* Effect.acquireRelease(
              tauri
                .listen("update-progress", (payload) => {
                  const decoded = Schema.decodeUnknownOption(UpdateProgress)(payload)
                  if (decoded._tag === "Some") onProgress(decoded.value.percent ?? undefined)
                })
                .pipe(Effect.mapError(failed)),
              (unsubscribe) => Effect.sync(unsubscribe),
            )
            yield* call(Schema.Unknown, "update_install")
          }),
        ),
      restart: Effect.asVoid(call(Schema.Unknown, "update_restart")),
      openReleasePage: (version) => Effect.asVoid(call(Schema.Unknown, "open_release_page", { version })),
    }
  }),
)
