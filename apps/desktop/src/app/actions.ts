import { Clock, Deferred, Effect, Option, Ref, Schedule, Schema } from "effect"
import { Core } from "@/core/core"
import { ValidationError, type CoreError, type StorageError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import {
  isAccountId,
  sameRenderParams,
  type DiscoveredConsole,
  type ControllerState,
  type PairedConsole,
  type PairedConsoles,
  type PsnAccountEvent,
  type Settings,
  type StreamEvent,
} from "@/core/schema"
import { framesPerSecond, hudStats, megabitsPerSecond, renderParams, streamOptions, type FrameSample } from "./format"

// Every side effect the UI triggers lives here, as an Effect over the Core and Preferences services.

/** Sony's sign-in window reported a failure. */
export class SignInFailed extends Schema.TaggedError<SignInFailed>()("SignInFailed", { message: Schema.String }) {}

/** A stream couldn't be restarted with new settings. */
export class ReconnectFailed extends Schema.TaggedError<ReconnectFailed>()("ReconnectFailed", {
  message: Schema.String,
}) {}

/** The console didn't acknowledge the wake-up packet. */
export class WakeFailed extends Schema.TaggedError<WakeFailed>()("WakeFailed", { message: Schema.String }) {}

/** Holds a subscription open until the fiber running it is interrupted, then unsubscribes. */
const listen = <E, R>(subscribe: Effect.Effect<() => void, E, R>): Effect.Effect<never, E, R> =>
  Effect.scoped(
    Effect.acquireRelease(subscribe, (unsubscribe) => Effect.sync(unsubscribe)).pipe(Effect.andThen(Effect.never)),
  )

// ---------- Account ----------

export const loadAccount: Effect.Effect<Option.Option<string>, StorageError, Preferences> = Effect.gen(function* () {
  const prefs = yield* Preferences
  return yield* prefs.accountId
})

/** Validates and stores a PSN account ID (8 bytes, base64). */
export const saveAccountId = (raw: string): Effect.Effect<string, ValidationError | StorageError, Preferences> =>
  Effect.gen(function* () {
    const id = raw.trim()
    if (!isAccountId(id)) {
      return yield* new ValidationError({
        message: "An account ID is 8 bytes in base64 (12 characters ending in '=')",
      })
    }
    const prefs = yield* Preferences
    yield* prefs.setAccountId(Option.some(id))
    return id
  })

export const signOut: Effect.Effect<void, StorageError, Preferences> = Effect.gen(function* () {
  const prefs = yield* Preferences
  yield* prefs.setAccountId(Option.none())
})

/** Opens Sony's sign-in window; the account arrives later through `onPsnAccount`. */
export const signIn: Effect.Effect<void, CoreError, Core> = Effect.gen(function* () {
  const core = yield* Core
  yield* core.psnLogin
})

/** Stores the account from a sign-in result, or fails with Sony's error. */
export const receivePsnAccount = (
  event: PsnAccountEvent,
): Effect.Effect<string, SignInFailed | ValidationError | StorageError, Preferences> =>
  "accountId" in event
    ? saveAccountId(event.accountId)
    : Effect.fail(new SignInFailed({ message: `PSN sign-in failed: ${event.error}` }))

export const onPsnAccount = (handler: (event: PsnAccountEvent) => void): Effect.Effect<never, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    return yield* listen(core.onPsnAccount(handler))
  })

// ---------- Consoles ----------

export const loadPaired: Effect.Effect<PairedConsoles, StorageError, Preferences> = Effect.gen(function* () {
  const prefs = yield* Preferences
  return yield* prefs.paired
})

export interface ScanResult {
  readonly discovered: readonly DiscoveredConsole[]
  readonly paired: PairedConsoles
}

/** One discovery round; keeps saved addresses current when a paired console changed IP. */
export const scan: Effect.Effect<ScanResult, CoreError | StorageError, Core | Preferences> = Effect.gen(function* () {
  const core = yield* Core
  const prefs = yield* Preferences
  const discovered = yield* core.discover
  yield* prefs.refreshAddresses(discovered.map(({ hostId, address }) => ({ hostId, address })))
  const paired = yield* prefs.paired
  return { discovered, paired }
})

export type ScanOutcome = ({ readonly ok: true } & ScanResult) | { readonly ok: false; readonly message: string }

export const discoveryInterval = "5 seconds"

/** Scans now and every 5 s until interrupted, reporting each round. */
export const pollDiscovery = (report: (outcome: ScanOutcome) => void): Effect.Effect<number, never, Core | Preferences> =>
  scan.pipe(
    Effect.match({
      onSuccess: (result): ScanOutcome => ({ ok: true, ...result }),
      onFailure: (error): ScanOutcome => ({ ok: false, message: `Discovery failed: ${error.message}` }),
    }),
    Effect.flatMap((outcome) => Effect.sync(() => { report(outcome); })),
    Effect.repeat(Schedule.spaced(discoveryInterval)),
  )

/** Pairs with a console using the PIN it shows; returns the updated paired list. */
export const pair = (
  console: DiscoveredConsole,
  pin: string,
): Effect.Effect<PairedConsoles, CoreError | ValidationError | StorageError, Core | Preferences> =>
  Effect.gen(function* () {
    const core = yield* Core
    const prefs = yield* Preferences
    const accountId = Option.getOrElse(yield* prefs.accountId, () => "")
    const credentials = yield* core.pair({ console, accountId, pin })
    yield* prefs.savePaired({ hostId: console.hostId, name: credentials.nickname || console.name, credentials })
    return yield* prefs.paired
  })

export const wake = (console: PairedConsole): Effect.Effect<void, CoreError | WakeFailed, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    const sent = yield* core.wakeup(console.credentials)
    if (!sent) return yield* new WakeFailed({ message: "Wake-up failed" })
  })

export const forget = (hostId: string): Effect.Effect<PairedConsoles, StorageError, Preferences> =>
  Effect.gen(function* () {
    const prefs = yield* Preferences
    yield* prefs.forget(hostId)
    return yield* prefs.paired
  })

// ---------- Settings ----------

export interface Startup {
  readonly settings: Settings
  readonly metalfxSupported: boolean
}

/** Loads saved settings and applies the saved picture settings to the renderer. */
export const startup: Effect.Effect<Startup, CoreError | StorageError, Core | Preferences> = Effect.gen(function* () {
  const core = yield* Core
  const prefs = yield* Preferences
  const settings = yield* prefs.settings
  const status = yield* core.rendererStatus
  yield* core.setRenderParams(renderParams(settings))
  return { settings, metalfxSupported: status.metalfxSupported }
})

/** Persists new settings, updating the renderer when a picture setting changed. */
export const changeSettings = (
  previous: Settings,
  next: Settings,
): Effect.Effect<Settings, CoreError | StorageError, Core | Preferences> =>
  Effect.gen(function* () {
    const core = yield* Core
    const prefs = yield* Preferences
    yield* prefs.saveSettings(next)
    const params = renderParams(next)
    if (!sameRenderParams(params, renderParams(previous))) yield* core.setRenderParams(params)
    return next
  })

// ---------- Streaming ----------

export const play = (console: PairedConsole, settings: Settings): Effect.Effect<void, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    yield* core.startStream(console.credentials, streamOptions(settings))
  })

// The PS5 refuses a new session for ~9 s after one ends ("busy"), so a reconnect retries.
export const reconnectRetryDelay = "1500 millis"
export const reconnectGiveUpMs = 30_000
export const reconnectAnswerTimeout = "15 seconds"

type Answer = "connected" | "busy"

/** Starts a stream and waits for the console's answer. The previous session's normal quit can
 * arrive meanwhile; only connected, busy and error quits count. */
const attemptStream = (
  console: PairedConsole,
  settings: Settings,
): Effect.Effect<Answer, CoreError | ReconnectFailed, Core> =>
  Effect.scoped(
    Effect.gen(function* () {
      const core = yield* Core
      const answer = yield* Deferred.make<Answer, ReconnectFailed>()
      yield* Effect.acquireRelease(
        core.onStreamEvent((event) => {
          if (event.type === "connected") Deferred.doneUnsafe(answer, Effect.succeed("connected"))
          else if (event.type === "quit" && event.busy === true) Deferred.doneUnsafe(answer, Effect.succeed("busy"))
          else if (event.type === "quit" && event.error)
            Deferred.doneUnsafe(answer, Effect.fail(new ReconnectFailed({ message: `Reconnect failed: ${event.reason}` })))
        }),
        (unsubscribe) => Effect.sync(unsubscribe),
      )
      yield* core.startStream(console.credentials, streamOptions(settings))
      return yield* Deferred.await(answer).pipe(
        Effect.timeoutOrElse({
          duration: reconnectAnswerTimeout,
          orElse: () => Effect.fail(new ReconnectFailed({ message: "The console didn't answer. Try again." })),
        }),
      )
    }),
  )

/** Restarts the stream with new settings, retrying while the console is still busy. */
export const reconnect = (
  console: PairedConsole,
  settings: Settings,
): Effect.Effect<void, CoreError | ReconnectFailed, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    yield* core.stopStream
    const started = yield* Clock.currentTimeMillis
    const loop: Effect.Effect<void, CoreError | ReconnectFailed, Core> = Effect.suspend(() =>
      Effect.flatMap(attemptStream(console, settings), (answer) =>
        answer === "connected"
          ? Effect.void
          : Effect.gen(function* () {
              if ((yield* Clock.currentTimeMillis) - started >= reconnectGiveUpMs) {
                return yield* new ReconnectFailed({ message: "The console is still busy. Try again in a moment." })
              }
              yield* Effect.sleep(reconnectRetryDelay)
              return yield* loop
            }),
      ),
    )
    return yield* loop
  })

export const stop: Effect.Effect<void, CoreError, Core> = Effect.gen(function* () {
  const core = yield* Core
  yield* core.stopStream
})

/** Sends a controller state to the console (keyboard-as-controller). */
export const setController = (state: ControllerState): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.setController(state))

/** Sends the console's login PIN (asked for when the PS5 user has a passcode). */
export const submitLoginPin = (raw: string): Effect.Effect<void, CoreError | ValidationError, Core> =>
  Effect.gen(function* () {
    const pin = raw.trim()
    if (!/^\d{4}$/.test(pin)) return yield* new ValidationError({ message: "The login PIN has 4 digits" })
    const core = yield* Core
    yield* core.setLoginPin(pin)
  })

export const onStreamEvent = (handler: (event: StreamEvent) => void): Effect.Effect<never, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    return yield* listen(core.onStreamEvent(handler))
  })

export const statsInterval = "1 second"

/** Polls the renderer every second, reporting the HUD stats line; failed polls are skipped. */
export const pollStats = (report: (stats: string) => void): Effect.Effect<number, never, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    const last = yield* Ref.make<FrameSample>({ frames: 0, bytes: 0, time: yield* Clock.currentTimeMillis })
    const tick = Effect.gen(function* () {
      const status = yield* core.rendererStatus
      const sample = {
        frames: status.stream.framesDecoded ?? 0,
        bytes: status.stream.bytesReceived ?? 0,
        time: yield* Clock.currentTimeMillis,
      }
      const previous = yield* Ref.getAndSet(last, sample)
      report(hudStats(status, framesPerSecond(previous, sample), megabitsPerSecond(previous, sample)))
    })
    return yield* Effect.ignore(tick).pipe(Effect.repeat(Schedule.spaced(statsInterval)))
  })
