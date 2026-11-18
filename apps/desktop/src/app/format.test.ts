import { describe, expect, it } from "vitest"
import { Option } from "effect"
import { defaultSettings } from "@/core/schema"
import {
  consoleRows,
  bitrateLabel,
  framesPerSecond,
  afterQuit,
  maxAutoReconnects,
  megabitsPerSecond,
  mlApplies,
  pipelineStages,
  psnDeviceIds,
  renderParams,
  hudStats,
  quitMessage,
  streamOptions,
  streamSummary,
  strengthLabel,
  upscalerLabel,
  type Stage,
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
    const settings = {
      ...defaultSettings,
      upscaler: "bilinear",
      sharpness: 0,
      deblock: 0.6,
      deband: 0.3,
      mlUpscale: true,
      compare: true,
      colorMatrix: "bt2020",
      colorRange: "full",
      chroma: "bilinear",
      accurateColor: false,
    } as const
    expect(renderParams({ ...settings, fps: 30, bitrate: 50000 })).toEqual({
      upscaler: "bilinear",
      sharpness: 0,
      deblock: 0.6,
      deband: 0.3,
      mlUpscale: true,
      compare: true,
      colorMatrix: "bt2020",
      colorRange: "full",
      chroma: "bilinear",
      accurateColor: false,
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
    expect(hudStats({ ...status({ width: 1280, height: 720 }), gpuMs: 1.436 }, 60, 9)).toBe(
      "1280×720 · 60 fps · 9.0 Mbps · MetalFX · GPU 1.4 ms",
    )
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

describe("psnDeviceIds", () => {
  it("matches paired consoles to PSN's by name, if Remote Play is on", () => {
    const bedroom = { ...pairedPs5, hostId: "HOST2", name: "Bedroom", credentials: { ...pairedPs5.credentials, nickname: "PS5-777" } }
    const onPsn = [
      { name: "Living Room", duid: "aa", remotePlay: true },
      { name: "PS5-777", duid: "bb", remotePlay: true }, // matched by the console's own nickname
      { name: "Office", duid: "cc", remotePlay: true },
    ]
    expect(psnDeviceIds({ HOST1: pairedPs5, HOST2: bedroom }, onPsn)).toEqual({ HOST1: "aa", HOST2: "bb" })
    expect(psnDeviceIds({ HOST1: pairedPs5 }, [{ name: "Living Room", duid: "aa", remotePlay: false }])).toEqual({})
  })
})

describe("afterQuit", () => {
  const live = { connected: true, reconnecting: false, autoReconnects: 0 } as const
  const dropped = { type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" } as const
  it("reconnects a connected stream that lost its connection, a few times", () => {
    expect(afterQuit(live, dropped)).toBe("reconnect")
    expect(afterQuit({ ...live, autoReconnects: maxAutoReconnects - 1 }, dropped)).toBe("reconnect")
    expect(afterQuit({ ...live, autoReconnects: maxAutoReconnects }, dropped)).toBe("end")
  })
  it("ends on final quits and on drops before the stream ever connected", () => {
    expect(afterQuit(live, { ...dropped, kind: "final" })).toBe("end")
    expect(afterQuit(live, { type: "quit", reason: "Stopped", error: false })).toBe("end")
    expect(afterQuit({ ...live, connected: false }, dropped)).toBe("end")
  })
  it("waits out a busy console when the stream first starts", () => {
    expect(afterQuit({ ...live, connected: false }, { ...dropped, kind: "busy" })).toBe("retry-start")
    expect(afterQuit(live, { ...dropped, kind: "busy" })).toBe("end") // busy mid-stream isn't expected: give up
  })
  it("leaves quits to a reconnect in progress", () => {
    expect(afterQuit({ ...live, reconnecting: "apply" }, dropped)).toBe("ignore")
    expect(afterQuit({ ...live, reconnecting: "dropped" }, { ...dropped, kind: "busy" })).toBe("ignore")
  })
})

describe("quitMessage", () => {
  it("only reports errors", () => {
    expect(quitMessage({ type: "quit", reason: "Timeout", error: true })).toEqual(Option.some("Disconnected: Timeout"))
    expect(quitMessage({ type: "quit", reason: "Stopped", error: false })).toEqual(Option.none())
  })
})

describe("ML super-resolution", () => {
  const ml = { ...defaultSettings, mlUpscale: true, height: 720 } as const
  it("applies to 720p and lower streams when the Mac supports it", () => {
    expect(mlApplies(ml, { metalfx: true, ml: true })).toBe(true)
    expect(mlApplies({ ...ml, height: 540 }, { metalfx: true, ml: true })).toBe(true)
    expect(mlApplies({ ...ml, height: 1080 }, { metalfx: true, ml: true })).toBe(false)
    expect(mlApplies(ml, { metalfx: true, ml: false })).toBe(false)
    expect(mlApplies({ ...ml, mlUpscale: false }, { metalfx: true, ml: true })).toBe(false)
  })
  it("shows in the pipeline and the HUD", () => {
    const [, upscale] = pipelineStages({ ...ml, upscaler: "bilinear" }, { metalfx: true, ml: true })
    expect(upscale).toMatchObject({ value: "ML + Bilinear", active: true })
    expect(hudStats({ ...status({ width: 1280, height: 720 }), mlActive: true }, 60, 8)).toBe(
      "1280×720 · 60 fps · 8.0 Mbps · ML + MetalFX",
    )
  })
})

describe("settings labels", () => {
  it("names bitrates and strengths", () => {
    expect(bitrateLabel(0)).toBe("Auto")
    expect(bitrateLabel(40000)).toBe("40 Mbps")
    expect(strengthLabel(0)).toBe("Off")
    expect(strengthLabel(0.35)).toBe("35%")
    expect(strengthLabel(1)).toBe("100%")
  })
  it("summarizes the stream settings", () => {
    expect(streamSummary(defaultSettings)).toBe("1080p · 60 fps · HEVC · auto bitrate")
    expect(streamSummary({ ...defaultSettings, height: 720, fps: 30, hevc: false, bitrate: 20000 })).toBe(
      "720p · 30 fps · H.264 · 20 Mbps",
    )
  })
})

describe("pipelineStages", () => {
  const view = (stages: readonly Stage[]) => stages.map((s) => [s.id, s.value, s.active])
  it("lists the picture steps in render order with their values", () => {
    expect(view(pipelineStages(defaultSettings, { metalfx: true, ml: true }))).toEqual([
      ["cleanup", "Off", false],
      ["upscale", "MetalFX", true],
      ["sharpen", "30%", true],
      ["color", "Accurate", true],
    ])
  })
  it("reflects changes and an unsupported MetalFX", () => {
    const settings = { ...defaultSettings, deblock: 0.2, deband: 0.6, sharpness: 0, accurateColor: false }
    expect(view(pipelineStages(settings, { metalfx: false, ml: false }))).toEqual([
      ["cleanup", "60%", true],
      ["upscale", "Bilinear", false],
      ["sharpen", "Off", false],
      ["color", "Vivid", false],
    ])
  })
})
