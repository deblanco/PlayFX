import { Option } from "effect"
import { useCallback, useEffect, useMemo, useState } from "react"
import { toast } from "sonner"
import { Toaster } from "@/components/ui/sonner"
import { defaultSettings, type PairedConsole, type Settings, type StreamEvent } from "@/core/schema"
import * as actions from "./actions"
import { quitMessage } from "./format"
import { Home } from "./Home"
import { useFork, useRun } from "./runtime"
import { StreamView } from "./StreamView"

/** A stream being started (`started: false`) or running, with what its events have told us so far. */
interface Session {
  readonly console: PairedConsole
  readonly started: boolean
  readonly title: string
  readonly loginPin: Option.Option<{ readonly incorrect: boolean }>
}

export const App = () => {
  const run = useRun()
  const [settings, setSettings] = useState<Settings>(defaultSettings)
  const [metalfxSupported, setMetalfxSupported] = useState(true)
  const [session, setSession] = useState<Session | null>(null)

  useEffect(() => {
    run(actions.startup, {
      onSuccess: (startup) => {
        setSettings(startup.settings)
        setMetalfxSupported(startup.metalfxSupported)
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

  // Subscribed for the app's lifetime: the console can ask for the login PIN or quit before
  // start_stream has even replied, and Tauri doesn't buffer events for late listeners.
  useFork(
    useMemo(
      () =>
        actions.onStreamEvent((event: StreamEvent) => {
          switch (event.type) {
            case "quit":
              end(quitMessage(event))
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
        }),
      [end],
    ),
  )

  const play = (console: PairedConsole) => {
    const starting: Session = { console, started: false, title: console.name, loginPin: Option.none() }
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
          metalfxSupported={metalfxSupported}
          onSettingsChange={changeSettings}
          onLoginPinSubmitted={clearLoginPin}
          onEnd={end}
        />
      ) : (
        <Home settings={settings} metalfxSupported={metalfxSupported} onSettingsChange={changeSettings} onPlay={play} />
      )}
      <Toaster position="bottom-center" />
    </>
  )
}
