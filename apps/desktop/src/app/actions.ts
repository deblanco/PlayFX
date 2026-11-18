import { Clock, Deferred, Effect, Option, Ref, Schedule, Schema } from "effect"
import { Core } from "@/core/core"
import { detailedLogs, setDetailedLogs } from "@/core/logging"
import { ValidationError, type CoreError, type StorageError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import {
  isAccountId,
  type Diagnostics,
  type RendererStatus,
  type DiscoveredConsole,
  type ControllerState,
  type PairedConsole,
  type PairedConsoles,
  type PsnAccountEvent,
  type Settings,
  type StreamEvent,
} from "@/core/schema"
import {
  describeEvent,
  framesPerSecond,
  hudStats,
  megabitsPerSecond,
  psnDeviceIds,
  renderParams,
  streamOptions,
  type Capabilities,
  type FrameSample,
} from "./format"

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

/** Forgets the account ID and the PSN sign-in kept for internet play. */
export const signOut: Effect.Effect<void, StorageError | CoreError, Preferences | Core> = Effect.gen(function* () {
  const prefs = yield* Preferences
  const core = yield* Core
  yield* prefs.setAccountId(Option.none())
  yield* core.psnSignOut
})

/** The PSN device IDs of the paired consoles PSN can reach (hostId → duid); empty when not signed in
 * for internet play, or when PSN can't be reached. */
export const psnReachable = (paired: PairedConsoles): Effect.Effect<Readonly<Record<string, string>>, never, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    if (!(yield* core.psnSignedIn)) return {}
    return psnDeviceIds(paired, yield* core.psnConsoles)
  }).pipe(Effect.orElseSucceed(() => ({})))

/** The console's PSN device ID if it can be reached over the internet right now (asks PSN). */
export const psnDuidFor = (console: PairedConsole): Effect.Effect<string | undefined, never, Core> =>
  Effect.map(psnReachable({ [console.hostId]: console }), (ids) => ids[console.hostId])

/** Whether consoles can be reached over the internet (a PSN sign-in is kept). */
export const internetReady: Effect.Effect<boolean, CoreError, Core> = Effect.flatMap(Core, (core) => core.psnSignedIn)

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
    yield* Effect.logInfo(`Pairing with ${console.name} at ${console.address}`)
    const credentials = yield* core.pair({ console, accountId, pin })
    yield* prefs.savePaired({ hostId: console.hostId, name: credentials.nickname || console.name, credentials })
    yield* Effect.logInfo(`Paired with ${credentials.nickname || console.name}`)
    return yield* prefs.paired
  })

export const wake = (console: PairedConsole): Effect.Effect<void, CoreError | WakeFailed, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    yield* Effect.logInfo(`Waking ${console.name}`)
    const sent = yield* core.wakeup(console.credentials)
    if (!sent) return yield* new WakeFailed({ message: "Wake-up failed" })
  })

export const wakeTimeout = "45 seconds"
export const wakePollInterval = "1 second"
/** Wake packets are UDP and can get lost: send one again every this many status checks. */
const wakeResendEvery = 5

/** Whether discovery currently sees `console` ready for Remote Play (a failed scan counts as not yet). */
const isReady = (console: PairedConsole): Effect.Effect<boolean, never, Core> =>
  Effect.flatMap(Core, (core) => core.discover).pipe(
    Effect.map((found) => found.some((d) => d.hostId === console.hostId && d.state === "ready")),
    Effect.orElseSucceed(() => false),
  )

/** How Play reaches a console after waking it. */
export type WakeRoute = { readonly via: "local" } | { readonly via: "internet"; readonly psnDuid: string }

/** With PSN available, how long to wait for a local wake before going through PSN instead. */
export const wakeFallbackAfter = "20 seconds"

/** Wakes a console from rest mode and waits until it can stream. A PS5 in deeper rest may not hear the
 * local wake-up at all; when PSN can reach it (`psnDuid`), Play then goes through PSN, which wakes it
 * as part of connecting. */
export const wakeUntilReady = (
  console: PairedConsole,
  psnDuid?: string,
): Effect.Effect<WakeRoute, CoreError | WakeFailed, Core> =>
  Effect.gen(function* () {
    const internet: WakeRoute | undefined = psnDuid === undefined ? undefined : { via: "internet", psnDuid }
    const local: WakeRoute = { via: "local" }
    const viaPsn = (why: string): Effect.Effect<WakeRoute> =>
      Effect.as(Effect.logInfo(`${why}; connecting through PSN, which wakes it`), internet ?? local)
    const sent = yield* wake(console).pipe(
      Effect.as(true),
      Effect.catch((error) => (internet ? Effect.succeed(false) : Effect.fail(error))),
    )
    if (!sent) return yield* viaPsn(`Couldn't wake ${console.name} on this network`)
    const waitForReady = (checks: number): Effect.Effect<void, never, Core> =>
      Effect.flatMap(isReady(console), (ready) =>
        ready
          ? Effect.void
          : Effect.gen(function* () {
              yield* Effect.sleep(wakePollInterval)
              // Resend now and then (UDP can get lost); a failed resend is no reason to stop waiting.
              if ((checks + 1) % wakeResendEvery === 0) yield* Effect.ignore(wake(console))
              return yield* waitForReady(checks + 1)
            }),
      )
    return yield* waitForReady(0).pipe(
      Effect.tap(() => Effect.logInfo(`${console.name} is ready`)),
      Effect.as(local),
      Effect.timeoutOrElse({
        duration: internet ? wakeFallbackAfter : wakeTimeout,
        orElse: () =>
          internet
            ? viaPsn(`${console.name} didn't answer the wake-up on this network`)
            : Effect.fail(
                new WakeFailed({
                  message: `${console.name} didn't wake up. Check that "Stay connected to the internet" is on in its rest mode settings.`,
                }),
              ),
      }),
      Effect.tapError((error) => Effect.logWarning(error.message)),
    )
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
  readonly capabilities: Capabilities
}

/** Switches detailed logs (native and web UI) when the setting differs from what's applied. */
const applyDetailedLogs = (on: boolean): Effect.Effect<void, CoreError, Core> =>
  Effect.gen(function* () {
    if ((yield* detailedLogs) === on) return
    const core = yield* Core
    yield* core.setDetailedLogs(on)
    yield* setDetailedLogs(on)
  })

/** Copying to the clipboard failed. */
export class ClipboardFailed extends Schema.TaggedError<ClipboardFailed>()("ClipboardFailed", {
  message: Schema.String,
}) {}

/** A bug-report text: versions, what the renderer supports, the settings (nothing secret in them), and
 * the end of the log file (already scrubbed of credentials). */
export const diagnosticsReport = (d: Diagnostics, status: RendererStatus, settings: Settings): string =>
  [
    `PS Remote Play ${d.appVersion} on ${d.os}`,
    `Renderer: MetalFX ${status.metalfxSupported ? "yes" : "no"}, ML super-resolution ${status.mlSupported ? "yes" : "no"}`,
    `Settings: ${JSON.stringify(settings)}`,
    `Log folder: ${d.logFolder}`,
    "",
    "Recent log:",
    d.recentLog,
  ].join("\n")

/** Puts a diagnostics report on the clipboard, for bug reports. */
export const copyDiagnostics = (settings: Settings): Effect.Effect<void, CoreError | ClipboardFailed, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    const report = diagnosticsReport(yield* core.diagnostics, yield* core.rendererStatus, settings)
    yield* Effect.tryPromise({
      try: () => navigator.clipboard.writeText(report),
      catch: () => new ClipboardFailed({ message: "Couldn't copy the diagnostics to the clipboard" }),
    })
    yield* Effect.logInfo("Diagnostics copied")
  })

export const openLogsFolder: Effect.Effect<void, CoreError, Core> = Effect.flatMap(Core, (core) => core.openLogsFolder)

/** Loads saved settings and applies the saved picture settings to the renderer. */
export const startup: Effect.Effect<Startup, CoreError | StorageError, Core | Preferences> = Effect.gen(function* () {
  const core = yield* Core
  const prefs = yield* Preferences
  const settings = yield* prefs.settings
  const status = yield* core.rendererStatus
  yield* core.setRenderParams(renderParams(settings))
  yield* applyDetailedLogs(settings.detailedLogs)
  return { settings, capabilities: { metalfx: status.metalfxSupported, ml: status.mlSupported } }
})

/** Persists new settings and applies their picture part to the renderer (cheap, and always the latest
 * state, so quick successive changes can't leave the renderer on a stale value). */
export const changeSettings = (next: Settings): Effect.Effect<Settings, CoreError | StorageError, Core | Preferences> =>
  Effect.gen(function* () {
    const core = yield* Core
    const prefs = yield* Preferences
    yield* prefs.saveSettings(next)
    yield* applyDetailedLogs(next.detailedLogs)
    yield* Effect.logDebug(`Settings: ${JSON.stringify(next)}`)
    yield* core.setRenderParams(renderParams(next))
    return next
  })

// ---------- Streaming ----------

/** Starts streaming; with `psnDuid` (the console's PSN device ID) it connects over the internet. */
export const play = (console: PairedConsole, settings: Settings, psnDuid?: string): Effect.Effect<void, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    const o = streamOptions(settings)
    yield* Effect.logInfo(
      `Play ${console.name} ${psnDuid === undefined ? "on the local network" : "over the internet"}: ` +
        `${String(o.height)}p${String(o.fps)} ${o.hevc ? "HEVC" : "H.264"}, ${o.bitrate === 0 ? "auto bitrate" : `${String(o.bitrate)} kbps`}`,
    )
    yield* core.startStream(console.credentials, o, psnDuid)
  })

export const psnPollInterval = "1 minute"

/** Which paired consoles PSN can reach, now and every minute, until interrupted. */
export const pollPsnReachable = (
  paired: PairedConsoles,
  report: (reachable: Readonly<Record<string, string>>) => void,
): Effect.Effect<number, never, Core> =>
  psnReachable(paired).pipe(
    Effect.flatMap((reachable) => Effect.sync(() => { report(reachable) })),
    Effect.repeat(Schedule.spaced(psnPollInterval)),
  )

// The PS5 refuses a new session for ~9 s after one ends ("busy"), so a reconnect retries.
export const reconnectRetryDelay = "1500 millis"
export const reconnectGiveUpMs = 30_000
export const reconnectAnswerTimeout = "15 seconds"
/** Over the internet, PSN setup alone can take up to ~30 s per step. */
export const remoteAnswerTimeout = "2 minutes"

/** After this long without a drop, a stream's earlier automatic reconnects are forgiven. */
export const stableAfter = "60 seconds"
export const waitUntilStable: Effect.Effect<void> = Effect.sleep(stableAfter)

type Answer = "connected" | "busy"

/** Starts a stream and waits for the console's answer: connected (or asking for the login PIN), busy,
 * or any other quit as a failure. The replaced session's own "stopped" quit can arrive meanwhile and
 * is ignored. */
const attemptStream = (
  console: PairedConsole,
  settings: Settings,
  psnDuid: string | undefined,
): Effect.Effect<Answer, CoreError | ReconnectFailed, Core> =>
  Effect.scoped(
    Effect.gen(function* () {
      const core = yield* Core
      const answer = yield* Deferred.make<Answer, ReconnectFailed>()
      yield* Effect.acquireRelease(
        core.onStreamEvent((event) => {
          if (event.type === "connected" || event.type === "loginPin") Deferred.doneUnsafe(answer, Effect.succeed("connected"))
          else if (event.type === "quit" && event.kind === "busy") Deferred.doneUnsafe(answer, Effect.succeed("busy"))
          else if (event.type === "quit" && event.kind !== "stopped")
            Deferred.doneUnsafe(answer, Effect.fail(new ReconnectFailed({ message: `Reconnect failed: ${event.reason}` })))
        }),
        (unsubscribe) => Effect.sync(unsubscribe),
      )
      yield* core.startStream(console.credentials, streamOptions(settings), psnDuid)
      return yield* Deferred.await(answer).pipe(
        Effect.timeoutOrElse({
          duration: psnDuid === undefined ? reconnectAnswerTimeout : remoteAnswerTimeout,
          orElse: () => Effect.fail(new ReconnectFailed({ message: "The console didn't answer. Try again." })),
        }),
      )
    }),
  )

/** Restarts the stream with new settings, retrying while the console is still busy. Starting replaces
 * the running session, so the last frame stays on screen until the new one arrives. */
export const reconnect = (
  console: PairedConsole,
  settings: Settings,
  psnDuid?: string,
): Effect.Effect<void, CoreError | ReconnectFailed, Core> =>
  Effect.gen(function* () {
    const started = yield* Clock.currentTimeMillis
    const loop: Effect.Effect<void, CoreError | ReconnectFailed, Core> = Effect.suspend(() =>
      Effect.flatMap(attemptStream(console, settings, psnDuid), (answer) =>
        answer === "connected"
          ? Effect.void
          : Effect.gen(function* () {
              if ((yield* Clock.currentTimeMillis) - started >= reconnectGiveUpMs) {
                return yield* new ReconnectFailed({ message: "The console is still busy. Try again in a moment." })
              }
              yield* Effect.logInfo(`The console is busy; retrying in ${reconnectRetryDelay}`)
              yield* Effect.sleep(reconnectRetryDelay)
              return yield* loop
            }),
      ),
    )
    yield* Effect.logInfo(`Restarting the stream ${psnDuid === undefined ? "on the local network" : "over the internet"}`)
    return yield* loop.pipe(
      Effect.tap(() => Effect.logInfo("Stream restarted")),
      Effect.tapError((error) => Effect.logWarning(`Restart failed: ${error.message}`)),
    )
  })

export const stop: Effect.Effect<void, CoreError, Core> = Effect.gen(function* () {
  const core = yield* Core
  yield* Effect.logInfo("Stopping the stream")
  yield* core.stopStream
})

/** Enters or leaves fullscreen; succeeds with whether the window is now fullscreen. */
export const toggleFullscreen: Effect.Effect<boolean, CoreError, Core> = Effect.flatMap(Core, (core) => core.toggleFullscreen)

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

/** Stream events, each also logged. They arrive in a plain callback, so logging runs with this fiber's
 * services (which carry the app's logger). */
export const onStreamEvent = (handler: (event: StreamEvent) => void): Effect.Effect<never, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    const run = Effect.runForkWith(yield* Effect.context())
    return yield* listen(
      core.onStreamEvent((event) => {
        const { line, warn } = describeEvent(event)
        run(warn ? Effect.logWarning(line) : Effect.logInfo(line))
        handler(event)
      }),
    )
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
