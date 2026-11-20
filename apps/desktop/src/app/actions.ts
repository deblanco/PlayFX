import { Clock, Deferred, Effect, Option, Ref, Schedule, Schema } from "effect"
import { Core } from "@/core/core"
import { detailedLogs, setDetailedLogs } from "@/core/logging"
import { CoreError, ValidationError, type StorageError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import {
  isAccountId,
  type AudioDevice,
  type DevCommand,
  type AppInfo,
  type Diagnostics,
  type Profile,
  type RendererStatus,
  type DiscoveredConsole,
  type ControllerState,
  type PointerTouch,
  type PairedConsole,
  type PairedConsoles,
  type PeerWifiReply,
  type PeerWifiState,
  type PsnAccountEvent,
  type Settings,
  type StreamEvent,
} from "@/core/schema"
import {
  describeEvent,
  framesPerSecond,
  hudStats,
  statRows,
  upscaleIdle,
  type StatRow,
  megabitsPerSecond,
  psnDeviceIds,
  renderParams,
  streamOptions,
  type Capabilities,
  type FrameSample,
} from "./format"
import { recommended, withProfile } from "./profiles"

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
  // The native sign-out first: if it fails, nothing changed (the UI still says signed in, and it is).
  // The other way round, a failure left the UI signed in with the account ID already gone.
  yield* core.psnSignOut
  yield* prefs.setAccountId(Option.none())
})

/** The PSN device IDs of the paired consoles PSN can reach (hostId → duid); empty when not signed in
 * for internet play, or when PSN can't be reached. */
export const psnReachable = (paired: PairedConsoles): Effect.Effect<Readonly<Record<string, string>>, never, Core> =>
  askPsn(paired).pipe(Effect.orElseSucceed(() => ({})))

/** What PSN says now; fails when PSN can't be asked. */
const askPsn = (paired: PairedConsoles): Effect.Effect<Readonly<Record<string, string>>, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    if (!(yield* core.psnSignedIn)) return {}
    return psnDeviceIds(paired, yield* core.psnConsoles)
  })

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
    : Effect.fail(
        new SignInFailed({
          message: `PSN sign-in failed: ${event.error.replace(/\.$/, "")}. Sign in with PlayStation again, and check that this Mac is online.`,
        }),
      )

export const onPsnAccount = (handler: (event: PsnAccountEvent) => void): Effect.Effect<never, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    return yield* listen(core.onPsnAccount(handler))
  })

/** Requests from the dev control port (debug builds only; docs/dev-control.md). */
export const onDevControl = (handler: (command: DevCommand) => void): Effect.Effect<never, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    return yield* listen(core.onDevControl(handler))
  })

// ---------- Profiles ----------

/** Settings profiles the user saved (the built-in one comes from `allProfiles`). */
export const loadProfiles: Effect.Effect<readonly Profile[], StorageError, Preferences> = Effect.flatMap(
  Preferences,
  (prefs) => prefs.profiles,
)

/** Saves the stream and picture settings in `settings` as a profile named `name`, replacing one of
 * that name; the saved profiles after. */
export const saveProfile = (
  name: string,
  settings: Settings,
): Effect.Effect<readonly Profile[], ValidationError | StorageError, Preferences> =>
  Effect.gen(function* () {
    const trimmed = name.trim()
    if (trimmed.length === 0 || trimmed.length > 40) {
      return yield* new ValidationError({ message: "Give the profile a name of up to 40 characters." })
    }
    if (trimmed === recommended.name) {
      return yield* new ValidationError({ message: `"${recommended.name}" is built in. Choose another name.` })
    }
    const prefs = yield* Preferences
    const next = withProfile(yield* prefs.profiles, trimmed, settings)
    yield* prefs.saveProfiles(next)
    return next
  })

/** Deletes a saved profile; the saved profiles after. */
export const deleteProfile = (name: string): Effect.Effect<readonly Profile[], StorageError, Preferences> =>
  Effect.gen(function* () {
    const prefs = yield* Preferences
    const next = (yield* prefs.profiles).filter((p) => p.name !== name)
    yield* prefs.saveProfiles(next)
    return next
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
  const settings = yield* prefs.settings
  const broadcast = yield* core.discover
  // With an address typed in, that console is also asked directly, whatever the Connect mode: it may be on
  // another subnet, where broadcasts don't reach, and still be played on the home network.
  const address = settings.consoleAddress.trim()
  const direct = address === "" ? [] : yield* Effect.orElseSucceed(core.discoverAt(address), () => [])
  const discovered = [...broadcast, ...direct.filter((d) => !broadcast.some((b) => b.hostId === d.hostId))]
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

// ---------- AirDrop & Handoff (peer-to-peer Wi-Fi) ----------

export const peerWifiInterval = "3 seconds"

/** Reads whether AirDrop and Handoff are taking the Wi-Fi now and every 3 s (macOS switches them on and off
 * by itself), reporting each reading. A failed reading is skipped: the next one comes soon. */
export const pollPeerWifi = (report: (state: PeerWifiState) => void): Effect.Effect<number, never, Core> =>
  Effect.flatMap(Core, (core) => core.peerWifiStatus).pipe(
    Effect.flatMap((state) => Effect.sync(() => { report(state) })),
    Effect.ignore,
    Effect.repeat(Schedule.spaced(peerWifiInterval)),
  )

/** Pauses AirDrop and Handoff while PlayFX is open (macOS asks for the password), or lets them back. Once
 * done, the choice is remembered (turning it off forgets it), so after a relaunch the first stream offers
 * it again. A choice that couldn't be saved is only logged: the pause itself happened. */
export const setPeerWifiPaused = (paused: boolean): Effect.Effect<PeerWifiReply, CoreError, Core | Preferences> =>
  Effect.gen(function* () {
    const reply = yield* Effect.flatMap(Core, (core) => core.setPeerWifiPaused(paused))
    if (reply.outcome === "done") {
      const prefs = yield* Preferences
      yield* prefs.saveSteadyWifi(paused).pipe(
        Effect.catch((error) => Effect.logWarning(`Couldn't remember Steady Wi-Fi: ${error.message}`)),
      )
    }
    return reply
  })

/** Whether Steady Wi-Fi was left on: then the next stream offers to pause AirDrop and Handoff again. */
export const loadSteadyWifi: Effect.Effect<boolean, StorageError, Preferences> = Effect.flatMap(
  Preferences,
  (prefs) => prefs.steadyWifi,
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

/** Where and how loud the stream plays; applied right away (the playing stream and later ones). */
const applyAudio = (settings: Settings): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.setAudioOutput(settings.volume, settings.audioDevice === "" ? undefined : settings.audioDevice))

/** The Mac's sound outputs, for the Output choice. */
export const audioDevices: Effect.Effect<readonly AudioDevice[], CoreError, Core> = Effect.flatMap(Core, (core) => core.audioDevices)

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
/** "PlayFX 0.1.0 (e038cd8) on macOS 27.2": the Diagnostics panel, the report and the log's start line say this. */
export const buildLine = (info: Pick<AppInfo, "appVersion" | "commit" | "os">): string =>
  `PlayFX ${info.appVersion} (${info.commit}) on ${info.os}`

export const appInfo: Effect.Effect<AppInfo, CoreError, Core> = Effect.flatMap(Core, (core) => core.appInfo)

export const diagnosticsReport = (d: Diagnostics, status: RendererStatus, settings: Settings): string =>
  [
    buildLine(d),
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

export const openSourceCode: Effect.Effect<void, CoreError, Core> = Effect.flatMap(Core, (core) => core.openSourceCode)

/** Opens the Local Network privacy settings; if it can't, says where they are. */
export const openLocalNetworkSettings: Effect.Effect<void, CoreError, Core> = Effect.flatMap(Core, (core) =>
  core.openLocalNetworkSettings.pipe(
    Effect.mapError(
      (error) =>
        new CoreError({
          command: error.command,
          message: "Couldn't open System Settings. Open it yourself, go to Privacy & Security › Local Network and turn on PlayFX.",
        }),
    ),
  ),
)

/** Loads saved settings and applies the saved picture settings to the renderer. */
/** The saved settings. Read on their own, so a native failure in `applyStartup` can't leave the UI on the
 * defaults, where the next change would save them over the user's settings. */
export const loadSettings: Effect.Effect<Settings, StorageError, Preferences> = Effect.flatMap(Preferences, (prefs) => prefs.settings)

/** Applies saved settings to the native side (picture, logs, sound); replies with what this Mac can do. */
export const applyStartup = (settings: Settings): Effect.Effect<Capabilities, CoreError, Core> => Effect.gen(function* () {
  const core = yield* Core
  const status = yield* core.rendererStatus
  yield* core.setRenderParams(renderParams(settings))
  yield* applyDetailedLogs(settings.detailedLogs)
  yield* Effect.ignore(applyAudio(settings))
  return { metalfx: status.metalfxSupported, ml: status.mlSupported, interpolation: status.interpolationSupported }
})

export const startup: Effect.Effect<Startup, CoreError | StorageError, Core | Preferences> = Effect.gen(function* () {
  const settings = yield* loadSettings
  return { settings, capabilities: yield* applyStartup(settings) }
})

/** Persists new settings and applies their picture part to the renderer (cheap, and always the latest
 * state, so quick successive changes can't leave the renderer on a stale value). */
export const changeSettings = (next: Settings): Effect.Effect<Settings, CoreError | StorageError, Core | Preferences> =>
  Effect.gen(function* () {
    const core = yield* Core
    const prefs = yield* Preferences
    yield* prefs.saveSettings(next)
    yield* applyDetailedLogs(next.detailedLogs)
    yield* Effect.ignore(applyAudio(next))
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
        `${String(o.height)}p${String(o.fps)} ${o.hevc ? (o.hdr ? "HEVC HDR" : "HEVC") : "H.264"}, ${o.bitrate === 0 ? "auto bitrate" : `${String(o.bitrate)} kbps`}`,
    )
    yield* core.startStream(console.credentials, o, psnDuid)
  })

export const psnPollInterval = "1 minute"

/** Which paired consoles PSN can reach, now and every minute, until interrupted. */
export const pollPsnReachable = (
  paired: PairedConsoles,
  report: (reachable: Readonly<Record<string, string>>) => void,
): Effect.Effect<number, never, Core> =>
  // A round where PSN can't be asked reports nothing: the last answer stands (one network blip used to
  // mark every console unreachable over the internet until the next round, a minute later).
  askPsn(paired).pipe(
    Effect.flatMap((reachable) => Effect.sync(() => { report(reachable) })),
    Effect.ignore,
    Effect.repeat(Schedule.spaced(psnPollInterval)),
  )

// The PS5 refuses a new session for ~9 s after one ends ("busy"), so a reconnect retries.
export const reconnectRetryDelay = "1500 millis"
/** Over the internet, how long the console needs after a stop before PSN can set up a new session. */
export const internetReconnectSettle = "10 seconds"
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
    if (psnDuid !== undefined) {
      // Through PSN a new session can't replace the running one: the console must let go of it first
      // (seen live: PSN timed out with "Host is down" when started straight away).
      const core = yield* Core
      yield* Effect.ignore(core.stopStream)
      yield* Effect.logInfo(`Waiting ${internetReconnectSettle} for the console to release the old session`)
      yield* Effect.sleep(internetReconnectSettle)
    }
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

/** Puts the console in rest mode, then stops the stream. The console ends the session itself once it
 * goes to sleep; the pause gives that request time to reach it before the stream closes. */
export const sleepAndStop: Effect.Effect<void, CoreError, Core> = Effect.gen(function* () {
  const core = yield* Core
  yield* Effect.logInfo("Putting the console in rest mode")
  yield* core.sleepConsole
  yield* Effect.sleep("1500 millis")
  yield* stop
})

/** Enters or leaves fullscreen; succeeds with whether the window is now fullscreen. */
export const toggleFullscreen: Effect.Effect<boolean, CoreError, Core> = Effect.flatMap(Core, (core) => core.toggleFullscreen)

/** Whether the window is fullscreen now; nothing when it can't be read (the label just stays as it was). */
export const fullscreenState: Effect.Effect<Option.Option<boolean>, never, Core> = Effect.option(
  Effect.flatMap(Core, (core) => core.fullscreenState),
)

/** Sends a controller state to the console (keyboard-as-controller). */
export const setController = (state: ControllerState): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.setController(state))

export const setPointerTouch = (touch: PointerTouch): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.setPointerTouch(touch))

export const setMicrophone = (on: boolean): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.setMicrophone(on))

export const keyboardSetText = (text: string): Effect.Effect<void, CoreError, Core> =>
  Effect.flatMap(Core, (core) => core.keyboardSetText(text))

/** Sends the typed text (Return) or cancels it (Esc). */
export const keyboardDone = (accept: boolean): Effect.Effect<void, CoreError, Core> =>
  Effect.gen(function* () {
    const core = yield* Core
    yield* core.keyboardDone(accept)
    yield* Effect.logInfo(accept ? "Sent text to the console" : "Cancelled typing on the console")
  })

/** Sends the console's login PIN (asked for when the PS5 user has a passcode). */
export const submitLoginPin = (raw: string): Effect.Effect<void, CoreError | ValidationError, Core> =>
  Effect.gen(function* () {
    const pin = raw.trim()
    if (!/^\d{4}$/.test(pin)) return yield* new ValidationError({ message: "The passcode has 4 digits" })
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

/** How long the bitrate must stay put before a stream reconnects to apply it (the slider passes values). */
export const bitrateSettle = "1200 millis"

/** How long the stream may go without a new frame before the picture counts as stopped. The console sends
 * frames all the time, even for a still scene; recovering from a lost frame normally takes under a second. */
export const stallAfterMs = 5_000

/** When, into a stretch without new frames, to ask the console for a keyframe before giving up on the picture
 * (ms). A lost reference frame leaves every following frame undecodable until a keyframe arrives; asking
 * again covers one that was itself lost. */
export const keyframeRequestsAtMs = [1_000, 3_000] as const

/** Watches a connected stream's decoded frames and returns once none has come for `stallAfterMs`: the video
 * stopped getting through (seen live: 95% of it lost, the keyframe asked for never arriving whole) while the
 * session, and its sound, went on. On the way it asks for a keyframe (`keyframeRequestsAtMs`). Polls that
 * fail count as no new frame. */
export const watchForStall: Effect.Effect<void, never, Core> = Effect.gen(function* () {
  const core = yield* Core
  let frames = -1
  let since = yield* Clock.currentTimeMillis
  let asked = 0
  for (;;) {
    yield* Effect.sleep(statsInterval)
    const now = yield* Clock.currentTimeMillis
    const polled = yield* core.rendererStatus.pipe(
      Effect.map((status) => Option.some(status.stream.framesDecoded ?? 0)),
      Effect.orElseSucceed(() => Option.none<number>()),
    )
    const decoded = Option.getOrElse(polled, () => frames)
    const due = keyframeRequestsAtMs[asked]
    if (decoded !== frames) {
      frames = decoded
      since = now
      asked = 0
    } else if (now - since >= stallAfterMs) {
      yield* Effect.logWarning(`No new frame for ${String(Math.round((now - since) / 1000))} s; the picture stopped`)
      return
    } else if (Option.isSome(polled) && due !== undefined && now - since >= due) {
      // Only on a poll that saw no new frame: a failed poll says nothing about the picture.
      asked += 1
      yield* Effect.logInfo(`No new frame for ${String(Math.round((now - since) / 1000))} s; asking for a keyframe`)
      yield* Effect.ignore(core.requestKeyframe)
    }
  }
})

/** Polls the renderer every second, reporting the HUD stats line; failed polls are skipped. */
/** The HUD's line and the stats panel's rows, refreshed every second. */
export interface LiveStats {
  readonly line: string
  readonly rows: readonly StatRow[]
  /** Why the chosen upscaler isn't enlarging the picture right now (see `upscaleIdle`). */
  readonly upscaleIdle?: string
}

export const pollStats = (report: (stats: LiveStats) => void, requestedHeight?: number): Effect.Effect<number, never, Core> =>
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
      const fps = framesPerSecond(previous, sample)
      const mbps = megabitsPerSecond(previous, sample)
      const idle = upscaleIdle(status.pacing)
      report({
        line: hudStats(status, fps, mbps),
        rows: statRows(status, fps, mbps, requestedHeight),
        ...(idle === undefined ? {} : { upscaleIdle: idle }),
      })
    })
    return yield* Effect.ignore(tick).pipe(Effect.repeat(Schedule.spaced(statsInterval)))
  })
