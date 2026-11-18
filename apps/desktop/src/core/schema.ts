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
export const Upscaler = Schema.Literals(["metalfx", "bilinear", "compare"])
export type Upscaler = typeof Upscaler.Type

/** Video bitrate in kbps; 0 lets the console pick its default for the resolution. */
export const Bitrate = Schema.Literals([0, 10000, 15000, 20000, 30000, 40000, 50000])
export type Bitrate = typeof Bitrate.Type

/** A setting added after the first release: settings saved before it existed decode with `value`. */
const since = <S extends Schema.Top>(schema: S, value: S["Encoded"]) =>
  schema.pipe(Schema.withDecodingDefaultKey(Effect.succeed(value)))

export const Settings = Schema.Struct({
  height: Resolution,
  fps: Fps,
  hevc: Schema.Boolean,
  bitrate: since(Bitrate, 0),
  autoDowngrade: since(Schema.Boolean, true),
  audio: since(Schema.Boolean, true),
  upscaler: Upscaler,
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

export const StreamOptions = Schema.Struct({
  height: Schema.Number,
  fps: Schema.Number,
  hevc: Schema.Boolean,
  bitrate: Schema.Number,
  audio: Schema.Boolean,
  autoDowngrade: Schema.Boolean,
})
export type StreamOptions = typeof StreamOptions.Type

export const StreamEvent = Schema.Union([
  Schema.Struct({ type: Schema.Literal("connected") }),
  Schema.Struct({ type: Schema.Literal("quit"), reason: Schema.String, error: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("loginPin"), incorrect: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("nickname"), name: Schema.String }),
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
})
export type StreamStats = typeof StreamStats.Type

export const RendererStatus = Schema.Struct({
  metalfxSupported: Schema.Boolean,
  activeMode: Schema.Literals(["bilinear", "metalfx", "compare", "none"]),
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
