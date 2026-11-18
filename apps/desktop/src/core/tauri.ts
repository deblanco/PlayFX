import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { Context, Effect, Layer } from "effect"
import { CoreError } from "./errors"

/** The raw Tauri IPC, isolated so everything above it can be tested with a fake. */
export class TauriBridge extends Context.Service<
  TauriBridge,
  {
    readonly invoke: (command: string, args?: Record<string, unknown>) => Effect.Effect<unknown, CoreError>
    /** Subscribes to an app event; the returned effect's value unsubscribes. */
    readonly listen: (event: string, handler: (payload: unknown) => void) => Effect.Effect<() => void, CoreError>
  }
>()("TauriBridge") {}

const describe = (error: unknown): string => (error instanceof Error ? error.message : String(error))

export const TauriBridgeLive = Layer.succeed(TauriBridge, {
  invoke: (command, args) =>
    Effect.tryPromise({
      try: () => invoke<unknown>(command, args),
      catch: (error) => new CoreError({ command, message: describe(error) }),
    }),
  listen: (event, handler) =>
    Effect.tryPromise({
      try: () => listen<unknown>(event, ({ payload }) => handler(payload)),
      catch: (error) => new CoreError({ command: `listen:${event}`, message: describe(error) }),
    }),
})
