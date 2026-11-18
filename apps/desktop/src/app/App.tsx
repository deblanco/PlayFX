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
import { afterQuit, quitMessage, streamOptions, type Capabilities, type Reconnecting } from "./format"
import { Home } from "./Home"
import { useRun, useRuntime } from "./runtime"
import { StreamView } from "./StreamView"

/** A stream being started (`started: false`) or running, with what its events have told us so far. */
interface Session {
  readonly console: PairedConsole
  readonly started: boolean
  readonly title: string
  readonly loginPin: Option.Option<{ readonly incorrect: boolean }>
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

export const App = () => {
  const run = useRun()
  const [settings, setSettings] = useState<Settings>(defaultSettings)
  const [capabilities, setCapabilities] = useState<Capabilities>({ metalfx: true, ml: false, smooth: false })
  const [session, setSession] = useState<Session | null>(null)
  const runtime = useRuntime()
  // Background work tied to the stream view: an in-flight reconnect, and the timer that forgives past
  // drops once the stream has been stable. Both are cancelled when the stream view goes away.
  const reconnectFiber = useRef<Fiber.Fiber<unknown, unknown> | null>(null)
  const stableTimer = useRef<Fiber.Fiber<unknown, unknown> | null>(null)

  useEffect(() => {
    run(actions.startup, {
      onSuccess: (startup) => {
        setSettings(startup.settings)
        setCapabilities(startup.capabilities)
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
      startedWith: streamOptions(settings),
      connected: false,
      reconnecting: false,
      autoReconnects: 0,
      psnDuid,
      psnFallback: psnDuid === undefined ? psnFallback : undefined,
      remoteStage: psnDuid === undefined ? undefined : "linking",
    }
    setSession(starting)
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
      reconnecting: why,
      autoReconnects: session.autoReconnects + (why === "dropped" ? 1 : 0),
    })
    cancelBackground()
    reconnectFiber.current = runtime.runFork(
      Effect.match(actions.reconnect(console, settings, session.psnDuid), {
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

  // Subscribed for the app's lifetime: the console can ask for the login PIN or quit before
  // start_stream has even replied, and Tauri doesn't buffer events for late listeners.
  useEffect(() => {
    const subscription = actions.onStreamEvent((event) => { onStreamEvent(event) })
    const fiber = runtime.runFork(Effect.tapError(subscription, (error) => Effect.sync(() => toast.error(error.message))))
    return () => {
      Effect.runFork(Fiber.interrupt(fiber))
    }
  }, [runtime])


  const clearLoginPin = useCallback(() => {
    setSession((s) => s && { ...s, loginPin: Option.none() })
  }, [])

  return (
    <>
      {session?.started === true ? (
        <StreamView
          title={session.title}
          loginPin={session.loginPin}
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
