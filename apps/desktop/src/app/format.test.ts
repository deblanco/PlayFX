import { describe, expect, it } from "vitest"
import { Option } from "effect"
import { defaultSettings } from "@/core/schema"
import {
  consoleRows,
  framesPerSecond,
  megabitsPerSecond,
  renderParams,
  hudStats,
  quitMessage,
  settingValue,
  streamOptions,
  upscalerLabel,
  withSetting,
} from "./format"
import { pairedPs5, ps5, status } from "./testing"

describe("consoleRows", () => {
  it("merges discovered and paired consoles", () => {
    const offline = { ...pairedPs5, hostId: "HOST2", name: "Bedroom", credentials: { ...pairedPs5.credentials, ps5: false, address: "10.0.0.2" } }
    const rows = consoleRows([ps5], { HOST1: pairedPs5, HOST2: offline })
    expect(rows.map((r) => [r.hostId, r.name, r.status, r.meta])).toEqual([
      ["HOST1", "Living Room", "ready", "PS5 · 192.168.0.40 · Astro Bot · paired"],
      ["HOST2", "Bedroom", "offline", "PS4 · 10.0.0.2 · paired"],
    ])
    expect(rows[0]?.discovered).toBe(ps5)
    expect(rows[1]?.discovered).toBeUndefined()
  })

  it("maps unknown state to offline and omits missing parts", () => {
    const { runningApp: _app, ...bare } = ps5
    const [row] = consoleRows([{ ...bare, state: "unknown", ps5: false }], {})
    expect(row).toMatchObject({ status: "offline", meta: "PS4 · 192.168.0.40", paired: undefined })
    expect(consoleRows([{ ...ps5, state: "standby" }], {})[0]?.status).toBe("standby")
  })
})

describe("streamOptions", () => {
  it("derives native stream options from settings", () => {
    const settings = { ...defaultSettings, height: 720, fps: 30, hevc: false, bitrate: 40000, audio: false } as const
    expect(streamOptions({ ...settings, autoDowngrade: false })).toEqual({
      height: 720,
      fps: 30,
      hevc: false,
      bitrate: 40000,
      audio: false,
      autoDowngrade: false,
    })
  })
})

describe("framesPerSecond", () => {
  it("computes the rate between samples", () => {
    expect(framesPerSecond({ frames: 0, bytes: 0, time: 0 }, { frames: 60, bytes: 0, time: 1000 })).toBe(60)
    expect(framesPerSecond({ frames: 100, bytes: 0, time: 0 }, { frames: 115, bytes: 0, time: 500 })).toBe(30)
  })
  it("never divides by zero or goes negative", () => {
    expect(framesPerSecond({ frames: 0, bytes: 0, time: 10 }, { frames: 60, bytes: 0, time: 10 })).toBe(0)
    expect(framesPerSecond({ frames: 90, bytes: 0, time: 0 }, { frames: 0, bytes: 0, time: 1000 })).toBe(0)
  })
})

describe("renderParams", () => {
  it("picks the picture settings", () => {
    expect(renderParams({ ...defaultSettings, upscaler: "bilinear", sharpness: 0, compare: true })).toEqual({
      upscaler: "bilinear",
      sharpness: 0,
      compare: true,
    })
  })
})

describe("megabitsPerSecond", () => {
  it("computes the received bitrate between samples", () => {
    expect(megabitsPerSecond({ frames: 0, bytes: 0, time: 0 }, { frames: 0, bytes: 1_875_000, time: 1000 })).toBe(15)
    expect(megabitsPerSecond({ frames: 0, bytes: 0, time: 0 }, { frames: 0, bytes: 155_000, time: 100 })).toBe(12.4)
  })
  it("never divides by zero or goes negative", () => {
    expect(megabitsPerSecond({ frames: 0, bytes: 0, time: 5 }, { frames: 0, bytes: 9, time: 5 })).toBe(0)
    expect(megabitsPerSecond({ frames: 0, bytes: 9, time: 0 }, { frames: 0, bytes: 0, time: 1000 })).toBe(0)
  })
})

describe("hudStats", () => {
  it("shows size, fps and upscaler", () => {
    expect(hudStats(status({ width: 1920, height: 1080 }), 60, 14.25)).toBe("1920×1080 · 60 fps · 14.3 Mbps · MetalFX")
  })
  it("waits for video and reports decode errors", () => {
    expect(hudStats({ ...status({ decodeErrors: 3 }), activeMode: "bilinear" }, 0, 0)).toBe(
      "waiting for video · 0 fps · 0.0 Mbps · Bilinear · 3 decode errors",
    )
  })
  it("says connecting while the stream isn't active", () => {
    expect(hudStats(status({ active: false }), 0, 0)).toBe("Connecting…")
  })
})

describe("upscalerLabel", () => {
  it("names each mode", () => {
    expect(upscalerLabel("none")).toBe("No upscaling")
    expect(upscalerLabel("metalfx")).toBe("MetalFX")
  })
})

describe("quitMessage", () => {
  it("only reports errors", () => {
    expect(quitMessage({ type: "quit", reason: "Timeout", error: true })).toEqual(Option.some("Disconnected: Timeout"))
    expect(quitMessage({ type: "quit", reason: "Stopped", error: false })).toEqual(Option.none())
  })
})

describe("withSetting / settingValue", () => {
  it("parses select values", () => {
    expect(withSetting(defaultSettings, "height", "720").height).toBe(720)
    expect(withSetting(defaultSettings, "fps", "30").fps).toBe(30)
    expect(withSetting(defaultSettings, "hevc", "h264").hevc).toBe(false)
    expect(withSetting(defaultSettings, "upscaler", "bilinear").upscaler).toBe("bilinear")
    expect(withSetting(defaultSettings, "bitrate", "30000").bitrate).toBe(30000)
    expect(withSetting(defaultSettings, "autoDowngrade", "off").autoDowngrade).toBe(false)
    expect(withSetting(defaultSettings, "audio", "off").audio).toBe(false)
    expect(withSetting(defaultSettings, "sharpness", "0.6").sharpness).toBe(0.6)
    expect(withSetting(defaultSettings, "compare", "on").compare).toBe(true)
  })
  it("ignores invalid values", () => {
    expect(withSetting(defaultSettings, "height", "999")).toBe(defaultSettings)
    expect(withSetting(defaultSettings, "bitrate", "12345")).toBe(defaultSettings)
    expect(withSetting(defaultSettings, "sharpness", "1.5")).toBe(defaultSettings)
  })
  it("renders select values", () => {
    expect(settingValue(defaultSettings, "height")).toBe("1080")
    expect(settingValue(defaultSettings, "hevc")).toBe("hevc")
    expect(settingValue({ ...defaultSettings, hevc: false }, "hevc")).toBe("h264")
    expect(settingValue(defaultSettings, "audio")).toBe("on")
    expect(settingValue({ ...defaultSettings, autoDowngrade: false }, "autoDowngrade")).toBe("off")
  })
})
