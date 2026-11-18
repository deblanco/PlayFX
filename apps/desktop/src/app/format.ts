import { Option } from "effect"
import {
  type DiscoveredConsole,
  type PairedConsole,
  type PairedConsoles,
  type RenderParams,
  type RendererStatus,
  type Settings,
  type StreamEvent,
  type StreamOptions,
} from "@/core/schema"

// Pure helpers: everything here is a function of its arguments, so the UI can stay dumb.

export type ConsoleStatus = "ready" | "standby" | "offline"

/** One line of the consoles list: what discovery saw and/or what we paired with. */
export interface ConsoleRow {
  readonly hostId: string
  readonly name: string
  readonly status: ConsoleStatus
  readonly meta: string
  readonly discovered: DiscoveredConsole | undefined
  readonly paired: PairedConsole | undefined
}

const statusOf = (console: DiscoveredConsole | undefined): ConsoleStatus =>
  console === undefined || console.state === "unknown" ? "offline" : console.state

/** Merges the consoles found on the network with the ones paired earlier (which may be offline). */
export const consoleRows = (discovered: readonly DiscoveredConsole[], paired: PairedConsoles): readonly ConsoleRow[] => {
  const ids = [...new Set([...discovered.map((d) => d.hostId), ...Object.keys(paired)])]
  return ids.map((hostId) => {
    const d = discovered.find((x) => x.hostId === hostId)
    const p = paired[hostId]
    const ps5 = d?.ps5 ?? p?.credentials.ps5 ?? true
    const address = d?.address ?? p?.credentials.address ?? ""
    const meta = [ps5 ? "PS5" : "PS4", address, d?.runningApp, p ? "paired" : undefined]
      .filter((part) => part !== undefined && part !== "")
      .join(" · ")
    return { hostId, name: d?.name ?? p?.name ?? hostId, status: statusOf(d), meta, discovered: d, paired: p }
  })
}

export const streamOptions = (settings: Settings): StreamOptions => ({
  height: settings.height,
  fps: settings.fps,
  hevc: settings.hevc,
  bitrate: settings.bitrate,
  audio: settings.audio,
  autoDowngrade: settings.autoDowngrade,
})

export const renderParams = (settings: Settings): RenderParams => ({
  upscaler: settings.upscaler,
  sharpness: settings.sharpness,
  deblock: settings.deblock,
  deband: settings.deband,
  mlUpscale: settings.mlUpscale,
  compare: settings.compare,
  colorMatrix: settings.colorMatrix,
  colorRange: settings.colorRange,
  chroma: settings.chroma,
  accurateColor: settings.accurateColor,
})

/** The decoder's counters at one moment, for computing rates between polls. */
export interface FrameSample {
  readonly frames: number
  readonly bytes: number
  readonly time: number
}

/** Frames per second between two samples of the decoder's frame counter. */
export const framesPerSecond = (previous: FrameSample, current: FrameSample): number => {
  const elapsed = current.time - previous.time
  if (elapsed <= 0) return 0
  return Math.max(0, Math.round(((current.frames - previous.frames) * 1000) / elapsed))
}

const upscalerLabels: Readonly<Record<RendererStatus["activeMode"], string>> = {
  metalfx: "MetalFX",
  bilinear: "Bilinear",
  none: "No upscaling",
}

export const upscalerLabel = (mode: RendererStatus["activeMode"], ml = false): string =>
  ml ? `ML + ${upscalerLabels[mode]}` : upscalerLabels[mode]

/** Received video bitrate between two samples, in Mbps with one decimal. */
export const megabitsPerSecond = (previous: FrameSample, current: FrameSample): number => {
  const elapsed = current.time - previous.time
  if (elapsed <= 0) return 0
  return Math.max(0, Math.round(((current.bytes - previous.bytes) * 8) / elapsed / 100) / 10)
}

/** The HUD's stats line. */
export const hudStats = (status: RendererStatus, fps: number, mbps: number): string => {
  const { stream } = status
  if (!stream.active) return "Connecting…"
  const size =
    stream.width !== undefined && stream.height !== undefined ? `${stream.width}×${stream.height}` : "waiting for video"
  const errors = stream.decodeErrors ?? 0
  const gpu = status.gpuMs > 0 ? `GPU ${status.gpuMs.toFixed(1)} ms` : undefined
  return [
    size,
    `${String(fps)} fps`,
    `${mbps.toFixed(1)} Mbps`,
    upscalerLabel(status.activeMode, status.mlActive),
    gpu,
    errors > 0 ? `${String(errors)} decode errors` : undefined,
  ]
    .filter((part) => part !== undefined)
    .join(" · ")
}

/** Toast text for a `quit` event, if the stream ended because of an error. */
export const quitMessage = (event: Extract<StreamEvent, { type: "quit" }>): Option.Option<string> =>
  event.error ? Option.some(`Disconnected: ${event.reason}`) : Option.none()

export type SettingKey = keyof Settings

/** "Auto" or "40 Mbps". */
export const bitrateLabel = (kbps: number): string => (kbps === 0 ? "Auto" : `${String(kbps / 1000)} Mbps`)

/** A 0–1 filter strength as the UI shows it: "Off" or "30%". */
export const strengthLabel = (strength: number): string =>
  strength === 0 ? "Off" : `${String(Math.round(strength * 100))}%`

/** The stream settings in one line, for the home screen. */
export const streamSummary = (settings: Settings): string =>
  [
    `${String(settings.height)}p`,
    `${String(settings.fps)} fps`,
    settings.hevc ? "HEVC" : "H.264",
    settings.bitrate === 0 ? "auto bitrate" : bitrateLabel(settings.bitrate),
  ].join(" · ")

/** What this Mac's renderer can do. */
export interface Capabilities {
  readonly metalfx: boolean
  /** Apple ML super-resolution (macOS 26+). */
  readonly ml: boolean
}

/** ML super-resolution only takes streams up to 1280 px wide, i.e. 720p and lower. */
export const mlApplies = (settings: Settings, capabilities: Capabilities): boolean =>
  settings.mlUpscale && capabilities.ml && settings.height <= 720

export type StageId = "cleanup" | "upscale" | "sharpen" | "color"

/** One step of the picture pipeline, in the order the renderer applies them. */
export interface Stage {
  readonly id: StageId
  readonly name: string
  readonly value: string
  /** Whether this step changes the picture. */
  readonly active: boolean
}

export const pipelineStages = (settings: Settings, capabilities: Capabilities): readonly Stage[] => {
  const cleanup = Math.max(settings.deblock, settings.deband)
  const metalfx = settings.upscaler === "metalfx" && capabilities.metalfx
  const upscaler = metalfx ? "MetalFX" : "Bilinear"
  return [
    { id: "cleanup", name: "Clean up", value: strengthLabel(cleanup), active: cleanup > 0 },
    {
      id: "upscale",
      name: "Upscale",
      value: mlApplies(settings, capabilities) ? `ML + ${upscaler}` : upscaler,
      active: metalfx || mlApplies(settings, capabilities),
    },
    { id: "sharpen", name: "Sharpen", value: strengthLabel(settings.sharpness), active: settings.sharpness > 0 },
    { id: "color", name: "Color", value: settings.accurateColor ? "Accurate" : "Vivid", active: settings.accurateColor },
  ]
}
