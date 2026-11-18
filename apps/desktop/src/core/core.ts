import { Context, Effect, Layer, Schema, Semaphore } from "effect"
import { CoreError, ValidationError } from "./errors"
import {
  Credentials,
  DiscoveredConsoles,
  isAccountId,
  isPin,
  PsnAccountEvent,
  RendererStatus,
  StartReply,
  StreamEvent,
  type ControllerState,
  type DiscoveredConsole,
  type StreamOptions,
  type RenderParams,
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
    readonly pair: (request: PairRequest) => Effect.Effect<Credentials, CoreError | ValidationError>
    readonly wakeup: (credentials: Credentials) => Effect.Effect<boolean, CoreError>
    /** Opens Sony's sign-in window; the result arrives through `onPsnAccount`. */
    readonly psnLogin: Effect.Effect<void, CoreError>
    /** Whether the PSN sign-in for internet play is kept (in the Keychain, never in the web UI). */
    readonly psnSignedIn: Effect.Effect<boolean, CoreError>
    readonly psnSignOut: Effect.Effect<void, CoreError>
    readonly startStream: (credentials: Credentials, options: StreamOptions) => Effect.Effect<void, CoreError>
    readonly stopStream: Effect.Effect<void, CoreError>
    readonly setLoginPin: (pin: string) => Effect.Effect<void, CoreError>
    readonly setController: (state: ControllerState) => Effect.Effect<void, CoreError>
    readonly setRenderParams: (params: RenderParams) => Effect.Effect<void, CoreError>
    /** Toggles native fullscreen; succeeds with the new state. */
    readonly toggleFullscreen: Effect.Effect<boolean, CoreError>
    readonly rendererStatus: Effect.Effect<RendererStatus, CoreError>
    readonly onStreamEvent: (handler: (event: StreamEvent) => void) => Effect.Effect<() => void, CoreError>
    readonly onPsnAccount: (handler: (event: PsnAccountEvent) => void) => Effect.Effect<() => void, CoreError>
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
      startStream: (credentials, options) =>
        Effect.asVoid(call(StartReply, "start_stream", { request: { credentials, options } })),
      stopStream: Effect.asVoid(call(unit, "stop_stream")),
      setLoginPin: (pin) => Effect.asVoid(call(unit, "set_login_pin", { pin })),
      setController: (state) => Effect.asVoid(call(unit, "set_controller", { state })),
      setRenderParams: (params) =>
        Semaphore.withPermit(renderParamsInOrder, Effect.asVoid(call(unit, "set_render_params", { params }))),
      toggleFullscreen: call(Schema.Boolean, "toggle_fullscreen"),
      rendererStatus: call(RendererStatus, "renderer_status"),
      onStreamEvent: subscribe(StreamEvent, "stream-event"),
      onPsnAccount: subscribe(PsnAccountEvent, "psn-account"),
    }
  }),
)
