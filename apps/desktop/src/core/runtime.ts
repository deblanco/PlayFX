import { Layer, ManagedRuntime } from "effect"
import { Core, CoreLive } from "./core"
import { LoggingLive } from "./logging"
import { LocalStorageLive, Preferences, SecurePreferencesLive } from "./preferences"
import { NativeSecretStoreLive } from "./secrets"
import { TauriBridgeLive } from "./tauri"

export type AppServices = Core | Preferences

const CoreAppLive = CoreLive.pipe(Layer.provide(TauriBridgeLive))

export const AppLayer: Layer.Layer<AppServices> = Layer.mergeAll(
  CoreAppLive,
  // Settings in localStorage; pairing keys and the account ID in the native secret store.
  SecurePreferencesLive.pipe(Layer.provide(Layer.merge(LocalStorageLive, NativeSecretStoreLive.pipe(Layer.provide(CoreAppLive))))),
  LoggingLive,
)

export type AppRuntime = ManagedRuntime.ManagedRuntime<AppServices, never>

export const makeAppRuntime = (layer: Layer.Layer<AppServices> = AppLayer): AppRuntime => ManagedRuntime.make(layer)
