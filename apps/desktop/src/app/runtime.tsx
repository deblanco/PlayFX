import { Effect, Fiber } from "effect"
import { createContext, use, useCallback, useEffect, type ReactNode } from "react"
import { toast } from "sonner"
import type { AppRuntime, AppServices } from "@/core/runtime"

const RuntimeContext = createContext<AppRuntime | null>(null)

export const RuntimeProvider = ({ runtime, children }: { runtime: AppRuntime; children: ReactNode }) => (
  <RuntimeContext value={runtime}>{children}</RuntimeContext>
)

export const useRuntime = (): AppRuntime => {
  const runtime = use(RuntimeContext)
  if (runtime === null) throw new Error("useRuntime must be used inside <RuntimeProvider>")
  return runtime
}

/** Every app error carries a user-facing message. */
interface Failure {
  readonly message: string
}

export interface RunCallbacks<A> {
  readonly onSuccess?: (value: A) => void
  readonly onFailure?: (error: Failure) => void
}

/** Runs an effect on the app runtime; failures are shown as toasts and logged. */
export const useRun = () => {
  const runtime = useRuntime()
  return useCallback(
    <A, E extends Failure>(effect: Effect.Effect<A, E, AppServices>, callbacks: RunCallbacks<A> = {}): void => {
      runtime.runFork(
        Effect.match(Effect.tapError(effect, (error) => Effect.logWarning(error.message)), {
          onSuccess: (value) => callbacks.onSuccess?.(value),
          onFailure: (error) => {
            toast.error(error.message)
            callbacks.onFailure?.(error)
          },
        }),
      )
    },
    [runtime],
  )
}

/**
 * Runs a long-lived effect (polling, subscriptions) while the component is mounted, interrupting it on
 * unmount or when `effect` changes — memoize it. Failures are shown as toasts.
 */
export const useFork = <A, E extends Failure>(effect: Effect.Effect<A, E, AppServices>): void => {
  const runtime = useRuntime()
  useEffect(() => {
    const fiber = runtime.runFork(
      Effect.tapError(effect, (error) =>
        Effect.andThen(Effect.logWarning(error.message), Effect.sync(() => toast.error(error.message))),
      ),
    )
    return () => {
      Effect.runFork(Fiber.interrupt(fiber))
    }
  }, [runtime, effect])
}
