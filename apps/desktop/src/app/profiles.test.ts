import { Option } from "effect"
import { describe, expect, it } from "vitest"
import { defaultSettings } from "@/core/schema"
import { streamOptions } from "./format"
import {
  allProfiles,
  applyProfile,
  isBuiltIn,
  isSaved,
  matchingProfile,
  needsReconnect,
  profileSettings,
  profileSummary,
  recommended,
  withProfile,
} from "./profiles"

describe("profiles", () => {
  it("starts from the Recommended profile: 1080p60, MetalFX, sharpness 0.3", () => {
    expect(recommended.settings).toMatchObject({ height: 1080, fps: 60, upscaler: "metalfx", sharpness: 0.3, view: "enhanced" })
    expect(profileSummary(recommended)).toBe("1080p60 · MetalFX · sharpness 0.3 · ML upscaling")
    expect(isBuiltIn(recommended)).toBe(true)
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, allProfiles([])))?.name).toBe("Recommended")
  })

  it("holds stream and picture settings, not app preferences", () => {
    const picked = profileSettings({ ...defaultSettings, showStats: true, volume: 0.2, fps: 30 })
    expect(picked.fps).toBe(30)
    expect("showStats" in picked || "volume" in picked || "connection" in picked).toBe(false)
  })

  it("applies only its own settings", () => {
    const tv = { name: "TV", settings: profileSettings({ ...defaultSettings, height: 720, frameInterpolation: true }) }
    const applied = applyProfile({ ...defaultSettings, showStats: true, volume: 0.4 }, tv)
    expect(applied).toMatchObject({ height: 720, frameInterpolation: true, showStats: true, volume: 0.4 })
  })

  it("saves by name, replacing a profile of the same name", () => {
    const once = withProfile([], "  TV ", { ...defaultSettings, height: 720 })
    expect(once.map((p) => p.name)).toEqual(["TV"])
    const twice = withProfile([...once, { ...recommended, name: "Desk" }], "TV", { ...defaultSettings, height: 540 })
    // Replaced where it was, not moved to the end.
    expect(twice.map((p) => [p.name, p.settings.height])).toEqual([["TV", 540], ["Desk", 1080]])
    expect(isBuiltIn(twice[0] ?? recommended)).toBe(false)
    expect(isSaved(twice, " Desk ")).toBe(true)
    expect(isSaved(twice, "Couch")).toBe(false)
  })

  it("finds the profile the settings match, or none", () => {
    const tv = withProfile([], "TV", { ...defaultSettings, height: 720 })
    const profiles = allProfiles(tv)
    expect(Option.getOrUndefined(matchingProfile({ ...defaultSettings, height: 720, showStats: true }, profiles))?.name).toBe("TV")
    expect(Option.isNone(matchingProfile({ ...defaultSettings, sharpness: 0.9 }, profiles))).toBe(true)
  })

  it("holds Touchpad touches: a profile can send only the touchpad click", () => {
    const gta = withProfile([], "GTA VI", { ...defaultSettings, touchpadTouches: false })
    expect(gta[0]?.settings.touchpadTouches).toBe(false)
    const profiles = allProfiles(gta)
    expect(Option.getOrUndefined(matchingProfile({ ...defaultSettings, touchpadTouches: false }, profiles))?.name).toBe("GTA VI")
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, profiles))?.name).toBe("Recommended")
    expect(applyProfile(defaultSettings, gta[0] ?? recommended).touchpadTouches).toBe(false)
    expect(applyProfile({ ...defaultSettings, touchpadTouches: false }, recommended).touchpadTouches).toBe(true)
  })

  it("needs a reconnect only for a different stream, not a different picture", () => {
    const running = streamOptions(defaultSettings)
    const profile = (overrides: Partial<typeof defaultSettings>) => ({
      name: "x",
      settings: profileSettings({ ...defaultSettings, ...overrides }),
    })
    expect(needsReconnect(defaultSettings, profile({ sharpness: 0.9, view: "split" }), running)).toBe(false)
    expect(needsReconnect(defaultSettings, profile({ touchpadTouches: false }), running)).toBe(false) // applies at once
    expect(needsReconnect(defaultSettings, profile({ bitrate: 15000 }), running)).toBe(true)
    expect(needsReconnect(defaultSettings, profile({ height: 720 }), running)).toBe(true)
    // Measured against the running stream, not the settings: going back to it costs nothing.
    expect(needsReconnect({ ...defaultSettings, fps: 30 }, recommended, running)).toBe(false)
  })

  it("summarizes what a profile does", () => {
    const summary = (overrides: Partial<typeof defaultSettings>) =>
      profileSummary({ name: "x", settings: profileSettings({ ...defaultSettings, ...overrides }) })
    expect(summary({ view: "original", fps: 30 })).toBe("1080p30 · original picture")
    expect(summary({ upscaler: "bilinear", sharpness: 0, mlUpscale: true, frameInterpolation: true, deblock: 0.5, hdr: true })).toBe(
      "1080p60 · bilinear · ML upscaling · Frame interpolation · cleanup · HDR",
    )
    expect(summary({ touchpadTouches: false })).toBe("1080p60 · MetalFX · sharpness 0.3 · ML upscaling · touchpad click only")
  })
})
