import { act, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Deferred, Effect } from "effect"
import { toast } from "sonner"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoreError } from "@/core/errors"
import type { PeerWifiReply } from "@/core/schema"
import * as actions from "./actions"
import { RuntimeProvider } from "./runtime"
import { LinkLine, linkPath, PeerWifiProvider, showsSteadyWifi, SteadyWifiRow, SteadyWifiSection } from "./SteadyWifi"
import { accountId, fakeCore, pairedPs5, renderApp, testRuntime, type FakeCore } from "./testing"

const renderWith = (core: FakeCore, element: React.ReactNode) =>
  render(
    <RuntimeProvider runtime={testRuntime(core)}>
      <PeerWifiProvider>{element}</PeerWifiProvider>
    </RuntimeProvider>,
  )

const steadySwitch = () => screen.getByRole("switch")

afterEach(() => {
  vi.restoreAllMocks()
})

describe("Steady Wi-Fi", () => {
  it("shows the stall on Home and pauses AirDrop and Handoff when switched on", async () => {
    const core = fakeCore()
    renderApp(core, { accountId, paired: [pairedPs5] })
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    const row = screen.getByText("Wi-Fi hiccups every second").closest("div")?.parentElement
    if (!row) throw new Error("no row")
    const toggle = within(row).getByRole("switch")
    expect(toggle).not.toBeChecked()
    await userEvent.click(toggle)
    expect(core.service.setPeerWifiPaused).toHaveBeenCalledWith(true)
    expect(await screen.findByText("Steady Wi-Fi")).toBeInTheDocument()
    expect(within(row).getByRole("switch")).toBeChecked()
    expect(screen.getByText("AirDrop and Handoff are paused until you turn this off or quit PlayFX.")).toBeInTheDocument()
    // And back.
    await userEvent.click(within(row).getByRole("switch"))
    expect(core.service.setPeerWifiPaused).toHaveBeenLastCalledWith(false)
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
  })

  it("says it's waiting while macOS asks for the password, and changes nothing if the prompt is closed", async () => {
    const answer = Effect.runSync(Deferred.make<PeerWifiReply>())
    const core = fakeCore({ setPeerWifiPaused: vi.fn(() => Deferred.await(answer)) })
    renderWith(core, <SteadyWifiRow />)
    await userEvent.click(await screen.findByRole("switch"))
    expect(await screen.findByText("Waiting for your password")).toBeInTheDocument()
    expect(steadySwitch()).toBeDisabled()
    const cancelled: PeerWifiReply = { state: "active", outcome: "cancelled" }
    Effect.runSync(Deferred.succeed(answer, cancelled))
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    await waitFor(() => { expect(steadySwitch()).toBeEnabled() })
    expect(steadySwitch()).not.toBeChecked()
  })

  it("keeps Home and Settings in step, and ignores readings while the prompt is open", async () => {
    const answer = Effect.runSync(Deferred.make<PeerWifiReply>())
    const core = fakeCore({ setPeerWifiPaused: vi.fn(() => Deferred.await(answer)) })
    renderWith(
      core,
      <>
        <SteadyWifiRow />
        <SteadyWifiSection />
      </>,
    )
    await waitFor(() => { expect(screen.getAllByRole("switch")).toHaveLength(2) })
    const [row, section] = screen.getAllByRole("switch")
    if (!row || !section) throw new Error("no switches")
    await userEvent.click(section)
    // A pause started in Settings disables the Home switch too.
    await waitFor(() => { expect(row).toBeDisabled() })
    // Meanwhile a reading says "paused" (macOS sees the marker): the switches don't move.
    core.state.peerWifi = "paused"
    await Effect.runPromise(Effect.sleep("3100 millis"))
    expect(row).not.toBeChecked()
    expect(screen.getAllByText("Waiting for your password")).toHaveLength(2)
    const paused: PeerWifiReply = { state: "paused", outcome: "done" }
    Effect.runSync(Deferred.succeed(answer, paused))
    await waitFor(() => { expect(row).toBeChecked() })
    expect(section).toBeChecked()
  }, 10_000)

  it("shows a failure and lets the user try again", async () => {
    const error = vi.spyOn(toast, "error")
    const core = fakeCore({
      setPeerWifiPaused: vi.fn(() => Effect.fail(new CoreError({ command: "set_peer_wifi_paused", message: "Couldn't pause AirDrop and Handoff: boom" }))),
    })
    renderWith(core, <SteadyWifiRow />)
    await userEvent.click(await screen.findByRole("switch"))
    await waitFor(() => { expect(error).toHaveBeenCalledWith("Couldn't pause AirDrop and Handoff: boom") })
    await waitFor(() => { expect(steadySwitch()).toBeEnabled() })
  })

  it("stays out of the way on Home when there's nothing to pause", async () => {
    for (const state of ["off", "absent"] as const) {
      const core = fakeCore()
      core.state.peerWifi = state
      const { unmount, container } = renderWith(core, <SteadyWifiRow />)
      await waitFor(() => { expect(container).toBeEmptyDOMElement() })
      unmount()
    }
  })

  it("explains the trade in Settings, and says so when it's already off", async () => {
    const core = fakeCore()
    const view = renderWith(core, <SteadyWifiSection />)
    expect(await screen.findByText(/stalled for up to 100 ms once a second/)).toBeInTheDocument()
    expect(screen.getByText(/Universal Control and a wireless Sidecar display don't work/)).toBeInTheDocument()
    await userEvent.click(steadySwitch())
    expect(await screen.findByText("Steady Wi-Fi")).toBeInTheDocument()
    view.unmount()

    core.state.peerWifi = "off"
    renderWith(core, <SteadyWifiSection />)
    expect(await screen.findByText("AirDrop and Handoff are already off, so nothing interrupts your Wi-Fi.")).toBeInTheDocument()
    expect(screen.queryByRole("switch")).not.toBeInTheDocument()
  })

  it("leaves Settings alone on a Mac without AirDrop's Wi-Fi", async () => {
    const reads = vi.fn(() => "absent" as const) // counted, to know when the reading has happened
    const { container } = renderWith(fakeCore({ peerWifiStatus: Effect.sync(reads) }), <SteadyWifiSection />)
    await waitFor(() => { expect(reads).toHaveBeenCalled() })
    expect(container).toBeEmptyDOMElement()
  })

  it("draws the link steady or stalling", () => {
    const { container, rerender } = render(<LinkLine steady={false} />)
    const line = container.firstElementChild
    expect(line?.getAttribute("data-steady")).toBe("false")
    // Stalling: the flow halts and surges once a second; steady: it flows evenly.
    expect(container.querySelector("svg:not(.lucide) path")?.getAttribute("class")).toContain("animate-stutter")
    rerender(<LinkLine steady />)
    expect(container.querySelector("svg:not(.lucide) path")?.getAttribute("class")).toContain("animate-flow")
    expect(container.querySelector("svg:not(.lucide) path")?.getAttribute("class")).not.toContain("animate-stutter")
    // A light crosses the link once, along the same path as the line.
    const light = container.querySelector("span")
    expect(light?.getAttribute("style")).toContain(linkPath(96))
  })

  it("follows the link's width", () => {
    expect(linkPath(200)).toBe("M 1 8 C 40 1 60 15 100 8 S 160 1 199 8")
    expect(linkPath(0)).toBe(linkPath(8)) // never collapses
    expect(showsSteadyWifi("active") && showsSteadyWifi("paused")).toBe(true)
    expect(showsSteadyWifi("off") || showsSteadyWifi("absent") || showsSteadyWifi(undefined)).toBe(false)
  })
})

/** Plays the paired console from Home and waits for the stream view; `connected` also reports it up. */
const play = async (core: FakeCore, { connected = false } = {}) => {
  const consoles = await screen.findByRole("region", { name: "Consoles" })
  const item = (await within(consoles).findByText("Living Room")).closest("li")
  if (!item) throw new Error("no console item")
  await userEvent.click(within(item).getByRole("button", { name: "Play" }))
  await screen.findByRole("button", { name: "Stop" })
  if (connected) act(() => { core.emitStream({ type: "connected" }) })
}

const stopStream = async () => {
  await userEvent.click(screen.getByRole("button", { name: "Stop" }))
  await userEvent.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Leave it on" }))
  await screen.findByRole("region", { name: "Consoles" })
}

describe("Steady Wi-Fi, remembered", () => {
  it("remembers the switch being turned on, and forgets it when turned off by hand", async () => {
    const core = fakeCore()
    const { runtime } = renderApp(core, { accountId, paired: [pairedPs5] })
    expect(await runtime.runPromise(actions.loadSteadyWifi)).toBe(false)
    await userEvent.click(await screen.findByRole("switch"))
    await waitFor(() => { expect(screen.getByRole("switch")).toBeChecked() })
    expect(await runtime.runPromise(actions.loadSteadyWifi)).toBe(true)
    await userEvent.click(screen.getByRole("switch"))
    await waitFor(() => { expect(screen.getByRole("switch")).not.toBeChecked() })
    expect(await runtime.runPromise(actions.loadSteadyWifi)).toBe(false)
  })

  it("asks again when a stream starts after a relaunch, and the stream starts meanwhile", async () => {
    const core = fakeCore()
    renderApp(core, { accountId, paired: [pairedPs5], steadyWifi: true })
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    // Not at launch: only when it matters.
    expect(core.service.setPeerWifiPaused).not.toHaveBeenCalled()
    await play(core)
    expect(core.service.startStream).toHaveBeenCalled()
    await waitFor(() => { expect(core.service.setPeerWifiPaused).toHaveBeenCalledExactlyOnceWith(true) })
  })

  it("doesn't ask when it wasn't left on, or when AirDrop and Handoff aren't on", async () => {
    const forgotten = fakeCore()
    const first = renderApp(forgotten, { accountId, paired: [pairedPs5] })
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    await play(forgotten)
    expect(forgotten.service.startStream).toHaveBeenCalled()
    first.unmount()

    const alreadyOff = fakeCore()
    alreadyOff.state.peerWifi = "off"
    renderApp(alreadyOff, { accountId, paired: [pairedPs5], steadyWifi: true })
    await play(alreadyOff)
    expect(alreadyOff.service.startStream).toHaveBeenCalled()
    expect(forgotten.service.setPeerWifiPaused).not.toHaveBeenCalled()
    expect(alreadyOff.service.setPeerWifiPaused).not.toHaveBeenCalled()
  })

  it("doesn't ask again once the prompt was dismissed, and keeps the choice for next time", async () => {
    const cancelled: PeerWifiReply = { state: "active", outcome: "cancelled" }
    const core = fakeCore({ setPeerWifiPaused: vi.fn(() => Effect.succeed(cancelled)) })
    const { runtime } = renderApp(core, { accountId, paired: [pairedPs5], steadyWifi: true })
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    await play(core, { connected: true })
    await waitFor(() => { expect(core.service.setPeerWifiPaused).toHaveBeenCalledOnce() })
    // The stream goes on.
    expect(screen.getByRole("button", { name: "Stop" })).toBeInTheDocument()
    await stopStream()
    await play(core)
    expect(core.service.startStream).toHaveBeenCalledTimes(2)
    expect(core.service.setPeerWifiPaused).toHaveBeenCalledOnce()
    expect(await runtime.runPromise(actions.loadSteadyWifi)).toBe(true)
  })
})

describe("the stall warning while streaming", () => {
  const warning = () => screen.queryByText("AirDrop is stalling the Wi-Fi")

  it("shows while AirDrop and Handoff are on, and turns Steady Wi-Fi on from the HUD", async () => {
    const answer = Effect.runSync(Deferred.make<PeerWifiReply>())
    const core = fakeCore({ setPeerWifiPaused: vi.fn(() => Deferred.await(answer)) })
    renderApp(core, { accountId, paired: [pairedPs5] })
    expect(await screen.findByText("Wi-Fi hiccups every second")).toBeInTheDocument()
    await play(core)
    // Not while connecting: the connecting screen has its own messages.
    expect(warning()).not.toBeInTheDocument()
    act(() => { core.emitStream({ type: "connected" }) })
    expect(warning()).toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Turn on Steady Wi-Fi" }))
    expect(core.service.setPeerWifiPaused).toHaveBeenCalledWith(true)
    expect(await screen.findByRole("button", { name: "Waiting for your password…" })).toBeDisabled()
    const paused: PeerWifiReply = { state: "paused", outcome: "done" }
    Effect.runSync(Deferred.succeed(answer, paused))
    await waitFor(() => { expect(warning()).not.toBeInTheDocument() })
  })

  it("comes and goes with the reading", async () => {
    const core = fakeCore()
    core.state.peerWifi = "off"
    renderApp(core, { accountId, paired: [pairedPs5] })
    await play(core, { connected: true })
    expect(warning()).not.toBeInTheDocument()
    // macOS turns AirDrop's Wi-Fi back on by itself: the next reading shows it.
    core.state.peerWifi = "active"
    await waitFor(() => { expect(warning()).toBeInTheDocument() }, { timeout: 4000 })
    core.state.peerWifi = "absent"
    await waitFor(() => { expect(warning()).not.toBeInTheDocument() }, { timeout: 4000 })
  }, 12_000)
})
