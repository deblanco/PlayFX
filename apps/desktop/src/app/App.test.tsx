import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Effect } from "effect"
import { toast } from "sonner"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoreError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { defaultSettings } from "@/core/schema"
import { cursorIdleMs, hudIdleMs } from "./StreamView"
import { useRuntime } from "./runtime"
import { accountId, credentials, fakeCore, pairedPs5, picture, ps5, renderApp, status } from "./testing"

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
    core.state.psnSignedIn = true // the native side kept the tokens
    act(() => {
      core.emitPsn({ accountId })
    })
    expect(await screen.findByText(`(${accountId})`)).toBeInTheDocument()
    expect(await screen.findByText(/Internet play is on/)).toBeInTheDocument()
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
    // A pasted ID pairs, but internet play needs the real sign-in.
    await userEvent.click(screen.getByRole("button", { name: "sign in with PlayStation" }))
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

  it("Play wakes a console in rest mode, then streams once it's ready", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, state: "standby" }]
    renderApp(core, { paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    expect(core.service.wakeup).toHaveBeenCalledWith(credentials)
    expect(item.getByRole("button", { name: "Waking…" })).toBeDisabled()
    expect(core.service.startStream).not.toHaveBeenCalled()
    core.state.discovered = [ps5]
    await waitFor(
      () => {
        expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.objectContaining({ height: 1080 }), undefined)
      },
      { timeout: 3000 },
    )
    expect(await screen.findByRole("button", { name: "Stop" })).toBeInTheDocument()
  })

  it("plays a console away from home over the internet, showing the setup steps", async () => {
    const core = fakeCore()
    core.state.discovered = [] // not on this network
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    expect(await item.findByText("internet")).toBeInTheDocument()
    expect(item.getByText(/over the internet/)).toBeInTheDocument()
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), "aa")
    const hud = await screen.findByRole("banner")
    expect(hud).toHaveTextContent("Reaching your PS5 over the internet…")
    act(() => {
      core.emitStream({ type: "remoteProgress", stage: "data" })
    })
    expect(hud).toHaveTextContent("Opening the data connection…")
    act(() => {
      core.emitStream({ type: "remoteProgress", stage: "connected" })
      core.emitStream({ type: "connected" })
    })
    expect(hud).not.toHaveTextContent("over the internet")

    // A drop reconnects over the internet too.
    vi.mocked(core.service.startStream).mockClear()
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
    })
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), "aa")
    })
  })

  it("can cancel waking, and reports a wake-up that couldn't be sent", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, state: "standby" }]
    renderApp(core, { paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    await userEvent.click(item.getByRole("button", { name: "Cancel" }))
    expect(item.getByRole("button", { name: "Play" })).toBeEnabled()
    core.state.discovered = [ps5]
    await new Promise((resolve) => setTimeout(resolve, 1500))
    expect(core.service.startStream).not.toHaveBeenCalled()

    core.state.discovered = [{ ...ps5, state: "standby" }]
    await waitFor(() => {
      expect(item.getByRole("button", { name: "Wake" })).toBeInTheDocument()
    }, { timeout: 7000 })
    vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    expect(await screen.findByText("Wake-up failed")).toBeInTheDocument()
    expect(item.getByRole("button", { name: "Play" })).toBeEnabled()
  }, 15_000)

  it("forgets a console", async () => {
    renderApp(fakeCore(), { paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Forget" }))
    expect(await item.findByRole("button", { name: "Pair" })).toBeInTheDocument()
    expect(item.queryByRole("button", { name: "Play" })).not.toBeInTheDocument()
  })
})

/** Opens the settings sheet from the home screen or the HUD, on the given tab. */
const openSettings = async (tab: "Picture" | "Stream") => {
  await userEvent.click(screen.getByRole("button", { name: /Settings/ }))
  const sheet = await screen.findByRole("dialog", { name: "Settings" })
  await userEvent.click(within(sheet).getByRole("tab", { name: tab }))
  return within(sheet)
}

/** Moves the slider named `name` with the keyboard. */
const nudge = (name: string, key: "ArrowRight" | "ArrowLeft", times = 1) => {
  const slider = screen.getByRole("slider", { name })
  for (let i = 0; i < times; i++) fireEvent.keyDown(slider, { key })
}

const savedSettings = (runtime: ReturnType<typeof renderApp>["runtime"]) =>
  runtime.runPromise(Effect.gen(function* () {
    const prefs = yield* Preferences
    return yield* prefs.settings
  }))

describe("settings", () => {
  it("summarizes the stream settings and edits them in the sheet", async () => {
    const core = fakeCore()
    const { runtime } = renderApp(core, { settings: { ...defaultSettings, height: 720 } })
    expect(await screen.findByText("720p · 60 fps · HEVC · auto bitrate")).toBeInTheDocument()
    const sheet = await openSettings("Stream")
    expect(sheet.getByText("Changes apply the next time you connect.")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("radio", { name: "540p" }))
    await userEvent.click(sheet.getByRole("radio", { name: "540p" })) // re-clicking keeps it selected
    await userEvent.click(sheet.getByRole("radio", { name: "30 fps" }))
    await userEvent.click(sheet.getByRole("radio", { name: "H.264" }))
    nudge("Bitrate", "ArrowRight", 5)
    expect(sheet.getByText("40 Mbps")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("switch", { name: /Lower resolution/ }))
    await userEvent.click(sheet.getByRole("switch", { name: "Sound" }))
    expect(sheet.queryByRole("status")).not.toBeInTheDocument() // nothing to reconnect at home
    await waitFor(async () => {
      expect(await savedSettings(runtime)).toEqual({
        ...defaultSettings,
        height: 540,
        fps: 30,
        hevc: false,
        bitrate: 40000,
        autoDowngrade: false,
        audio: false,
      })
    })
    expect(screen.getByText("540p · 30 fps · H.264 · 40 Mbps")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Reset stream" }))
    await waitFor(async () => {
      expect(await savedSettings(runtime)).toEqual(defaultSettings)
    })
    await userEvent.click(sheet.getByRole("radio", { name: "60 fps" }))
    await userEvent.click(sheet.getByRole("radio", { name: "1080p" }))
    await userEvent.click(sheet.getByRole("radio", { name: "HEVC" }))
  })

  it("applies picture settings live and shows them along the pipeline", async () => {
    const core = fakeCore()
    const { runtime } = renderApp(core)
    await waitFor(() => {
      expect(core.service.setRenderParams).toHaveBeenCalledWith(picture())
    })
    const sheet = await openSettings("Picture")
    expect(sheet.getByText("Changes show on the video right away.")).toBeInTheDocument()
    expect(sheet.queryByRole("switch", { name: "Split screen" })).not.toBeInTheDocument() // only while streaming
    const pipeline = within(sheet.getByRole("navigation", { name: "Picture pipeline" }))

    await userEvent.click(sheet.getByRole("radio", { name: "Bilinear" }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ upscaler: "bilinear" }))
    nudge("Sharpness", "ArrowRight")
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ upscaler: "bilinear", sharpness: 0.35 }))
    nudge("Blockiness", "ArrowRight", 2)
    nudge("Banding", "ArrowRight")
    await userEvent.click(sheet.getByRole("radio", { name: "Vivid" }))
    await userEvent.click(sheet.getByRole("radio", { name: "Smooth" }))
    await userEvent.click(sheet.getByRole("button", { name: "For unusual streams" }))
    await userEvent.click(sheet.getByRole("radio", { name: "601" }))
    await userEvent.click(sheet.getByRole("radio", { name: "Full" }))
    const tuned = picture({
      upscaler: "bilinear",
      sharpness: 0.35,
      deblock: 0.1,
      deband: 0.05,
      accurateColor: false,
      chroma: "bilinear",
      colorMatrix: "bt601",
      colorRange: "full",
    })
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(tuned)
    expect(pipeline.getAllByRole("listitem").map((item) => item.textContent)).toEqual([
      "Clean up10%",
      "UpscaleBilinear",
      "Sharpen35%",
      "ColorVivid",
    ])
    await waitFor(async () => {
      expect(await savedSettings(runtime)).toEqual({ ...defaultSettings, ...tuned })
    })

    // A pipeline stage jumps to its controls.
    await userEvent.click(pipeline.getByRole("button", { name: /Sharpen/ }))
    expect(sheet.getByRole("heading", { name: /Sharpen/ })).toHaveFocus()

    await userEvent.click(sheet.getByRole("button", { name: "Reset picture" }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture())
    await userEvent.click(sheet.getByRole("radio", { name: "Accurate" }))
    await userEvent.click(sheet.getByRole("radio", { name: "Sharp" }))
    await userEvent.click(sheet.getByRole("radio", { name: "MetalFX" }))
    await userEvent.click(within(sheet.getByRole("radiogroup", { name: "Color matrix" })).getByRole("radio", { name: "Auto" }))
    await userEvent.click(within(sheet.getByRole("radiogroup", { name: "Color range" })).getByRole("radio", { name: "Auto" }))
    nudge("Sharpness", "ArrowLeft", 10)
    expect(pipeline.getByRole("button", { name: /Sharpen/ })).toHaveTextContent("Off")
    await userEvent.click(sheet.getByRole("button", { name: "Close" }))
    expect(screen.queryByRole("dialog", { name: "Settings" })).not.toBeInTheDocument()
  })

  it("offers ML upscaling where the Mac supports it", async () => {
    const core = fakeCore()
    core.state.status = { ...status(), mlSupported: true }
    renderApp(core, { settings: { ...defaultSettings, height: 720 } })
    await waitFor(() => {
      expect(core.service.setRenderParams).toHaveBeenCalled()
    })
    const sheet = await openSettings("Picture")
    await userEvent.click(sheet.getByRole("switch", { name: /ML upscaling first/ }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ mlUpscale: true }))
    const pipeline = within(sheet.getByRole("navigation", { name: "Picture pipeline" }))
    expect(pipeline.getByRole("button", { name: /Upscale/ })).toHaveTextContent("ML + MetalFX")
  })

  it("disables MetalFX when the GPU doesn't support it", async () => {
    const core = fakeCore()
    core.state.status = status({}, false)
    renderApp(core)
    await waitFor(() => {
      expect(core.service.setRenderParams).toHaveBeenCalled()
    })
    const sheet = await openSettings("Picture")
    await waitFor(() => {
      expect(sheet.getByRole("radio", { name: "MetalFX" })).toBeDisabled()
    })
    expect(sheet.getByText("MetalFX isn't available on this Mac.")).toBeInTheDocument()
    expect(sheet.getByRole("switch", { name: /ML upscaling first/ })).toBeDisabled()
    expect(sheet.getByText("Needs macOS 26 on a supported Mac.")).toBeInTheDocument()
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
      autoDowngrade: true,
    }, undefined)
    expect(screen.queryByText("Consoles")).not.toBeInTheDocument()
    expect(screen.getByText("Living Room")).toBeInTheDocument()
    expect(await screen.findByText(/^1920×1080 · \d+ fps · [\d.]+ Mbps · MetalFX$/)).toBeInTheDocument()
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
    // Going home brings back the idle picture (the renderer kept the last frame after the quit).
    await waitFor(() => {
      expect(core.counts.stopStream).toBe(1)
    })
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

  it("tunes the picture from the HUD with a labelled split screen", async () => {
    const { core } = await startStreaming()
    expect(screen.queryByLabelText("Split-screen comparison")).not.toBeInTheDocument()
    const sheet = await openSettings("Picture")
    await userEvent.click(sheet.getByRole("switch", { name: /Split screen/ }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ compare: true }))
    const labels = screen.getByLabelText("Split-screen comparison")
    expect(labels).toHaveTextContent("Original")
    expect(labels).toHaveTextContent("Enhanced")
    // The keyboard drives the settings, not the console, while they're open.
    vi.mocked(core.service.setController).mockClear()
    fireEvent.keyDown(window, { code: "ArrowUp" })
    expect(core.service.setController).not.toHaveBeenCalled()
  })

  it("reconnects to apply new stream settings, waiting out a busy console", async () => {
    const { core } = await startStreaming()
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")
    expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    await userEvent.click(sheet.getByRole("radio", { name: "720p" }))
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnect to use the new stream settings.")
    expect(screen.getByLabelText("Reconnect to apply")).toBeInTheDocument()

    await userEvent.click(sheet.getByRole("button", { name: "Reconnect" }))
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnecting…")
    expect(screen.getByRole("banner")).toHaveTextContent("Reconnecting…")
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.objectContaining({ height: 720 }), undefined)
    })
    expect(core.counts.stopStream).toBe(0) // the new session replaces the old one
    // The old session's quit and a busy console don't end the stream view.
    act(() => {
      core.emitStream({ type: "quit", reason: "Stopped", error: false, kind: "stopped" })
    })
    expect(screen.getByRole("banner")).toHaveTextContent("Reconnecting…")
    act(() => {
      core.emitStream({ type: "quit", reason: "Remote Play on Console is already in use", error: true, kind: "busy" })
    })
    expect(screen.getByRole("banner")).toHaveTextContent("Reconnecting…")
    await waitFor(
      () => {
        expect(core.service.startStream).toHaveBeenCalledTimes(2) // retried after the busy answer
      },
      { timeout: 3000 },
    )
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    })
    expect(screen.queryByText(/Disconnected/)).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Reconnect to apply")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Stop" })).toBeInTheDocument()
  })

  it("reconnects on its own when the connection drops, keeping the stream view", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "connected" })
    })
    vi.mocked(core.service.startStream).mockClear()
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
    })
    expect(screen.getByRole("banner")).toHaveTextContent("Connection lost. Reconnecting…")
    expect(screen.queryByText(/Disconnected/)).not.toBeInTheDocument()
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(screen.getByRole("banner")).not.toHaveTextContent("Reconnecting")
    })
    expect(screen.getByRole("button", { name: "Stop" })).toBeInTheDocument()
  })

  it("gives up after repeated drops and goes home with the reason", async () => {
    const { core } = await startStreaming()
    const drop = () => {
      act(() => {
        core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
      })
    }
    act(() => {
      core.emitStream({ type: "connected" })
    })
    for (let i = 1; i <= 3; i++) {
      drop()
      await waitFor(() => {
        expect(core.service.startStream).toHaveBeenCalledTimes(1 + i)
      })
      act(() => {
        core.emitStream({ type: "connected" })
      })
      await waitFor(() => {
        expect(screen.getByRole("banner")).not.toHaveTextContent("Reconnecting")
      })
    }
    drop()
    expect(await screen.findByText("Disconnected: Stream Connection Unknown")).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
  })

  it("cancels a reconnect in progress when the user stops", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "connected" })
    })
    vi.mocked(core.service.startStream).mockClear()
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
    })
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
    act(() => {
      core.emitStream({ type: "quit", reason: "in use", error: true, kind: "busy" }) // retry scheduled…
    })
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 1800)) // …past the retry delay: nothing restarts
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/Reconnect failed/)).not.toBeInTheDocument()
  })

  it("waits out a console that's still busy when the stream starts", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "quit", reason: "Remote Play on Console is already in use", error: true, kind: "busy" })
    })
    expect(screen.getByRole("banner")).toHaveTextContent("Waiting for the console…")
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(2)
    })
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(screen.getByRole("banner")).not.toHaveTextContent("Waiting")
    })
    expect(screen.queryByText(/Disconnected/)).not.toBeInTheDocument()
  })

  it("doesn't retry a drop before the stream ever connected", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
    })
    expect(await screen.findByText("Disconnected: Stream Connection Unknown")).toBeInTheDocument()
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
  })

  it("goes home with the error when a reconnect fails", async () => {
    const { core } = await startStreaming()
    const sheet = await openSettings("Stream")
    await userEvent.click(sheet.getByRole("radio", { name: "30 fps" }))
    await userEvent.click(sheet.getByRole("button", { name: "Reconnect" }))
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(2)
    })
    act(() => {
      core.emitStream({ type: "quit", reason: "Version mismatch", error: true })
    })
    expect(await screen.findByText("Reconnect failed: Version mismatch")).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
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

  it("hides the cursor after 5 s without mouse movement, but not while the settings are open", async () => {
    await startStreaming()
    const html = document.documentElement
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    fireEvent.mouseMove(window)
    act(() => {
      vi.advanceTimersByTime(cursorIdleMs - 1)
    })
    expect(html).not.toHaveClass("cursor-none")
    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(html).toHaveClass("cursor-none")
    fireEvent.mouseMove(window) // any movement brings it back
    expect(html).not.toHaveClass("cursor-none")
    vi.useRealTimers()

    await userEvent.click(screen.getByRole("button", { name: /Settings/ }))
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    act(() => {
      vi.advanceTimersByTime(cursorIdleMs * 2)
    })
    expect(html).not.toHaveClass("cursor-none")
  })

  it("toggles fullscreen from the HUD and by double-clicking the video", async () => {
    const { core } = await startStreaming()
    await userEvent.click(screen.getByRole("button", { name: "Fullscreen" }))
    expect(await screen.findByRole("button", { name: "Exit fullscreen" })).toBeInTheDocument()
    expect(core.state.fullscreen).toBe(true)
    fireEvent.doubleClick(document.body) // the video area
    expect(await screen.findByRole("button", { name: "Fullscreen" })).toBeInTheDocument()
    fireEvent.doubleClick(screen.getByRole("banner")) // the HUD itself: no toggle
    expect(core.state.fullscreen).toBe(false)
  })

  it("leaves the cursor visible once the stream view is gone", async () => {
    await startStreaming()
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    fireEvent.mouseMove(window) // restart the idle timer under fake time
    act(() => {
      vi.advanceTimersByTime(cursorIdleMs)
    })
    expect(document.documentElement).toHaveClass("cursor-none")
    vi.useRealTimers()
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(document.documentElement).not.toHaveClass("cursor-none")
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
