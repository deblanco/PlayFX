import { Effect, Fiber, Option } from "effect"
import { useEffect, useId, useMemo, useRef, useState } from "react"
import { toast } from "sonner"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import type { DiscoveredConsole, PairedConsole, PairedConsoles, PsnConsole, PsnPairStage, Settings } from "@/core/schema"
import * as actions from "./actions"
import { AddByIp, NoConsoles } from "./ConsoleHelp"
import { useElapsedSeconds } from "./ConnectingOverlay"
import { useDevControl } from "./devControl"
import { useDevAutoplay } from "./devSeed"
import { consoleRows, psnPairHint, psnPairStep, samePaired, type ConsoleRow } from "./format"
import { PinInput } from "./PinInput"
import { useFork, useRun, useRuntime } from "./runtime"
import { StatusBadge } from "./StatusBadge"

interface ConsoleListProps {
  readonly accountId: Option.Option<string>
  /** `psnDuid`: connect over the internet to the console with that PSN device ID. */
  /** `psnFallback`: playing locally, the console's PSN device ID, if PSN can reach it too. */
  /** How Play reaches a console (Automatic, home network only, or internet only). */
  readonly connection?: Settings["connection"]
  readonly onPlay: (console: PairedConsole, psnDuid?: string, psnFallback?: string) => void
  /** Whether any console is paired, once the pairings have loaded. */
  readonly onPairedChange?: (paired: boolean) => void
  /** The saved console IP ("" for none), asked directly on every scan. */
  readonly consoleAddress: string
  readonly onConsoleAddressChange: (address: string) => void
}

export const ConsoleList = ({
  accountId,
  connection = "auto",
  onPlay,
  onPairedChange,
  consoleAddress,
  onConsoleAddressChange,
}: ConsoleListProps) => {
  const run = useRun()
  const [discovered, setDiscovered] = useState<readonly DiscoveredConsole[]>([])
  const [paired, setPaired] = useState<PairedConsoles>({})
  // Discovery errors only: an empty scan has its own box under the list (looking, then what to check).
  const [scanMessage, setScanMessage] = useState("")
  // Whether a scan has finished: until then an empty list is just not known yet.
  const [scanned, setScanned] = useState(false)
  const [pairing, setPairing] = useState<string | null>(null)
  // Play on a console in rest mode wakes it first; this is the one being woken, cancellable.
  const runtime = useRuntime()
  const [waking, setWaking] = useState<string | null>(null)
  const wakeFiber = useRef<Fiber.Fiber<unknown, unknown> | null>(null)

  // Pairing through PSN (no code): the console being paired (by PSN device ID: its row's host ID changes when
  // discovery finds it meanwhile) and its step, cancellable. A failure leaves its reason on that console's row:
  // in the PIN form when it's on this network, else as a note.
  const [psnPairing, setPsnPairing] = useState<{ readonly duid: string; readonly stage: PsnPairStage | undefined } | null>(null)
  const psnPairFiber = useRef<Fiber.Fiber<unknown, unknown> | null>(null)
  const [pairProblem, setPairProblem] = useState<{ readonly duid: string; readonly message: string } | null>(null)
  useEffect(() => () => { if (psnPairFiber.current) runtime.runFork(Fiber.interrupt(psnPairFiber.current)) }, [runtime])

  const pairThroughPsn = (row: ConsoleRow, console: PsnConsole) => {
    setPairing(null)
    setPairProblem(null)
    setPsnPairing({ duid: console.duid, stage: undefined })
    const onProgress = (stage: PsnPairStage) => { setPsnPairing((p) => p && { ...p, stage }) }
    psnPairFiber.current = runtime.runFork(
      Effect.match(Effect.tapError(actions.pairThroughPsn(console, row.discovered, onProgress), (e) => Effect.logWarning(e.message)), {
        onSuccess: (next) => {
          psnPairFiber.current = null
          setPsnPairing(null)
          setPaired(next)
          toast.success(`Paired with ${row.name}`)
        },
        onFailure: (error) => {
          psnPairFiber.current = null
          setPsnPairing(null)
          setPairProblem({ duid: console.duid, message: error.message })
        },
      }),
    )
  }

  /** Why pairing this row's console through PSN failed, if it did. */
  const problemOn = (row: ConsoleRow): string | undefined =>
    pairProblem !== null && pairProblem.duid === row.psn?.duid ? pairProblem.message : undefined

  const cancelPsnPairing = () => {
    if (psnPairFiber.current) runtime.runFork(Fiber.interrupt(psnPairFiber.current))
    psnPairFiber.current = null
    setPsnPairing(null)
  }

  const cancelWake = () => {
    if (wakeFiber.current) runtime.runFork(Fiber.interrupt(wakeFiber.current))
    wakeFiber.current = null
    setWaking(null)
  }
  useEffect(() => () => { if (wakeFiber.current) runtime.runFork(Fiber.interrupt(wakeFiber.current)) }, [runtime])

  /** Plays right away when the console is ready; wakes it and waits first when it's in rest mode. */
  const play = (row: ConsoleRow, console: PairedConsole) => {
    const duid = onPsn[row.hostId]
    if (connection === "internet" || (row.status === "internet" && connection === "auto")) {
      // PSN wakes the console as part of connecting.
      if (duid !== undefined) onPlay(console, duid)
      else toast.error(`${row.name} isn't reachable over the internet. Sign in to PSN for internet play, or connect on your home network.`)
      return
    }
    if (row.status === "internet" || row.status === "offline") {
      toast.error(`${row.name} isn't on this network. Choose Automatic or Internet to play it over the internet.`)
      return
    }
    // The internet as a fallback only in Automatic.
    const fallback = connection === "auto" ? duid : undefined
    if (row.status !== "standby") {
      onPlay(console, undefined, fallback)
      return
    }
    setWaking(row.hostId)
    wakeFiber.current = runtime.runFork(
      Effect.match(actions.wakeUntilReady(console, fallback), {
        onSuccess: (route) => {
          wakeFiber.current = null
          setWaking(null)
          if (route.via === "internet") onPlay(console, route.psnDuid)
          else onPlay(console, undefined, fallback)
        },
        onFailure: (error) => {
          wakeFiber.current = null
          setWaking(null)
          toast.error(error.message)
        },
      }),
    )
  }

  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    run(actions.loadPaired, {
      onSuccess: (saved) => {
        setPaired(saved)
        setLoaded(true)
      },
    })
  }, [run])
  const anyPaired = Object.keys(paired).length > 0
  useEffect(() => {
    if (loaded) onPairedChange?.(anyPaired)
  }, [loaded, anyPaired, onPairedChange])

  useFork(
    useMemo(
      () =>
        actions.pollDiscovery((outcome) => {
          setScanned(true)
          if (outcome.ok) {
            setDiscovered(outcome.discovered)
            // Discovery hands a fresh object every scan; keeping the old one when nothing changed stops
            // the PSN poll below from restarting (and asking Sony) every few seconds.
            setPaired((current) => (samePaired(current, outcome.paired) ? current : outcome.paired))
            setScanMessage("")
          } else {
            setScanMessage(outcome.message)
          }
        }),
      [],
    ),
  )

  // Paired consoles PSN can reach and the account's PS5s (when signed in for internet play), refreshed every
  // minute, and at once after signing in or out.
  const [onPsn, setOnPsn] = useState<Readonly<Record<string, string>>>({})
  const [account, setAccount] = useState<readonly PsnConsole[]>([])
  useFork(
    useMemo(
      () =>
        actions.pollPsn(paired, (view) => {
          setOnPsn(view.reachable)
          setAccount(view.consoles)
        }),
      // eslint-disable-next-line react-hooks/exhaustive-deps -- a sign-in or sign-out asks PSN again at once
      [paired, accountId],
    ),
  )

  const rows = consoleRows(discovered, paired, onPsn, account)
  const signedIn = Option.isSome(accountId)
  useDevAutoplay(rows, onPlay)
  // Dev control port: play the first paired console, as its Play button would.
  useDevControl((command) => {
    if (command.type !== "play") return
    const row = rows.find((r) => r.paired !== undefined)
    if (row?.paired !== undefined) play(row, row.paired)
    else toast.error("Dev control: no paired console to play")
  })

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
              onPair={() => {
                setPairing(row.hostId)
                setPairProblem(null)
              }}
              psnPairing={psnPairing !== null}
              onPairThroughPsn={(console) => { pairThroughPsn(row, console) }}
              onWake={(console) => { run(actions.wake(console), {
                  onSuccess: () => toast.success("Wake-up sent; the console takes ~20 s to start."),
                }); }
              }
              waking={waking === row.hostId}
              onPlay={(console) => { play(row, console) }}
              onCancelWake={cancelWake}
              onForget={() => { run(actions.forget(row.hostId), { onSuccess: setPaired }); }}
            />
            {row.psn?.remotePlay === false && (
              <p className="text-xs text-muted-foreground">
                Remote Play is off on {row.name}. To pair it, turn it on, on the PS5: Settings › System › Remote Play ›
                Enable Remote Play.
              </p>
            )}
            {psnPairing !== null && psnPairing.duid === row.psn?.duid && (
              <PsnPairingStatus name={row.name} stage={psnPairing.stage} onCancel={cancelPsnPairing} />
            )}
            {problemOn(row) !== undefined && row.discovered === undefined && (
              <p role="alert" className="border-t pt-2 text-xs text-destructive">
                {problemOn(row)} To pair with a code instead, connect the PS5 to this Mac's network: it shows up
                here with Pair.
              </p>
            )}
            {(pairing === row.hostId || problemOn(row) !== undefined) && row.discovered !== undefined && (
              <PairForm
                console={row.discovered}
                problem={problemOn(row)}
                onPaired={(next) => {
                  setPaired(next)
                  setPairing(null)
                  setPairProblem(null)
                  toast.success(`Paired with ${row.name}`)
                }}
                onCancel={() => {
                  setPairing(null)
                  setPairProblem(null)
                }}
              />
            )}
          </li>
        ))}
      </ul>
      {/* Paired consoles stay listed when they aren't here: whether discovery found any decides the help. */}
      {discovered.length === 0 ? (
        <NoConsoles
          scanned={scanned}
          listed={rows.length > 0}
          address={consoleAddress}
          onAddressChange={onConsoleAddressChange}
          onOpenLocalNetwork={() => { run(actions.openLocalNetworkSettings) }}
        />
      ) : (
        <AddByIp address={consoleAddress} onAddressChange={onConsoleAddressChange} />
      )}
    </section>
  )
}

interface ConsoleItemProps {
  readonly row: ConsoleRow
  readonly signedIn: boolean
  readonly onPair: () => void
  /** A pairing through PSN is under way (on this row or another): one at a time. */
  readonly psnPairing: boolean
  readonly onPairThroughPsn: (console: PsnConsole) => void
  readonly onWake: (console: PairedConsole) => void
  /** Being woken up by Play. */
  readonly waking: boolean
  readonly onPlay: (console: PairedConsole) => void
  readonly onCancelWake: () => void
  readonly onForget: () => void
}

const ConsoleItem = ({ row, signedIn, onPair, psnPairing, onPairThroughPsn, onWake, waking, onPlay, onCancelWake, onForget }: ConsoleItemProps) => {
  const { paired } = row
  const psn = row.psn?.remotePlay === true ? row.psn : undefined
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
          <>
            {psn !== undefined && (
              <Button size="sm" disabled={psnPairing} onClick={() => { onPairThroughPsn(psn) }}>
                Pair (no code needed)
              </Button>
            )}
            {row.discovered !== undefined && (
              <Button
                size="sm"
                variant="outline"
                disabled={!signedIn || psnPairing}
                title={signedIn ? undefined : "Sign in first"}
                onClick={onPair}
              >
                {psn === undefined ? "Pair" : "Pair with a code"}
              </Button>
            )}
          </>
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

/** Where the console shows its pairing code. */
const pairingPath = (ps5: boolean): string =>
  ps5
    ? "On the PS5: Settings › System › Remote Play › Pair Device (Link Device on some versions)"
    : "On the PS4: Settings › Remote Play Connection Settings › Add Device"

/** Pairing through PSN under way: the step, how long it's been, and a way out. */
const PsnPairingStatus = ({ name, stage, onCancel }: { readonly name: string; readonly stage: PsnPairStage | undefined; readonly onCancel: () => void }) => {
  const seconds = useElapsedSeconds()
  return (
    <div className="flex items-center justify-between gap-3 border-t pt-2">
      <p role="status" className="flex items-start gap-2 text-xs text-muted-foreground">
        <span aria-hidden className="mt-1 size-1.5 shrink-0 animate-pulse rounded-full bg-ice motion-reduce:animate-none" />
        <span>
          <span className="text-foreground">{psnPairStep(stage, name)}</span>{" "}
          <span className="tabular-nums">{String(seconds)} s</span> so far. {psnPairHint(seconds)}
        </span>
      </p>
      <Button size="sm" variant="ghost" onClick={onCancel}>
        Cancel
      </Button>
    </div>
  )
}

interface PairFormProps {
  readonly console: DiscoveredConsole
  /** Why pairing through PSN didn't work, when the form opened after it. */
  readonly problem?: string | undefined
  readonly onPaired: (paired: PairedConsoles) => void
  readonly onCancel: () => void
}

const PairForm = ({ console, problem, onPaired, onCancel }: PairFormProps) => {
  const run = useRun()
  const id = useId()
  const [pin, setPin] = useState("")
  const [busy, setBusy] = useState(false)
  const hint = `${id}-hint`

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
      {problem !== undefined && (
        <Alert variant="destructive" className="bg-transparent">
          <AlertTitle>Couldn't pair through PSN</AlertTitle>
          <AlertDescription>{problem} Pair with the code from the PS5 instead.</AlertDescription>
        </Alert>
      )}
      <Label htmlFor={id} className="text-xs text-muted-foreground">
        {pairingPath(console.ps5)}
      </Label>
      <p id={hint} className="text-xs text-muted-foreground">
        Type the 8-digit pairing code it shows, not your console passcode. The code is valid for about 5 minutes: keep
        that screen open.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <PinInput id={id} value={pin} onChange={setPin} disabled={busy} describedBy={hint} />
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
