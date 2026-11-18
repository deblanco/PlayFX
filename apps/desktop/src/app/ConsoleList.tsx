import { Effect, Fiber, Option } from "effect"
import { useEffect, useId, useMemo, useRef, useState } from "react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import type { DiscoveredConsole, PairedConsole, PairedConsoles } from "@/core/schema"
import * as actions from "./actions"
import { useDevAutoplay } from "./devSeed"
import { consoleRows, type ConsoleRow } from "./format"
import { PinInput } from "./PinInput"
import { useFork, useRun, useRuntime } from "./runtime"
import { StatusBadge } from "./StatusBadge"

interface ConsoleListProps {
  readonly accountId: Option.Option<string>
  /** `psnDuid`: connect over the internet to the console with that PSN device ID. */
  readonly onPlay: (console: PairedConsole, psnDuid?: string) => void
}

export const ConsoleList = ({ accountId, onPlay }: ConsoleListProps) => {
  const run = useRun()
  const [discovered, setDiscovered] = useState<readonly DiscoveredConsole[]>([])
  const [paired, setPaired] = useState<PairedConsoles>({})
  const [scanMessage, setScanMessage] = useState("Searching…")
  const [pairing, setPairing] = useState<string | null>(null)
  // Play on a console in rest mode wakes it first; this is the one being woken, cancellable.
  const runtime = useRuntime()
  const [waking, setWaking] = useState<string | null>(null)
  const wakeFiber = useRef<Fiber.Fiber<unknown, unknown> | null>(null)

  const cancelWake = () => {
    if (wakeFiber.current) runtime.runFork(Fiber.interrupt(wakeFiber.current))
    wakeFiber.current = null
    setWaking(null)
  }
  useEffect(() => () => { if (wakeFiber.current) runtime.runFork(Fiber.interrupt(wakeFiber.current)) }, [runtime])

  /** Plays right away when the console is ready; wakes it and waits first when it's in rest mode. */
  const play = (row: ConsoleRow, console: PairedConsole) => {
    if (row.status === "internet" && row.psnDuid !== undefined) {
      onPlay(console, row.psnDuid)
      return
    }
    if (row.status !== "standby") {
      onPlay(console)
      return
    }
    setWaking(row.hostId)
    wakeFiber.current = runtime.runFork(
      Effect.match(actions.wakeUntilReady(console, onPsn[row.hostId]), {
        onSuccess: (route) => {
          wakeFiber.current = null
          setWaking(null)
          onPlay(console, route.via === "internet" ? route.psnDuid : undefined)
        },
        onFailure: (error) => {
          wakeFiber.current = null
          setWaking(null)
          toast.error(error.message)
        },
      }),
    )
  }

  useEffect(() => {
    run(actions.loadPaired, { onSuccess: setPaired })
  }, [run])

  useFork(
    useMemo(
      () =>
        actions.pollDiscovery((outcome) => {
          if (outcome.ok) {
            setDiscovered(outcome.discovered)
            setPaired(outcome.paired)
            setScanMessage(outcome.discovered.length > 0 ? "" : "No consoles found on this network")
          } else {
            setScanMessage(outcome.message)
          }
        }),
      [],
    ),
  )

  // Paired consoles PSN can reach (when signed in for internet play), refreshed every minute.
  const [onPsn, setOnPsn] = useState<Readonly<Record<string, string>>>({})
  useFork(useMemo(() => actions.pollPsnReachable(paired, setOnPsn), [paired]))

  const rows = consoleRows(discovered, paired, onPsn)
  const signedIn = Option.isSome(accountId)
  useDevAutoplay(rows, onPlay)

  return (
    <section aria-label="Consoles" className="flex flex-col gap-2">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="text-sm font-medium">Consoles</h2>
        <span role="status" className="text-xs text-muted-foreground">
          {scanMessage}
        </span>
      </div>
      <ul className="flex flex-col gap-2">
        {rows.map((row) => (
          <li key={row.hostId} className="flex flex-col gap-2 rounded-lg border bg-background/40 p-3">
            <ConsoleItem
              row={row}
              signedIn={signedIn}
              onPair={() => { setPairing(row.hostId); }}
              onWake={(console) => { run(actions.wake(console), {
                  onSuccess: () => toast.success("Wake-up sent; the console takes ~20 s to start."),
                }); }
              }
              waking={waking === row.hostId}
              onPlay={(console) => { play(row, console) }}
              onCancelWake={cancelWake}
              onForget={() => { run(actions.forget(row.hostId), { onSuccess: setPaired }); }}
            />
            {pairing === row.hostId && row.discovered !== undefined && (
              <PairForm
                console={row.discovered}
                onPaired={(next) => {
                  setPaired(next)
                  setPairing(null)
                  toast.success(`Paired with ${row.name}`)
                }}
                onCancel={() => { setPairing(null); }}
              />
            )}
          </li>
        ))}
      </ul>
    </section>
  )
}

interface ConsoleItemProps {
  readonly row: ConsoleRow
  readonly signedIn: boolean
  readonly onPair: () => void
  readonly onWake: (console: PairedConsole) => void
  /** Being woken up by Play. */
  readonly waking: boolean
  readonly onPlay: (console: PairedConsole) => void
  readonly onCancelWake: () => void
  readonly onForget: () => void
}

const ConsoleItem = ({ row, signedIn, onPair, onWake, waking, onPlay, onCancelWake, onForget }: ConsoleItemProps) => {
  const { paired } = row
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <div className="flex items-center gap-2">
          <span className="truncate font-medium">{row.name}</span>
          <StatusBadge status={row.status} />
        </div>
        <span className="truncate text-xs text-muted-foreground">{row.meta}</span>
      </div>
      <div className="flex items-center gap-1.5">
        {paired === undefined ? (
          row.discovered !== undefined && (
            <Button size="sm" variant="outline" disabled={!signedIn} title={signedIn ? undefined : "Sign in first"} onClick={onPair}>
              Pair
            </Button>
          )
        ) : (
          <>
            {waking ? (
              <Button size="sm" variant="outline" onClick={onCancelWake}>
                Cancel
              </Button>
            ) : (
              row.status === "standby" && (
                <Button size="sm" variant="outline" onClick={() => { onWake(paired); }}>
                  Wake
                </Button>
              )
            )}
            <Button
              size="sm"
              disabled={waking || row.status === "offline"}
              title={row.status === "standby" && !waking ? "Wakes the console, then plays" : undefined}
              onClick={() => { onPlay(paired); }}
            >
              {waking ? "Waking…" : "Play"}
            </Button>
            <Button size="sm" variant="ghost" onClick={onForget}>
              Forget
            </Button>
          </>
        )}
      </div>
    </div>
  )
}

interface PairFormProps {
  readonly console: DiscoveredConsole
  readonly onPaired: (paired: PairedConsoles) => void
  readonly onCancel: () => void
}

const PairForm = ({ console, onPaired, onCancel }: PairFormProps) => {
  const run = useRun()
  const id = useId()
  const [pin, setPin] = useState("")
  const [busy, setBusy] = useState(false)

  return (
    <form
      aria-label={`Pair ${console.name}`}
      className="flex flex-col gap-2 border-t pt-2"
      onSubmit={(event) => {
        event.preventDefault()
        setBusy(true)
        run(actions.pair(console, pin), {
          onSuccess: onPaired,
          onFailure: () => { setBusy(false); },
        })
      }}
    >
      <Label htmlFor={id} className="text-xs text-muted-foreground">
        On the PS5: Settings → System → Remote Play → Pair Device
      </Label>
      <div className="flex flex-wrap items-center gap-2">
        <PinInput id={id} value={pin} onChange={setPin} disabled={busy} />
        <Button type="submit" size="sm" disabled={busy || pin.length !== 8}>
          {busy ? "Pairing…" : "Pair"}
        </Button>
        <Button type="button" size="sm" variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </form>
  )
}
