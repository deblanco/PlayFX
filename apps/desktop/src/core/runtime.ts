import { Layer, ManagedRuntime } from "effect"
import { Core, CoreLive } from "./core"
import { LoggingLive } from "./logging"
import { LocalStorageLive, Preferences, PreferencesLive } from "./preferences"
import { TauriBridgeLive } from "./tauri"

export type AppServices = Core | Preferences

export const AppLayer: Layer.Layer<AppServices> = Layer.mergeAll(
  CoreLive.pipe(Layer.provide(TauriBridgeLive)),
  PreferencesLive.pipe(Layer.provide(LocalStorageLive)),
  LoggingLive,
)

export type AppRuntime = ManagedRuntime.ManagedRuntime<AppServices, never>

export const makeAppRuntime = (layer: Layer.Layer<AppServices> = AppLayer): AppRuntime => ManagedRuntime.make(layer)
