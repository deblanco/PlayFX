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
import { quitMessage, streamOptions, type Capabilities } from "./format"
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
  /** Restarting with new stream settings; quit events then belong to the reconnect. */
  readonly reconnecting: boolean
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

  const end = useCallback((error: Option.Option<string>) => {
    setSession(null)
    Option.map(error, (message) => toast.error(message))
  }, [])

  // While reconnecting, quit events belong to the reconnect (the old session ending, or the console
  // still busy), not to the user. An effect event sees the latest session without re-subscribing.
  const onStreamEvent = useEffectEvent((event: StreamEvent) => {
    switch (event.type) {
      case "quit":
        if (session?.reconnecting !== true) end(quitMessage(event))
        break
      case "loginPin":
        setSession((s) => s && { ...s, loginPin: Option.some({ incorrect: event.incorrect }) })
        break
      case "nickname":
        setSession((s) => s && { ...s, title: event.name })
        break
      case "connected":
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
      reconnecting: false,
    }
    setSession(starting)
    run(actions.play(console, settings), {
      // A quit that arrived while starting already cleared (or replaced) the session.
      onSuccess: () => { setSession((s) => (s?.console === console ? { ...s, started: true } : s)); },
      onFailure: () => { setSession((s) => (s?.console === console ? null : s)); },
    })
  }

  const reconnect = () => {
    if (!session) return
    const { console } = session
    setSession({ ...session, reconnecting: true })
    run(actions.reconnect(console, settings), {
      onSuccess: () => {
        setSession((s) => s && { ...s, reconnecting: false, startedWith: streamOptions(settings) })
      },
      onFailure: () => { end(Option.none()) }, // run() already showed the error
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
            onReconnect: reconnect,
          }}
          onLoginPinSubmitted={clearLoginPin}
          onEnd={end}
        />
      ) : (
        <Home settings={settings} capabilities={capabilities} onSettingsChange={changeSettings} onPlay={play} />
      )}
      <Toaster position="bottom-center" />
    </>
  )
}
