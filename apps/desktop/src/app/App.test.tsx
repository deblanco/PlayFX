import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Effect } from "effect"
import { toast } from "sonner"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoreError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { defaultSettings } from "@/core/schema"
import { hudIdleMs } from "./StreamView"
import { useRuntime } from "./runtime"
import { accountId, credentials, fakeCore, pairedPs5, ps5, renderApp, status } from "./testing"

const coreError = (command: string, message: string) => new CoreError({ command, message })

const consoleItem = async (name = "Living Room") => {
  const consoles = await screen.findByRole("region", { name: "Consoles" })
  const item = (await within(consoles).findByText(name)).closest("li")
  if (!item) throw new Error(`no console item ${name}`)
  return within(item)
}

/** Renders the app with a paired, ready console and starts streaming it. */
const startStreaming = async (core = fakeCore()) => {
  const app = renderApp(core, { accountId, paired: [pairedPs5] })
  const item = await consoleItem()
  await userEvent.click(item.getByRole("button", { name: "Play" }))
  await screen.findByRole("button", { name: "Stop" })
  await waitFor(() => {
    expect(core.streamListeners()).toBe(1)
  })
  return { ...app, core }
}

afterEach(() => {
  vi.useRealTimers()
  toast.dismiss()
})

describe("runtime context", () => {
  it("requires a RuntimeProvider", () => {
    const Probe = () => {
      useRuntime()
      return null
    }
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    expect(() => render(<Probe />)).toThrow(/RuntimeProvider/)
  })
})

describe("home: discovery", () => {
  it("lists discovered consoles with status and meta", async () => {
    const core = fakeCore()
    renderApp(core)
    const item = await consoleItem()
    expect(item.getByText("ready")).toBeInTheDocument()
    expect(item.getByText("PS5 · 192.168.0.40 · Astro Bot")).toBeInTheDocument()
    expect(item.getByRole("button", { name: "Pair" })).toBeDisabled()
    expect(item.getByRole("button", { name: "Pair" })).toHaveAttribute("title", "Sign in first")
    expect(core.counts.discover).toBeGreaterThan(0)
  })

  it("says when no consoles are found", async () => {
    const core = fakeCore()
    core.state.discovered = []
    renderApp(core)
    expect(await screen.findByText("No consoles found on this network")).toBeInTheDocument()
  })

  it("reports discovery failures but still lists paired consoles as offline", async () => {
    const core = fakeCore({ discover: Effect.fail(coreError("discover", "no network")) })
    renderApp(core, { paired: [pairedPs5] })
    expect(await screen.findByText("Discovery failed: no network")).toBeInTheDocument()
    const item = await consoleItem()
    expect(item.getByText("offline")).toBeInTheDocument()
    expect(item.getByRole("button", { name: "Play" })).toBeDisabled()
  })
})

describe("home: PSN account", () => {
  it("signs in with PlayStation", async () => {
    const core = fakeCore()
    renderApp(core)
    await userEvent.click(await screen.findByRole("button", { name: "Sign in with PlayStation" }))
    expect(core.counts.psnLogin).toBe(1)
    await waitFor(() => {
      expect(core.psnListeners()).toBe(1)
    })
    act(() => {
      core.emitPsn({ error: "denied" })
    })
    expect(await screen.findByText("PSN sign-in failed: denied")).toBeInTheDocument()
    act(() => {
      core.emitPsn({ accountId })
    })
    expect(await screen.findByText(`(${accountId})`)).toBeInTheDocument()
    const item = await consoleItem()
    expect(item.getByRole("button", { name: "Pair" })).toBeEnabled()
  })

  it("treats a corrupt stored account ID as signed out", async () => {
    renderApp(fakeCore(), { accountId: "abc" })
    expect(await screen.findByRole("button", { name: "Sign in with PlayStation" })).toBeInTheDocument()
    expect(screen.queryByText(/PSN account linked/)).not.toBeInTheDocument()
    const item = await consoleItem()
    expect(item.getByRole("button", { name: "Pair" })).toBeDisabled()
  })

  it("shows sign-in failures from the native side", async () => {
    renderApp(fakeCore({ psnLogin: Effect.fail(coreError("psn_login", "window failed")) }))
    await userEvent.click(await screen.findByRole("button", { name: "Sign in with PlayStation" }))
    expect(await screen.findByText("window failed")).toBeInTheDocument()
  })

  it("accepts a pasted account ID, rejects bad ones, and signs out", async () => {
    const { runtime } = renderApp(fakeCore())
    const input = await screen.findByLabelText("Account ID")
    await userEvent.type(input, "not-an-id")
    await userEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(await screen.findByText(/8 bytes in base64/)).toBeInTheDocument()
    await userEvent.clear(input)
    await userEvent.type(input, accountId)
    await userEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(await screen.findByText(/PSN account linked/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Sign out" }))
    expect(await screen.findByRole("button", { name: "Sign in with PlayStation" })).toBeInTheDocument()
    const stored = await runtime.runPromise(Preferences.use((prefs) => prefs.accountId))
    expect(stored._tag).toBe("None")
  })
})

describe("home: pairing", () => {
  const openPairForm = async (core = fakeCore()) => {
    renderApp(core, { accountId })
    const item = await consoleItem()
    await userEvent.click(item.getByRole("button", { name: "Pair" }))
    expect(screen.getByText("On the PS5: Settings → System → Remote Play → Pair Device")).toBeInTheDocument()
    const form = within(screen.getByRole("form", { name: "Pair Living Room" }))
    fireEvent.change(screen.getByLabelText("On the PS5: Settings → System → Remote Play → Pair Device"), {
      target: { value: "12345678" },
    })
    return { core, form }
  }

  it("pairs with the PIN and offers Play", async () => {
    const { core, form } = await openPairForm()
    await userEvent.click(form.getByRole("button", { name: "Pair" }))
    expect(core.service.pair).toHaveBeenCalledWith({ console: ps5, accountId, pin: "12345678" })
    expect(await screen.findByText("Paired with Living Room")).toBeInTheDocument()
    const item = await consoleItem()
    expect(item.getByText("PS5 · 192.168.0.40 · Astro Bot · paired")).toBeInTheDocument()
    expect(item.getByRole("button", { name: "Play" })).toBeEnabled()
    expect(screen.queryByRole("form", { name: "Pair Living Room" })).not.toBeInTheDocument()
  })

  it("shows pairing errors and lets the user retry or cancel", async () => {
    const core = fakeCore({ pair: () => Effect.fail(coreError("register_console", "Wrong PIN")) })
    const { form } = await openPairForm(core)
    await userEvent.click(form.getByRole("button", { name: "Pair" }))
    expect(await screen.findByText("Wrong PIN")).toBeInTheDocument()
    await waitFor(() => {
      expect(form.getByRole("button", { name: "Pair" })).toBeEnabled()
    })
    await userEvent.click(form.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("form", { name: "Pair Living Room" })).not.toBeInTheDocument()
  })
})

describe("home: paired consoles", () => {
  it("wakes a console in standby", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, state: "standby" }]
    renderApp(core, { paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Wake" }))
    expect(core.service.wakeup).toHaveBeenCalledWith(credentials)
    expect(await screen.findByText("Wake-up sent; the console takes ~20 s to start.")).toBeInTheDocument()
    vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
    await userEvent.click(item.getByRole("button", { name: "Wake" }))
    expect(await screen.findByText("Wake-up failed")).toBeInTheDocument()
  })

  it("forgets a console", async () => {
    renderApp(fakeCore(), { paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Forget" }))
    expect(await item.findByRole("button", { name: "Pair" })).toBeInTheDocument()
    expect(item.queryByRole("button", { name: "Play" })).not.toBeInTheDocument()
  })
})

describe("settings", () => {
  it("applies the saved upscaler on load and persists changes", async () => {
    const core = fakeCore()
    const { runtime } = renderApp(core, { settings: { ...defaultSettings, height: 720 } })
    const resolution = await screen.findByLabelText("Resolution")
    await waitFor(() => {
      expect(resolution).toHaveValue("720")
    })
    expect(core.service.setUpscaler).toHaveBeenCalledWith("metalfx")
    await userEvent.selectOptions(resolution, "540")
    await userEvent.selectOptions(screen.getByLabelText("FPS"), "30")
    await userEvent.selectOptions(screen.getByLabelText("Codec"), "h264")
    await userEvent.selectOptions(screen.getByLabelText("Upscaler"), "bilinear")
    expect(core.service.setUpscaler).toHaveBeenLastCalledWith("bilinear")
    await waitFor(async () => {
      const saved = await runtime.runPromise(Preferences.use((prefs) => prefs.settings))
      expect(saved).toEqual({ height: 540, fps: 30, hevc: false, upscaler: "bilinear" })
    })
  })

  it("disables MetalFX when the GPU doesn't support it", async () => {
    const core = fakeCore()
    core.state.status = status({}, false)
    renderApp(core)
    const option = await screen.findByRole("option", { name: "MetalFX" })
    await waitFor(() => {
      expect(option).toBeDisabled()
    })
  })

  it("toasts startup failures", async () => {
    renderApp(fakeCore({ rendererStatus: Effect.fail(coreError("renderer_status", "no renderer")) }))
    expect(await screen.findByText("no renderer")).toBeInTheDocument()
  })
})

describe("streaming", () => {
  it("plays: hides the card and shows the HUD with live stats", async () => {
    const core = fakeCore()
    core.state.status = status({ width: 1920, height: 1080, framesDecoded: 0 })
    await startStreaming(core)
    expect(core.service.startStream).toHaveBeenCalledWith(credentials, {
      height: 1080,
      fps: 60,
      hevc: true,
      bitrate: 0,
      audio: true,
    })
    expect(screen.queryByText("Consoles")).not.toBeInTheDocument()
    expect(screen.getByText("Living Room")).toBeInTheDocument()
    expect(await screen.findByText(/^1920×1080 · \d+ fps · MetalFX$/)).toBeInTheDocument()
  })

  it("stays home when the stream can't start", async () => {
    const core = fakeCore({ startStream: () => Effect.fail(coreError("start_stream", "busy")) })
    renderApp(core, { accountId, paired: [pairedPs5] })
    await userEvent.click((await consoleItem()).getByRole("button", { name: "Play" }))
    expect(await screen.findByText("busy")).toBeInTheDocument()
    expect(screen.getByText("Consoles")).toBeInTheDocument()
  })

  it("renames the HUD on nickname and returns home on quit with an error", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "connected" })
      core.emitStream({ type: "nickname", name: "Den PS5" })
    })
    expect(await screen.findByText("Den PS5")).toBeInTheDocument()
    act(() => {
      core.emitStream({ type: "quit", reason: "Network timeout", error: true })
    })
    expect(await screen.findByText("Disconnected: Network timeout")).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    // The app keeps listening for the next stream.
    expect(core.streamListeners()).toBe(1)
  })

  it("shows the login PIN prompt when the console asks before start_stream replies", async () => {
    const core = fakeCore()
    vi.mocked(core.service.startStream).mockImplementation(() =>
      Effect.sync(() => {
        core.emitStream({ type: "nickname", name: "Den PS5" })
        core.emitStream({ type: "loginPin", incorrect: false })
      }),
    )
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    expect(screen.getByText("Den PS5")).toBeInTheDocument()
  })

  it("reports a quit that arrives before start_stream replies and stays home", async () => {
    const core = fakeCore()
    vi.mocked(core.service.startStream).mockImplementation(() =>
      Effect.sync(() => {
        core.emitStream({ type: "quit", reason: "RP_IN_USE", error: true })
      }),
    )
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    expect(await screen.findByText("Disconnected: RP_IN_USE")).toBeInTheDocument()
    expect(screen.getByText("Consoles")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Stop" })).not.toBeInTheDocument()
  })

  it("ignores events while no stream is running", async () => {
    const core = fakeCore()
    renderApp(core, { accountId, paired: [pairedPs5] })
    await consoleItem()
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    act(() => {
      core.emitStream({ type: "nickname", name: "Den PS5" })
      core.emitStream({ type: "loginPin", incorrect: false })
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(screen.queryByText("Den PS5")).not.toBeInTheDocument()
  })

  it("returns home quietly on a normal quit", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "quit", reason: "Stopped", error: false })
    })
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(screen.queryByText(/Disconnected/)).not.toBeInTheDocument()
  })

  it("asks for the login PIN and sends it", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "loginPin", incorrect: false })
    })
    const dialog = within(await screen.findByRole("dialog"))
    expect(dialog.getByText("Enter the console's login PIN.")).toBeInTheDocument()
    await userEvent.type(dialog.getByLabelText("Login PIN"), "12")
    await userEvent.click(dialog.getByRole("button", { name: "Send" }))
    expect(await screen.findByText("The login PIN has 4 digits")).toBeInTheDocument()
    await userEvent.type(dialog.getByLabelText("Login PIN"), "34")
    await userEvent.click(dialog.getByRole("button", { name: "Send" }))
    expect(core.service.setLoginPin).toHaveBeenCalledWith("1234")
    await waitFor(() => {
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    })
  })

  it("says when the login PIN was wrong and can stop instead", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "loginPin", incorrect: true })
    })
    const dialog = within(await screen.findByRole("dialog"))
    expect(dialog.getByText("Wrong PIN. Enter the console's login PIN.")).toBeInTheDocument()
    await userEvent.click(dialog.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(core.counts.stopStream).toBe(1)
  })

  it("stops the stream from the HUD, even if stopping fails", async () => {
    const { core } = await startStreaming(fakeCore({ stopStream: Effect.fail(coreError("stop_stream", "already gone")) }))
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("already gone")).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(core.streamListeners()).toBe(1)
  })

  it("changes the upscaler from the HUD", async () => {
    const { core } = await startStreaming()
    await userEvent.selectOptions(screen.getByLabelText("Upscaler"), "bilinear")
    expect(core.service.setUpscaler).toHaveBeenLastCalledWith("bilinear")
    expect(screen.queryByLabelText("Upscaler comparison")).not.toBeInTheDocument()
  })

  it("labels the halves of the split-screen comparison", async () => {
    const { core } = await startStreaming()
    await userEvent.selectOptions(screen.getByLabelText("Upscaler"), "compare")
    expect(core.service.setUpscaler).toHaveBeenLastCalledWith("compare")
    const labels = screen.getByLabelText("Upscaler comparison")
    expect(labels).toHaveTextContent("Bilinear")
    expect(labels).toHaveTextContent("MetalFX")
  })

  it("fades the HUD after 2.5 s without mouse movement", async () => {
    await startStreaming()
    const hud = screen.getByRole("banner")
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    fireEvent.mouseMove(window)
    expect(hud).toHaveAttribute("data-idle", "false")
    act(() => {
      vi.advanceTimersByTime(hudIdleMs - 1)
    })
    expect(hud).toHaveAttribute("data-idle", "false")
    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(hud).toHaveAttribute("data-idle", "true")
    fireEvent.mouseMove(window)
    expect(hud).toHaveAttribute("data-idle", "false")
  })
})

describe("subscription failures", () => {
  it("toasts when a native event can't be subscribed", async () => {
    renderApp(fakeCore({ onPsnAccount: () => Effect.fail(coreError("listen:psn-account", "no ipc")) }))
    expect(await screen.findByText("no ipc")).toBeInTheDocument()
  })
})

describe("keyboard controller", () => {
  it("forwards pressed keys to the console and releases on key up", async () => {
    const { core } = await startStreaming()
    const dpadUp = 1 << 6

    fireEvent.keyDown(window, { code: "ArrowUp" })
    await waitFor(() => {
      expect(core.service.setController).toHaveBeenCalled()
    })
    const pressed = vi.mocked(core.service.setController).mock.lastCall?.[0]
    expect(pressed && pressed.buttons & dpadUp).toBe(dpadUp)

    fireEvent.keyUp(window, { code: "ArrowUp" })
    await waitFor(() => {
      const released = vi.mocked(core.service.setController).mock.lastCall?.[0]
      expect(released?.buttons).toBe(0)
    })
  })

  it("does not capture keys while the login PIN dialog is open", async () => {
    const core = fakeCore()
    await startStreaming(core)
    act(() => {
      core.emitStream({ type: "loginPin", incorrect: false })
    })
    await screen.findByRole("dialog")
    vi.mocked(core.service.setController).mockClear()
    fireEvent.keyDown(window, { code: "ArrowUp" })
    expect(core.service.setController).not.toHaveBeenCalled()
  })
})
