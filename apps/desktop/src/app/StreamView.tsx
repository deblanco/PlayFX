import { Effect, Option } from "effect"
import { SlidersHorizontal } from "lucide-react"
import { useEffect, useId, useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { idleController, type Settings } from "@/core/schema"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import type { Capabilities } from "./format"
import { controllerStateFrom, isControllerKey, keyboardLayout } from "./keyboard"
import { useFork, useRun, useRuntime } from "./runtime"
import { SettingsSheet, type ReconnectState, type SettingsTab } from "./SettingsSheet"

export const hudIdleMs = 2500

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
  readonly settings: Settings
  readonly capabilities: Capabilities
  readonly onSettingsChange: (next: Settings) => void
  /** Whether stream settings changed since connecting, and how to reconnect with them. */
  readonly reconnect: ReconnectState
  readonly onLoginPinSubmitted: () => void
  /** The stream ended; carries the error to show, if any. */
  readonly onEnd: (error: Option.Option<string>) => void
}

export const StreamView = ({
  title,
  loginPin,
  settings,
  capabilities,
  onSettingsChange,
  reconnect,
  onLoginPinSubmitted,
  onEnd,
}: StreamViewProps) => {
  const run = useRun()
  const idle = useIdle(hudIdleMs)
  const [stats, setStats] = useState("Connecting…")
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [tab, setTab] = useState<SettingsTab>("picture")

  useFork(useMemo(() => actions.pollStats(setStats), []))
  // Off while the login-PIN dialog or the settings are open, so typing there isn't read as gameplay.
  useKeyboardController(Option.isNone(loginPin) && !settingsOpen)

  const stop = () => {
    const end = () => { onEnd(Option.none()); }
    run(actions.stop, { onSuccess: end, onFailure: end })
  }

  return (
    <>
      <header
        data-idle={idle}
        className={cn(
          "fixed inset-x-0 top-0 flex items-center gap-4 bg-gradient-to-b from-black/70 to-transparent px-4 pt-3 pb-6 transition-opacity duration-500",
          idle && !settingsOpen && "pointer-events-none opacity-0",
        settingsOpen && "pr-[24rem]", // keep the HUD's buttons clear of the settings sheet
        )}
      >
        <span className="font-medium">{title}</span>
        <span className="flex-1 truncate text-xs text-muted-foreground tabular-nums">
          {reconnect.reconnecting ? "Reconnecting…" : stats}
        </span>
        <details className="group relative text-xs">
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
          onClick={() => {
            setTab(reconnect.pending ? "stream" : "picture")
            setSettingsOpen(true)
          }}
        >
          <SlidersHorizontal /> Settings
          {reconnect.pending && <span aria-label="Reconnect to apply" className="size-1.5 rounded-full bg-signal" />}
        </Button>
        <Button variant="destructive" size="sm" onClick={stop}>
          Stop
        </Button>
      </header>
      {settings.compare && <CompareLabels />}
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
      {Option.isSome(loginPin) && (
        <LoginPinPrompt incorrect={loginPin.value.incorrect} onSubmitted={onLoginPinSubmitted} onCancel={stop} />
      )}
    </>
  )
}

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
