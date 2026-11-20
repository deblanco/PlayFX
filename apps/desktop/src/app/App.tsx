import { Effect, Fiber, Option } from "effect"
import { useCallback, useEffect, useEffectEvent, useRef, useState } from "react"
import { toast } from "sonner"
import { Toaster } from "@/components/ui/sonner"
import {
  defaultSettings,
  sameStreamOptions,
  type PairedConsole,
  type Settings,
  type StreamEvent,
  type StreamOptions,
} from "@/core/schema"
import * as actions from "./actions"
import { patchSettings, useDevControl } from "./devControl"
import {
  afterQuit,
  afterStall,
  microphoneProblem,
  onlyBitrateChanged,
  quitMessage,
  streamOptions,
  type Capabilities,
  type MicState,
  type Reconnecting,
  stallMessage,
} from "./format"
import { Home } from "./Home"
import { useRun, useRuntime } from "./runtime"
import { StreamView } from "./StreamView"
import { PeerWifiProvider, usePeerWifiContext } from "./SteadyWifi"

/** A stream being started (`started: false`) or running, with what its events have told us so far. */
interface Session {
  readonly console: PairedConsole
  readonly started: boolean
  readonly title: string
  readonly loginPin: Option.Option<{ readonly incorrect: boolean }>
  /** Voice chat (reset with every new session: the microphone belongs to it). */
  readonly mic: MicState
  /** The console's text keyboard is open, with the field's text. */
  readonly keyboard: Option.Option<string>
  /** The stream options the running session was started with. */
  readonly startedWith: StreamOptions
  /** The console accepted the stream (as opposed to still connecting). */
  readonly connected: boolean
  /** Restarting the stream; quit events then belong to the reconnect. */
  readonly reconnecting: Reconnecting
  /** Set when streaming over the internet: the console's PSN device ID (reused to reconnect). */
  readonly psnDuid: string | undefined
  /** Playing locally, the console's PSN device ID when it's also on the PSN account: used to go
   * through PSN instead if the local network can't reach it. */
  readonly psnFallback: string | undefined
  /** While connecting over the internet, the setup step under way. */
  readonly remoteStage: "linking" | "data" | undefined
  /** Automatic reconnects since the stream was last stable (capped, so a bad link doesn't loop forever). */
  readonly autoReconnects: number
}

export const App = () => (
  <PeerWifiProvider>
    <Screens />
  </PeerWifiProvider>
)

const Screens = () => {
  const run = useRun()
  const wifi = usePeerWifiContext()
  const [settings, setSettings] = useState<Settings>(defaultSettings)
  const [capabilities, setCapabilities] = useState<Capabilities>({ metalfx: true, ml: false, interpolation: false })
  const [session, setSession] = useState<Session | null>(null)
  const runtime = useRuntime()
  // Background work tied to the stream view: an in-flight reconnect, and the timer that forgives past
  // drops once the stream has been stable. Both are cancelled when the stream view goes away.
  const reconnectFiber = useRef<Fiber.Fiber<unknown, unknown> | null>(null)
  const stableTimer = useRef<Fiber.Fiber<unknown, unknown> | null>(null)

  useEffect(() => {
    run(actions.loadSettings, {
      onSuccess: (saved) => {
        setSettings(saved)
        run(actions.applyStartup(saved), { onSuccess: setCapabilities })
      },
    })
  }, [run])

  const changeSettings = (next: Settings) => {
    setSettings(next)
    run(actions.changeSettings(next))
  }

  /** Cancels the background work; a reconnect may have started a session, so that one is stopped. */
  const cancelBackground = useCallback(() => {
    const reconnecting = reconnectFiber.current
    reconnectFiber.current = null
    if (reconnecting) runtime.runFork(Effect.andThen(Fiber.interrupt(reconnecting), Effect.ignore(actions.stop)))
    if (stableTimer.current) runtime.runFork(Fiber.interrupt(stableTimer.current))
    stableTimer.current = null
  }, [runtime])

  /** Back home, after the stream view stopped the stream itself. */
  const leave = useCallback(
    (error: Option.Option<string>) => {
      cancelBackground()
      setSession(null)
      Option.map(error, (message) => toast.error(message))
    },
    [cancelBackground],
  )

  /** Back home after the stream ended on its own: also brings back the idle picture behind the home
   * screen (after a quit the renderer keeps the last frame, in case the stream is reconnected). */
  const end = useCallback(
    (error: Option.Option<string>) => {
      leave(error)
      run(Effect.ignore(actions.stop))
    },
    [leave, run],
  )

  const play = (console: PairedConsole, psnDuid?: string, psnFallback?: string) => {
    const starting: Session = {
      console,
      started: false,
      title: console.name,
      loginPin: Option.none(),
      keyboard: Option.none(),
      mic: "off",
      startedWith: streamOptions(settings),
      connected: false,
      reconnecting: false,
      autoReconnects: 0,
      psnDuid,
      psnFallback: psnDuid === undefined ? psnFallback : undefined,
      remoteStage: psnDuid === undefined ? undefined : "linking",
    }
    setSession(starting)
    // Steady Wi-Fi left on last time: macOS asks for the password while the stream connects.
    wifi.beforeStream()
    run(actions.play(console, settings, psnDuid), {
      // A quit that arrived while starting already cleared (or replaced) the session.
      onSuccess: () => { setSession((s) => (s?.console === console ? { ...s, started: true } : s)); },
      onFailure: () => { setSession((s) => (s?.console === console ? null : s)); },
    })
  }

  /** Back home after a stream ended with an error, offering to play the same console the same way again. */
  const fail = (failed: Session, error: Option.Option<string>) => {
    end(Option.none())
    Option.map(error, (message) =>
      toast.error(message, {
        action: { label: "Try again", onClick: () => { play(failed.console, failed.psnDuid, failed.psnFallback) } },
      }),
    )
  }

  /** Restarts the stream: to apply new stream settings, or after the connection dropped. */
  const reconnect = (why: Exclude<Reconnecting, false>) => {
    if (!session) return
    const { console } = session
    setSession({
      ...session,
      mic: "off", // the new session starts without it
      reconnecting: why,
      autoReconnects: session.autoReconnects + (why === "dropped" || why === "stalled" ? 1 : 0),
    })
    // A reconnect already under way is interrupted first and only then the new attempt starts (which
    // replaces any session itself). Cancelling it on the side (interrupt, then stop) raced the new attempt:
    // that stop could land after the new session started and end it.
    const previous = reconnectFiber.current
    reconnectFiber.current = null
    if (stableTimer.current) runtime.runFork(Fiber.interrupt(stableTimer.current))
    stableTimer.current = null
    const attempt = actions.reconnect(console, settings, session.psnDuid)
    reconnectFiber.current = runtime.runFork(
      Effect.match(previous ? Effect.andThen(Fiber.interrupt(previous), attempt) : attempt, {
        onSuccess: () => {
          reconnectFiber.current = null
          setSession((s) => s && { ...s, connected: true, reconnecting: false, startedWith: streamOptions(settings) })
          // Forgive past drops once the stream has stayed up for a while.
          stableTimer.current = runtime.runFork(
            Effect.andThen(actions.waitUntilStable, Effect.sync(() => {
              setSession((s) => s && { ...s, autoReconnects: 0 })
            })),
          )
        },
        onFailure: (error) => {
          reconnectFiber.current = null
          fail(session, Option.some(error.message))
        },
      }),
    )
  }


  // A lost connection reconnects on its own; while reconnecting, quit events belong to the reconnect.
  // An effect event sees the latest session without re-subscribing.
  const onStreamEvent = useEffectEvent((event: StreamEvent) => {
    switch (event.type) {
      case "quit": {
        const next = session ? afterQuit(session, event) : "end"
        if (next === "reconnect") reconnect("dropped")
        else if (next === "retry-start") reconnect("starting")
        else if (next === "via-internet" && settings.connection !== "auto" && session) fail(session, quitMessage(event))
        else if (next === "via-internet" && session) {
          // Known from the console list, or asked now (Play may have come before that lookup finished).
          const { console, psnFallback } = session
          const duid = psnFallback === undefined ? actions.psnDuidFor(console) : Effect.succeed(psnFallback)
          run(duid, {
            onSuccess: (found) => {
              if (found === undefined) {
                fail(session, quitMessage(event))
                return
              }
              toast.info(`Couldn't reach ${console.name} on this network. Connecting over the internet…`)
              run(Effect.logWarning(`${console.name} unreachable on the local network; trying through PSN`))
              play(console, found)
            },
          })
        }
        else if (next === "end" && session) fail(session, quitMessage(event))
        else if (next === "end") end(quitMessage(event))
        break
      }
      case "loginPin":
        setSession((s) => s && { ...s, loginPin: Option.some({ incorrect: event.incorrect }) })
        break
      case "nickname":
        setSession((s) => s && { ...s, title: event.name })
        break
      case "microphone":
        if (event.state === "denied" || event.state === "unavailable") toast.error(microphoneProblem(event.state))
        setSession((s) => s && { ...s, mic: event.state === "on" ? "on" : "off" })
        break
      case "keyboard":
        setSession((s) => s && { ...s, keyboard: event.change === "close" ? Option.none() : Option.some(event.text) })
        break
      case "network":
        // The stream's sockets belong to the old network: reconnect at once rather than waiting for it
        // to time out. While offline there's nothing to do; the change back online triggers this.
        if (event.online && session?.started === true && session.reconnecting === false) reconnect("network")
        break
      case "connected":
        setSession((s) => s && { ...s, connected: true, remoteStage: undefined })
        break
      case "remoteProgress":
        setSession((s) => s && { ...s, remoteStage: event.stage === "connected" ? undefined : event.stage })
        break
    }
  })

  // The picture can stop while the session goes on (its video no longer getting through, sound still
  // playing): reconnect, as for a dropped connection. Watched while connected and not already reconnecting.
  const onStall = useEffectEvent(() => {
    if (session?.reconnecting !== false) return
    if (afterStall(session) === "reconnect") reconnect("stalled")
    else fail(session, Option.some(stallMessage))
  })
  const watchingPicture = session?.connected === true && session.reconnecting === false
  useEffect(() => {
    if (!watchingPicture) return
    const fiber = runtime.runFork(Effect.andThen(actions.watchForStall, Effect.sync(() => { onStall() })))
    return () => { runtime.runFork(Fiber.interrupt(fiber)) }
  }, [watchingPicture, runtime])

  // Only the bitrate changed: the console takes it once, at the start, so it's applied by reconnecting on the
  // app's own once the slider has stayed put for a moment. Other stream settings wait for Reconnect.
  const bitrateOnly = session?.connected === true && session.reconnecting === false
    && onlyBitrateChanged(session.startedWith, streamOptions(settings))
  const onBitrateSettled = useEffectEvent(() => {
    if (bitrateOnly) reconnect("apply")
  })
  const settlingBitrate = bitrateOnly ? settings.bitrate : undefined
  useEffect(() => {
    if (settlingBitrate === undefined) return
    const fiber = runtime.runFork(Effect.andThen(Effect.sleep(actions.bitrateSettle), Effect.sync(() => { onBitrateSettled() })))
    return () => { runtime.runFork(Fiber.interrupt(fiber)) }
  }, [settlingBitrate, runtime])

  // Subscribed for the app's lifetime: the console can ask for the login PIN or quit before
  // start_stream has even replied, and Tauri doesn't buffer events for late listeners.
  useEffect(() => {
    const subscription = actions.onStreamEvent((event) => { onStreamEvent(event) })
    const fiber = runtime.runFork(Effect.tapError(subscription, (error) => Effect.sync(() => toast.error(error.message))))
    return () => {
      Effect.runFork(Fiber.interrupt(fiber))
    }
  }, [runtime])


  useDevControl((command) => {
    if (command.type === "settings") {
      const next = patchSettings(settings, command.patch)
      if (Option.isSome(next)) changeSettings(next.value)
      else toast.error("Dev control: those aren't valid settings")
    } else if (command.type === "reconnect" && session?.started === true) {
      reconnect("apply")
    }
  })

  const clearLoginPin = useCallback(() => {
    setSession((s) => s && { ...s, loginPin: Option.none() })
  }, [])

  return (
    <>
      {session?.started === true ? (
        <StreamView
          title={session.title}
          loginPin={session.loginPin}
          keyboard={session.keyboard}
          mic={session.mic}
          onMicToggle={() => {
            const on = session.mic === "off"
            setSession((s) => s && { ...s, mic: on ? "pending" : "off" })
            // The outcome comes as a "microphone" event; if the request itself fails none will, so the
            // button isn't left disabled on "pending".
            run(actions.setMicrophone(on), { onFailure: () => { setSession((s) => s && { ...s, mic: "off" }) } })
          }}
          onKeyboardDone={() => { setSession((s) => s && { ...s, keyboard: Option.none() }) }}
          settings={settings}
          capabilities={capabilities}
          onSettingsChange={changeSettings}
          reconnect={{
            pending: !sameStreamOptions(session.startedWith, streamOptions(settings)),
            reconnecting: session.reconnecting,
            onReconnect: () => { reconnect("apply") },
          }}
          remoteStage={session.remoteStage}
          connected={session.connected}
          route={session.psnDuid === undefined ? "local" : "internet"}
          onLoginPinSubmitted={clearLoginPin}
          onEnd={leave}
        />
      ) : (
        <Home settings={settings} capabilities={capabilities} onSettingsChange={changeSettings} onPlay={play} />
      )}
      <Toaster position="bottom-center" />
    </>
  )
}
