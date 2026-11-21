import { Effect, Option } from "effect"
import { Download, RefreshCw } from "lucide-react"
import { createContext, use, useCallback, useEffect, useMemo, useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import type { AppServices } from "@/core/runtime"
import type { UpdateCheck } from "@/core/updater"
import { useFork, useRun, useRuntime } from "./runtime"
import * as updates from "./selfUpdate"

// A newer release: a banner on Home (never over the stream) offers it; "Update" downloads, verifies and
// installs it, then restarts PlayFX. Nothing installs or restarts while a stream runs.

export type UpdatePhase =
  | { readonly kind: "idle" }
  | { readonly kind: "downloading"; readonly percent: number | undefined }
  | { readonly kind: "restarting" }
  | { readonly kind: "failed"; readonly message: string }

export interface Updates {
  /** The newer release a check found. */
  readonly available: string | undefined
  /** Whether the Home banner shows: a newer release not put off with "Later", or one being installed. */
  readonly showBanner: boolean
  readonly phase: UpdatePhase
  /** A stream is running or starting: updating waits. */
  readonly streaming: boolean
  /** A check by hand found this (it shows a release put off with "Later" again). */
  readonly checked: (check: UpdateCheck) => void
  readonly update: () => void
  readonly later: () => void
  /** The release's page on GitHub: what's new, and the DMG when updating here fails. */
  readonly openReleasePage: () => void
}

const idle: UpdatePhase = { kind: "idle" }

/** Runs an effect whose failure the caller shows itself (no toast). */
const useAttempt = () => {
  const runtime = useRuntime()
  return useCallback(
    <A, E extends { readonly message: string }>(
      effect: Effect.Effect<A, E, AppServices>,
      onSuccess: (value: A) => void,
      onFailure: (error: E) => void,
    ) => {
      runtime.runFork(Effect.match(Effect.tapError(effect, (error) => Effect.logWarning(error.message)), { onSuccess, onFailure }))
    },
    [runtime],
  )
}

const ignore = () => undefined

const useUpdatesState = (streaming: boolean): Updates => {
  const run = useRun()
  const attempt = useAttempt()
  const [available, setAvailable] = useState<string | undefined>(undefined)
  const [dismissed, setDismissed] = useState<string | undefined>(undefined)
  const [phase, setPhase] = useState<UpdatePhase>(idle)
  useEffect(() => {
    attempt(updates.loadDismissedUpdate, (version) => { setDismissed(Option.getOrUndefined(version)) }, ignore)
  }, [attempt])
  useFork(
    useMemo(
      () => updates.checkPeriodically((check) => { if (check.status === "available") setAvailable(check.version) }),
      [],
    ),
  )
  const checked = useCallback((check: UpdateCheck) => {
    if (check.status !== "available") return
    setAvailable(check.version)
    setDismissed((version) => (version === check.version ? undefined : version))
  }, [])
  const busy = phase.kind === "downloading" || phase.kind === "restarting"
  const update = useCallback(() => {
    if (streaming || busy || available === undefined) return
    setPhase({ kind: "downloading", percent: undefined })
    attempt(
      updates.installUpdate(
        (percent) => { setPhase({ kind: "downloading", percent }) },
        () => { setPhase({ kind: "restarting" }) },
      ),
      ignore,
      (error) => { setPhase({ kind: "failed", message: error.message }) },
    )
  }, [attempt, streaming, busy, available])
  const later = useCallback(() => {
    if (available === undefined || busy) return
    setDismissed(available)
    setPhase(idle)
    attempt(updates.dismissUpdate(available), ignore, ignore)
  }, [attempt, available, busy])
  const openReleasePage = useCallback(() => {
    if (available !== undefined) run(updates.openReleasePage(available))
  }, [run, available])
  return {
    available,
    showBanner: available !== undefined && (available !== dismissed || phase.kind !== "idle"),
    phase,
    streaming,
    checked,
    update,
    later,
    openReleasePage,
  }
}

const UpdatesContext = createContext<Updates | null>(null)

/** One update state for the app: the background check, the Home banner and the Diagnostics check share it. */
export const UpdatesProvider = ({ streaming, children }: { readonly streaming: boolean; readonly children: ReactNode }) => (
  <UpdatesContext value={useUpdatesState(streaming)}>{children}</UpdatesContext>
)

export const useUpdates = (): Updates => {
  const value = use(UpdatesContext)
  if (value === null) throw new Error("Updates need an <UpdatesProvider> above them")
  return value
}

const headline = (version: string, phase: UpdatePhase): string => {
  switch (phase.kind) {
    case "idle":
      return `PlayFX ${version} is available.`
    case "downloading":
      return phase.percent === undefined ? "Downloading…" : `Downloading… ${String(phase.percent)}%`
    case "restarting":
      return "Restarting…"
    case "failed":
      return `Couldn't update to PlayFX ${version}.`
  }
}

/** The Home screen's banner for a newer release. */
export const UpdateBanner = () => {
  const { available, showBanner, phase, streaming, update, later, openReleasePage } = useUpdates()
  if (!showBanner || available === undefined) return null
  return (
    <section
      aria-label="PlayFX update"
      className="flex w-full max-w-xl items-center gap-3 rounded-xl border border-signal/40 bg-card/70 px-4 py-3 shadow-2xl backdrop-blur-xl"
    >
      <Download className="size-4 shrink-0 text-signal" aria-hidden />
      <div className="flex min-w-0 flex-1 flex-col gap-0.5" role="status">
        <p className="text-sm font-medium text-foreground tabular-nums">{headline(available, phase)}</p>
        {phase.kind === "failed" && <p className="text-xs text-muted-foreground">{phase.message}</p>}
        {phase.kind === "idle" && streaming && <p className="text-xs text-muted-foreground">Finish playing to update</p>}
      </div>
      {phase.kind === "idle" && (
        <>
          <Button variant="link" size="sm" className="px-1 text-muted-foreground" onClick={openReleasePage}>
            What's new
          </Button>
          <Button variant="ghost" size="sm" onClick={later}>Later</Button>
          <Button size="sm" onClick={update} disabled={streaming} className="bg-signal text-black hover:bg-signal/90">
            Update
          </Button>
        </>
      )}
      {phase.kind === "failed" && (
        <>
          <Button variant="ghost" size="sm" onClick={later}>Later</Button>
          <Button variant="secondary" size="sm" onClick={openReleasePage}>Download from GitHub</Button>
        </>
      )}
    </section>
  )
}

/** Settings › Diagnostics: "Check for updates" next to `children` (the version), and what it found below. */
export const UpdateCheckRow = ({ children }: { readonly children: ReactNode }) => {
  const attempt = useAttempt()
  const { checked } = useUpdates()
  const [checking, setChecking] = useState(false)
  const [line, setLine] = useState<string | undefined>(undefined)
  const check = () => {
    setChecking(true)
    setLine("Checking for updates…")
    attempt(
      updates.checkForUpdates,
      (found) => {
        setChecking(false)
        setLine(updates.checkLine(found))
        checked(found)
      },
      (error) => {
        setChecking(false)
        setLine(`Couldn't check for updates: ${error.message}`)
      },
    )
  }
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center justify-between gap-3">
        {children}
        <Button variant="ghost" size="sm" className="shrink-0" disabled={checking} onClick={check}>
          <RefreshCw /> Check for updates
        </Button>
      </div>
      {line !== undefined && (
        <p role="status" aria-label="Update check" className="text-xs text-muted-foreground">{line}</p>
      )}
    </div>
  )
}
