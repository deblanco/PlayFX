import { Option } from "effect"
import { useEffect, useId, useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { Settings } from "@/core/schema"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import { useFork, useRun } from "./runtime"
import { UpscalerSelect } from "./Settings"

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

interface StreamViewProps {
  /** The console's name, as last reported by the stream. */
  readonly title: string
  /** Set while the console waits for its login PIN. */
  readonly loginPin: Option.Option<{ readonly incorrect: boolean }>
  readonly settings: Settings
  readonly metalfxSupported: boolean
  readonly onSettingsChange: (next: Settings) => void
  readonly onLoginPinSubmitted: () => void
  /** The stream ended; carries the error to show, if any. */
  readonly onEnd: (error: Option.Option<string>) => void
}

export const StreamView = ({
  title,
  loginPin,
  settings,
  metalfxSupported,
  onSettingsChange,
  onLoginPinSubmitted,
  onEnd,
}: StreamViewProps) => {
  const run = useRun()
  const idle = useIdle(hudIdleMs)
  const [stats, setStats] = useState("Connecting…")

  useFork(useMemo(() => actions.pollStats(setStats), []))

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
          idle && "pointer-events-none opacity-0",
        )}
      >
        <span className="font-medium">{title}</span>
        <span className="flex-1 truncate text-xs text-muted-foreground tabular-nums">{stats}</span>
        <UpscalerSelect settings={settings} metalfxSupported={metalfxSupported} onChange={onSettingsChange} />
        <Button variant="destructive" size="sm" onClick={stop}>
          Stop
        </Button>
      </header>
      {Option.isSome(loginPin) && (
        <LoginPinPrompt incorrect={loginPin.value.incorrect} onSubmitted={onLoginPinSubmitted} onCancel={stop} />
      )}
    </>
  )
}

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
