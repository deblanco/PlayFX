import { debug, error, info, trace, warn } from "@tauri-apps/plugin-log"
import { Cause, Effect, Layer, Logger, References, type LogLevel } from "effect"

// The web UI's Effect logs go to the app's log file (with the native and Rust entries), through
// tauri-plugin-log. Nothing secret is logged from here: tokens never reach the web UI.

/** Writes one formatted line at a level. */
export type LogWriter = (level: LogLevel.LogLevel, line: string) => void

/** The message parts, then the failure when the entry carries one. */
export const formatEntry = (message: unknown, cause: Cause.Cause<unknown>): string => {
  const text = (Array.isArray(message) ? message : [message]).map(String).join(" ")
  return cause.reasons.length === 0 ? text : `${text}\n${Cause.pretty(cause)}`
}

export const makeLogger = (write: LogWriter): Logger.Logger<unknown, void> =>
  Logger.make(({ logLevel, message, cause }) => { write(logLevel, formatEntry(message, cause)) })

const byLevel: Partial<Record<LogLevel.LogLevel, (line: string) => Promise<void>>> = {
  Fatal: error,
  Error: error,
  Warn: warn,
  Info: info,
  Debug: debug,
  Trace: trace,
}

/** Debug lines are kept only while detailed logs are on (Settings → Diagnostics). */
let detailed = false
export const setDetailedLogs = (on: boolean): Effect.Effect<void> => Effect.sync(() => { detailed = on })
export const detailedLogs: Effect.Effect<boolean> = Effect.sync(() => detailed)

/** Fire and forget: a log line must never fail or block the app. */
const toLogFile: LogWriter = (level, line) => {
  const send = byLevel[level]
  const kept = detailed || (level !== "Debug" && level !== "Trace")
  if (send && kept) Effect.runFork(Effect.ignore(Effect.tryPromise(() => send(line))))
}

/** Replaces Effect's console logger with the app's log file; lets debug entries reach it (the file
 * writer then keeps them only while detailed logs are on). */
export const LoggingLive: Layer.Layer<never> = Layer.mergeAll(
  Logger.layer([makeLogger(toLogFile)]),
  Layer.succeed(References.MinimumLogLevel, "Debug"),
)
