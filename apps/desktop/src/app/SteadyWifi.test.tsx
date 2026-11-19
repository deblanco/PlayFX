import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Deferred, Effect } from "effect"
import { toast } from "sonner"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoreError } from "@/core/errors"
import type { PeerWifiReply } from "@/core/schema"
import { RuntimeProvider } from "./runtime"
import { LinkLine, linkPath, showsSteadyWifi, SteadyWifiRow, SteadyWifiSection } from "./SteadyWifi"
import { accountId, fakeCore, pairedPs5, renderApp, testRuntime, type FakeCore } from "./testing"

const renderWith = (core: FakeCore, element: React.ReactNode) =>
  render(<RuntimeProvider runtime={testRuntime(core)}>{element}</RuntimeProvider>)

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
    const core = fakeCore()
    core.state.peerWifi = "absent"
    const { container } = renderWith(core, <SteadyWifiSection />)
    await new Promise((resolve) => setTimeout(resolve, 20))
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
