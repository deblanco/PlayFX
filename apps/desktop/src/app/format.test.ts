import { describe, expect, it } from "vitest"
import { Option } from "effect"
import { defaultSettings, type PacingStats } from "@/core/schema"
import {
  isIpv4,
  consoleRows,
  describeEvent,
  bitrateLabel,
  framesPerSecond,
  afterQuit,
  afterStall,
  maxAutoReconnects,
  megabitsPerSecond,
  mlApplies,
  pipelineStages,
  psnDeviceIds,
  renderParams,
  hudStats,
  quitMessage,
  samePaired,
  microphoneProblem,
  onlyBitrateChanged,
  statRows,
  upscaleIdle,
  type StatRow,
  connectionHint,
  connectionSteps,
  connectionTitle,
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
      hdr: false,
    })
    // HDR needs HEVC: asking for it with H.264 doesn't send it.
    expect(streamOptions({ ...settings, hdr: true }).hdr).toBe(false)
    expect(streamOptions({ ...defaultSettings, hdr: true }).hdr).toBe(true)
    expect(streamSummary({ ...defaultSettings, hdr: true })).toContain("HEVC HDR")
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
      frameInterpolation: true,
      view: "split",
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
      frameInterpolation: true,
      compare: true,
      colorMatrix: "bt2020",
      colorRange: "full",
      chroma: "bilinear",
      accurateColor: false,
    })
  })

  it("turns every processing step off in the Original view, keeping the colors", () => {
    const tuned = { ...defaultSettings, sharpness: 0.8, deblock: 0.5, deband: 0.5, mlUpscale: true, frameInterpolation: true }
    expect(renderParams({ ...tuned, view: "original" })).toMatchObject({
      upscaler: "bilinear", sharpness: 0, deblock: 0, deband: 0, mlUpscale: false, frameInterpolation: false, compare: false,
      accurateColor: true,
    })
    expect(renderParams({ ...tuned, view: "enhanced" })).toMatchObject({ sharpness: 0.8, compare: false })
    expect(pipelineStages({ ...tuned, view: "original" }, { metalfx: true, ml: true, interpolation: true }).some((s) => s.active && s.id !== "color")).toBe(false)
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

describe("consoleRows over the internet", () => {
  it("shows a paired console PSN can reach, when it isn't on this network", () => {
    const [away] = consoleRows([], { HOST1: pairedPs5 }, { HOST1: "aa" })
    expect(away).toMatchObject({ status: "internet", psnDuid: "aa", meta: "PS5 · over the internet · paired" })
    // On this network: play locally.
    const [home] = consoleRows([ps5], { HOST1: pairedPs5 }, { HOST1: "aa" })
    expect(home).toMatchObject({ status: "ready", psnDuid: undefined })
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

describe("afterStall", () => {
  it("reconnects a stopped picture until the automatic reconnects are used up", () => {
    expect(afterStall({ autoReconnects: 0 })).toBe("reconnect")
    expect(afterStall({ autoReconnects: maxAutoReconnects - 1 })).toBe("reconnect")
    expect(afterStall({ autoReconnects: maxAutoReconnects })).toBe("end")
  })
})

describe("afterQuit", () => {
  const live = { connected: true, reconnecting: false, autoReconnects: 0 } as const
  const dropped = { type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" } as const
  it("tries PSN when the local network can't reach the console", () => {
    const starting = { connected: false, reconnecting: false, autoReconnects: 0 } as const
    const unreachable = { type: "quit", reason: "Unknown Session Request Error", error: true, kind: "final" } as const
    expect(afterQuit({ ...starting, psnFallback: "aa" }, unreachable)).toBe("via-internet")
    expect(afterQuit(starting, unreachable)).toBe("via-internet") // PSN is asked then
    expect(afterQuit({ ...starting, psnFallback: "aa", psnDuid: "aa" }, unreachable)).toBe("end") // already via PSN
    expect(afterQuit({ ...live, psnFallback: "aa" }, unreachable)).toBe("end") // it had connected
    expect(afterQuit({ ...starting, psnFallback: "aa" }, { ...unreachable, reason: "Connection Refused in Session Request" })).toBe("end")
  })

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

describe("describeEvent", () => {
  it("turns stream events into log lines, warning on error quits", () => {
    expect(describeEvent({ type: "connected" })).toEqual({ line: "Stream connected", warn: false })
    expect(describeEvent({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })).toEqual({
      line: "Stream ended: Stream Connection Unknown (dropped)",
      warn: true,
    })
    expect(describeEvent({ type: "quit", reason: "Stopped", error: false })).toEqual({ line: "Stream ended: Stopped (final)", warn: false })
    expect(describeEvent({ type: "remoteProgress", stage: "data" }).line).toBe("Over the internet: data")
    expect(describeEvent({ type: "loginPin", incorrect: true }).line).toContain("wrong PIN")
    expect(describeEvent({ type: "loginPin", incorrect: false }).line).toBe("Console asks for its login PIN")
    expect(describeEvent({ type: "nickname", name: "PS5-454" }).line).toBe("Console name: PS5-454")
    expect(describeEvent({ type: "network", online: true })).toEqual({ line: "The Mac's network changed", warn: false })
    expect(describeEvent({ type: "network", online: false })).toEqual({ line: "The Mac went offline", warn: true })
    expect(describeEvent({ type: "microphone", state: "denied" })).toEqual({ line: "Microphone denied", warn: true })
    expect(describeEvent({ type: "keyboard", change: "open", text: "" }).line).toBe("Console keyboard: open")
  })
})

describe("quitMessage", () => {
  it("only reports errors", () => {
    expect(quitMessage({ type: "quit", reason: "Timeout", error: true })).toEqual(Option.some("Disconnected: Timeout"))
    expect(quitMessage({ type: "quit", reason: "Stopped", error: false })).toEqual(Option.none())
  })

  it("says what went wrong and what to do for known reasons", () => {
    expect(quitMessage({ type: "quit", reason: "Unknown Session Request Error", error: true })).toEqual(
      Option.some(
        "Couldn't reach the console on this network. Check that the Mac and the console are on the same network, or play over the internet.",
      ),
    )
  })
})

describe("ML super-resolution", () => {
  const ml = { ...defaultSettings, mlUpscale: true, height: 720 } as const
  it("applies to 720p and lower streams when the Mac supports it", () => {
    expect(mlApplies(ml, { metalfx: true, ml: true, interpolation: false })).toBe(true)
    expect(mlApplies({ ...ml, height: 540 }, { metalfx: true, ml: true, interpolation: false })).toBe(true)
    expect(mlApplies({ ...ml, height: 1080 }, { metalfx: true, ml: true, interpolation: false })).toBe(false)
    expect(mlApplies(ml, { metalfx: true, ml: false, interpolation: false })).toBe(false)
    expect(mlApplies({ ...ml, mlUpscale: false }, { metalfx: true, ml: true, interpolation: false })).toBe(false)
  })
  it("shows in the pipeline and the HUD", () => {
    const [, upscale] = pipelineStages({ ...ml, upscaler: "bilinear" }, { metalfx: true, ml: true, interpolation: false })
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
    expect(view(pipelineStages(defaultSettings, { metalfx: true, ml: true, interpolation: false }))).toEqual([
      ["cleanup", "Off", false],
      ["upscale", "MetalFX", true],
      ["sharpen", "30%", true],
      ["color", "Accurate", true],
    ])
  })
  it("reflects changes and an unsupported MetalFX", () => {
    const settings = { ...defaultSettings, deblock: 0.2, deband: 0.6, sharpness: 0, accurateColor: false }
    expect(view(pipelineStages(settings, { metalfx: false, ml: false, interpolation: false }))).toEqual([
      ["cleanup", "60%", true],
      ["upscale", "Bilinear", false],
      ["sharpen", "Off", false],
      ["color", "Vivid", false],
    ])
  })
  it("unlights the upscale step and says why when the renderer reports it idle", () => {
    const caps = { metalfx: true, ml: true, interpolation: false }
    const [, upscale] = pipelineStages(defaultSettings, caps, "not needed")
    expect(upscale).toMatchObject({ value: "MetalFX", active: false, note: "not needed" })
    // Bilinear chosen: nothing is idle, so no note.
    const [, bilinear] = pipelineStages({ ...defaultSettings, upscaler: "bilinear" }, caps, "not needed")
    expect(bilinear).toEqual({ id: "upscale", name: "Upscale", value: "Bilinear", active: false })
  })
})

describe("upscaleIdle", () => {
  const pacing: PacingStats = {
    generatedFps: 0, skippedFrames: 0, skippedInterpolations: 0, delayMs: 0,
    interpolation: "off", upscale: "metalfx", ml: "off", displayHz: 0, streamFps: 0, gameFps: 0, repeatedFrames: 0,
  }
  it("says why the chosen upscaler isn't enlarging the picture", () => {
    expect(upscaleIdle(null)).toBeUndefined()
    expect(upscaleIdle(pacing)).toBeUndefined()
    expect(upscaleIdle({ ...pacing, upscale: "notLarger" })).toBe("not needed")
    expect(upscaleIdle({ ...pacing, upscale: "bilinear", ml: "streamTooLarge" })).toBe("not needed")
    expect(upscaleIdle({ ...pacing, upscale: "notLarger", ml: "on" })).toBeUndefined()
    expect(upscaleIdle({ ...pacing, upscale: "unsupported" })).toBe("unavailable")
    expect(upscaleIdle({ ...pacing, upscale: "failed" })).toBe("failed")
    expect(upscaleIdle({ ...pacing, upscale: "bilinear" })).toBeUndefined()
    expect(upscaleIdle({ ...pacing, upscale: "bilinear", ml: "hdr" })).toBe("not for HDR")
  })
})

describe("connecting screen", () => {
  const states = (steps: ReturnType<typeof connectionSteps>) => steps.map((step) => step.state)

  it("follows the console's setup stages over the internet", () => {
    expect(connectionSteps("internet", "linking", "PS5").map((step) => step.label)).toEqual([
      "Finding your PS5 through PSN",
      "Opening a direct connection to it",
      "Starting the stream",
    ])
    expect(states(connectionSteps("internet", "linking", "PS5"))).toEqual(["active", "waiting", "waiting"])
    expect(states(connectionSteps("internet", "data", "PS5"))).toEqual(["done", "active", "waiting"])
    expect(states(connectionSteps("internet", undefined, "PS5"))).toEqual(["done", "done", "active"])
  })

  it("waits for the console on the local network", () => {
    expect(connectionSteps("local", undefined, "Living Room")).toEqual([
      { label: "Contacting Living Room on your network", state: "active" },
      { label: "Starting the stream", state: "waiting" },
    ])
  })

  it("names what's happening", () => {
    expect(connectionTitle(false, "PS5")).toBe("Connecting to PS5")
    expect(connectionTitle("dropped", "PS5")).toBe("Connection lost. Reconnecting to PS5")
    expect(connectionTitle("stalled", "PS5")).toBe("The picture stopped. Reconnecting to PS5")
    expect(connectionTitle("apply", "PS5")).toBe("Reconnecting to PS5 with the new settings")
    expect(connectionTitle("starting", "PS5")).toBe("PS5 is finishing its last session")
    expect(connectionTitle("network", "PS5")).toBe("Your network changed. Reconnecting to PS5")
  })

  it("sets expectations, then says what to check when it's slow", () => {
    expect(connectionHint("internet", 10)).toBe("Over the internet this usually takes 20 to 40 seconds.")
    expect(connectionHint("internet", 60)).toMatch(/^This is taking longer than usual/)
    expect(connectionHint("local", 3)).toBe("On your network this takes a few seconds.")
    expect(connectionHint("local", 15)).toBe("This is taking longer than usual. Check that the PS5 is on.")
  })
})

describe("samePaired", () => {
  it("compares contents, not identity", () => {
    expect(samePaired({ HOST1: pairedPs5 }, { HOST1: { ...pairedPs5 } })).toBe(true)
    expect(samePaired({ HOST1: pairedPs5 }, { HOST1: { ...pairedPs5, name: "Den" } })).toBe(false)
    expect(samePaired({ HOST1: pairedPs5 }, {})).toBe(false)
  })
})

describe("onlyBitrateChanged", () => {
  const started = streamOptions(defaultSettings)
  it("is true only when the bitrate is the one difference", () => {
    expect(onlyBitrateChanged(started, streamOptions({ ...defaultSettings, bitrate: 30000 }))).toBe(true)
    expect(onlyBitrateChanged(started, started)).toBe(false)
    expect(onlyBitrateChanged(started, streamOptions({ ...defaultSettings, bitrate: 30000, height: 720 }))).toBe(false)
    expect(onlyBitrateChanged(started, streamOptions({ ...defaultSettings, height: 720 }))).toBe(false)
  })
})

describe("statRows", () => {
  const idlePacing: PacingStats = {
    generatedFps: 0, skippedFrames: 0, skippedInterpolations: 0, delayMs: 0,
    interpolation: "off", upscale: "metalfx", ml: "off", displayHz: 60, streamFps: 60, gameFps: 0, repeatedFrames: 0,
  }
  const at1080 = (pacing: Partial<PacingStats>) =>
    statRows({ ...status({ width: 1920, height: 1080 }), pacing: { ...idlePacing, ...pacing } }, 60, 5)
  const find = (rows: readonly StatRow[], label: string) => rows.find((row) => row.label === label)

  it("counts the in-between images shown, and says why there are none", () => {
    expect(find(at1080({ interpolation: "on", generatedFps: 29.6 }), "Frame interpolation"))
      .toEqual({ label: "Frame interpolation", value: "30/s", inline: "+30 generated", warn: false })
    expect(find(at1080({ interpolation: "on", generatedFps: 28, skippedInterpolations: 3 }), "Frame interpolation")?.inline)
      .toBe("+28 generated (3 missed)")
    // Turned on and possible, but nothing reached the screen: worth a look.
    expect(find(at1080({ interpolation: "on" }), "Frame interpolation")).toMatchObject({ inline: "+0 generated", warn: true })
    expect(find(at1080({ interpolation: "screen", displayHz: 74.97, streamFps: 59.94 }), "Frame interpolation"))
      .toMatchObject({ value: "Idle: 60 fps on a 75 Hz screen", inline: "no interpolation: 60 fps on a 75 Hz screen", warn: false })
    // The screen's rate isn't measured yet: nothing to say.
    expect(find(at1080({ interpolation: "screen", displayHz: 0 }), "Frame interpolation")).toBeUndefined()
    expect(find(at1080({ interpolation: "unsupported" }), "Frame interpolation")?.inline).toBe("interpolation unavailable on this Mac")
    expect(find(at1080({ interpolation: "off" }), "Frame interpolation")).toBeUndefined()
    // A paused game: nothing to make, no warning.
    expect(find(at1080({ interpolation: "still" }), "Frame interpolation"))
      .toMatchObject({ inline: "no interpolation: still picture", warn: false })
  })

  it("names a game slower than the stream, and what the screen shows", () => {
    const rate = (pacing: Partial<PacingStats>, shownFps = 60) =>
      find(statRows({ ...status({ width: 1920, height: 1080 }), shownFps, pacing: { ...idlePacing, ...pacing } }, 60, 5), "Frame rate")?.inline
    expect(rate({ gameFps: 30.2 })).toBe("30 fps game · 60 fps stream")
    expect(rate({ gameFps: 30, interpolation: "on", generatedFps: 30 })).toBe("30 fps game · 60 fps stream · 60 shown")
    expect(rate({ gameFps: 30, interpolation: "on", generatedFps: 90 }, 120)).toBe("30 fps game · 60 fps stream · 120 shown")
    // A game at the stream's rate (or not measured yet) is just the stream's rate.
    expect(rate({ gameFps: 59 })).toBe("60 fps")
    expect(rate({ gameFps: 0 })).toBe("60 fps")
  })

  it("shows what the console's encoder aims for next to what arrives", () => {
    const rows = statRows({ ...status({ width: 1920, height: 1080, targetBitrateKbps: 19417 }), pacing: idlePacing }, 60, 7.46)
    expect(find(rows, "Bitrate")?.inline).toBe("7.5 Mbps (target 19.4)")
    expect(find(at1080({}), "Bitrate")?.inline).toBe("5.0 Mbps")
  })

  it("says why MetalFX or ML upscaling, turned on, didn't run", () => {
    expect(find(at1080({ upscale: "notLarger" }), "Upscaler")).toMatchObject({ inline: "MetalFX (no upscale needed)", warn: false })
    expect(find(at1080({ upscale: "unsupported" }), "Upscaler")?.inline).toBe("MetalFX (MetalFX unavailable)")
    expect(find(at1080({ upscale: "failed" }), "Upscaler")).toMatchObject({ warn: true })
    expect(find(at1080({ upscale: "bilinear" }), "Upscaler")?.inline).toBe("MetalFX")
    expect(find(at1080({ ml: "streamTooLarge" }), "ML upscaling")?.inline).toBe("ML idle (only for 720p and lower)")
    expect(find(at1080({ ml: "notLarger" }), "ML upscaling")?.inline).toBe("ML idle (no upscale needed)")
    expect(find(at1080({ ml: "unsupported" }), "ML upscaling")?.inline).toBe("ML idle (unavailable on this Mac)")
    expect(find(at1080({ ml: "hdr" }), "ML upscaling")?.inline).toBe("ML idle (not for HDR)")
    expect(find(at1080({ ml: "on" }), "ML upscaling")).toBeUndefined()
    expect(find(at1080({ ml: "off" }), "ML upscaling")).toBeUndefined()
  })

  it("is empty until video arrives", () => {
    expect(statRows(status({}), 0, 0)).toEqual([])
  })

  it("lists the stream's numbers and flags the troubling ones", () => {
    const rows = statRows(
      { ...status({ width: 1920, height: 1080, framesLost: 3, decodeErrors: 1, rttMs: 4.25 }), gpuMs: 1.24 },
      60,
      24.31,
    )
    expect(rows.map((row) => [row.label, row.value, row.warn])).toEqual([
      ["Resolution", "1920×1080", false],
      ["Frame rate", "60 fps", false],
      ["Bitrate", "24.3 Mbps", false],
      ["Ping", "4.3 ms", false],
      ["GPU", "1.2 ms", false],
      ["Upscaler", "MetalFX", false],
      ["Lost frames", "3", true],
      ["Decode errors", "1", true],
    ])
    const smooth = statRows({ ...status({ width: 1280, height: 720 }), interpolationActive: true, hdrActive: true }, 60, 5)
    expect(smooth.find((row) => row.label === "Frame interpolation")?.inline).toBe("frame interpolation")
    // Frame generation: the screen gets more images than the stream sends.
    const generated = statRows({ ...status({ width: 1920, height: 1080 }), interpolationActive: true, shownFps: 59.6 }, 30, 5)
    expect(generated.find((row) => row.label === "Frame rate")?.inline).toBe("30 fps · 60 shown")
    const pacing = { ...idlePacing, skippedFrames: 4, delayMs: 3 }
    const skipping = statRows({ ...status({ width: 1920, height: 1080 }), pacing }, 60, 5)
    expect(skipping.find((row) => row.label === "Skipped frames")).toMatchObject({ inline: "4 skipped", warn: true })
    const plain = statRows({ ...status({ width: 1920, height: 1080 }), shownFps: 61 }, 60, 5)
    expect(plain.find((row) => row.label === "Frame rate")?.inline).toBe("60 fps")
    expect(smooth.find((row) => row.label === "HDR")?.inline).toBe("HDR")
    const measured = statRows({ ...status({ width: 1280, height: 720, decodeMs: 3.2 }), displayMs: 12.6 }, 60, 5, 1080)
    expect(measured.find((row) => row.label === "Latency")).toMatchObject({ inline: "latency 16 ms", warn: false })
    expect(measured.find((row) => row.label === "Resolution")).toMatchObject({ inline: "1280×720 (asked 1080p)", warn: true })
    expect(statRows({ ...status({ width: 1280, height: 720 }), displayMs: 40 }, 60, 5, 720).find((r) => r.label === "Latency")?.warn).toBe(true)
    const slow = statRows({ ...status({ width: 1280, height: 720, rttMs: 85 }), gpuMs: 9 }, 30, 5)
    expect(slow.find((row) => row.label === "Ping")).toEqual({ label: "Ping", value: "85 ms", inline: "ping 85 ms", warn: true })
    expect(slow.find((row) => row.label === "GPU")?.warn).toBe(true)
    expect(slow.some((row) => row.label === "Decode errors")).toBe(false)
  })
})

describe("microphoneProblem", () => {
  it("says how to fix it", () => {
    expect(microphoneProblem("denied")).toMatch(/Privacy & Security › Microphone/)
    expect(microphoneProblem("unavailable")).toMatch(/^No microphone found/)
  })
})

describe("isIpv4", () => {
  it("accepts dotted IPv4 addresses only", () => {
    expect(isIpv4("192.168.1.20")).toBe(true)
    expect(isIpv4("10.0.0.255")).toBe(true)
    for (const bad of ["192.168.1", "192.168.1.256", "ps5.local", "1.2.3.4.5", "1.2.3.x", ""]) expect(isIpv4(bad)).toBe(false)
  })
})
