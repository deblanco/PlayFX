import { Option } from "effect"
import { describe, expect, it } from "vitest"
import { defaultSettings } from "@/core/schema"
import {
  allProfiles,
  applyProfile,
  isBuiltIn,
  matchingProfile,
  profileSettings,
  profileSummary,
  recommended,
  withProfile,
} from "./profiles"

describe("profiles", () => {
  it("starts from the Recommended profile: 1080p60, MetalFX, sharpness 0.3", () => {
    expect(recommended.settings).toMatchObject({ height: 1080, fps: 60, upscaler: "metalfx", sharpness: 0.3, view: "enhanced" })
    expect(profileSummary(recommended)).toBe("1080p60 · MetalFX · sharpness 0.3")
    expect(isBuiltIn(recommended)).toBe(true)
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, allProfiles([])))?.name).toBe("Recommended")
  })

  it("holds stream and picture settings, not app preferences", () => {
    const picked = profileSettings({ ...defaultSettings, showStats: true, volume: 0.2, fps: 30 })
    expect(picked.fps).toBe(30)
    expect("showStats" in picked || "volume" in picked || "connection" in picked).toBe(false)
  })

  it("applies only its own settings", () => {
    const tv = { name: "TV", settings: profileSettings({ ...defaultSettings, height: 720, smoothMotion: true }) }
    const applied = applyProfile({ ...defaultSettings, showStats: true, volume: 0.4 }, tv)
    expect(applied).toMatchObject({ height: 720, smoothMotion: true, showStats: true, volume: 0.4 })
  })

  it("saves by name, replacing a profile of the same name", () => {
    const once = withProfile([], "  TV ", { ...defaultSettings, height: 720 })
    expect(once.map((p) => p.name)).toEqual(["TV"])
    const twice = withProfile([...once, { ...recommended, name: "Desk" }], "TV", { ...defaultSettings, height: 540 })
    expect(twice.map((p) => [p.name, p.settings.height])).toEqual([["Desk", 1080], ["TV", 540]])
    expect(isBuiltIn(twice[1] ?? recommended)).toBe(false)
  })

  it("finds the profile the settings match, or none", () => {
    const tv = withProfile([], "TV", { ...defaultSettings, height: 720 })
    const profiles = allProfiles(tv)
    expect(Option.getOrUndefined(matchingProfile({ ...defaultSettings, height: 720, showStats: true }, profiles))?.name).toBe("TV")
    expect(Option.isNone(matchingProfile({ ...defaultSettings, sharpness: 0.9 }, profiles))).toBe(true)
  })

  it("summarizes what a profile does", () => {
    const summary = (overrides: Partial<typeof defaultSettings>) =>
      profileSummary({ name: "x", settings: profileSettings({ ...defaultSettings, ...overrides }) })
    expect(summary({ view: "original", fps: 30 })).toBe("1080p30 · original picture")
    expect(summary({ upscaler: "bilinear", sharpness: 0, mlUpscale: true, smoothMotion: true, deblock: 0.5, hdr: true })).toBe(
      "1080p60 · bilinear · ML upscaling · Smooth motion · cleanup · HDR",
    )
  })
})
