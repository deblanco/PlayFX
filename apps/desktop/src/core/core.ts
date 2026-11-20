import { Context, Effect, Layer, Option, Schema, Semaphore } from "effect"
import { CoreError, ValidationError } from "./errors"
import {
  Credentials,
  DevCommand,
  DiscoveredConsoles,
  isAccountId,
  isPin,
  PsnAccountEvent,
  RendererStatus,
  StartReply,
  StreamEvent,
  AudioDevice,
  type ControllerState,
  type PointerTouch,
  type DiscoveredConsole,
  type StreamOptions,
  type RenderParams,
  PsnConsole,
  AppInfo,
  Diagnostics,
  PeerWifiReply,
  PeerWifiStatus,
  type PeerWifiState,
} from "./schema"
import { TauriBridge } from "./tauri"

export interface PairRequest {
  readonly console: DiscoveredConsole
  readonly accountId: string
  readonly pin: string
}

/** Typed access to the native StreamCore (via Tauri commands and events). */
export class Core extends Context.Service<
  Core,
  {
    readonly discover: Effect.Effect<readonly DiscoveredConsole[], CoreError>
    /** Asks one console directly at an IP address (for when broadcast discovery can't reach it). */
    readonly discoverAt: (address: string) => Effect.Effect<readonly DiscoveredConsole[], CoreError>
    readonly pair: (request: PairRequest) => Effect.Effect<Credentials, CoreError | ValidationError>
    readonly wakeup: (credentials: Credentials) => Effect.Effect<boolean, CoreError>
    /** Opens Sony's sign-in window; the result arrives through `onPsnAccount`. */
    readonly psnLogin: Effect.Effect<void, CoreError>
    /** Whether the PSN sign-in for internet play is kept (in the Keychain, never in the web UI). */
    readonly psnSignedIn: Effect.Effect<boolean, CoreError>
    readonly psnSignOut: Effect.Effect<void, CoreError>
    /** The PS5s on the PSN account (for playing over the internet). */
    readonly psnConsoles: Effect.Effect<readonly PsnConsole[], CoreError>
    /** Starts a stream; with `psnDuid` (the console's PSN device ID) it connects over the internet. */
    readonly startStream: (
      credentials: Credentials,
      options: StreamOptions,
      psnDuid?: string,
    ) => Effect.Effect<void, CoreError>
    readonly stopStream: Effect.Effect<void, CoreError>
    /** Puts the console in rest mode; it ends the session itself. */
    readonly sleepConsole: Effect.Effect<void, CoreError>
    /** Asks the console for a keyframe (the picture stopped arriving whole). */
    readonly requestKeyframe: Effect.Effect<void, CoreError>
    readonly setLoginPin: (pin: string) => Effect.Effect<void, CoreError>
    readonly setController: (state: ControllerState) => Effect.Effect<void, CoreError>
    /** Types into the console's open text field (replacing its text); `keyboardDone` sends or cancels. */
    readonly keyboardSetText: (text: string) => Effect.Effect<void, CoreError>
    readonly keyboardDone: (accept: boolean) => Effect.Effect<void, CoreError>
    /** The Mac's sound outputs, and where and how loud the stream plays (applied at once). */
    readonly audioDevices: Effect.Effect<readonly AudioDevice[], CoreError>
    readonly setAudioOutput: (volume: number, deviceUID: string | undefined) => Effect.Effect<void, CoreError>
    /** AirDrop and Handoff's peer-to-peer Wi-Fi (AWDL). */
    readonly peerWifiStatus: Effect.Effect<PeerWifiState, CoreError>
    /** Pauses it while PlayFX is open (macOS asks for the administrator password) or lets it back. */
    readonly setPeerWifiPaused: (paused: boolean) => Effect.Effect<PeerWifiReply, CoreError>
    /** The native secret store (Keychain in release builds, a 0600 file in development). */
    readonly secretGet: (key: string) => Effect.Effect<Option.Option<string>, CoreError>
    readonly secretSet: (key: string, value: string) => Effect.Effect<void, CoreError>
    readonly secretRemove: (key: string) => Effect.Effect<void, CoreError>
    /** Voice chat on/off; the outcome arrives as a "microphone" stream event. */
    readonly setMicrophone: (on: boolean) => Effect.Effect<void, CoreError>
    /** The Mac's pointer as a touchpad finger (merged natively with the pad's state). */
    readonly setPointerTouch: (touch: PointerTouch) => Effect.Effect<void, CoreError>
    readonly setRenderParams: (params: RenderParams) => Effect.Effect<void, CoreError>
    readonly setDetailedLogs: (on: boolean) => Effect.Effect<void, CoreError>
    readonly openLogsFolder: Effect.Effect<void, CoreError>
    /** Opens PlayFX's source code (AGPL-3.0) in the browser. */
    readonly openSourceCode: Effect.Effect<void, CoreError>
    readonly diagnostics: Effect.Effect<Diagnostics, CoreError>
    /** The app's version, build commit and macOS version. */
    readonly appInfo: Effect.Effect<AppInfo, CoreError>
    /** Toggles native fullscreen; succeeds with the new state. */
    readonly toggleFullscreen: Effect.Effect<boolean, CoreError>
    /** Whether the window is fullscreen now (the green button and ⌃⌘F change it too). */
    readonly fullscreenState: Effect.Effect<boolean, CoreError>
    readonly rendererStatus: Effect.Effect<RendererStatus, CoreError>
    readonly onStreamEvent: (handler: (event: StreamEvent) => void) => Effect.Effect<() => void, CoreError>
    readonly onPsnAccount: (handler: (event: PsnAccountEvent) => void) => Effect.Effect<() => void, CoreError>
    /** Requests from the dev control port (debug builds only). */
    readonly onDevControl: (handler: (command: DevCommand) => void) => Effect.Effect<() => void, CoreError>
  }
>()("Core") {}

export const CoreLive = Layer.effect(
  Core,
  Effect.gen(function* () {
    const tauri = yield* TauriBridge
    // Picture updates (one per slider tick) must reach the renderer in order: Tauri runs async commands
    // on a thread pool, so concurrent calls could land out of order and leave an old value applied.
    const renderParamsInOrder = yield* Semaphore.make(1)

    /** Invokes a command and decodes its reply, turning schema mismatches into CoreError. */
    const call = <S extends Schema.Top & { readonly DecodingServices: never }>(
      schema: S,
      command: string,
      args?: Record<string, unknown>,
    ): Effect.Effect<S["Type"], CoreError> =>
      tauri.invoke(command, args).pipe(
        Effect.flatMap((reply) =>
          Schema.decodeUnknownEffect(schema)(reply).pipe(
            Effect.mapError((error) => new CoreError({ command, message: `Unexpected reply: ${error.message}` })),
          ),
        ),
      )

    /** Subscribes to an event, dropping payloads that don't match the schema. */
    const subscribe =
      <S extends Schema.Top & { readonly DecodingServices: never }>(schema: S, event: string) =>
      (handler: (value: S["Type"]) => void) =>
        tauri.listen(event, (payload) => {
          const decoded = Schema.decodeUnknownOption(schema)(payload)
          if (decoded._tag === "Some") handler(decoded.value)
        })

    const unit = Schema.Unknown

    return {
      discover: call(DiscoveredConsoles, "discover"),
      discoverAt: (address) => call(DiscoveredConsoles, "discover", { host: address }),
      pair: ({ console, accountId, pin }) =>
        Effect.gen(function* () {
          const digits = pin.replace(/\D/g, "")
          if (!isPin(digits)) return yield* new ValidationError({ message: "The PIN has 8 digits" })
          if (!isAccountId(accountId)) return yield* new ValidationError({ message: "Sign in to PlayStation first" })
          return yield* call(Credentials, "register_console", {
            request: { address: console.address, ps5: console.ps5, accountId, pin: digits },
          })
        }),
      wakeup: (credentials) => call(Schema.Boolean, "wakeup", { credentials }),
      psnLogin: Effect.asVoid(call(unit, "psn_login")),
      psnSignedIn: call(Schema.Boolean, "psn_signed_in"),
      psnSignOut: Effect.asVoid(call(unit, "psn_sign_out")),
      psnConsoles: call(Schema.Array(PsnConsole), "psn_consoles"),
      startStream: (credentials, options, psnDuid) =>
        Effect.asVoid(
          call(StartReply, "start_stream", {
            request: psnDuid === undefined ? { credentials, options } : { credentials, options, remote: { duid: psnDuid } },
          }),
        ),
      stopStream: Effect.asVoid(call(unit, "stop_stream")),
      sleepConsole: Effect.asVoid(call(unit, "sleep_console")),
      requestKeyframe: Effect.asVoid(call(unit, "request_keyframe")),
      setLoginPin: (pin) => Effect.asVoid(call(unit, "set_login_pin", { pin })),
      setController: (state) => Effect.asVoid(call(unit, "set_controller", { state })),
      setPointerTouch: (touch) => Effect.asVoid(call(unit, "set_pointer_touch", { touch })),
      keyboardSetText: (text) => Effect.asVoid(call(unit, "keyboard_set_text", { text })),
      keyboardDone: (accept) => Effect.asVoid(call(unit, "keyboard_done", { accept })),
      setMicrophone: (on) => Effect.asVoid(call(unit, "set_microphone", { on })),
      audioDevices: call(Schema.Array(AudioDevice), "audio_devices"),
      setAudioOutput: (volume, deviceUID) =>
        Effect.asVoid(
          call(Schema.Struct({ ok: Schema.Literal(true) }), "set_audio_output", {
            output: deviceUID === undefined ? { volume } : { volume, deviceUID },
          }),
        ),
      peerWifiStatus: Effect.map(call(PeerWifiStatus, "peer_wifi_status"), (reply) => reply.state),
      setPeerWifiPaused: (paused) => call(PeerWifiReply, "set_peer_wifi_paused", { paused }),
      secretGet: (key) =>
        Effect.map(call(Schema.Struct({ value: Schema.NullOr(Schema.String) }), "secret_get", { key }), (r) =>
          Option.fromNullishOr(r.value),
        ),
      secretSet: (key, value) => Effect.asVoid(call(Schema.Struct({ ok: Schema.Literal(true) }), "secret_set", { key, value })),
      secretRemove: (key) => Effect.asVoid(call(unit, "secret_remove", { key })),
      setRenderParams: (params) =>
        Semaphore.withPermit(renderParamsInOrder, Effect.asVoid(call(unit, "set_render_params", { params }))),
      toggleFullscreen: call(Schema.Boolean, "toggle_fullscreen"),
      fullscreenState: call(Schema.Boolean, "fullscreen_state"),
      setDetailedLogs: (on) => Effect.asVoid(call(unit, "set_detailed_logs", { on })),
      openLogsFolder: Effect.asVoid(call(unit, "open_logs_folder")),
      openSourceCode: Effect.asVoid(call(unit, "open_source_code")),
      diagnostics: call(Diagnostics, "diagnostics"),
      appInfo: call(AppInfo, "app_info"),
      rendererStatus: call(RendererStatus, "renderer_status"),
      onStreamEvent: subscribe(StreamEvent, "stream-event"),
      onPsnAccount: subscribe(PsnAccountEvent, "psn-account"),
      onDevControl: subscribe(DevCommand, "dev-control"),
    }
  }),
)
