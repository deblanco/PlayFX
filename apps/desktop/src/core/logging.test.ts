import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Logger, type LogLevel } from "effect"
import { vi } from "vitest"
import { detailedLogs, formatEntry, LoggingLive, makeLogger, setDetailedLogs } from "./logging"

const plugin = vi.hoisted(() => ({
  info: vi.fn(() => Promise.resolve()),
  warn: vi.fn(() => Promise.reject(new Error("no IPC"))), // a failing write must not break anything
  error: vi.fn(() => Promise.resolve()),
  debug: vi.fn(() => Promise.resolve()),
  trace: vi.fn(() => Promise.resolve()),
}))
vi.mock("@tauri-apps/plugin-log", () => plugin)

describe("logging", () => {
  it("formats message parts and a failure's cause", () => {
    expect(formatEntry(["Play", "Living Room", 1080], Cause.empty)).toBe("Play Living Room 1080")
    expect(formatEntry("single", Cause.empty)).toBe("single")
    const line = formatEntry(["Restart failed"], Cause.fail(new Error("console busy")))
    expect(line.startsWith("Restart failed\n")).toBe(true)
    expect(line).toContain("console busy")
  })

  it.effect("writes each entry at its level", () => {
    const lines: (readonly [LogLevel.LogLevel, string])[] = []
    return Effect.gen(function* () {
      yield* Effect.logInfo("hello", "world")
      yield* Effect.logWarning("careful")
      yield* Effect.logError("broken")
      expect(lines).toEqual([
        ["Info", "hello world"],
        ["Warn", "careful"],
        ["Error", "broken"],
      ])
    }).pipe(Effect.provide(Logger.layer([makeLogger((level, line) => lines.push([level, line]))])))
  })

  it.effect("keeps debug lines only while detailed logs are on", () =>
    Effect.gen(function* () {
      plugin.debug.mockClear()
      yield* Effect.logDebug("quiet")
      yield* Effect.yieldNow
      expect(plugin.debug).not.toHaveBeenCalled()
      yield* setDetailedLogs(true)
      expect(yield* detailedLogs).toBe(true)
      yield* Effect.logDebug("now kept")
      yield* Effect.yieldNow
      expect(plugin.debug).toHaveBeenCalledWith("now kept")
      yield* setDetailedLogs(false)
    }).pipe(Effect.provide(LoggingLive)),
  )

  it.effect("sends entries to the app's log file by level", () =>
    Effect.gen(function* () {
      yield* Effect.logInfo("to the file")
      yield* Effect.logWarning("also to the file")
      yield* Effect.yieldNow
      expect(plugin.info).toHaveBeenCalledWith("to the file")
      expect(plugin.warn).toHaveBeenCalledWith("also to the file")
    }).pipe(Effect.provide(LoggingLive)),
  )
})
