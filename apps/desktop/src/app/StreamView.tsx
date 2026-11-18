import { Effect, Option } from "effect"
import { Maximize, Mic, MicOff, Minimize, SlidersHorizontal } from "lucide-react"
import { useEffect, useEffectEvent, useId, useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { idleController, type Settings } from "@/core/schema"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import { ConnectingOverlay } from "./ConnectingOverlay"
import { ConsoleKeyboard } from "./ConsoleKeyboard"
import { TouchpadPointer } from "./TouchpadPointer"
import type { Capabilities, MicState, Route, StatRow } from "./format"
import { controllerStateFrom, isControllerKey, keyboardLayout } from "./keyboard"
import { useFork, useRun, useRuntime } from "./runtime"
import { SettingsSheet, type ReconnectState, type SettingsTab } from "./SettingsSheet"

export const hudIdleMs = 2500
/** The cursor hides over the video after this long without moving (it comes back on any movement). */
export const cursorIdleMs = 5000

/** True once the mouse has been still for `ms`. */
const useIdle = (ms: number): boolean => {
  const [idle, setIdle] = useState(false)
  useEffect(() => {
    let timer = window.setTimeout(() => { setIdle(true); }, ms)
    const poke = () => {
      setIdle(false)
      window.clearTimeout(timer)
      timer = window.setTimeout(() => { setIdle(true); }, ms)
    }
    window.addEventListener("mousemove", poke)
    return () => {
      window.clearTimeout(timer)
      window.removeEventListener("mousemove", poke)
    }
  }, [ms])
  return idle
}

/** Hides the mouse cursor over the whole window while `hidden` (Tailwind's `cursor-none` on <html>). */
const useHiddenCursor = (hidden: boolean): void => {
  useEffect(() => {
    document.documentElement.classList.toggle("cursor-none", hidden)
    return () => { document.documentElement.classList.remove("cursor-none") }
  }, [hidden])
}

/** Keyboard-as-controller: forwards key state to the console while `enabled`. Mainly for testing
 * gameplay without a physical pad. Fire-and-forget (a dead session is handled by the quit event). */
const useKeyboardController = (enabled: boolean): void => {
  const runtime = useRuntime()
  useEffect(() => {
    if (!enabled) return
    const pressed = new Set<string>()
    const send = (): void => {
      runtime.runFork(Effect.ignore(actions.setController(controllerStateFrom(pressed))))
    }
    const down = (event: KeyboardEvent): void => {
      if (!isControllerKey(event.code)) return
      event.preventDefault()
      if (event.repeat || pressed.has(event.code)) return
      pressed.add(event.code)
      send()
    }
    const up = (event: KeyboardEvent): void => {
      if (!pressed.delete(event.code)) return
      event.preventDefault()
      send()
    }
    const clear = (): void => {
      if (pressed.size === 0) return
      pressed.clear()
      send()
    }
    window.addEventListener("keydown", down)
    window.addEventListener("keyup", up)
    window.addEventListener("blur", clear)
    return () => {
      window.removeEventListener("keydown", down)
      window.removeEventListener("keyup", up)
      window.removeEventListener("blur", clear)
      runtime.runFork(Effect.ignore(actions.setController(idleController)))
    }
  }, [enabled, runtime])
}

interface StreamViewProps {
  /** The console's name, as last reported by the stream. */
  readonly title: string
  /** Set while the console waits for its login PIN. */
  readonly loginPin: Option.Option<{ readonly incorrect: boolean }>
  /** Set while the console's text keyboard is open, with the field's text. */
  readonly keyboard?: Option.Option<string>
  readonly onKeyboardDone?: () => void
  /** Voice chat from the HUD. */
  readonly mic?: MicState
  readonly onMicToggle?: () => void
  readonly settings: Settings
  readonly capabilities: Capabilities
  readonly onSettingsChange: (next: Settings) => void
  /** Whether stream settings changed since connecting, and how to reconnect with them. */
  readonly reconnect: ReconnectState
  /** While connecting over the internet, the setup step under way. */
  readonly remoteStage?: "linking" | "data" | undefined
  /** The console accepted the stream; until then the connecting screen shows. */
  readonly connected?: boolean
  readonly route?: Route
  readonly onLoginPinSubmitted: () => void
  /** The stream ended; carries the error to show, if any. */
  readonly onEnd: (error: Option.Option<string>) => void
}

export const StreamView = ({
  title,
  loginPin,
  keyboard = Option.none(),
  onKeyboardDone = () => undefined,
  mic = "off",
  onMicToggle = () => undefined,
  settings,
  capabilities,
  onSettingsChange,
  reconnect,
  remoteStage,
  connected = true,
  route = "local",
  onLoginPinSubmitted,
  onEnd,
}: StreamViewProps) => {
  const run = useRun()
  const idle = useIdle(hudIdleMs)
  const [stats, setStats] = useState<actions.LiveStats>({ line: "Connecting…", rows: [] })
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [tab, setTab] = useState<SettingsTab>("picture")
  const [fullscreen, setFullscreen] = useState(false)
  const cursorIdle = useIdle(cursorIdleMs)
  useHiddenCursor(cursorIdle && !settingsOpen)

  const toggleFullscreen = () => {
    run(actions.toggleFullscreen, { onSuccess: setFullscreen })
  }
  // Double-clicking the video (not the HUD or the settings) toggles fullscreen, as in video players.
  const onDoubleClick = useEffectEvent((event: MouseEvent) => {
    if (event.target instanceof Element && event.target.closest("header, [role=dialog]") !== null) return
    if (event.altKey) return // ⌥-clicks press the touchpad
    toggleFullscreen()
  })
  useEffect(() => {
    const listener = (event: MouseEvent) => { onDoubleClick(event) }
    window.addEventListener("dblclick", listener)
    return () => { window.removeEventListener("dblclick", listener) }
  }, [])

  useFork(useMemo(() => actions.pollStats(setStats), []))
  // Off while the login-PIN dialog or the settings are open, so typing there isn't read as gameplay.
  useKeyboardController(Option.isNone(loginPin) && !settingsOpen && Option.isNone(keyboard))

  const hudHidden = idle && !settingsOpen
  const fade = cn("transition-opacity duration-500", hudHidden && "opacity-0")
  const keepStats = settings.showStats && connected && reconnect.reconnecting === false && stats.rows.length > 0

  const stop = () => {
    const end = () => { onEnd(Option.none()); }
    run(actions.stop, { onSuccess: end, onFailure: end })
  }

  return (
    <>
      <header
        data-idle={idle}
        className={cn(
          "fixed inset-x-0 top-0 flex items-center gap-4 px-4 pt-3 pb-6",
          hudHidden && "pointer-events-none",
          settingsOpen && "pr-[24rem]", // keep the HUD's buttons clear of the settings sheet
        )}
      >
        <div aria-hidden className={cn("absolute inset-0 -z-10 bg-gradient-to-b from-black/70 to-transparent", fade)} />
        <span className={cn("font-medium", fade)}>{title}</span>
        {/* With "Stats on screen" on, this line stays when the rest of the HUD fades. */}
        <span
          aria-label={keepStats ? "Stream stats" : undefined}
          className={cn(
            "flex-1 truncate text-xs text-muted-foreground tabular-nums [text-shadow:0_1px_2px_rgb(0_0_0/0.8)]",
            !keepStats && fade,
          )}
        >
          {reconnect.reconnecting === "dropped"
            ? "Connection lost. Reconnecting…"
            : reconnect.reconnecting === "network"
              ? "Network changed. Reconnecting…"
            : reconnect.reconnecting === "apply"
              ? "Reconnecting…"
              : reconnect.reconnecting === "starting"
                ? "Waiting for the console…"
                : remoteStage === "linking"
                  ? "Reaching your PS5 over the internet…"
                  : remoteStage === "data"
                    ? "Opening the data connection…"
                    : keepStats
                      ? <StatsLine rows={stats.rows} />
                      : stats.line}
        </span>
        <details className={cn("group relative text-xs", fade)}>
          <summary className="cursor-pointer list-none rounded-md border px-2 py-1 text-muted-foreground select-none hover:text-foreground">
            Keys
          </summary>
          <div className="absolute right-0 z-10 mt-2 w-56 rounded-lg border bg-popover/95 p-3 shadow-xl backdrop-blur-xl">
            <p className="mb-2 font-medium text-foreground">Keyboard controller</p>
            <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-muted-foreground">
              {keyboardLayout.map(([keys, action]) => (
                <div key={keys} className="col-span-2 grid grid-cols-subgrid">
                  <dt className="font-mono text-foreground">{keys}</dt>
                  <dd className="text-right">{action}</dd>
                </div>
              ))}
            </dl>
          </div>
        </details>
        <Button
          variant="secondary"
          size="sm"
          aria-pressed={mic !== "off"}
          className={cn(fade, mic === "on" && "bg-signal/90 text-black hover:bg-signal")}
          disabled={mic === "pending"}
          onClick={onMicToggle}
        >
          {mic === "off" ? <MicOff /> : <Mic />}
          {mic === "on" ? "Mic on" : "Mic"}
        </Button>
        <Button variant="secondary" size="sm" className={fade} onClick={toggleFullscreen}>
          {fullscreen ? <Minimize /> : <Maximize />}
          {fullscreen ? "Exit fullscreen" : "Fullscreen"}
        </Button>
        <Button
          variant="secondary"
          size="sm"
          className={fade}
          onClick={() => {
            setTab(reconnect.pending ? "stream" : "picture")
            setSettingsOpen(true)
          }}
        >
          <SlidersHorizontal /> Settings
          {reconnect.pending && <span aria-label="Reconnect to apply" className="size-1.5 rounded-full bg-signal" />}
        </Button>
        <Button variant="destructive" size="sm" className={fade} onClick={stop}>
          Stop
        </Button>
      </header>
      {settings.view === "split" && connected && <CompareLabels />}
      {mic === "on" && hudHidden && (
        // The HUD faded: the microphone being live must still be obvious.
        <span
          role="status"
          className="pointer-events-none fixed top-3.5 right-4 flex items-center gap-1.5 rounded-full bg-signal/90 px-2.5 py-1 text-xs font-medium text-black shadow-lg"
        >
          <Mic className="size-3.5" /> Mic on
        </span>
      )}
      <TouchpadPointer enabled={connected && Option.isNone(loginPin) && !settingsOpen} />
      {(!connected || reconnect.reconnecting !== false) && Option.isNone(loginPin) && (
        <ConnectingOverlay
          consoleName={title}
          route={route}
          stage={remoteStage}
          reconnecting={reconnect.reconnecting}
          onCancel={stop}
        />
      )}
      <SettingsSheet
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        tab={tab}
        onTabChange={setTab}
        settings={settings}
        capabilities={capabilities}
        onChange={onSettingsChange}
        reconnect={reconnect}
      />
      {Option.isSome(keyboard) && (
        <ConsoleKeyboard consoleName={title} text={keyboard.value} onDone={onKeyboardDone} />
      )}
      {Option.isSome(loginPin) && (
        <LoginPinPrompt incorrect={loginPin.value.incorrect} onSubmitted={onLoginPinSubmitted} onCancel={stop} />
      )}
    </>
  )
}

/** The stream's numbers in the HUD's line, with the troubling ones in the signal colour. */
const StatsLine = ({ rows }: { readonly rows: readonly StatRow[] }) =>
  rows.map((row, i) => (
    <span key={row.label}>
      {i > 0 && " · "}
      <span className={cn(row.warn && "text-signal")}>{row.inline}</span>
    </span>
  ))

/** Names the two halves of the split-screen comparison, on either side of the divider (the
 * video's center), so both stay visible with the settings sheet open. */
const CompareLabels = () => (
  <div
    aria-label="Split-screen comparison"
    className="pointer-events-none fixed bottom-4 left-1/2 grid -translate-x-1/2 grid-cols-[1fr_auto_1fr] items-center gap-3"
  >
    <span className="justify-self-end rounded-md bg-black/60 px-2 py-1 text-xs font-medium text-white backdrop-blur">Original</span>
    <span aria-hidden className="h-4 w-px" />
    <span className="rounded-md bg-black/60 px-2 py-1 text-xs font-medium text-white backdrop-blur">Enhanced</span>
  </div>
)

interface LoginPinPromptProps {
  readonly incorrect: boolean
  readonly onSubmitted: () => void
  readonly onCancel: () => void
}

const LoginPinPrompt = ({ incorrect, onSubmitted, onCancel }: LoginPinPromptProps) => {
  const run = useRun()
  const id = useId()
  const [pin, setPin] = useState("")
  return (
    <div className="fixed inset-0 flex items-center justify-center p-6">
      <Card role="dialog" aria-labelledby={`${id}-title`} className="w-full max-w-xs bg-card/80 backdrop-blur-xl">
        <CardHeader>
          <CardTitle id={`${id}-title`}>Console login PIN</CardTitle>
          <CardDescription>
            {incorrect ? "Wrong PIN. Enter the console's login PIN." : "Enter the console's login PIN."}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-col gap-3"
            onSubmit={(event) => {
              event.preventDefault()
              run(actions.submitLoginPin(pin), { onSuccess: onSubmitted })
            }}
          >
            <Label htmlFor={id} className="sr-only">
              Login PIN
            </Label>
            <Input
              id={id}
              type="password"
              inputMode="numeric"
              autoComplete="off"
              maxLength={4}
              autoFocus
              value={pin}
              onChange={(event) => { setPin(event.target.value); }}
            />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" onClick={onCancel}>
                Stop
              </Button>
              <Button type="submit">Send</Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
