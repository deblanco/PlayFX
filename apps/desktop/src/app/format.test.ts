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
  psnHostId,
  psnPairHint,
  psnPairStep,
  renderParams,
  hudStats,
  interpolationReason,
  quitMessage,
  unreachableReasons,
  reorderLine,
  samePaired,
  microphoneProblem,
  onlyBitrateChanged,
  statRows,
  upscaleIdle,
  addDropSample,
  dropRates,
  dropWindowMs,
  missedWarnRate,
  noDrops,
  skippedWarnRate,
  type DropRates,
  type DropSample,
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
import { pairedPs5, ps5, psnPs5, status } from "./testing"

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

describe("consoleRows with the PSN account's PS5s", () => {
  const unpaired = { ...ps5, hostId: "HOST9" }

  it("offers pairing through PSN on the unpaired console found here with the same name", () => {
    const rows = consoleRows([unpaired], {}, {}, [psnPs5])
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ hostId: "HOST9", status: "ready", psn: psnPs5, discovered: unpaired })
  })

  it("lists a PS5 that isn't found here on its own row, saying when Remote Play is off", () => {
    const off = { name: "Bedroom", duid: "bb", remotePlay: false }
    const rows = consoleRows([], {}, {}, [psnPs5, off])
    expect(rows.map((r) => [r.hostId, r.name, r.status, r.meta, r.psnDuid])).toEqual([
      ["psn:aa", "Living Room", "internet", "PS5 · on your PSN account", "aa"],
      ["psn:bb", "Bedroom", "offline", "PS5 · Remote Play is off", "bb"],
    ])
    expect(rows[1]?.psn).toBe(off)
  })

  it("leaves out PS5s already paired, by PSN device ID or by name", () => {
    const viaPsn = { ...pairedPs5, hostId: "F8461CA1B2C3", name: "Renamed", psnDuid: "aa" }
    expect(consoleRows([], { F8461CA1B2C3: viaPsn }, {}, [psnPs5]).map((r) => r.hostId)).toEqual(["F8461CA1B2C3"])
    const rows = consoleRows([ps5], { HOST1: pairedPs5 }, {}, [psnPs5])
    expect(rows.map((r) => [r.hostId, r.psn])).toEqual([["HOST1", undefined]])
    // A PS4 found here isn't the account's PS5 of the same name.
    const ps4 = { ...unpaired, ps5: false }
    expect(consoleRows([ps4], {}, {}, [psnPs5]).map((r) => [r.hostId, r.psn])).toEqual([["HOST9", undefined], ["psn:aa", psnPs5]])
  })

  it("leaves out a PS5 paired with a code and renamed since, by the name it's found under here", () => {
    const oldName = { ...pairedPs5, name: "Old Name", credentials: { ...pairedPs5.credentials, nickname: "Old Name" } }
    const rows = consoleRows([ps5], { HOST1: oldName }, {}, [psnPs5])
    expect(rows.map((r) => [r.hostId, r.psn])).toEqual([["HOST1", undefined]])
    // Paired through PSN, it's matched by device ID only: the account's other PS5 of that name stays.
    const viaPsn = { ...oldName, psnDuid: "bb" }
    expect(consoleRows([ps5], { HOST1: viaPsn }, {}, [psnPs5]).map((r) => r.hostId)).toEqual(["HOST1", "psn:aa"])
  })
})

describe("psnHostId", () => {
  it("is discovery's host ID, the MAC as uppercase hex, or the PSN device ID when the MAC is unknown", () => {
    expect(psnHostId("f8:46:1c:a1:b2:c3", "aa")).toBe("F8461CA1B2C3")
    expect(psnHostId("00:00:00:00:00:00", "aa")).toBe("psn:aa")
    expect(psnHostId("", "aa")).toBe("psn:aa")
  })
})

describe("pairing through PSN copy", () => {
  it("names the step under way and what to expect", () => {
    expect(psnPairStep(undefined, "PS5-454")).toBe("Finding PS5-454 through PSN…")
    expect(psnPairStep("linking", "PS5-454")).toBe("Finding PS5-454 through PSN…")
    expect(psnPairStep("registering", "PS5-454")).toBe("Pairing this Mac with PS5-454…")
    expect(psnPairHint(10)).toBe("This takes 20 to 30 seconds. Nothing to do on the PS5.")
    expect(psnPairHint(60)).toMatch(/^This is taking longer than usual\. Check that the PS5 is on/)
  })
})

describe("psnDeviceIds", () => {
  it("matches a console paired through PSN by its device ID, whatever its name", () => {
    const viaPsn = { ...pairedPs5, name: "Renamed", psnDuid: "bb" }
    const onPsn = [psnPs5, { name: "Bedroom", duid: "bb", remotePlay: true }]
    expect(psnDeviceIds({ HOST1: viaPsn }, onPsn)).toEqual({ HOST1: "bb" })
  })

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
  const dropped = { type: "quit", reason: "The connection to the PS5 was lost.", error: true, kind: "dropped" } as const
  it("tries PSN when the local network can't reach the console", () => {
    const starting = { connected: false, reconnecting: false, autoReconnects: 0 } as const
    const unreachable = {
      type: "quit",
      reason: "The PS5 didn't answer. Check that it's on and on the same network as this Mac.",
      error: true,
      kind: "final",
    } as const
    expect(afterQuit({ ...starting, psnFallback: "aa" }, unreachable)).toBe("via-internet")
    expect(afterQuit(starting, unreachable)).toBe("via-internet") // PSN is asked then
    expect(afterQuit({ ...starting, psnFallback: "aa", psnDuid: "aa" }, unreachable)).toBe("end") // already via PSN
    expect(afterQuit({ ...live, psnFallback: "aa" }, unreachable)).toBe("end") // it had connected
    const blocked = "Couldn't reach the PS5. Allow PlayFX in System Settings › Privacy & Security › Local Network, and turn off any VPN."
    expect(afterQuit({ ...starting, psnFallback: "aa" }, { ...unreachable, reason: blocked })).toBe("via-internet")
    expect(unreachableReasons).toHaveLength(4) // PS5 and PS4, each "didn't answer" and "couldn't reach"
    const busy = "The PS5 is already streaming to another device. End that session, or wait a few seconds and try again."
    expect(afterQuit({ ...starting, psnFallback: "aa" }, { ...unreachable, reason: busy })).toBe("end")
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
    expect(describeEvent({ type: "quit", reason: "The connection to the PS5 was lost.", error: true, kind: "dropped" })).toEqual({
      line: "Stream ended: The connection to the PS5 was lost. (dropped)",
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
  it("only reports errors, in the engine's words", () => {
    const lost = "The connection to the PS5 was lost."
    expect(quitMessage({ type: "quit", reason: lost, error: true })).toEqual(Option.some(lost))
    expect(quitMessage({ type: "quit", reason: "Stopped", error: false })).toEqual(Option.none())
  })

  it("adds playing over the internet to a PS5 that didn't answer on this network", () => {
    expect(
      quitMessage({ type: "quit", reason: "The PS5 didn't answer. Check that it's on and on the same network as this Mac.", error: true }),
    ).toEqual(
      Option.some("The PS5 didn't answer on this network. Check that it's on and on the same network as this Mac, or play over the internet."),
    )
    const ps4 = "The PS4 didn't answer. Check that it's on and on the same network as this Mac."
    expect(quitMessage({ type: "quit", reason: ps4, error: true })).toEqual(Option.some(ps4)) // no internet play for a PS4
  })
})

describe("ML super-resolution", () => {
  const ml = { ...defaultSettings, mlUpscale: true, height: 720 } as const
  it("applies to every stream resolution when the Mac supports it", () => {
    expect(mlApplies(ml, { metalfx: true, ml: true, interpolation: false })).toBe(true)
    expect(mlApplies({ ...ml, height: 540 }, { metalfx: true, ml: true, interpolation: false })).toBe(true)
    expect(mlApplies({ ...ml, height: 1080 }, { metalfx: true, ml: true, interpolation: false })).toBe(true)
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
    expect(streamSummary(defaultSettings)).toBe("1080p · 60 fps · HEVC · 20 Mbps")
    expect(streamSummary({ ...defaultSettings, bitrate: 0 })).toBe("1080p · 60 fps · HEVC · auto bitrate")
    expect(streamSummary({ ...defaultSettings, height: 720, fps: 30, hevc: false, bitrate: 40000 })).toBe(
      "720p · 30 fps · H.264 · 40 Mbps",
    )
  })
})

describe("pipelineStages", () => {
  const view = (stages: readonly Stage[]) => stages.map((s) => [s.id, s.value, s.active])
  it("lists the picture steps in render order with their values", () => {
    expect(view(pipelineStages(defaultSettings, { metalfx: true, ml: true, interpolation: false }))).toEqual([
      ["cleanup", "Off", false],
      ["upscale", "ML + MetalFX", true],
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
    expect(upscale).toMatchObject({ value: "ML + MetalFX", active: false, note: "not needed" })
    // Bilinear chosen, ML off: nothing is idle, so no note.
    const [, bilinear] = pipelineStages({ ...defaultSettings, upscaler: "bilinear", mlUpscale: false }, caps, "not needed")
    expect(bilinear).toEqual({ id: "upscale", name: "Upscale", value: "Bilinear", active: false })
  })
})

describe("interpolationReason", () => {
  const idlePacing: PacingStats = {
    generatedFps: 0, skippedFrames: 0, missedInterpolations: 0, delayMs: 0,
    interpolation: "off", upscale: "metalfx", ml: "off", displayHz: 60, streamFps: 60, gameFps: 0, repeatedFrames: 0, wifiStalls: false,
  }
  const reason = (pacing: Partial<PacingStats>, hdrActive = false, active = true) =>
    interpolationReason({ ...status({ active }), hdrActive, pacing: { ...idlePacing, ...pacing } })

  it("says why for each case its switch's description doesn't cover, only while streaming", () => {
    expect(reason({ interpolation: "sdrInHdr" })).toBe(
      "This game is SDR, but HDR is on, so its frames arrive in a format frame interpolation can't take. Turn HDR off in Stream for this game.",
    )
    expect(reason({ interpolation: "hdrUnsupported" }, true)).toBe("HDR needs MetalFX's frame interpolator (macOS 26 and a supported Mac).")
    expect(reason({ interpolation: "failed" }, true)).toBe("MetalFX failed several times, so it's off until PlayFX restarts.")
    expect(reason({ interpolation: "on", generatedFps: 30 }, true))
      .toBe("In HDR it makes one image between two frames (60 at most from a 30 fps game).")
    expect(reason({ interpolation: "screen" }, true)).toBe("No images in between: 60 fps on a 60 Hz screen.")
    expect(reason({ interpolation: "screen", displayHz: 74.97, streamFps: 59.94 }, true)).toBe("No images in between: 60 fps on a 75 Hz screen.")
    // The switch's own description covers the rest: SDR on, failed or on a slow screen, off, unavailable, a still picture.
    expect(reason({ interpolation: "screen", displayHz: 0 }, true)).toBeUndefined()
    expect(reason({ interpolation: "screen", displayHz: 74.97, streamFps: 59.94 })).toBeUndefined()
    expect(reason({ interpolation: "on" })).toBeUndefined()
    expect(reason({ interpolation: "failed" })).toBeUndefined()
    for (const interpolation of ["off", "unsupported", "still"] as const) expect(reason({ interpolation }, true)).toBeUndefined()
    // No stream, or no word from the renderer yet.
    expect(reason({ interpolation: "sdrInHdr" }, false, false)).toBeUndefined()
    expect(interpolationReason({ ...status(), pacing: null })).toBeUndefined()
  })
})

describe("upscaleIdle", () => {
  const pacing: PacingStats = {
    generatedFps: 0, skippedFrames: 0, missedInterpolations: 0, delayMs: 0,
    interpolation: "off", upscale: "metalfx", ml: "off", displayHz: 0, streamFps: 0, gameFps: 0, repeatedFrames: 0, wifiStalls: false,
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
    expect(upscaleIdle({ ...pacing, upscale: "bilinear", ml: "failed" })).toBe("failed")
    expect(upscaleIdle({ ...pacing, upscale: "bilinear", ml: "stalled" })).toBe("waiting on the model")
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

describe("drop rates", () => {
  /** Polls a second apart, after `start`'s, with these totals of missed pairs (skipped frames at half of them). */
  const poll = (totals: readonly number[], start: readonly DropSample[] = []) => {
    const from = start.at(-1)?.time ?? 0
    return totals.reduce((samples, missed, i) => addDropSample(samples, { time: from + 1000 * (i + 1), missed, skipped: missed / 2 }), start)
  }

  it("gives drops per second over the last few seconds, however big the totals get", () => {
    expect(dropRates([])).toEqual(noDrops)
    expect(dropRates(poll([500]))).toEqual(noDrops) // one reading: no rate yet
    expect(dropRates(poll([500, 503]))).toEqual({ missed: 3, skipped: 1.5 })
    // Ten seconds at 2/s, then two at 10/s: only the last five seconds count.
    const window = poll([100, 102, 104, 106, 108, 110, 112, 114, 116, 118, 120, 130, 140])
    expect(window.length).toBe(dropWindowMs / 1000 + 1)
    expect(dropRates(window).missed).toBeCloseTo((140 - 114) / 5)
    // Quiet again: the rate falls back to nothing once the window has passed.
    expect(dropRates(poll([140, 140, 140, 140, 140, 140], window)).missed).toBe(0)
  })

  it("starts over when a total goes down (a new stream)", () => {
    const before = poll([900, 910, 920])
    const after = addDropSample(before, { time: 4000, missed: 2, skipped: 1 })
    expect(after).toEqual([{ time: 4000, missed: 2, skipped: 1 }])
    expect(dropRates(after)).toEqual(noDrops)
    // Skipped frames alone going down also means a new stream.
    expect(addDropSample(before, { time: 4000, missed: 930, skipped: 0 })).toHaveLength(1)
  })
})

describe("statRows", () => {
  const idlePacing: PacingStats = {
    generatedFps: 0, skippedFrames: 0, missedInterpolations: 0, delayMs: 0,
    interpolation: "off", upscale: "metalfx", ml: "off", displayHz: 60, streamFps: 60, gameFps: 0, repeatedFrames: 0, wifiStalls: false,
  }
  const at1080 = (pacing: Partial<PacingStats>, rates?: DropRates) =>
    statRows({ ...status({ width: 1920, height: 1080 }), pacing: { ...idlePacing, ...pacing } }, 60, 5, undefined, rates)
  const find = (rows: readonly StatRow[], label: string) => rows.find((row) => row.label === label)

  it("counts the in-between images shown, and says why there are none", () => {
    expect(find(at1080({ interpolation: "on", generatedFps: 29.6 }), "Frame interpolation"))
      .toEqual({ label: "Frame interpolation", value: "30/s", inline: "+30 generated", warn: false })
    // Missed pairs as a rate over the last few seconds: amber once a few a second go without.
    const missing = (missed: number) => find(at1080({ interpolation: "on", generatedFps: 28 }, { missed, skipped: 0 }), "Frame interpolation")
    expect(missing(0.4)).toMatchObject({ value: "28/s", inline: "+28 generated (0.4/s missed)", warn: false })
    expect(missing(2.9)).toMatchObject({ inline: "+28 generated (2.9/s missed)", warn: false })
    expect(missing(missedWarnRate)).toMatchObject({ inline: "+28 generated (3/s missed)", warn: true })
    expect(missing(14.6)?.inline).toBe("+28 generated (15/s missed)")
    // Turned on and possible, but nothing reached the screen: worth a look.
    expect(find(at1080({ interpolation: "on" }), "Frame interpolation")).toMatchObject({ inline: "+0 generated", warn: true })
    expect(find(at1080({ interpolation: "screen", displayHz: 74.97, streamFps: 59.94 }), "Frame interpolation"))
      .toMatchObject({ value: "Idle: 60 fps on a 75 Hz screen", inline: "no interpolation: 60 fps on a 75 Hz screen", warn: false })
    // The screen's rate isn't measured yet: nothing to say.
    expect(find(at1080({ interpolation: "screen", displayHz: 0 }), "Frame interpolation")).toBeUndefined()
    expect(find(at1080({ interpolation: "unsupported" }), "Frame interpolation")?.inline).toBe("interpolation unavailable")
    expect(find(at1080({ interpolation: "off" }), "Frame interpolation")).toBeUndefined()
    // A paused game: nothing to make, no warning.
    expect(find(at1080({ interpolation: "still" }), "Frame interpolation"))
      .toMatchObject({ inline: "no interpolation: still picture", warn: false })
    // Its engine kept failing (off until the app restarts) or no size works: flagged.
    expect(find(at1080({ interpolation: "failed" }), "Frame interpolation"))
      .toEqual({ label: "Frame interpolation", value: "Off: kept failing", inline: "interpolation off: it kept failing", warn: true })
  })

  it("says why an HDR stream, or an SDR game with HDR on, gets no in-between images", () => {
    const hdr = (pacing: Partial<PacingStats>) =>
      find(statRows({ ...status({ width: 1920, height: 1080 }), hdrActive: true, pacing: { ...idlePacing, ...pacing } }, 60, 5),
        "Frame interpolation")
    // The HDR setting on, an SDR game: its 10-bit frames reach no engine (the stream isn't HDR on screen).
    expect(find(at1080({ interpolation: "sdrInHdr" }), "Frame interpolation"))
      .toEqual({ label: "Frame interpolation", value: "Idle: SDR game with HDR on", inline: "no interpolation: SDR game with HDR on", warn: false })
    expect(hdr({ interpolation: "hdrUnsupported" }))
      .toEqual({ label: "Frame interpolation", value: "Unavailable in HDR", inline: "no interpolation in HDR on this Mac", warn: false })
    // MetalFX's engine kept failing: said which, and flagged.
    expect(hdr({ interpolation: "failed" }))
      .toEqual({ label: "Frame interpolation", value: "Off: MetalFX kept failing", inline: "interpolation off: MetalFX kept failing (HDR)", warn: true })
    // The rest read as in SDR.
    expect(hdr({ interpolation: "screen", displayHz: 60, streamFps: 60 })?.inline).toBe("no interpolation: 60 fps on a 60 Hz screen")
    expect(hdr({ interpolation: "on", generatedFps: 30 })?.inline).toBe("+30 generated")
    expect(hdr({ interpolation: "unsupported" })?.inline).toBe("interpolation unavailable")
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
    expect(find(at1080({ ml: "streamTooLarge" }), "ML upscaling")?.inline).toBe("ML idle (not for this stream size)")
    expect(find(at1080({ ml: "notLarger" }), "ML upscaling")?.inline).toBe("ML idle (no upscale needed)")
    expect(find(at1080({ ml: "unsupported" }), "ML upscaling")?.inline).toBe("ML idle (unavailable on this Mac)")
    expect(find(at1080({ ml: "hdr" }), "ML upscaling")?.inline).toBe("ML idle (not for HDR)")
    expect(find(at1080({ ml: "failed" }), "ML upscaling"))
      .toEqual({ label: "ML upscaling", value: "Off: video processor failed", inline: "ML off (video processor failed)", warn: true })
    // Waiting on a slow model build: not a failure, no warning.
    expect(find(at1080({ ml: "stalled" }), "ML upscaling"))
      .toMatchObject({ inline: "ML idle (waiting on the model)", warn: false })
    expect(find(at1080({ ml: "on" }), "ML upscaling")).toBeUndefined()
    expect(find(at1080({ ml: "off" }), "ML upscaling")).toBeUndefined()
  })

  it("says how long a missing packet is waited for, once a stream says", () => {
    expect(reorderLine({ active: true, reorderWaitMs: 4.4, reorderHolesFilled: 12, reorderLatePackets: 3, reorderHolesLost: 5, reorderQueueFull: 0 }))
      .toBe("Reorder wait 4 ms · 12 holes filled while waiting · 3 late packets · 5 holes lost · 0 holes skipped for a full queue")
    expect(reorderLine({ active: true, reorderWaitMs: 16 })).toBe("Reorder wait 16 ms · 0 holes filled while waiting · 0 late packets · 0 holes lost · 0 holes skipped for a full queue")
    expect(reorderLine({ active: true, reorderWaitMs: 7, reorderHolesFilled: 1, reorderLatePackets: 1, reorderHolesLost: 1, reorderQueueFull: 1 }))
      .toBe("Reorder wait 7 ms · 1 hole filled while waiting · 1 late packet · 1 hole lost · 1 hole skipped for a full queue")
    // Not connected yet, an older host, or no stream.
    expect(reorderLine({ active: true, reorderWaitMs: 0 })).toBeUndefined()
    expect(reorderLine({ active: true })).toBeUndefined()
    expect(reorderLine({ active: false, reorderWaitMs: 16 })).toBeUndefined()
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
    // Skipped frames as a rate: a big total from a long session says nothing; one a second is a visible hitch.
    const pacing = { ...idlePacing, skippedFrames: 4000, delayMs: 3 }
    const skipping = (skipped: number) =>
      statRows({ ...status({ width: 1920, height: 1080 }), pacing }, 60, 5, undefined, { missed: 0, skipped })
        .find((row) => row.label === "Skipped frames")
    expect(skipping(0)).toBeUndefined()
    expect(skipping(0.2)).toEqual({ label: "Skipped frames", value: "0.2/s", inline: "0.2/s skipped", warn: false })
    expect(skipping(skippedWarnRate)).toMatchObject({ inline: "1/s skipped", warn: true })
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
