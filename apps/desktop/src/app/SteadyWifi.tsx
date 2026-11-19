import { Gamepad2, Laptop } from "lucide-react"
import { useCallback, useId, useMemo, useState } from "react"
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
}

/** The state of AirDrop and Handoff, kept current while mounted, and the switch to pause them. */
export const usePeerWifi = (): PeerWifi => {
  const run = useRun()
  const [state, setState] = useState<PeerWifiState | undefined>(undefined)
  const [pending, setPending] = useState(false)
  useFork(useMemo(() => actions.pollPeerWifi(setState), []))
  const setPaused = useCallback(
    (paused: boolean) => {
      setPending(true)
      run(actions.setPeerWifiPaused(paused), {
        // A dismissed prompt changes nothing, and the reply's state already says so.
        onSuccess: (reply) => {
          setState(reply.state)
          setPending(false)
        },
        onFailure: () => { setPending(false) },
      })
    },
    [run],
  )
  return { state, pending, setPaused }
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
  const wifi = usePeerWifi()
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
  const wifi = usePeerWifi()
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
