import { Option } from "effect"
import {
  defaultSettings,
  sameProfileSettings,
  sameStreamOptions,
  type Profile,
  type ProfileSettings,
  type Settings,
  type StreamOptions,
} from "@/core/schema"
import { streamOptions } from "./format"

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
  touchpadTouches: s.touchpadTouches,
})

/** The built-in profile new installs start with: 1080p60 HEVC at 20 Mbps, MetalFX, sharpness 0.3, ML upscaling
 * and Frame interpolation. */
export const recommended: Profile = { name: "Recommended", settings: profileSettings(defaultSettings) }

/** Recommended at 30 fps with only the touchpad click sent: GTA VI opens its map on a resting thumb. */
export const gtaVI: Profile = { name: "GTA VI", settings: { ...recommended.settings, fps: 30, touchpadTouches: false } }

const builtInProfiles: readonly Profile[] = [recommended, gtaVI]

/** Built-in profiles first, then the user's. */
export const allProfiles = (saved: readonly Profile[]): readonly Profile[] => [...builtInProfiles, ...saved]

/** Whether `name` (trimmed) is a built-in profile's, which can't be saved over. */
export const isBuiltInName = (name: string): boolean => builtInProfiles.some((p) => p.name === name.trim())

export const isBuiltIn = (profile: Profile): boolean => isBuiltInName(profile.name)

/** Saved profiles with a built-in profile's name (saved before it was built in) renamed "<name> (saved)", so
 * both show, and the saved one can still be picked, replaced and deleted by its new name. */
export const withoutBuiltInNames = (saved: readonly Profile[]): readonly Profile[] => {
  const taken = new Set(saved.map((p) => p.name))
  return saved.map((p) => {
    if (!isBuiltInName(p.name)) return p
    let name = `${p.name} (saved)`
    for (let n = 2; taken.has(name); n++) name = `${p.name} (saved ${String(n)})`
    taken.add(name)
    return { ...p, name }
  })
}

/** `settings` with a profile's stream, picture and touchpad settings; everything else unchanged. */
export const applyProfile = (settings: Settings, profile: Profile): Settings => ({ ...settings, ...profile.settings })

/** Whether switching to `profile` during a stream started with `running` needs a reconnect: its stream
 * settings (resolution, frame rate, codec, bitrate, HDR) differ from the stream's; picture settings apply at once. */
export const needsReconnect = (settings: Settings, profile: Profile, running: StreamOptions): boolean =>
  !sameStreamOptions(streamOptions(applyProfile(settings, profile)), running)

/** The profile `settings` currently matches, if any. A saved profile wins over a built-in one with the same
 * settings, so it can still be selected and deleted. */
export const matchingProfile = (settings: Settings, profiles: readonly Profile[]): Option.Option<Profile> => {
  const current = profileSettings(settings)
  const matches = profiles.filter((p) => sameProfileSettings(p.settings, current))
  return Option.fromNullishOr(matches.find((p) => !isBuiltIn(p)) ?? matches[0])
}

/** Saves `settings` under `name`: a saved profile of that name is replaced where it is, a new one goes last. */
export const withProfile = (saved: readonly Profile[], name: string, settings: Settings): readonly Profile[] => {
  const profile = { name: name.trim(), settings: profileSettings(settings) }
  return isSaved(saved, profile.name)
    ? saved.map((p) => (p.name === profile.name ? profile : p))
    : [...saved, profile]
}

/** Whether `name` (trimmed) is one of the saved profiles, so saving under it replaces that profile. */
export const isSaved = (saved: readonly Profile[], name: string): boolean => saved.some((p) => p.name === name.trim())

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
  if (!s.touchpadTouches) parts.push("touchpad click only")
  return parts.join(" · ")
}
