import { Effect, Option } from "effect"
import { Maximize, Mic, MicOff, Minimize, SlidersHorizontal } from "lucide-react"
import { useEffect, useEffectEvent, useId, useMemo, useRef, useState } from "react"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
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
import { SteadyWifiWarning } from "./SteadyWifi"

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

/** Presses (`true`) or lets go of a key's control from outside the keyboard, e.g. the HUD's PS button. */
type PressKey = (code: string, down: boolean) => void

/** Keyboard-as-controller: forwards key state to the console while `enabled`. Mainly for testing
 * gameplay without a physical pad. Fire-and-forget (a dead session is handled by the quit event).
 * Returns a way to press a key's control from the HUD, merged with the keys held (does nothing while off). */
const useKeyboardController = (enabled: boolean): PressKey => {
  const runtime = useRuntime()
  const press = useRef<PressKey>(() => undefined)
  useEffect(() => {
    if (!enabled) return
    const pressed = new Set<string>()
    const send = (): void => {
      runtime.runFork(Effect.ignore(actions.setController(controllerStateFrom(pressed))))
    }
    const clear = (): void => {
      if (pressed.size === 0) return
      pressed.clear()
      send()
    }
    const down = (event: KeyboardEvent): void => {
      // A shortcut (⌘⇧4, ⌘Z…) isn't gameplay, and macOS sends no key-up for a key pressed with ⌘ held:
      // it would stay held on the console. Let the shortcut through and let go of everything.
      if (event.metaKey || event.ctrlKey) {
        clear()
        return
      }
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
    press.current = (code, held) => {
      if (held ? pressed.has(code) : !pressed.has(code)) return
      if (held) pressed.add(code)
      else pressed.delete(code)
      send()
    }
    window.addEventListener("keydown", down)
    window.addEventListener("keyup", up)
    window.addEventListener("blur", clear)
    return () => {
      press.current = () => undefined
      window.removeEventListener("keydown", down)
      window.removeEventListener("keyup", up)
      window.removeEventListener("blur", clear)
      runtime.runFork(Effect.ignore(actions.setController(idleController)))
    }
  }, [enabled, runtime])
  return (code, down) => { press.current(code, down) }
}

interface StreamViewProps {
  /** The console's name, as last reported by the stream. */
  readonly title: string
  /** A PS5 (else a PS4), for naming it in the passcode prompt. */
  readonly ps5: boolean
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
  ps5,
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
  // The window can go fullscreen without the button (the green button, ⌃⌘F, a previous stream): read it,
  // now and on every resize, so the button's label is never the opposite of what it does.
  useEffect(() => {
    const sync = () => {
      run(actions.fullscreenState, { onSuccess: (state) => { if (Option.isSome(state)) setFullscreen(state.value) } })
    }
    sync()
    window.addEventListener("resize", sync)
    return () => { window.removeEventListener("resize", sync) }
  }, [run])
  // Double-clicking the video (not the HUD or the settings) toggles fullscreen, as in video players.
  const onDoubleClick = useEffectEvent((event: MouseEvent) => {
    // Only the video: not the HUD, a dialog (including the rest-mode alert), the console's keyboard bar or
    // the connecting screen, where a double click selects text or presses a button.
    if (event.target instanceof Element
      && event.target.closest("header, [role=dialog], [role=alertdialog], [data-no-fullscreen]") !== null) return
    if (event.altKey) return // ⌥-clicks press the touchpad
    toggleFullscreen()
  })
  useEffect(() => {
    const listener = (event: MouseEvent) => { onDoubleClick(event) }
    window.addEventListener("dblclick", listener)
    return () => { window.removeEventListener("dblclick", listener) }
  }, [])

  useFork(useMemo(() => actions.pollStats(setStats, settings.height), [settings.height]))

  const hudHidden = idle && !settingsOpen
  // The controls show and hide at once, with no fade. transition-none also overrides the buttons' transition-all.
  const hide = cn("transition-none", hudHidden && "opacity-0")
  const keepStats = settings.showStats && connected && reconnect.reconnecting === false && stats.rows.length > 0

  const end = () => { onEnd(Option.none()) }
  const stop = () => { run(actions.stop, { onSuccess: end, onFailure: end }) }
  // Once streaming, Stop asks whether to put the console in rest mode too.
  const [askingRest, setAskingRest] = useState(false)
  // Off while anything else takes the keyboard (the login PIN, the settings, the console's text field, the
  // rest-mode dialog) and before the stream is up, so typing or Enter on a button isn't read as gameplay.
  const controlling = connected && Option.isNone(loginPin) && !settingsOpen && Option.isNone(keyboard) && !askingRest
  const pressKey = useKeyboardController(controlling)
  const requestStop = () => {
    if (connected) setAskingRest(true)
    else stop()
  }

  return (
    <>
      <RestModeDialog
        open={askingRest}
        console={title}
        onOpenChange={setAskingRest}
        onLeaveOn={stop}
        onRest={() => { run(actions.sleepAndStop, { onSuccess: end, onFailure: end }) }}
      />
      <header
        data-idle={idle}
        className={cn(
          "fixed inset-x-0 top-0 flex items-center gap-4 px-4 pt-3 pb-6",
          hudHidden && "pointer-events-none",
          settingsOpen && "pr-[24rem]", // keep the HUD's buttons clear of the settings sheet
        )}
      >
        <div aria-hidden className={cn("absolute inset-0 -z-10 bg-gradient-to-b from-black/70 to-transparent", hide)} />
        <span className={cn("font-medium", hide)}>{title}</span>
        {/* Connection messages always; the stream's numbers only with "Stats on screen" on, and then they stay
            when the rest of the HUD hides. */}
        <span
          aria-label={keepStats ? "Stream stats" : undefined}
          className={cn(
            "flex-1 truncate text-xs text-muted-foreground tabular-nums [text-shadow:0_1px_2px_rgb(0_0_0/0.8)]",
            !keepStats && hide,
          )}
        >
          {reconnect.reconnecting === "dropped"
            ? "Connection lost. Reconnecting…"
            : reconnect.reconnecting === "stalled"
              ? "The picture stopped. Reconnecting…"
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
                      : settings.showStats ? stats.line : null /* off: no numbers, even with the HUD up */}
        </span>
        {/* Stays when the HUD hides, like the stats: it explains a stuttering stream. */}
        {connected && reconnect.reconnecting === false && <SteadyWifiWarning />}
        <details className={cn("group relative text-xs", hide)}>
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
          className={cn(hide, mic === "on" && "bg-signal/90 text-black hover:bg-signal")}
          disabled={mic === "pending"}
          onClick={onMicToggle}
        >
          {mic === "off" ? <MicOff /> : <Mic />}
          {mic === "on" ? "Mic on" : "Mic"}
        </Button>
        <Button variant="secondary" size="sm" className={hide} onClick={toggleFullscreen}>
          {fullscreen ? <Minimize /> : <Maximize />}
          {fullscreen ? "Exit fullscreen" : "Fullscreen"}
        </Button>
        <Button
          variant="secondary"
          size="sm"
          className={hide}
          onClick={() => {
            setTab(reconnect.pending ? "stream" : "picture")
            setSettingsOpen(true)
          }}
        >
          <SlidersHorizontal /> Settings
          {reconnect.pending && <span aria-label="Reconnect to apply" className="size-1.5 rounded-full bg-signal" />}
        </Button>
        <Button variant="destructive" size="sm" className={hide} onClick={requestStop}>
          Stop
        </Button>
      </header>
      {settings.view === "split" && connected && <CompareLabels />}
      {controlling && (
        <PsButton
          className={cn(hide, hudHidden && "pointer-events-none", settings.view === "split" ? "bottom-14" : "bottom-6")}
          onPress={(down) => { pressKey("KeyP", down) }}
        />
      )}
      {mic === "on" && hudHidden && (
        // The HUD is hidden: the microphone being live must still be obvious.
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
        {...(stats.upscaleIdle === undefined ? {} : { upscaleIdle: stats.upscaleIdle })}
        onChange={onSettingsChange}
        reconnect={reconnect}
      />
      {Option.isSome(keyboard) && (
        <ConsoleKeyboard consoleName={title} text={keyboard.value} onDone={onKeyboardDone} />
      )}
      {Option.isSome(loginPin) && (
        <LoginPinPrompt ps5={ps5} incorrect={loginPin.value.incorrect} onSubmitted={onLoginPinSubmitted} onCancel={stop} />
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

/** macOS never hands the pad's PS button to apps, so the HUD has one: held while the pointer is down, as
 * on the pad (a short press opens the control center, a long one goes home). Above the split-screen labels
 * when they show. */
const PsButton = ({ className, onPress }: { readonly className: string; readonly onPress: (down: boolean) => void }) => (
  <button
    type="button"
    aria-label="PS button"
    tabIndex={-1} // never focused: Enter and Space belong to the keyboard controller
    data-no-fullscreen
    className={cn(
      "fixed left-1/2 flex size-14 -translate-x-1/2 items-center justify-center rounded-full border border-white/25",
      "bg-black/35 text-lg font-semibold tracking-tight text-white/80 shadow-lg backdrop-blur-md select-none",
      "hover:bg-black/50 hover:text-white active:scale-95 active:bg-white/20",
      className,
    )}
    onPointerDown={() => { onPress(true) }}
    onPointerUp={() => { onPress(false) }}
    onPointerLeave={() => { onPress(false) }}
    onPointerCancel={() => { onPress(false) }}
  >
    PS
  </button>
)

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
  readonly ps5: boolean
  readonly incorrect: boolean
  readonly onSubmitted: () => void
  readonly onCancel: () => void
}

const LoginPinPrompt = ({ ps5, incorrect, onSubmitted, onCancel }: LoginPinPromptProps) => {
  const run = useRun()
  const id = useId()
  const [pin, setPin] = useState("")
  return (
    <div className="fixed inset-0 flex items-center justify-center p-6">
      <Card role="dialog" aria-labelledby={`${id}-title`} className="w-full max-w-xs bg-card/80 backdrop-blur-xl">
        <CardHeader>
          <CardTitle id={`${id}-title`}>Console passcode</CardTitle>
          <CardDescription>
            {incorrect ? "Wrong passcode. " : ""}Enter your {ps5 ? "PS5" : "PS4"} user's passcode (4 digits), not the pairing code.
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
              Passcode
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

/** Asked when Stop is pressed while streaming: put the console in rest mode too, or leave it on. */
const RestModeDialog = ({ open, console, onOpenChange, onRest, onLeaveOn }: {
  readonly open: boolean
  readonly console: string
  readonly onOpenChange: (open: boolean) => void
  readonly onRest: () => void
  readonly onLeaveOn: () => void
}) => (
  <AlertDialog open={open} onOpenChange={onOpenChange}>
    <AlertDialogContent>
      <AlertDialogHeader>
        <AlertDialogTitle>Put {console} in rest mode?</AlertDialogTitle>
        <AlertDialogDescription>
          Rest mode saves power, and the PS5 wakes up again the next time you play. Leave it on if someone will
          keep playing on the TV.
        </AlertDialogDescription>
      </AlertDialogHeader>
      <AlertDialogFooter>
        <AlertDialogCancel>Keep playing</AlertDialogCancel>
        <AlertDialogAction variant="outline" onClick={onLeaveOn}>Leave it on</AlertDialogAction>
        <AlertDialogAction onClick={onRest}>Rest mode</AlertDialogAction>
      </AlertDialogFooter>
    </AlertDialogContent>
  </AlertDialog>
)
