import { Option, Schema } from "effect"
import {
  Settings,
  type DiscoveredConsole,
  type PairedConsole,
  type PairedConsoles,
  type RendererStatus,
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
  bitrate: 0,
  audio: true,
})

export interface FrameSample {
  readonly frames: number
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
  compare: "Bilinear | MetalFX",
  none: "No upscaling",
}

export const upscalerLabel = (mode: RendererStatus["activeMode"]): string => upscalerLabels[mode]

/** The HUD's stats line. */
export const hudStats = (status: RendererStatus, fps: number): string => {
  const { stream } = status
  if (!stream.active) return "Connecting…"
  const size =
    stream.width !== undefined && stream.height !== undefined ? `${stream.width}×${stream.height}` : "waiting for video"
  const errors = stream.decodeErrors ?? 0
  return [size, `${fps} fps`, upscalerLabel(status.activeMode), errors > 0 ? `${errors} decode errors` : undefined]
    .filter((part) => part !== undefined)
    .join(" · ")
}

/** Toast text for a `quit` event, if the stream ended because of an error. */
export const quitMessage = (event: Extract<StreamEvent, { type: "quit" }>): Option.Option<string> =>
  event.error ? Option.some(`Disconnected: ${event.reason}`) : Option.none()

export type SettingKey = keyof Settings

const parsers: Readonly<Record<SettingKey, (raw: string) => unknown>> = {
  height: Number,
  fps: Number,
  hevc: (raw) => raw === "hevc",
  upscaler: (raw) => raw,
}

/** Applies a raw `<select>` value to the settings; values the schema rejects leave them unchanged. */
export const withSetting = (settings: Settings, key: SettingKey, raw: string): Settings =>
  Option.getOrElse(Schema.decodeUnknownOption(Settings)({ ...settings, [key]: parsers[key](raw) }), () => settings)

/** The `<select>` value for a setting. */
export const settingValue = (settings: Settings, key: SettingKey): string =>
  key === "hevc" ? (settings.hevc ? "hevc" : "h264") : String(settings[key])
