import { useEffect, useRef } from "react"
import type { PairedConsole } from "@/core/schema"
import type { ConsoleRow } from "./format"

/// Dev-only E2E: once a ready, paired console appears, start streaming it automatically, so the
/// full Play path can be exercised without clicking. Inert unless `import.meta.env.DEV` and
/// `VITE_PSRP_AUTOPLAY` are set.
export const useDevAutoplay = (rows: readonly ConsoleRow[], onPlay: (console: PairedConsole) => void): void => {
  const fired = useRef(false)
  useEffect(() => {
    if (fired.current || !import.meta.env.DEV || import.meta.env["VITE_PSRP_AUTOPLAY"] !== "1") return
    const ready = rows.find((r) => r.status === "ready" && r.paired !== undefined)
    if (ready?.paired !== undefined) {
      fired.current = true
      onPlay(ready.paired)
    }
  }, [rows, onPlay])
}

/// Dev-only E2E helper: preloads the app's local storage so it starts already paired with a
/// real console, for testing the streaming path end to end without the pairing UI. Completely
/// inert unless BOTH `import.meta.env.DEV` and `VITE_PSRP_SEED` are set, so it never affects a
/// production build. The seed file is gitignored and holds private registration keys.
export const seedDevStorage = async (): Promise<void> => {
  if (!import.meta.env.DEV || import.meta.env["VITE_PSRP_SEED"] !== "1") return
  const seed = (await import("./dev-seed.local.json")).default as {
    readonly accountId: string
    readonly consoles: Record<string, unknown>
    readonly settings?: unknown
  }
  const put = (key: string, value: string): void => {
    if (localStorage.getItem(key) === null) localStorage.setItem(key, value)
  }
  put("psrp.accountId", seed.accountId)
  put("psrp.consoles", JSON.stringify(seed.consoles))
  if (seed.settings !== undefined) put("psrp.settings", JSON.stringify(seed.settings))
}
