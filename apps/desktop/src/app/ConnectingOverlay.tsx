import { Check, Cloud, Gamepad2, Laptop, type LucideIcon } from "lucide-react"
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { activeStep, connectionHint, connectionSteps, connectionTitle, type Reconnecting, type Route } from "./format"

interface ConnectingOverlayProps {
  readonly consoleName: string
  readonly route: Route
  readonly stage: "linking" | "data" | undefined
  readonly reconnecting: Reconnecting
  readonly onCancel: () => void
}

/** Seconds since the component appeared, ticking once a second. */
export const useElapsedSeconds = (): number => {
  const [seconds, setSeconds] = useState(0)
  useEffect(() => {
    const start = Date.now()
    const timer = window.setInterval(() => { setSeconds(Math.floor((Date.now() - start) / 1000)) }, 1000)
    return () => { window.clearInterval(timer) }
  }, [])
  return seconds
}

const width = 320
const midY = 26
/** A gentle wave between two nodes, like the backdrop's ribbons. */
const wave = (x1: number, x2: number): string => {
  const third = (x2 - x1) / 3
  return `M ${String(x1)} ${String(midY)} C ${String(x1 + third)} ${String(midY - 14)}, ${String(x2 - third)} ${String(midY + 14)}, ${String(x2)} ${String(midY)}`
}

interface Node {
  readonly x: number
  readonly icon: LucideIcon
  readonly label: string
}

/** The route the stream takes, drawn as nodes joined by waves: done links glow, the link being set up
 * carries a travelling pulse, and the console pulses while the stream starts. */
const RouteMap = ({ route, active, consoleName }: { readonly route: Route; readonly active: number; readonly consoleName: string }) => {
  const nodes: readonly Node[] =
    route === "internet"
      ? [
          { x: 24, icon: Laptop, label: "This Mac" },
          { x: width / 2, icon: Cloud, label: "PSN" },
          { x: width - 24, icon: Gamepad2, label: consoleName },
        ]
      : [
          { x: 24, icon: Laptop, label: "This Mac" },
          { x: width - 24, icon: Gamepad2, label: consoleName },
        ]
  const links = nodes.slice(1).map((node, i) => ({ d: wave((nodes[i]?.x ?? 0) + 18, node.x - 18), i }))
  const consoleActive = active >= links.length
  return (
    <div aria-hidden className="relative mx-auto h-20" style={{ width }}>
      <svg width={width} height={52} className="absolute inset-x-0 top-0 overflow-visible">
        {links.map(({ d, i }) => (
          <path
            key={d}
            d={d}
            fill="none"
            strokeLinecap="round"
            className={cn(
              "transition-[stroke,stroke-opacity] duration-700",
              i < active && "stroke-ice stroke-[2] drop-shadow-[0_0_6px_var(--color-ribbon)]",
              i === active && "animate-flow stroke-ice/70 stroke-[1.5] [stroke-dasharray:2_6] motion-reduce:animate-none",
              i > active && "stroke-white/15 stroke-[1.5] [stroke-dasharray:2_6]",
            )}
          />
        ))}
      </svg>
      {links.map(({ d, i }) =>
        i === active ? (
          <span
            key={`pulse-${d}`}
            className="absolute top-0 left-0 size-2 -translate-x-1 -translate-y-1 animate-travel rounded-full bg-ice shadow-[0_0_12px_3px_var(--color-ribbon)] motion-reduce:hidden"
            style={{ offsetPath: `path('${d}')`, offsetRotate: "0deg" }}
          />
        ) : null,
      )}
      {nodes.map(({ x, icon: Icon, label }, n) => {
        const reached = n <= active
        const pulsing = consoleActive && n === nodes.length - 1
        return (
          <div key={label} className="absolute top-2 flex w-24 -translate-x-1/2 flex-col items-center gap-1.5" style={{ left: x }}>
            <span
              className={cn(
                "relative grid size-9 place-items-center rounded-full border transition-colors duration-700",
                reached ? "border-ice/60 bg-ribbon/25 text-ice" : "border-white/15 bg-black/30 text-white/40",
              )}
            >
              {pulsing && <span className="absolute inset-0 animate-ping rounded-full border border-ice/70 motion-reduce:hidden" />}
              <Icon className="size-4" />
            </span>
            <span className={cn("max-w-24 truncate text-[11px]", reached ? "text-white/80" : "text-white/40")}>{label}</span>
          </div>
        )
      })}
    </div>
  )
}

/** Shown until the stream connects (a connection over the internet takes ~25 s): the route, the step
 * under way, how long it's been, and a way out. */
export const ConnectingOverlay = ({ consoleName, route, stage, reconnecting, onCancel }: ConnectingOverlayProps) => {
  const seconds = useElapsedSeconds()
  const steps = connectionSteps(route, stage, consoleName)
  const current = steps.find((step) => step.state === "active")
  return (
    <div className="pointer-events-none fixed inset-0 flex items-center justify-center p-6">
      <section
        data-no-fullscreen
        aria-labelledby="connecting-title"
        className="pointer-events-auto w-full max-w-sm rounded-2xl border border-white/10 bg-glass p-6 text-white shadow-2xl backdrop-blur-xl"
      >
        <h2 id="connecting-title" className="text-lg font-medium text-balance">
          {connectionTitle(reconnecting, consoleName)}
        </h2>
        <div className="mt-5">
          <RouteMap route={route} active={activeStep(route, stage)} consoleName={consoleName} />
        </div>
        <ol className="mt-2 flex flex-col gap-2.5 text-sm">
          {steps.map((step) => (
            <li key={step.label} className="flex items-center gap-3" aria-current={step.state === "active" ? "step" : undefined}>
              <span
                className={cn(
                  "grid size-4 shrink-0 place-items-center rounded-full",
                  step.state === "done" && "bg-ice text-black",
                  step.state === "active" && "border border-ice",
                  step.state === "waiting" && "border border-white/20",
                )}
              >
                {step.state === "done" && <Check className="size-3" strokeWidth={3} />}
                {step.state === "active" && <span className="size-1.5 animate-pulse rounded-full bg-ice motion-reduce:animate-none" />}
              </span>
              <span className={cn(step.state === "waiting" ? "text-white/45" : "text-white", step.state === "done" && "text-white/70")}>
                {step.label}
              </span>
            </li>
          ))}
        </ol>
        <div className="mt-6 flex items-end justify-between gap-4">
          <p role="status" className="text-xs text-white/60">
            <span className="sr-only">{current?.label}. </span>
            <span className="font-medium text-white/85 tabular-nums">{String(seconds)} s</span> so far.{" "}
            {connectionHint(route, seconds)}
          </p>
          <Button variant="secondary" size="sm" onClick={onCancel}>
            Cancel
          </Button>
        </div>
      </section>
    </div>
  )
}
