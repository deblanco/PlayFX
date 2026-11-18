import { Option } from "effect"
import {
  type DiscoveredConsole,
  type PairedConsole,
  type PairedConsoles,
  type PsnConsole,
  type RenderParams,
  type RendererStatus,
  type Settings,
  type StreamEvent,
  type StreamOptions,
} from "@/core/schema"

// Pure helpers: everything here is a function of its arguments, so the UI can stay dumb.

/** "internet": not on this network, but reachable through PSN. */
export type ConsoleStatus = "ready" | "standby" | "offline" | "internet"

/** One line of the consoles list: what discovery saw and/or what we paired with. */
export interface ConsoleRow {
  readonly hostId: string
  readonly name: string
  readonly status: ConsoleStatus
  readonly meta: string
  readonly discovered: DiscoveredConsole | undefined
  readonly paired: PairedConsole | undefined
  /** The console's PSN device ID when it's only reachable over the internet. */
  readonly psnDuid: string | undefined
}

const statusOf = (console: DiscoveredConsole | undefined): ConsoleStatus =>
  console === undefined || console.state === "unknown" ? "offline" : console.state

/** Merges the consoles found on the network with the ones paired earlier (which may be offline). */
export const consoleRows = (
  discovered: readonly DiscoveredConsole[],
  paired: PairedConsoles,
  onPsn: Readonly<Record<string, string>> = {},
): readonly ConsoleRow[] => {
  const ids = [...new Set([...discovered.map((d) => d.hostId), ...Object.keys(paired)])]
  return ids.map((hostId) => {
    const d = discovered.find((x) => x.hostId === hostId)
    const p = paired[hostId]
    const ps5 = d?.ps5 ?? p?.credentials.ps5 ?? true
    const address = d?.address ?? p?.credentials.address ?? ""
    // On this network, play locally; otherwise PSN may still reach it.
    const psnDuid = d === undefined && p !== undefined ? onPsn[hostId] : undefined
    const status = psnDuid === undefined ? statusOf(d) : "internet"
    const meta = [ps5 ? "PS5" : "PS4", psnDuid === undefined ? address : "over the internet", d?.runningApp, p ? "paired" : undefined]
      .filter((part) => part !== undefined && part !== "")
      .join(" · ")
    return { hostId, name: d?.name ?? p?.name ?? hostId, status, meta, discovered: d, paired: p, psnDuid }
  })
}

export const streamOptions = (settings: Settings): StreamOptions => ({
  height: settings.height,
  fps: settings.fps,
  hevc: settings.hevc,
  bitrate: settings.bitrate,
  audio: settings.audio,
  autoDowngrade: settings.autoDowngrade,
  hdr: settings.hevc && settings.hdr,
})

/** The settings as the picture uses them: in the Original view, every processing step is off. */
export const effectivePicture = (settings: Settings): Settings =>
  settings.view === "original"
    ? { ...settings, upscaler: "bilinear", sharpness: 0, deblock: 0, deband: 0, mlUpscale: false, smoothMotion: false }
    : settings

export const renderParams = (settings: Settings): RenderParams => {
  const picture = effectivePicture(settings)
  return {
    upscaler: picture.upscaler,
    sharpness: picture.sharpness,
    deblock: picture.deblock,
    deband: picture.deband,
    mlUpscale: picture.mlUpscale,
    smoothMotion: picture.smoothMotion,
    compare: settings.view === "split",
    colorMatrix: picture.colorMatrix,
    colorRange: picture.colorRange,
    chroma: picture.chroma,
    accurateColor: picture.accurateColor,
  }
}

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

/** One number on the stats panel; `warn` marks one that signals trouble. */
export interface StatRow {
  readonly label: string
  readonly value: string
  /** As it reads in the HUD's line ("ping 12 ms", "0 lost frames"). */
  readonly inline: string
  readonly warn: boolean
}

/** What the stream is doing, for the stats panel (empty until video arrives). */
export const statRows = (status: RendererStatus, fps: number, mbps: number, requestedHeight?: number): readonly StatRow[] => {
  const { stream } = status
  if (!stream.active || stream.width === undefined || stream.height === undefined) return []
  const lost = stream.framesLost ?? 0
  const errors = stream.decodeErrors ?? 0
  const rtt = stream.rttMs ?? 0
  const row = (label: string, value: string, inline: string, warn = false): StatRow => ({ label, value, inline, warn })
  const size = `${String(stream.width)}×${String(stream.height)}`
  // The console lowers the resolution when the network can't keep up (auto-downgrade).
  const lower = requestedHeight !== undefined && stream.height < requestedHeight
  // On the Mac: decoding, then waiting for the screen (the network's part is the ping).
  const latency = (stream.decodeMs ?? 0) + status.displayMs
  const ping = `${rtt.toFixed(rtt < 10 ? 1 : 0)} ms`
  const gpu = `${status.gpuMs.toFixed(1)} ms`
  const upscaler = upscalerLabel(status.activeMode, status.mlActive)
  const rows: (StatRow | undefined)[] = [
    row("Resolution", size, lower ? `${size} (asked ${String(requestedHeight)}p)` : size, lower),
    row("Frame rate", `${String(fps)} fps`, `${String(fps)} fps`),
    row("Bitrate", `${mbps.toFixed(1)} Mbps`, `${mbps.toFixed(1)} Mbps`),
    rtt > 0 ? row("Ping", ping, `ping ${ping}`, rtt >= 60) : undefined,
    status.gpuMs > 0 ? row("GPU", gpu, `GPU ${gpu}`, status.gpuMs >= 8) : undefined,
    status.displayMs > 0 ? row("Latency", `${latency.toFixed(0)} ms`, `latency ${latency.toFixed(0)} ms`, latency >= 33) : undefined,
    row("Upscaler", upscaler, upscaler),
    status.smoothActive ? row("Smooth motion", "On", "smooth motion") : undefined,
    status.hdrActive ? row("HDR", "On", "HDR") : undefined,
    row("Lost frames", String(lost), `${String(lost)} lost frames`, lost > 0),
    errors > 0 ? row("Decode errors", String(errors), `${String(errors)} decode errors`, true) : undefined,
  ]
  return rows.filter((row) => row !== undefined)
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

/** Whether two paired-console lists hold the same consoles with the same details. */
export const samePaired = (a: PairedConsoles, b: PairedConsoles): boolean => JSON.stringify(a) === JSON.stringify(b)

/** The PSN device ID of each paired console PSN knows (with Remote Play on), matched by name as
 * chiaki-ng does: hostId → duid. */
export const psnDeviceIds = (
  paired: PairedConsoles,
  onPsn: readonly PsnConsole[],
): Readonly<Record<string, string>> =>
  Object.fromEntries(
    Object.values(paired).flatMap((console) => {
      const match = onPsn.find((c) => c.remotePlay && (c.name === console.name || c.name === console.credentials.nickname))
      return match ? [[console.hostId, match.duid]] : []
    }),
  )

/** Why a stream is being (re)started: new stream settings, a lost connection, or a console that was
 * still busy when the stream first started (e.g. just woken, or just after another session). */
export type Reconnecting = false | "apply" | "dropped" | "starting" | "network"

/** How many automatic reconnects in a row (without a stable minute in between) before giving up. */
export const maxAutoReconnects = 3

/** libchiaki's reason when the console can't be reached on the local network at all. */
export const unreachableReason = "Unknown Session Request Error"

/** What a quit means for the running stream. */
export const afterQuit = (
  session: {
    readonly connected: boolean
    readonly reconnecting: Reconnecting
    readonly autoReconnects: number
    readonly psnDuid?: string | undefined
    readonly psnFallback?: string | undefined
  },
  event: Extract<StreamEvent, { type: "quit" }>,
): "ignore" | "reconnect" | "retry-start" | "via-internet" | "end" => {
  if (session.reconnecting !== false) return "ignore" // the old session ending, or a busy console: the reconnect handles it
  if (!session.connected && event.kind === "busy") return "retry-start" // still busy for a few seconds: wait it out
  // Not reachable on this network: try through PSN (if the console is on the account).
  if (!session.connected && session.psnDuid === undefined && event.reason === unreachableReason) return "via-internet"
  if (session.connected && event.kind === "dropped" && session.autoReconnects < maxAutoReconnects) return "reconnect"
  return "end"
}

/** One stream event as a log line, and whether it's worth a warning. */
export const describeEvent = (event: StreamEvent): { readonly line: string; readonly warn: boolean } => {
  switch (event.type) {
    case "connected":
      return { line: "Stream connected", warn: false }
    case "quit":
      return { line: `Stream ended: ${event.reason} (${event.kind ?? "final"})`, warn: event.error }
    case "remoteProgress":
      return { line: `Over the internet: ${event.stage}`, warn: false }
    case "loginPin":
      return { line: event.incorrect ? "Console asks for its login PIN again (wrong PIN)" : "Console asks for its login PIN", warn: false }
    case "microphone":
      return { line: `Microphone ${event.state}`, warn: event.state === "denied" || event.state === "unavailable" }
    case "keyboard":
      return { line: `Console keyboard: ${event.change}`, warn: false }
    case "network":
      return { line: event.online ? "The Mac's network changed" : "The Mac went offline", warn: !event.online }
    case "nickname":
      return { line: `Console name: ${event.name}`, warn: false }
  }
}

/** libchiaki's quit reasons in plain words, with what to do about them. */
const quitReasons: Readonly<Record<string, string>> = {
  "Unknown Session Request Error":
    "Couldn't reach the console on this network. Check that the Mac and the console are on the same network, or play over the internet.",
  "Connection Refused in Session Request": "The console refused the connection. Check that Remote Play is turned on in its settings.",
  "Remote Play on Console has crashed": "Remote Play stopped on the console. Try again in a moment.",
  "RP-Version mismatch": "The console's Remote Play version isn't supported. Update the console's system software.",
  "Ctrl failed to connect": "The console stopped answering while connecting. Try again.",
  "The Console Registration using PSN has failed": "PSN couldn't set up the connection to the console. Try again, or sign in to PSN again.",
}

/** Toast text for a `quit` event, if the stream ended because of an error. */
export const quitMessage = (event: Extract<StreamEvent, { type: "quit" }>): Option.Option<string> =>
  event.error ? Option.some(quitReasons[event.reason] ?? `Disconnected: ${event.reason}`) : Option.none()

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
    settings.hevc ? (settings.hdr ? "HEVC HDR" : "HEVC") : "H.264",
    settings.bitrate === 0 ? "auto bitrate" : bitrateLabel(settings.bitrate),
  ].join(" · ")

/** What this Mac's renderer can do. */
export interface Capabilities {
  readonly metalfx: boolean
  /** Apple ML super-resolution (macOS 26+). */
  readonly ml: boolean
  /** Frame interpolation, "Smooth motion" (macOS 26+). */
  readonly smooth: boolean
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

export const pipelineStages = (chosen: Settings, capabilities: Capabilities): readonly Stage[] => {
  const settings = effectivePicture(chosen)
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

/** How a stream reaches the console. */
export type Route = "local" | "internet"

export interface ConnectStep {
  readonly label: string
  readonly state: "done" | "active" | "waiting"
}

/** Which step of connecting is under way: over the internet the console reports its setup stages;
 * on the local network there's a single wait for the console. */
export const activeStep = (route: Route, stage: "linking" | "data" | undefined): number =>
  route === "local" ? 0 : stage === "linking" ? 0 : stage === "data" ? 1 : 2

/** The steps of connecting, in order, in plain words. */
export const connectionSteps = (route: Route, stage: "linking" | "data" | undefined, consoleName: string): readonly ConnectStep[] => {
  const labels =
    route === "internet"
      ? ["Finding your PS5 through PSN", "Opening a direct connection to it", "Starting the stream"]
      : [`Contacting ${consoleName} on your network`, "Starting the stream"]
  const active = activeStep(route, stage)
  return labels.map((label, i) => ({ label, state: i < active ? "done" : i === active ? "active" : "waiting" }))
}

/** The connecting screen's heading. */
export const connectionTitle = (reconnecting: Reconnecting, consoleName: string): string => {
  switch (reconnecting) {
    case "dropped":
      return `Connection lost. Reconnecting to ${consoleName}`
    case "network":
      return `Your network changed. Reconnecting to ${consoleName}`
    case "apply":
      return `Reconnecting to ${consoleName} with the new settings`
    case "starting":
      return `${consoleName} is finishing its last session`
    case false:
      return `Connecting to ${consoleName}`
  }
}

/** What to expect after `seconds` of waiting, then what to check once it's taking too long. */
export const connectionHint = (route: Route, seconds: number): string => {
  if (route === "internet") {
    return seconds < 60
      ? "Over the internet this usually takes 20 to 40 seconds."
      : "This is taking longer than usual. Check that the PS5 is on, or in rest mode with \"Stay connected to the internet\" on."
  }
  return seconds < 15 ? "On your network this takes a few seconds." : "This is taking longer than usual. Check that the PS5 is on."
}

/** Voice chat from the HUD: off, waiting for macOS (permission, starting), or live. */
export type MicState = "off" | "pending" | "on"

/** What to tell the user when the microphone can't be used, and how to fix it. */
export const microphoneProblem = (state: "denied" | "unavailable"): string =>
  state === "denied"
    ? "PlayFX can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then turn it on again."
    : "No microphone found. Connect one, or pick an input in System Settings › Sound."

