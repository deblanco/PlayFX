import { Effect, Fiber, Option } from "effect"
import { useCallback, useEffect, useEffectEvent, useState } from "react"
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
  /** Reconnects after a lost connection so far (capped, so a bad link doesn't loop forever). */
  readonly autoReconnects: number
}

export const App = () => {
  const run = useRun()
  const [settings, setSettings] = useState<Settings>(defaultSettings)
  const [capabilities, setCapabilities] = useState<Capabilities>({ metalfx: true, ml: false })
  const [session, setSession] = useState<Session | null>(null)

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
    run(actions.changeSettings(settings, next))
  }

  /** Back home, after the stream view stopped the stream itself. */
  const leave = useCallback((error: Option.Option<string>) => {
    setSession(null)
    Option.map(error, (message) => toast.error(message))
  }, [])

  /** Back home after the stream ended on its own: also brings back the idle picture behind the home
   * screen (after a quit the renderer keeps the last frame, in case the stream is reconnected). */
  const end = useCallback(
    (error: Option.Option<string>) => {
      leave(error)
      run(Effect.ignore(actions.stop))
    },
    [leave, run],
  )

  /** Restarts the stream: to apply new stream settings, or after the connection dropped. */
  const reconnect = (why: "apply" | "dropped") => {
    if (!session) return
    const { console } = session
    setSession({
      ...session,
      reconnecting: why,
      autoReconnects: session.autoReconnects + (why === "dropped" ? 1 : 0),
    })
    run(actions.reconnect(console, settings), {
      onSuccess: () => {
        setSession((s) => s && { ...s, connected: true, reconnecting: false, startedWith: streamOptions(settings) })
      },
      onFailure: () => { end(Option.none()) }, // run() already showed the error
    })
  }

  // A lost connection reconnects on its own; while reconnecting, quit events belong to the reconnect.
  // An effect event sees the latest session without re-subscribing.
  const onStreamEvent = useEffectEvent((event: StreamEvent) => {
    switch (event.type) {
      case "quit": {
        const next = session ? afterQuit(session, event) : "end"
        if (next === "reconnect") reconnect("dropped")
        else if (next === "end") end(quitMessage(event))
        break
      }
      case "loginPin":
        setSession((s) => s && { ...s, loginPin: Option.some({ incorrect: event.incorrect }) })
        break
      case "nickname":
        setSession((s) => s && { ...s, title: event.name })
        break
      case "connected":
        setSession((s) => s && { ...s, connected: true })
        break
    }
  })

  // Subscribed for the app's lifetime: the console can ask for the login PIN or quit before
  // start_stream has even replied, and Tauri doesn't buffer events for late listeners.
  const runtime = useRuntime()
  useEffect(() => {
    const subscription = actions.onStreamEvent((event) => { onStreamEvent(event) })
    const fiber = runtime.runFork(Effect.tapError(subscription, (error) => Effect.sync(() => toast.error(error.message))))
    return () => {
      Effect.runFork(Fiber.interrupt(fiber))
    }
  }, [runtime])

  const play = (console: PairedConsole) => {
    const starting: Session = {
      console,
      started: false,
      title: console.name,
      loginPin: Option.none(),
      startedWith: streamOptions(settings),
      connected: false,
      reconnecting: false,
      autoReconnects: 0,
    }
    setSession(starting)
    run(actions.play(console, settings), {
      // A quit that arrived while starting already cleared (or replaced) the session.
      onSuccess: () => { setSession((s) => (s?.console === console ? { ...s, started: true } : s)); },
      onFailure: () => { setSession((s) => (s?.console === console ? null : s)); },
    })
  }

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
