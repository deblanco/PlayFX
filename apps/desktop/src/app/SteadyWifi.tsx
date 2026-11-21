import { Gamepad2, Laptop, TriangleAlert } from "lucide-react"
import { createContext, use, useCallback, useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Separator } from "@/components/ui/separator"
import { Switch } from "@/components/ui/switch"
import type { PeerWifiState } from "@/core/schema"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import { useFork, useRun } from "./runtime"

// AirDrop and Handoff share the Mac's one Wi-Fi radio: about once a second they take it off the network's
// channel for ~90 ms, and the stream stalls with it. "Steady Wi-Fi" pauses them while PlayFX is open.
// See docs/NETWORK.md.

export interface PeerWifi {
  /** Unknown until the first reading. */
  readonly state: PeerWifiState | undefined
  /** The password prompt is open (pausing) or the helper is stopping (resuming). */
  readonly pending: boolean
  readonly setPaused: (paused: boolean) => void
  /** A stream is starting: while AirDrop and Handoff are on, a toast suggests Steady Wi-Fi. It never asks
   * for the password by itself, and suggests at most once in a run of the app (not at all after a password
   * prompt was dismissed or failed). */
  readonly suggestBeforeStream: () => void
}

/** What the Play toast says: `undefined` when there's nothing to suggest (AirDrop and Handoff aren't on, or
 * a change is under way). `remembered`: Steady Wi-Fi was left on last time. */
export const suggestion = (
  state: PeerWifiState | undefined,
  pending: boolean,
  remembered: boolean,
): { readonly title: string; readonly description: string } | undefined =>
  state !== "active" || pending
    ? undefined
    : {
        title: "Smoother play on Wi-Fi",
        description: remembered
          ? "Steady Wi-Fi was on last time. Turn it on again?"
          : "AirDrop and Handoff interrupt your Wi-Fi about once a second. Steady Wi-Fi pauses them while you play.",
      }

/** The toast's icon: the Home row's wave, stalling once a second as AirDrop does. */
const WaveIcon = () => (
  <svg width={16} height={16} aria-hidden className="shrink-0 overflow-visible">
    <path
      d={linkPath(16)}
      fill="none"
      strokeLinecap="round"
      className="animate-stutter stroke-ice stroke-[1.75] [stroke-dasharray:2_3] motion-reduce:animate-none"
    />
  </svg>
)

/** The state of AirDrop and Handoff, kept current while mounted, and the switch to pause them. */
const usePeerWifi = (): PeerWifi => {
  const run = useRun()
  const [reading, setReading] = useState<PeerWifiState | undefined>(undefined)
  // While a change is in flight, what it started from: readings taken meanwhile (the prompt can stay open
  // for minutes) don't move the switch; the change's reply has the last word.
  const [pending, setPending] = useState<{ readonly from: PeerWifiState | undefined } | undefined>(undefined)
  // Steady Wi-Fi was left on (saved): the Play toast says so.
  const [remembered, setRemembered] = useState(false)
  // The Play toast was shown, or a pause prompt was dismissed (or failed), in this run of the app: stream
  // starts don't suggest Steady Wi-Fi again.
  const declined = useRef(false)
  // The Play toast on screen, closed once the switch moves some other way (it would offer a stale choice).
  const shown = useRef<string | number | undefined>(undefined)
  useFork(useMemo(() => actions.pollPeerWifi(setReading), []))
  useEffect(() => { run(actions.loadSteadyWifi, { onSuccess: setRemembered }) }, [run])
  const setPaused = useCallback(
    (paused: boolean) => {
      setPending({ from: reading })
      run(actions.setPeerWifiPaused(paused), {
        // A dismissed prompt changes nothing, and the reply's state already says so.
        onSuccess: (reply) => {
          setReading(reply.state)
          setPending(undefined)
          if (reply.outcome === "done") setRemembered(paused)
          else declined.current = true
        },
        onFailure: () => {
          setPending(undefined)
          if (paused) declined.current = true
        },
      })
    },
    [run, reading],
  )
  useEffect(() => {
    if (shown.current !== undefined && (reading !== "active" || pending !== undefined)) {
      toast.dismiss(shown.current)
      shown.current = undefined
    }
  }, [reading, pending])
  const suggestBeforeStream = useCallback(() => {
    const text = suggestion(reading, pending !== undefined, remembered)
    if (text === undefined || declined.current) return
    declined.current = true
    shown.current = toast(text.title, {
      description: text.description,
      icon: <WaveIcon />,
      duration: 10_000,
      action: { label: "Turn on", onClick: () => { setPaused(true) } },
      cancel: { label: "Not now", onClick: () => undefined },
    })
  }, [reading, pending, remembered, setPaused])
  return {
    state: pending === undefined ? reading : pending.from,
    pending: pending !== undefined,
    setPaused,
    suggestBeforeStream,
  }
}

const PeerWifiContext = createContext<PeerWifi | null>(null)

/** One reading and one switch for the whole app: the Home row, the Settings section (on Home and while
 * streaming) and the stream's warning show the same state, and a pause started in one disables the others. */
export const PeerWifiProvider = ({ children }: { readonly children: ReactNode }) => (
  <PeerWifiContext value={usePeerWifi()}>{children}</PeerWifiContext>
)

export const usePeerWifiContext = (): PeerWifi => {
  const wifi = use(PeerWifiContext)
  if (wifi === null) throw new Error("Steady Wi-Fi needs a <PeerWifiProvider> above it")
  return wifi
}

/** Whether there's anything to show: AWDL exists and is on, or PlayFX is keeping it off. */
export const showsSteadyWifi = (state: PeerWifiState | undefined): state is "active" | "paused" =>
  state === "active" || state === "paused"

const copy = {
  active: {
    title: "Wi-Fi hiccups every second",
    short: "AirDrop and Handoff take your Mac's Wi-Fi for about 90 ms each second. Pause them while you play.",
  },
  pending: {
    title: "Waiting for your password",
    short: "macOS asks before PlayFX can pause AirDrop and Handoff.",
  },
  paused: {
    title: "Steady Wi-Fi",
    short: "AirDrop and Handoff are paused until you turn this off or quit PlayFX.",
  },
  off: {
    title: "Steady Wi-Fi",
    short: "AirDrop and Handoff are already off, so nothing interrupts your Wi-Fi.",
  },
} as const

/** A gentle wave across `width` pixels, 16 high, like the backdrop's ribbons. */
export const linkPath = (width: number): string => {
  const w = Math.max(width, 8)
  const x = (f: number) => Math.round(w * f * 10) / 10
  return `M 1 8 C ${x(0.2)} 1 ${x(0.3)} 15 ${x(0.5)} 8 S ${x(0.8)} 1 ${x(1) - 1} 8`
}

/** The element's width, following resizes (a fixed guess where ResizeObserver doesn't exist, as in tests). */
const useWidth = (fallback: number): [(element: HTMLElement | null) => void, number] => {
  const [width, setWidth] = useState(fallback)
  const ref = useCallback((element: HTMLElement | null) => {
    if (element === null || typeof ResizeObserver === "undefined") return
    const observer = new ResizeObserver(([entry]) => {
      if (entry !== undefined) setWidth(entry.contentRect.width)
    })
    observer.observe(element)
    return () => { observer.disconnect() }
  }, [])
  return [ref, width]
}

/**
 * The link from the Mac to the console as a line of light. While AirDrop and Handoff are on, its flow
 * halts for a beat once a second and then surges to catch up, at the rhythm of the real stall (packets
 * wait, then arrive in a burst); paused, it flows evenly and glows, and a light crosses it once to say so.
 */
export const LinkLine = ({ steady, className }: { readonly steady: boolean; readonly className?: string }) => {
  const [ref, width] = useWidth(96)
  const d = linkPath(width)
  const end = cn("size-3.5 shrink-0 transition-colors duration-500", steady ? "text-ice" : "text-white/45")
  return (
    <div className={cn("flex items-center gap-1.5", className)} aria-hidden data-steady={steady}>
      <Laptop className={end} />
      <div ref={ref} className="relative h-4 min-w-0 flex-1">
        <svg width={width} height={16} className="absolute inset-0 overflow-visible">
          <path
            d={d}
            fill="none"
            strokeLinecap="round"
            className={cn(
              "[stroke-dasharray:2_6] transition-[stroke,stroke-width] duration-500 motion-reduce:animate-none",
              steady
                ? "animate-flow stroke-ice stroke-2 drop-shadow-[0_0_5px_var(--color-ribbon)]"
                : "animate-stutter stroke-ice/70 stroke-[1.75]",
            )}
          />
        </svg>
        {steady && (
          <span
            className="absolute top-0 left-0 size-1.5 -translate-x-[3px] -translate-y-[3px] animate-steady rounded-full bg-ice opacity-0 shadow-[0_0_10px_3px_var(--color-ribbon)] motion-reduce:hidden"
            style={{ offsetPath: `path('${d}')`, offsetRotate: "0deg" }}
          />
        )}
      </div>
      <Gamepad2 className={end} />
    </div>
  )
}

const textFor = (wifi: PeerWifi, state: "active" | "paused" | "off") =>
  wifi.pending && state === "active" ? copy.pending : copy[state]

/** Home: one row, shown only while AirDrop and Handoff are on or paused by PlayFX. */
export const SteadyWifiRow = () => {
  const wifi = usePeerWifiContext()
  const id = useId()
  if (!showsSteadyWifi(wifi.state)) return null
  const paused = wifi.state === "paused"
  const text = textFor(wifi, wifi.state)
  return (
    <>
      <Separator />
      <div className="flex items-center gap-3">
        <LinkLine steady={paused} className="w-32 shrink-0" />
        <label htmlFor={id} className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="text-sm">{text.title}</span>
          <span className="text-xs text-muted-foreground">{text.short}</span>
        </label>
        <Switch
          id={id}
          checked={paused}
          disabled={wifi.pending}
          onCheckedChange={wifi.setPaused}
          className="data-[state=checked]:bg-signal"
        />
      </div>
    </>
  )
}

/** Settings → Stream: the same switch with what it measured and what it costs. */
export const SteadyWifiSection = () => {
  const wifi = usePeerWifiContext()
  const id = useId()
  if (wifi.state === undefined || wifi.state === "absent") return null
  const state = wifi.state
  const steady = state !== "active"
  const text = textFor(wifi, state)
  return (
    <section className="flex flex-col gap-3 rounded-lg border border-white/10 bg-white/[0.03] p-3.5">
      <div className="flex items-start justify-between gap-4">
        <label htmlFor={id} className="flex flex-col gap-0.5">
          <span className="text-sm">{text.title}</span>
          <span className="text-xs text-muted-foreground">{text.short}</span>
        </label>
        {state !== "off" && (
          <Switch
            id={id}
            checked={state === "paused"}
            disabled={wifi.pending}
            onCheckedChange={wifi.setPaused}
            className="mt-0.5 data-[state=checked]:bg-signal"
          />
        )}
      </div>
      <LinkLine steady={steady} className="w-full" />
      <p className="text-xs text-muted-foreground">
        Measured with a PS5 over Wi-Fi: with AirDrop and Handoff on, the link to the console stalled for up to
        100 ms once a second. Paused, the worst was 21 ms.
      </p>
      <p className="text-xs text-muted-foreground">
        While paused, AirDrop, Handoff, Universal Control and a wireless Sidecar display don't work. macOS asks
        for your password each time you turn this on.
      </p>
    </section>
  )
}

/** While streaming, in the HUD, with the switch at hand: AirDrop and Handoff are on and stalling the stream, or
 * the stream's frames show their stall (`stalling`: frames stop and come in a burst at a steady period) while
 * they read as off, which macOS flips by itself. Nothing while Steady Wi-Fi is on, or with no AirDrop radio:
 * there's nothing more to offer, so the stall is only logged. */
export const SteadyWifiWarning = ({ stalling }: { readonly stalling: boolean }) => {
  const wifi = usePeerWifiContext()
  if (wifi.state !== "active" && !(wifi.state === "off" && stalling)) return null
  return (
    <span role="status" className="flex shrink-0 items-center gap-1.5 text-xs text-signal [text-shadow:0_1px_2px_rgb(0_0_0/0.8)]">
      <TriangleAlert className="size-3.5" aria-hidden />
      {wifi.state === "active" ? "AirDrop is stalling the Wi-Fi" : "The Wi-Fi keeps stalling"}
      <Button
        variant="link"
        size="xs"
        disabled={wifi.pending}
        onClick={() => { wifi.setPaused(true) }}
        className="px-0 text-signal underline"
      >
        {wifi.pending ? "Waiting for your password…" : "Turn on Steady Wi-Fi"}
      </Button>
    </span>
  )
}
