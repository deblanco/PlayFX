import { Effect, Schema } from "effect"

// Everything that crosses the native boundary or localStorage is described here once;
// TypeScript types are derived from these schemas.

export const ConsoleState = Schema.Literals(["ready", "standby", "unknown"])
export type ConsoleState = typeof ConsoleState.Type

export const DiscoveredConsole = Schema.Struct({
  address: Schema.String,
  name: Schema.String,
  hostId: Schema.String,
  systemVersion: Schema.String,
  runningApp: Schema.optionalKey(Schema.String),
  ps5: Schema.Boolean,
  state: ConsoleState,
})
export type DiscoveredConsole = typeof DiscoveredConsole.Type

export const DiscoveredConsoles = Schema.Array(DiscoveredConsole)

/** Pairing result: everything needed to stream later. Stays on this machine. */
export const Credentials = Schema.Struct({
  address: Schema.String,
  ps5: Schema.Boolean,
  nickname: Schema.String,
  mac: Schema.String,
  registKey: Schema.String,
  rpKey: Schema.String,
  accountId: Schema.String,
})
export type Credentials = typeof Credentials.Type

export const PairedConsole = Schema.Struct({
  hostId: Schema.String,
  name: Schema.String,
  credentials: Credentials,
})
export type PairedConsole = typeof PairedConsole.Type

export const PairedConsoles = Schema.Record(Schema.String, PairedConsole)
export type PairedConsoles = typeof PairedConsoles.Type

export const Resolution = Schema.Literals([540, 720, 1080])
export const Fps = Schema.Literals([30, 60])
export const Upscaler = Schema.Literals(["metalfx", "bilinear"])
export type Upscaler = typeof Upscaler.Type

/** Video bitrates offered, in kbps; 0 lets the console pick its default for the resolution. */
export const bitrates = [0, 10000, 15000, 20000, 30000, 40000, 50000] as const
export const Bitrate = Schema.Literals(bitrates)
export type Bitrate = typeof Bitrate.Type

/** A setting added after the first release: settings saved before it existed decode with `value`. */
const since = <S extends Schema.Top>(schema: S, value: S["Encoded"]) =>
  schema.pipe(Schema.withDecodingDefaultKey(Effect.succeed(value)))

/** A filter strength: 0 = off … 1 = strongest. */
export const Strength = Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 1 }))

/** YCbCr → RGB matrix; "auto" uses what the stream signals (the PS5 sends BT.709). */
export const ColorMatrix = Schema.Literals(["auto", "bt601", "bt709", "bt2020"])
/** How YCbCr values are scaled; "auto" uses the decoded frame's format. */
export const ColorRange = Schema.Literals(["auto", "limited", "full"])
/** How half-resolution color is brought up to full resolution. */
export const ChromaFilter = Schema.Literals(["bicubic", "bilinear"])
/** How Play reaches a console: the home network first then the internet, or only one of them. */
export const ConnectionRoute = Schema.Literals(["auto", "local", "internet"])

/** Picture settings, applied to every frame without reconnecting (StreamCore's RenderParams). */
export const RenderParams = Schema.Struct({
  upscaler: Upscaler,
  /** Sharpening after the upscale. */
  sharpness: Strength,
  /** Smooths compression blocking before the upscale. */
  deblock: Strength,
  /** Smooths banding in gradients before the upscale. */
  deband: Strength,
  /** Apple's ML super-resolution on the decoded frame first (720p and lower, macOS 26+). */
  mlUpscale: Schema.Boolean,
  /** An interpolated frame between stream frames when the screen is fast enough (macOS 26+). */
  smoothMotion: Schema.Boolean,
  /** Split screen: left half is the unprocessed baseline, right half these settings. */
  compare: Schema.Boolean,
  colorMatrix: ColorMatrix,
  colorRange: ColorRange,
  chroma: ChromaFilter,
  /** Color-manage the output as sRGB; off shows the display's native, more saturated colors. */
  accurateColor: Schema.Boolean,
})
export type RenderParams = typeof RenderParams.Type

export const Settings = Schema.Struct({
  height: Resolution,
  fps: Fps,
  hevc: Schema.Boolean,
  bitrate: since(Bitrate, 0),
  autoDowngrade: since(Schema.Boolean, true),
  audio: since(Schema.Boolean, true),
  upscaler: Upscaler,
  sharpness: since(Strength, 0.3),
  deblock: since(Strength, 0),
  deband: since(Strength, 0),
  mlUpscale: since(Schema.Boolean, false),
  smoothMotion: since(Schema.Boolean, false),
  compare: since(Schema.Boolean, false),
  colorMatrix: since(ColorMatrix, "auto"),
  colorRange: since(ColorRange, "auto"),
  chroma: since(ChromaFilter, "bicubic"),
  accurateColor: since(Schema.Boolean, true),
  /** Debug entries in the log file (native, libchiaki and web UI), for tracking down problems. */
  detailedLogs: since(Schema.Boolean, false),
  connection: since(ConnectionRoute, "auto"),
  /** Keeps the stream's numbers (frame rate, bitrate, ping, GPU time…) on screen while playing. */
  showStats: since(Schema.Boolean, false),
})
export type Settings = typeof Settings.Type

export const defaultSettings: Settings = {
  height: 1080,
  fps: 60,
  hevc: true,
  bitrate: 0,
  autoDowngrade: true,
  audio: true,
  upscaler: "metalfx",
  sharpness: 0.3,
  deblock: 0,
  deband: 0,
  mlUpscale: false,
  smoothMotion: false,
  compare: false,
  colorMatrix: "auto",
  colorRange: "auto",
  chroma: "bicubic",
  accurateColor: true,
  detailedLogs: false,
  connection: "auto",
  showStats: false,
}

/** Controller state sent to the console (keyboard-as-controller, on-screen pad, …).
 * Button bits and ranges match StreamCore's `sc_session_set_controller`. */
export const ControllerState = Schema.Struct({
  buttons: Schema.Number,
  l2: Schema.Number,
  r2: Schema.Number,
  leftX: Schema.Number,
  leftY: Schema.Number,
  rightX: Schema.Number,
  rightY: Schema.Number,
})
export type ControllerState = typeof ControllerState.Type

export const idleController: ControllerState = { buttons: 0, l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0 }

/** For bug reports: versions and the end of the log file (already scrubbed). */
export const Diagnostics = Schema.Struct({
  appVersion: Schema.String,
  os: Schema.String,
  logFolder: Schema.String,
  recentLog: Schema.String,
})
export type Diagnostics = typeof Diagnostics.Type

/** A console on the PSN account (internet play; PS5 only). */
export const PsnConsole = Schema.Struct({
  name: Schema.String,
  /** The console's PSN device ID (hex). */
  duid: Schema.String,
  remotePlay: Schema.Boolean,
})
export type PsnConsole = typeof PsnConsole.Type

export const StreamOptions = Schema.Struct({
  height: Schema.Number,
  fps: Schema.Number,
  hevc: Schema.Boolean,
  bitrate: Schema.Number,
  audio: Schema.Boolean,
  autoDowngrade: Schema.Boolean,
})
export type StreamOptions = typeof StreamOptions.Type
export const sameStreamOptions = Schema.toEquivalence(StreamOptions)

export const StreamEvent = Schema.Union([
  Schema.Struct({ type: Schema.Literal("connected") }),
  Schema.Struct({
    type: Schema.Literal("quit"),
    reason: Schema.String,
    error: Schema.Boolean,
    /** final: don't retry · busy: Remote Play still in use (~9 s after a session ends), retry soon ·
     * dropped: the connection was lost mid-stream, worth reconnecting · stopped: this client stopped it. */
    kind: Schema.optionalKey(Schema.Literals(["final", "busy", "dropped", "stopped"])),
  }),
  Schema.Struct({ type: Schema.Literal("loginPin"), incorrect: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("nickname"), name: Schema.String }),
  /** Connecting over the internet: linking (PSN, up to ~30 s per step) → data → connected. */
  Schema.Struct({ type: Schema.Literal("remoteProgress"), stage: Schema.Literals(["linking", "data", "connected"]) }),
])
export type StreamEvent = typeof StreamEvent.Type

export const PsnAccountEvent = Schema.Union([
  Schema.Struct({ accountId: Schema.String }),
  Schema.Struct({ error: Schema.String }),
])
export type PsnAccountEvent = typeof PsnAccountEvent.Type

export const StreamStats = Schema.Struct({
  active: Schema.Boolean,
  framesDecoded: Schema.optionalKey(Schema.Number),
  decodeErrors: Schema.optionalKey(Schema.Number),
  framesLost: Schema.optionalKey(Schema.Number),
  width: Schema.optionalKey(Schema.Number),
  height: Schema.optionalKey(Schema.Number),
  bytesReceived: Schema.optionalKey(Schema.Number),
  /** Round trip to the console, measured while connecting (0 until then). */
  rttMs: Schema.optionalKey(Schema.Number),
})
export type StreamStats = typeof StreamStats.Type

export const RendererStatus = Schema.Struct({
  metalfxSupported: Schema.Boolean,
  activeMode: Schema.Literals(["bilinear", "metalfx", "none"]),
  /** Smoothed GPU time per rendered frame; 0 until something was rendered. */
  gpuMs: Schema.Number,
  /** Apple ML super-resolution can run on this Mac (macOS 26+). */
  mlSupported: Schema.Boolean,
  /** The last frame went through ML super-resolution. */
  mlActive: Schema.Boolean,
  /** Frame interpolation ("Smooth motion") can run on this Mac (macOS 26+). */
  smoothSupported: Schema.Boolean,
  /** The last stream frame was preceded by an interpolated one. */
  smoothActive: Schema.Boolean,
  stream: StreamStats,
})
export type RendererStatus = typeof RendererStatus.Type

export const StartReply = Schema.Struct({ ok: Schema.Literal(true) })

/** A PSN account ID is 8 bytes, base64-encoded. */
export const isAccountId = (value: string): boolean => {
  if (!/^[A-Za-z0-9+/]{11}=$/.test(value)) return false
  return atob(value).length === 8
}

/** Pairing PINs are exactly 8 digits. */
export const isPin = (value: string): boolean => /^\d{8}$/.test(value)
