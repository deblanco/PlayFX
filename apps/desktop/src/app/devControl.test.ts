import { Option } from "effect"
import { describe, expect, it } from "vitest"
import { defaultSettings } from "@/core/schema"
import { patchSettings } from "./devControl"

describe("patchSettings", () => {
  it("changes only what the patch names", () => {
    expect(patchSettings(defaultSettings, { view: "split", sharpness: 0.6 })).toEqual(
      Option.some({ ...defaultSettings, view: "split", sharpness: 0.6 }),
    )
    expect(patchSettings(defaultSettings, {})).toEqual(Option.some(defaultSettings))
  })

  it("refuses values settings can't hold", () => {
    expect(Option.isNone(patchSettings(defaultSettings, { fps: 45 }))).toBe(true)
    expect(Option.isNone(patchSettings(defaultSettings, { upscaler: "fsr" }))).toBe(true)
  })
})
