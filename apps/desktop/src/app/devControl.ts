import { Effect, Fiber, Option, Schema } from "effect"
import { useEffect, useEffectEvent } from "react"
import { Settings, type DevCommand } from "@/core/schema"
import * as actions from "./actions"
import { useRuntime } from "./runtime"

/** Settings with a dev control port patch applied, or none when the result isn't valid settings. */
export const patchSettings = (current: Settings, patch: Readonly<Record<string, unknown>>): Option.Option<Settings> =>
  Schema.decodeUnknownOption(Settings)({ ...Schema.encodeSync(Settings)(current), ...patch })

/** Carries out requests from the dev-only control port (`PLAYFX_DEV_CONTROL`; docs/dev-control.md).
 * Inert outside development builds, so a release never listens. */
export const useDevControl = (handler: (command: DevCommand) => void): void => {
  const runtime = useRuntime()
  const onCommand = useEffectEvent(handler)
  useEffect(() => {
    if (!import.meta.env.DEV) return
    const fiber = runtime.runFork(Effect.ignore(actions.onDevControl((command) => { onCommand(command) })))
    return () => {
      Effect.runFork(Fiber.interrupt(fiber))
    }
  }, [runtime])
}
