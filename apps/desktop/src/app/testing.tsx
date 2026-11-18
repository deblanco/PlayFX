import { render } from "@testing-library/react"
import { Effect, Layer } from "effect"
import { vi } from "vitest"
import { Core } from "@/core/core"
import { memoryStore, PreferencesLive } from "@/core/preferences"
import { makeAppRuntime, type AppRuntime } from "@/core/runtime"
import type {
  Credentials,
  DiscoveredConsole,
  PairedConsole,
  PsnAccountEvent,
  RendererStatus,
  RenderParams,
  Settings,
  StreamEvent,
} from "@/core/schema"
import { defaultSettings } from "@/core/schema"
import { App } from "./App"
import { renderParams } from "./format"
import { RuntimeProvider } from "./runtime"

// Test doubles shared by the app's tests: a scriptable Core and in-memory Preferences.

export const accountId = "AAAAAAAAAAA="

export const ps5: DiscoveredConsole = {
  address: "192.168.0.40",
  name: "Living Room",
  hostId: "HOST1",
  systemVersion: "09060008",
  runningApp: "Astro Bot",
  ps5: true,
  state: "ready",
}

export const credentials: Credentials = {
  address: "192.168.0.40",
  ps5: true,
  nickname: "Living Room",
  mac: "a1b2c3d4e5f6",
  registKey: "regist",
  rpKey: "rp",
  accountId,
}

export const pairedPs5: PairedConsole = { hostId: "HOST1", name: "Living Room", credentials }

/** Default picture settings with some overridden, as the renderer receives them. */
export const picture = (overrides: Partial<RenderParams> = {}): RenderParams => ({
  ...renderParams(defaultSettings),
  ...overrides,
})

export const status = (stream: Partial<RendererStatus["stream"]> = {}, metalfxSupported = true): RendererStatus => ({
  metalfxSupported,
  activeMode: "metalfx",
  gpuMs: 0,
  mlSupported: false,
  mlActive: false,
  stream: { active: true, ...stream },
})

type CoreService = Core["Service"]

/** A Core whose replies are mutable state, recording calls and letting tests fire events. */
export const fakeCore = (overrides: Partial<CoreService> = {}) => {
  const state = { discovered: [ps5] as readonly DiscoveredConsole[], status: status() }
  const counts = { discover: 0, psnLogin: 0, stopStream: 0 }
  const streamHandlers = new Set<(event: StreamEvent) => void>()
  const psnHandlers = new Set<(event: PsnAccountEvent) => void>()
  const service: CoreService = {
    discover: Effect.sync(() => {
      counts.discover++
      return state.discovered
    }),
    pair: vi.fn<CoreService["pair"]>(() => Effect.succeed(credentials)),
    wakeup: vi.fn<CoreService["wakeup"]>(() => Effect.succeed(true)),
    psnLogin: Effect.sync(() => {
      counts.psnLogin++
    }),
    startStream: vi.fn<CoreService["startStream"]>(() => Effect.void),
    stopStream: Effect.sync(() => {
      counts.stopStream++
    }),
    setLoginPin: vi.fn<CoreService["setLoginPin"]>(() => Effect.void),
    setController: vi.fn<CoreService["setController"]>(() => Effect.void),
    setRenderParams: vi.fn<CoreService["setRenderParams"]>(() => Effect.void),
    rendererStatus: Effect.sync(() => state.status),
    onStreamEvent: (handler) =>
      Effect.sync(() => {
        streamHandlers.add(handler)
        return () => streamHandlers.delete(handler)
      }),
    onPsnAccount: (handler) =>
      Effect.sync(() => {
        psnHandlers.add(handler)
        return () => psnHandlers.delete(handler)
      }),
    ...overrides,
  }
  return {
    service,
    state,
    counts,
    layer: Layer.succeed(Core, service),
    streamListeners: () => streamHandlers.size,
    psnListeners: () => psnHandlers.size,
    emitStream: (event: StreamEvent) => {
      for (const handler of streamHandlers) handler(event)
    },
    emitPsn: (event: PsnAccountEvent) => {
      for (const handler of psnHandlers) handler(event)
    },
  }
}

export type FakeCore = ReturnType<typeof fakeCore>

export interface StoredPrefs {
  readonly accountId?: string
  readonly paired?: readonly PairedConsole[]
  readonly settings?: Settings
}

/** localStorage contents for `memoryStore`. */
export const storedPrefs = ({ accountId: id, paired, settings }: StoredPrefs = {}): Record<string, string> => ({
  ...(id === undefined ? {} : { "psrp.accountId": id }),
  ...(paired === undefined ? {} : { "psrp.consoles": JSON.stringify(Object.fromEntries(paired.map((p) => [p.hostId, p]))) }),
  ...(settings === undefined ? {} : { "psrp.settings": JSON.stringify(settings) }),
})

export const prefsLayer = (prefs: StoredPrefs = {}) => PreferencesLive.pipe(Layer.provide(memoryStore(storedPrefs(prefs))))

export const testRuntime = (core: FakeCore, prefs: StoredPrefs = {}): AppRuntime =>
  makeAppRuntime(Layer.mergeAll(core.layer, prefsLayer(prefs)))

export const renderApp = (core: FakeCore, prefs: StoredPrefs = {}) => {
  const runtime = testRuntime(core, prefs)
  return {
    runtime,
    ...render(
      <RuntimeProvider runtime={runtime}>
        <App />
      </RuntimeProvider>,
    ),
  }
}
