import { Option } from "effect"
import { describe, expect, it } from "vitest"
import { defaultSettings } from "@/core/schema"
import { streamOptions } from "./format"
import {
  allProfiles,
  applyProfile,
  gtaVI,
  isBuiltIn,
  isBuiltInName,
  isSaved,
  matchingProfile,
  needsReconnect,
  profileSettings,
  profileSummary,
  recommended,
  withoutBuiltInNames,
  withProfile,
} from "./profiles"

describe("profiles", () => {
  it("starts from the Recommended profile: 1080p60 HEVC at 20 Mbps, MetalFX, sharpness 0.3, Frame interpolation", () => {
    expect(recommended.settings).toMatchObject({
      height: 1080,
      fps: 60,
      hevc: true,
      bitrate: 20000,
      hdr: false,
      upscaler: "metalfx",
      sharpness: 0.3,
      mlUpscale: true,
      frameInterpolation: true,
      view: "enhanced",
      touchpadTouches: true,
    })
    expect(profileSummary(recommended)).toBe("1080p60 · MetalFX · sharpness 0.3 · ML upscaling · Frame interpolation")
    expect(isBuiltIn(recommended)).toBe(true)
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, allProfiles([])))?.name).toBe("Recommended")
  })

  it("has a built-in GTA VI profile: Recommended at 30 fps without ML upscaling, sending only the touchpad click", () => {
    expect(gtaVI.settings).toEqual({ ...recommended.settings, fps: 30, mlUpscale: false, touchpadTouches: false })
    expect(profileSummary(gtaVI)).toBe("1080p30 · MetalFX · sharpness 0.3 · Frame interpolation · touchpad click only")
    expect(isBuiltIn(gtaVI)).toBe(true)
    expect(isBuiltInName(" GTA VI ")).toBe(true)
    expect(isBuiltInName("GTA VI (saved)")).toBe(false)
    const applied = applyProfile({ ...defaultSettings, showStats: true }, gtaVI)
    expect(applied).toEqual({ ...defaultSettings, showStats: true, fps: 30, mlUpscale: false, touchpadTouches: false })
    expect(Option.getOrUndefined(matchingProfile(applied, allProfiles([])))?.name).toBe("GTA VI")
    // A different frame rate: switching to it mid-stream needs a reconnect.
    expect(needsReconnect(defaultSettings, gtaVI, streamOptions(defaultSettings))).toBe(true)
  })

  it("lists the built-in profiles first, Recommended then GTA VI", () => {
    const couch = withProfile([], "Couch", { ...defaultSettings, height: 720 })
    expect(allProfiles(couch).map((p) => p.name)).toEqual(["Recommended", "GTA VI", "Couch"])
    expect(allProfiles(couch).map(isBuiltIn)).toEqual([true, true, false])
  })

  it("renames a saved profile with a built-in name, keeping its settings and place", () => {
    const mine = withProfile([], "GTA VI", { ...defaultSettings, sharpness: 0.6 })
    const desk = withProfile([], "Desk", defaultSettings)
    const renamed = withoutBuiltInNames([...desk, ...mine])
    expect(renamed.map((p) => p.name)).toEqual(["Desk", "GTA VI (saved)"])
    expect(renamed[1]?.settings).toEqual(mine[0]?.settings)
    // Nothing to rename: the same list.
    expect(withoutBuiltInNames(desk)).toEqual(desk)
    // The new name already taken: the next free one, so no two profiles share a name.
    const both = withoutBuiltInNames([
      ...withProfile([], "GTA VI (saved)", defaultSettings),
      ...mine,
      ...withProfile([], "Recommended", defaultSettings),
    ])
    expect(both.map((p) => p.name)).toEqual(["GTA VI (saved)", "GTA VI (saved 2)", "Recommended (saved)"])
    expect(new Set(allProfiles(both).map((p) => p.name)).size).toBe(5)
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

  it("prefers a saved profile over a built-in one with the same settings, so it can be selected and deleted", () => {
    const legacy = withoutBuiltInNames(withProfile([], "GTA VI", applyProfile(defaultSettings, gtaVI)))
    const gta = applyProfile(defaultSettings, gtaVI)
    expect(Option.getOrUndefined(matchingProfile(gta, allProfiles(legacy)))?.name).toBe("GTA VI (saved)")
    expect(Option.getOrUndefined(matchingProfile(gta, allProfiles([])))?.name).toBe("GTA VI")
    const desk = withProfile([], "Desk", defaultSettings)
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, allProfiles(desk)))?.name).toBe("Desk")
  })

  it("holds Touchpad touches: a profile can send only the touchpad click", () => {
    const thumb = withProfile([], "Thumb rest", { ...defaultSettings, touchpadTouches: false })
    expect(thumb[0]?.settings.touchpadTouches).toBe(false)
    const profiles = allProfiles(thumb)
    expect(Option.getOrUndefined(matchingProfile({ ...defaultSettings, touchpadTouches: false }, profiles))?.name).toBe("Thumb rest")
    expect(Option.getOrUndefined(matchingProfile(defaultSettings, profiles))?.name).toBe("Recommended")
    expect(applyProfile(defaultSettings, thumb[0] ?? recommended).touchpadTouches).toBe(false)
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
    expect(summary({ touchpadTouches: false, frameInterpolation: false })).toBe(
      "1080p60 · MetalFX · sharpness 0.3 · ML upscaling · touchpad click only",
    )
  })
})
