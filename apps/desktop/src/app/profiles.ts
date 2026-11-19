import { Option } from "effect"
import { defaultSettings, sameProfileSettings, type Profile, type ProfileSettings, type Settings } from "@/core/schema"

/** The profile settings within `settings`. */
export const profileSettings = (s: Settings): ProfileSettings => ({
  height: s.height,
  fps: s.fps,
  hevc: s.hevc,
  bitrate: s.bitrate,
  hdr: s.hdr,
  view: s.view,
  upscaler: s.upscaler,
  sharpness: s.sharpness,
  deblock: s.deblock,
  deband: s.deband,
  mlUpscale: s.mlUpscale,
  frameInterpolation: s.frameInterpolation,
  colorMatrix: s.colorMatrix,
  colorRange: s.colorRange,
  chroma: s.chroma,
  accurateColor: s.accurateColor,
})

/** The built-in profile, which new installs start with: 1080p60, MetalFX, sharpness 0.3. */
export const recommended: Profile = { name: "Recommended", settings: profileSettings(defaultSettings) }

/** Built-in profiles first, then the user's. */
export const allProfiles = (saved: readonly Profile[]): readonly Profile[] => [recommended, ...saved]

export const isBuiltIn = (profile: Profile): boolean => profile.name === recommended.name

/** `settings` with a profile's stream and picture settings; everything else unchanged. */
export const applyProfile = (settings: Settings, profile: Profile): Settings => ({ ...settings, ...profile.settings })

/** The profile `settings` currently matches, if any. */
export const matchingProfile = (settings: Settings, profiles: readonly Profile[]): Option.Option<Profile> => {
  const current = profileSettings(settings)
  return Option.fromNullishOr(profiles.find((p) => sameProfileSettings(p.settings, current)))
}

/** Saves `settings` under `name`, replacing a saved profile of that name; the built-in name is taken. */
export const withProfile = (saved: readonly Profile[], name: string, settings: Settings): readonly Profile[] => {
  const profile = { name: name.trim(), settings: profileSettings(settings) }
  return [...saved.filter((p) => p.name !== profile.name), profile]
}

/** A short description: "1080p60 · MetalFX · sharpness 0.3". */
export const profileSummary = (profile: Profile): string => {
  const s = profile.settings
  const parts = [`${String(s.height)}p${String(s.fps)}`]
  if (s.view === "original") parts.push("original picture")
  else {
    parts.push(s.upscaler === "metalfx" ? "MetalFX" : "bilinear")
    if (s.sharpness > 0) parts.push(`sharpness ${String(Math.round(s.sharpness * 100) / 100)}`)
    if (s.mlUpscale) parts.push("ML upscaling")
    if (s.frameInterpolation) parts.push("Frame interpolation")
    if (s.deblock > 0 || s.deband > 0) parts.push("cleanup")
  }
  if (s.hdr) parts.push("HDR")
  return parts.join(" · ")
}
