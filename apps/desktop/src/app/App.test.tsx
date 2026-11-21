import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Deferred, Effect } from "effect"
import { TestClock } from "effect/testing"
import { toast } from "sonner"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoreError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { defaultSettings, type Profile, type Settings } from "@/core/schema"
import { cursorIdleMs, hudIdleMs } from "./StreamView"
import { renderParams } from "./format"
import { profileSettings } from "./profiles"
import { useRuntime } from "./runtime"
import { accountId, credentials, fakeCore, pairedPs5, picture, ps5, psnPs5, renderApp, status } from "./testing"

const coreError = (command: string, message: string) => new CoreError({ command, message })

const consoleItem = async (name = "Living Room") => {
  const consoles = await screen.findByRole("region", { name: "Consoles" })
  const item = (await within(consoles).findByText(name)).closest("li")
  if (!item) throw new Error(`no console item ${name}`)
  return within(item)
}

/** Renders the app with a paired, ready console and starts streaming it. */
/** Plays the paired console; `connected` also reports the stream as up (otherwise it stays connecting). */
const startStreaming = async (
  core = fakeCore(),
  { connected = true, testClock = false, paired = pairedPs5, profiles = [] as readonly Profile[] } = {},
) => {
  const app = renderApp(core, { accountId, paired: [paired], profiles }, { testClock })
  const item = await consoleItem()
  await userEvent.click(item.getByRole("button", { name: "Play" }))
  await screen.findByRole("button", { name: "Stop" })
  await waitFor(() => {
    expect(core.streamListeners()).toBe(1)
  })
  if (connected) {
    act(() => {
      core.emitStream({ type: "connected" })
    })
  }
  return { ...app, core }
}

/** Presses the HUD's Stop and answers the rest mode question. */
const stopFromHud = async (answer: "Leave it on" | "Rest mode" | "Keep playing" = "Leave it on") => {
  await userEvent.click(screen.getByRole("button", { name: "Stop" }))
  const dialog = await screen.findByRole("alertdialog")
  await userEvent.click(within(dialog).getByRole("button", { name: answer }))
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

  it("stays calm while the first scan runs", async () => {
    renderApp(fakeCore({ discover: Effect.never }))
    expect(await screen.findByText("Looking for consoles on this network…")).toBeInTheDocument()
    // One status line for one state: the header doesn't say it too.
    expect(within(screen.getByRole("region", { name: "Consoles" })).getByRole("status")).toBeEmptyDOMElement()
    expect(screen.queryByText("No consoles found yet")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Console IP address")).not.toBeInTheDocument()
  })

  it("says what to check once a scan finds nothing, with the console IP whatever the Connect mode", async () => {
    const core = fakeCore()
    core.state.discovered = []
    const { runtime } = renderApp(core)
    const help = within(await screen.findByRole("region", { name: "No consoles found yet" }))
    expect(screen.queryByText("Looking for consoles on this network…")).not.toBeInTheDocument()
    expect(within(screen.getByRole("region", { name: "Consoles" })).getByRole("status")).toBeEmptyDOMElement()
    expect(help.getByText(/in rest mode with Stay Connected to the Internet/)).toBeInTheDocument()
    expect(help.getByText(/same network as this Mac/)).toBeInTheDocument()
    expect(help.getByText("Any VPN on this Mac is off.")).toBeInTheDocument()
    expect(help.getByText("PlayFX keeps looking. If your console doesn't show up, check that:")).toBeInTheDocument()
    expect(help.getByText("On a different subnet here, or behind a second router at home? Enter its IP.")).toBeInTheDocument()
    // Someone away from home is pointed to the internet, not to an IP that can't work.
    expect(help.getByText("Away from home? Play a paired PS5 over the internet with Connect › Internet.")).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Automatic" })).toBeChecked()
    await userEvent.click(help.getByRole("button", { name: "Open Local Network settings" }))
    await waitFor(() => {
      expect(core.counts.openLocalNetworkSettings).toBe(1)
    })
    await userEvent.type(help.getByLabelText("Console IP address"), "10.0.1.5{Enter}")
    await waitFor(async () => {
      expect((await savedSettings(runtime)).consoleAddress).toBe("10.0.1.5")
    })
  })

  it("says where the Local Network settings are when it can't open them", async () => {
    const core = fakeCore({ openLocalNetworkSettings: Effect.fail(coreError("open_local_network_settings", "denied")) })
    core.state.discovered = []
    renderApp(core)
    await userEvent.click(await screen.findByRole("button", { name: "Open Local Network settings" }))
    expect(
      await screen.findByText("Couldn't open System Settings. Open it yourself, go to Privacy & Security › Local Network and turn on PlayFX."),
    ).toBeInTheDocument()
  })

  it("hides the help once a console shows up", async () => {
    renderApp(fakeCore())
    await consoleItem()
    expect(screen.queryByText("No consoles found yet")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open Local Network settings" })).not.toBeInTheDocument()
  })

  it("says what to check when paired consoles are listed but none is on this network", async () => {
    const core = fakeCore()
    core.state.discovered = []
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    expect(item.getByText("offline")).toBeInTheDocument()
    const help = within(await screen.findByRole("region", { name: "No consoles on this network yet" }))
    expect(help.getByText("Any VPN on this Mac is off.")).toBeInTheDocument()
    expect(help.getByRole("button", { name: "Open Local Network settings" })).toBeInTheDocument()
    expect(help.getByLabelText("Console IP address")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Console missing? Add it by IP" })).not.toBeInTheDocument()
  })

  it("leaves the help out in Internet mode under consoles listed through PSN", async () => {
    const core = fakeCore()
    core.state.discovered = []
    core.state.psnSignedIn = true
    core.state.psnConsoles = [psnPs5]
    renderApp(core, { accountId, paired: [pairedPs5], settings: { ...defaultSettings, connection: "internet" } })
    const item = await consoleItem()
    expect(await item.findByText("internet")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.queryByRole("region", { name: "No consoles on this network yet" })).not.toBeInTheDocument()
    })
    expect(screen.queryByText("Looking for consoles on this network…")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open Local Network settings" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Console IP address")).not.toBeInTheDocument()
  })

  it("keeps the help in Internet mode when no console is listed through PSN, asking for the PSN sign-in", async () => {
    const core = fakeCore()
    core.state.discovered = []
    renderApp(core, { accountId, paired: [pairedPs5], settings: { ...defaultSettings, connection: "internet" } })
    expect(await (await consoleItem()).findByText("offline")).toBeInTheDocument()
    const help = within(await screen.findByRole("region", { name: "No consoles on this network yet" }))
    // Already in Internet mode: the step that helps is the PSN sign-in, not choosing Internet.
    expect(await help.findByText("Playing over the internet? Sign in with PlayStation above, and your PS5s show up here.")).toBeInTheDocument()
    expect(help.queryByText(/Connect › Internet/)).not.toBeInTheDocument()
  })

  it("points to Remote Play in Internet mode when signed in and PSN lists no console", async () => {
    const core = fakeCore()
    core.state.discovered = []
    core.state.psnSignedIn = true
    renderApp(core, { accountId, paired: [pairedPs5], settings: { ...defaultSettings, connection: "internet" } })
    const help = within(await screen.findByRole("region", { name: "No consoles on this network yet" }))
    expect(await help.findByText(/^Playing over the internet\? Your PS5 shows up here through PSN when Remote Play is on/)).toBeInTheDocument()
    expect(help.queryByText(/Sign in with PlayStation/)).not.toBeInTheDocument()
    expect(help.queryByText(/Connect › Internet/)).not.toBeInTheDocument()
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

describe("home: help", () => {
  it("opens the help page from Home", async () => {
    const core = fakeCore()
    renderApp(core)
    await userEvent.click(await screen.findByRole("button", { name: "Help" }))
    await waitFor(() => {
      expect(core.counts.openHelp).toBe(1)
    })
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
    // One "PSN sign-in failed", and what to do next.
    expect(
      await screen.findByText("PSN sign-in failed: denied. Sign in with PlayStation again, and check that this Mac is online."),
    ).toBeInTheDocument()
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
    expect(screen.getByText("On the PS5: Settings › System › Remote Play › Pair Device (Link Device on some versions)")).toBeInTheDocument()
    const form = within(screen.getByRole("form", { name: "Pair Living Room" }))
    // The 8-digit pairing code, not the passcode, and how long it lasts.
    expect(screen.getByLabelText("On the PS5: Settings › System › Remote Play › Pair Device (Link Device on some versions)")).toHaveAccessibleDescription(
      "Type the 8-digit pairing code it shows, not your console passcode. The code is valid for about 5 minutes: keep that screen open.",
    )
    fireEvent.change(screen.getByLabelText("On the PS5: Settings › System › Remote Play › Pair Device (Link Device on some versions)"), {
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

describe("home: pairing a PS4", () => {
  it("shows where a PS4 shows its code", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, ps5: false }]
    renderApp(core, { accountId })
    const item = await consoleItem()
    await userEvent.click(item.getByRole("button", { name: "Pair" }))
    expect(screen.getByText("On the PS4: Settings › Remote Play Connection Settings › Add Device")).toBeInTheDocument()
  })
})

describe("home: pairing through PSN", () => {
  /** Signed in for internet play, with `psnPs5` on the account; nothing found on this network by default. */
  const signedIn = (overrides: Parameters<typeof fakeCore>[0] = {}, discovered: (typeof ps5)[] = []) => {
    const core = fakeCore(overrides)
    core.state.psnSignedIn = true
    core.state.psnConsoles = [psnPs5]
    core.state.discovered = discovered
    renderApp(core, { accountId })
    return core
  }

  it("pairs a PS5 on the account with no code, and can then play it over the internet", async () => {
    const core = signedIn()
    const item = await consoleItem()
    expect(item.getByText("PS5 · on your PSN account")).toBeInTheDocument()
    expect(item.queryByRole("button", { name: "Pair with a code" })).not.toBeInTheDocument() // not on this network
    await userEvent.click(item.getByRole("button", { name: "Pair (no code needed)" }))
    expect(core.service.pairPsn).toHaveBeenCalledWith({ duid: "aa", accountId }, expect.any(Function))
    expect(await screen.findByText("Paired with Living Room")).toBeInTheDocument()
    const paired = await consoleItem()
    expect(await paired.findByText("PS5 · over the internet · paired")).toBeInTheDocument()
    expect(paired.getByRole("button", { name: "Play" })).toBeEnabled()
  })

  it("shows the step under way, and Cancel stops it", async () => {
    const core = signedIn({
      pairPsn: (_request, onProgress) =>
        Effect.andThen(Effect.sync(() => { onProgress("registering") }), Effect.never),
    })
    const item = await consoleItem()
    await userEvent.click(item.getByRole("button", { name: "Pair (no code needed)" }))
    expect(await item.findByText("Pairing this Mac with Living Room…")).toBeInTheDocument()
    expect(item.getByText(/This takes 20 to 30 seconds/)).toBeInTheDocument()
    expect(item.getByRole("button", { name: "Pair (no code needed)" })).toBeDisabled() // one at a time
    await userEvent.click(item.getByRole("button", { name: "Cancel" }))
    expect(await item.findByRole("button", { name: "Pair (no code needed)" })).toBeEnabled()
    expect(item.queryByRole("status")).not.toBeInTheDocument()
    expect(core.service.pair).not.toHaveBeenCalled()
  })

  it("opens the PIN form with the reason when it fails on a console found here", async () => {
    signedIn({ pairPsn: () => Effect.fail(coreError("pair_psn", "The PS5 didn't accept pairing through PSN.")) }, [ps5])
    const item = await consoleItem()
    expect(item.getByRole("button", { name: "Pair with a code" })).toBeEnabled()
    await userEvent.click(item.getByRole("button", { name: "Pair (no code needed)" }))
    const form = within(await screen.findByRole("form", { name: "Pair Living Room" }))
    expect(form.getByText("Couldn't pair through PSN")).toBeInTheDocument()
    expect(form.getByText("The PS5 didn't accept pairing through PSN.")).toBeInTheDocument()
    expect(form.getByText("Pair with the code from the PS5 instead.")).toBeInTheDocument()
    await userEvent.click(form.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("form", { name: "Pair Living Room" })).not.toBeInTheDocument()
    // Pairing with a code from the start shows no PSN reason.
    await userEvent.click(item.getByRole("button", { name: "Pair with a code" }))
    expect(screen.queryByText("Couldn't pair through PSN")).not.toBeInTheDocument()
  })

  it("stays on the console when discovery finds it during the pairing", async () => {
    const answer = Effect.runSync(Deferred.make<boolean>())
    const core = fakeCore({
      pairPsn: (_request, onProgress) =>
        Effect.andThen(
          Effect.sync(() => { onProgress("registering") }),
          Effect.andThen(Deferred.await(answer), Effect.fail(coreError("pair_psn", "The PS5 didn't accept pairing through PSN."))),
        ),
    })
    core.state.psnSignedIn = true
    core.state.psnConsoles = [psnPs5]
    core.state.discovered = []
    const { runtime } = renderApp(core, { accountId }, { testClock: true })
    vi.useFakeTimers({ toFake: ["Date"] })
    await userEvent.click((await consoleItem()).getByRole("button", { name: "Pair (no code needed)" }))
    expect(await (await consoleItem()).findByText("Pairing this Mac with Living Room…")).toBeInTheDocument()
    // Found on this network 50 s in: the row is now discovery's, under another host ID.
    vi.setSystemTime(Date.now() + 50_000)
    core.state.discovered = [ps5]
    await act(() => runtime.runPromise(TestClock.adjust(5000)))
    const found = await consoleItem()
    expect(await found.findByText("PS5 · 192.168.0.40 · Astro Bot")).toBeInTheDocument()
    expect(found.getByText("Pairing this Mac with Living Room…")).toBeInTheDocument()
    // The time counts from the pairing's start, not from when the row changed.
    expect(found.getByRole("status")).toHaveTextContent("50 s so far. This is taking longer than usual.")
    expect(found.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
    // Its failure lands there too: the PIN form opens with the reason.
    Effect.runSync(Deferred.succeed(answer, true))
    const form = within(await screen.findByRole("form", { name: "Pair Living Room" }))
    expect(form.getByText("Couldn't pair through PSN")).toBeInTheDocument()
  })

  it("says how to pair with a code when it fails on a console not found here", async () => {
    // A native reason without a full stop doesn't run into the next step: each is its own sentence.
    signedIn({ pairPsn: () => Effect.fail(coreError("pair_psn", "PSN didn't answer")) })
    const item = await consoleItem()
    await userEvent.click(item.getByRole("button", { name: "Pair (no code needed)" }))
    const alert = within(await item.findByRole("alert"))
    expect(alert.getByText("PSN didn't answer")).toBeInTheDocument()
    expect(alert.getByText("To pair with a code instead, connect the PS5 to this Mac's network: it shows up here with Pair.")).toBeInTheDocument()
  })

  it("offers it right after signing in", async () => {
    const core = fakeCore()
    core.state.psnConsoles = [psnPs5]
    core.state.discovered = []
    renderApp(core)
    await waitFor(() => {
      expect(core.psnListeners()).toBe(1)
    })
    expect(screen.queryByRole("button", { name: "Pair (no code needed)" })).not.toBeInTheDocument()
    core.state.psnSignedIn = true // the native side kept the tokens
    act(() => {
      core.emitPsn({ accountId })
    })
    expect(await screen.findByRole("button", { name: "Pair (no code needed)" })).toBeEnabled()
  })

  it("says when Remote Play is off, with no way to pair through PSN", async () => {
    const core = fakeCore()
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ ...psnPs5, remotePlay: false }]
    core.state.discovered = []
    renderApp(core, { accountId })
    const item = await consoleItem()
    expect(item.getByText("PS5 · Remote Play is off")).toBeInTheDocument()
    expect(item.getByText(/To pair it, turn it on, on the PS5: Settings › System › Remote Play › Enable Remote Play/)).toBeInTheDocument()
    expect(item.queryByRole("button", { name: "Pair (no code needed)" })).not.toBeInTheDocument()
  })
})

describe("home: paired consoles", () => {
  it("wakes a console in standby", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, state: "standby" }]
    renderApp(core, { paired: [pairedPs5] })
    const item = await consoleItem()
    expect(item.getByText("rest mode")).toBeInTheDocument() // Sony's words, not "standby"
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
    // The connecting screen shows the route's steps and how long it's been.
    const connecting = screen.getByRole("region", { name: "Connecting to Living Room" })
    expect(within(connecting).getByText("Finding your PS5 through PSN").closest("li")).toHaveAttribute("aria-current", "step")
    expect(within(connecting).getByRole("status")).toHaveTextContent("0 s so far. Over the internet this usually takes 20 to 40 seconds.")
    await waitFor(() => {
      expect(within(connecting).getByRole("status")).toHaveTextContent("1 s so far.")
    }, { timeout: 2000 })
    act(() => {
      core.emitStream({ type: "remoteProgress", stage: "data" })
    })
    expect(hud).toHaveTextContent("Opening the data connection…")
    expect(within(connecting).getByText("Opening a direct connection to it").closest("li")).toHaveAttribute("aria-current", "step")
    act(() => {
      core.emitStream({ type: "remoteProgress", stage: "connected" })
      core.emitStream({ type: "connected" })
    })
    expect(hud).not.toHaveTextContent("over the internet")
    expect(screen.queryByRole("region", { name: "Connecting to Living Room" })).not.toBeInTheDocument()

    // A drop reconnects over the internet too: the old session is stopped, then (after the console
    // lets go of it; the wait is covered in actions.test) a new one starts through PSN.
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
    })
    expect(await screen.findByRole("region", { name: "Connection lost. Reconnecting to Living Room" })).toBeInTheDocument()
    await waitFor(() => {
      expect(core.counts.stopStream).toBe(1)
    })
  })

  it("plays a resting console through PSN when it can't be woken on this network", async () => {
    const core = fakeCore()
    core.state.discovered = [{ ...ps5, state: "standby" }]
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    vi.mocked(core.service.wakeup).mockReturnValueOnce(Effect.succeed(false))
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), "aa")
    })
  })

  it("plays through PSN when the local network can't reach the console", async () => {
    const core = fakeCore()
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.anything(), undefined) // locally first
    act(() => {
      core.emitStream({ type: "quit", reason: "Unknown Session Request Error", error: true, kind: "final" })
    })
    expect(await screen.findByText("Couldn't reach Living Room on this network. Connecting over the internet…")).toBeInTheDocument()
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.anything(), "aa")
    })
    expect(await screen.findByRole("banner")).toHaveTextContent("Reaching your PS5 over the internet…")
  })

  it("lets the home screen choose how Play connects", async () => {
    const core = fakeCore()
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    const connect = screen.getByRole("radiogroup", { name: "Connect" })
    expect(within(connect).getByRole("radio", { name: "Automatic" })).toHaveAttribute("aria-checked", "true")

    // Internet: through PSN even though the console is on this network.
    await userEvent.click(within(connect).getByRole("radio", { name: "Internet" }))
    expect(screen.getByText(/Always through PSN, even at home/)).toBeInTheDocument()
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.anything(), "aa")
    })
  })

  it("plays only on the home network when asked to, without falling back", async () => {
    const core = fakeCore()
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(within(screen.getByRole("radiogroup", { name: "Connect" })).getByRole("radio", { name: "Home network" }))
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.anything(), undefined)
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    act(() => {
      core.emitStream({ type: "quit", reason: "Unknown Session Request Error", error: true, kind: "final" })
    })
    expect(await screen.findByText(/^Couldn't reach the console on this network/)).toBeInTheDocument()
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
  })

  it("says why a console can't be played over the internet", async () => {
    const core = fakeCore() // on this network, but not signed in to PSN
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(within(screen.getByRole("radiogroup", { name: "Connect" })).getByRole("radio", { name: "Internet" }))
    await userEvent.click(await item.findByRole("button", { name: "Play" }))
    expect(
      await screen.findByText("Living Room isn't reachable over the internet. Sign in to PSN for internet play, or connect on your home network."),
    ).toBeInTheDocument()
    expect(core.service.startStream).not.toHaveBeenCalled()
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
const openSettings = async (tab: "Picture" | "Stream" | "Diagnostics") => {
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
    expect(await screen.findByText("720p · 60 fps · HEVC · 20 Mbps")).toBeInTheDocument()
    const sheet = await openSettings("Stream")
    expect(sheet.getByText("Changes apply the next time you connect.")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("radio", { name: "540p" }))
    await userEvent.click(sheet.getByRole("radio", { name: "540p" })) // re-clicking keeps it selected
    await userEvent.click(sheet.getByRole("radio", { name: "30 fps" }))
    await userEvent.click(sheet.getByRole("radio", { name: "H.264" }))
    nudge("Bitrate", "ArrowRight", 2)
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
    expect(sheet.getByText("The stream with the steps below.")).toBeInTheDocument() // the Enhanced view
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
      expect(await savedSettings(runtime)).toEqual({ ...defaultSettings, ...tuned, compare: undefined }) // compare is derived from view
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
    const toggle = sheet.getByRole("switch", { name: /ML upscaling first/ })
    expect(toggle).toBeChecked() // on by default
    const pipeline = within(sheet.getByRole("navigation", { name: "Picture pipeline" }))
    expect(pipeline.getByRole("button", { name: /Upscale/ })).toHaveTextContent("ML + MetalFX")
    await userEvent.click(toggle)
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ mlUpscale: false }))
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
    expect(sheet.getAllByText("Needs macOS 26 on a supported Mac.")).toHaveLength(2) // ML upscaling, Frame interpolation
    expect(sheet.getByRole("switch", { name: /Frame interpolation/ })).toBeDisabled()
  })

  it("offers diagnostics: detailed logs, copying a report, the logs folder", async () => {
    const core = fakeCore()
    Object.defineProperty(navigator, "clipboard", { value: { writeText: () => Promise.resolve() }, configurable: true })
    renderApp(core)
    const sheet = await openSettings("Diagnostics")
    expect(sheet.getByText("For tracking down problems and reporting bugs.")).toBeInTheDocument()
    // The version and the commit it was built from, first thing in the panel.
    expect(await sheet.findByLabelText("Version")).toHaveTextContent("PlayFX 0.1.0 (abc1234) on macOS 27.2")
    expect(sheet.getByText(/never contain your PlayStation sign-in/)).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("switch", { name: /Detailed logs/ }))
    await waitFor(() => {
      expect(core.service.setDetailedLogs).toHaveBeenLastCalledWith(true)
    })
    await userEvent.click(sheet.getByRole("button", { name: "Copy diagnostics" }))
    expect(await screen.findByText("Diagnostics copied. Paste them into your bug report.")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Open logs folder" }))
    await waitFor(() => {
      expect(core.counts.openLogsFolder).toBe(1)
    })
    await userEvent.click(sheet.getByRole("button", { name: "Help" }))
    await waitFor(() => {
      expect(core.counts.openHelp).toBe(1)
    })
    expect(sheet.getByText(/free software under the GNU AGPL-3.0/)).toBeInTheDocument()
    expect(sheet.getByText(/THIRD_PARTY_LICENSES/)).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Source code" }))
    await waitFor(() => {
      expect(core.counts.openSourceCode).toBe(1)
    })
    await userEvent.click(sheet.getByRole("switch", { name: /Detailed logs/ })) // back off
  })

  it("picks the sound output and volume, applied at once", async () => {
    const core = fakeCore()
    renderApp(core)
    await waitFor(() => {
      expect(core.service.setAudioOutput).toHaveBeenCalledWith(1, undefined) // saved settings applied at startup
    })
    const sheet = await openSettings("Stream")
    const output = await sheet.findByRole("combobox", { name: "Output" })
    await waitFor(() => {
      expect(within(output).getByRole("option", { name: "AirPods Pro" })).toBeInTheDocument()
    })
    await userEvent.selectOptions(output, "AirPods")
    expect(core.service.setAudioOutput).toHaveBeenLastCalledWith(1, "AirPods")
    expect(sheet.getByText("Volume and output change right away.")).toBeInTheDocument()
    sheet.getByRole("slider", { name: "Volume" }).focus()
    await userEvent.keyboard("{ArrowLeft}")
    expect(core.service.setAudioOutput).toHaveBeenLastCalledWith(0.95, "AirPods")
  })

  it("says when the chosen sound output isn't connected", async () => {
    renderApp(fakeCore(), { settings: { ...defaultSettings, audioDevice: "Unplugged" } })
    const sheet = await openSettings("Stream")
    expect(await sheet.findByText(/isn't connected, so sound plays through the system default/)).toBeInTheDocument()
  })

  it("asks for HDR only with HEVC", async () => {
    renderApp(fakeCore())
    const sheet = await openSettings("Stream")
    const hdr = sheet.getByRole("switch", { name: /HDR/ })
    await userEvent.click(hdr)
    expect(hdr).toBeChecked()
    await userEvent.click(sheet.getByRole("radio", { name: "H.264" }))
    expect(sheet.getByRole("switch", { name: /HDR/ })).toBeDisabled()
    expect(sheet.getByText("Needs the HEVC codec.")).toBeInTheDocument()
  })

  it("guides a first run step by step, and steps aside once a console is paired", async () => {
    renderApp(fakeCore()) // signed out, nothing paired
    const guide = await screen.findByRole("region", { name: "Get started" })
    // The PS5's own settings come first: Remote Play on, and waking from rest mode.
    expect(within(guide).getByText("Get your PS5 ready").closest("li")).toHaveAttribute("aria-current", "step")
    expect(within(guide).getByText(/Settings › System › Remote Play › Enable Remote Play/)).toBeInTheDocument()
    expect(
      within(guide).getByText(
        /Stay Connected to the Internet and Enable Turning On PS5 from Network in Settings › System › Power Saving › Features Available in Rest Mode/,
      ),
    ).toBeInTheDocument()
    expect(within(guide).getByText("Sign in with PlayStation").closest("li")).not.toHaveAttribute("aria-current")
    expect(within(guide).getByText(/Pair Device \(Link Device on some versions\)/)).toBeInTheDocument()
  })

  it("shows the next step once signed in, and no guide for a paired console", async () => {
    const { unmount } = renderApp(fakeCore(), { accountId })
    const guide = await screen.findByRole("region", { name: "Get started" })
    expect(within(guide).getByText("Pair your PS5").closest("li")).toHaveAttribute("aria-current", "step")
    // Signing in says nothing about the PS5's settings: that step stays open, not ticked off.
    expect(within(guide).getAllByLabelText("Done")).toHaveLength(1)
    expect(within(guide).getByText("Get your PS5 ready")).not.toHaveClass("line-through")
    expect(within(guide).getByText(/Settings › System › Remote Play › Enable Remote Play/)).toBeInTheDocument()
    unmount()
    renderApp(fakeCore(), { accountId, paired: [pairedPs5] })
    await consoleItem()
    expect(screen.queryByRole("region", { name: "Get started" })).not.toBeInTheDocument()
  })

  it("keeps the guide after pairing until the first Play, with Play as the step to take", async () => {
    const core = fakeCore()
    renderApp(core, { accountId })
    const item = await consoleItem()
    await userEvent.click(item.getByRole("button", { name: "Pair" }))
    fireEvent.change(screen.getByLabelText(/^On the PS5:/), { target: { value: "12345678" } })
    await userEvent.click(within(screen.getByRole("form", { name: "Pair Living Room" })).getByRole("button", { name: "Pair" }))
    await screen.findByText("Paired with Living Room")
    const guide = screen.getByRole("region", { name: "Get started" })
    expect(within(guide).getByText("Play").closest("li")).toHaveAttribute("aria-current", "step")
    expect(within(guide).getByText("Press Play. PlayFX wakes your PS5 if it's in rest mode.")).toBeInTheDocument()
    // Pairing worked, so the PS5 was ready: that step ticks off and folds away.
    expect(within(guide).getAllByLabelText("Done")).toHaveLength(3)
    expect(within(guide).queryByText(/Enable Remote Play/)).not.toBeInTheDocument()
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await stopFromHud()
    await consoleItem()
    expect(screen.queryByRole("region", { name: "Get started" })).not.toBeInTheDocument()
  })

  it("toasts startup failures, and still shows the saved settings", async () => {
    // A native failure must not leave the UI on the defaults: the next change would save them over these.
    renderApp(fakeCore({ rendererStatus: Effect.fail(coreError("renderer_status", "no renderer")) }), {
      settings: { ...defaultSettings, height: 720, fps: 30 },
    })
    expect(await screen.findByText("no renderer")).toBeInTheDocument()
    expect(await screen.findByText(/720p · 30 fps/)).toBeInTheDocument()
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
      bitrate: 20000,
      audio: true,
      autoDowngrade: true,
      hdr: false,
    }, undefined)
    expect(screen.queryByText("Consoles")).not.toBeInTheDocument()
    expect(screen.getByText("Living Room")).toBeInTheDocument()
    // "Stats on screen" is off by default: no numbers in the HUD (see "shows the stream's numbers only when
    // asked to" for them appearing once it's on).
    expect(screen.queryByText(/1920×1080/)).not.toBeInTheDocument()
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
    expect(dialog.getByText("Console passcode")).toBeInTheDocument()
    expect(dialog.getByText("Enter your PS5 user's passcode (4 digits), not the pairing code.")).toBeInTheDocument()
    await userEvent.type(dialog.getByLabelText("Passcode"), "12")
    await userEvent.click(dialog.getByRole("button", { name: "Send" }))
    expect(await screen.findByText("The passcode has 4 digits")).toBeInTheDocument()
    await userEvent.type(dialog.getByLabelText("Passcode"), "34")
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
    expect(dialog.getByText("Wrong passcode. Enter your PS5 user's passcode (4 digits), not the pairing code.")).toBeInTheDocument()
    await userEvent.click(dialog.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(core.counts.stopStream).toBe(1)
  })

  it("names a PS4 in the passcode prompt when streaming one", async () => {
    const ps4 = { ...pairedPs5, credentials: { ...pairedPs5.credentials, ps5: false } }
    const { core } = await startStreaming(fakeCore(), { paired: ps4 })
    act(() => {
      core.emitStream({ type: "loginPin", incorrect: false })
    })
    const dialog = within(await screen.findByRole("dialog"))
    expect(dialog.getByText("Enter your PS4 user's passcode (4 digits), not the pairing code.")).toBeInTheDocument()
  })

  it("stops the stream from the HUD, even if stopping fails", async () => {
    const { core } = await startStreaming(fakeCore({ stopStream: Effect.fail(coreError("stop_stream", "already gone")) }))
    await stopFromHud()
    expect(await screen.findByText("already gone")).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(core.streamListeners()).toBe(1)
  })

  it("asks on Stop whether to put the console in rest mode", async () => {
    const { core } = await startStreaming()
    await stopFromHud("Keep playing")
    await waitFor(() => {
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument()
    })
    expect(core.counts.stopStream).toBe(0) // still streaming
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(within(await screen.findByRole("alertdialog")).getByText("Put Living Room in rest mode?")).toBeInTheDocument()
    await userEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Rest mode" }))
    await waitFor(() => {
      expect(core.counts.stopStream).toBe(1)
    }, { timeout: 3000 })
    expect(core.counts.sleepConsole).toBe(1) // asked before the stream was stopped
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
  })

  it("stops at once while still connecting", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument()
    expect(core.counts.sleepConsole).toBe(0)
  })

  it("turns Frame interpolation (on by default) off and on for the renderer", async () => {
    const core = fakeCore()
    core.state.status = { ...status(), interpolationSupported: true }
    await startStreaming(core)
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ frameInterpolation: true }))
    const sheet = await openSettings("Picture")
    await userEvent.click(sheet.getByRole("switch", { name: /Frame interpolation/ }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ frameInterpolation: false }))
    await userEvent.click(sheet.getByRole("switch", { name: /Frame interpolation/ }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ frameInterpolation: true }))
  })

  it("uses the pointer as the touchpad while ⌥ Option is held", async () => {
    const { core } = await startStreaming()
    const touch = vi.mocked(core.service.setPointerTouch)
    // jsdom's window is 1024×768: the 16:9 video is 1024×576, 96 px down.
    fireEvent.keyDown(window, { key: "Alt", altKey: true })
    fireEvent.mouseMove(window, { clientX: 512, clientY: 384, altKey: true })
    expect(await screen.findByRole("status", { name: /Touchpad/ })).toBeInTheDocument()
    await waitFor(() => {
      expect(touch).toHaveBeenLastCalledWith({ down: true, x: 0.5, y: 0.5, pressed: false })
    })
    fireEvent.mouseDown(window, { button: 0, clientX: 512, clientY: 384, altKey: true })
    await waitFor(() => {
      expect(touch).toHaveBeenLastCalledWith({ down: true, x: 0.5, y: 0.5, pressed: true })
    })
    fireEvent.mouseUp(window, { button: 0, altKey: true })
    fireEvent.keyUp(window, { key: "Alt" })
    await waitFor(() => {
      expect(touch).toHaveBeenLastCalledWith({ down: false, x: 0, y: 0, pressed: false })
    })
  })

  it("shows the stream's numbers only when asked to", async () => {
    const core = fakeCore()
    core.state.status = status({ width: 1920, height: 1080, framesDecoded: 0, rttMs: 12 })
    await startStreaming(core)
    expect(screen.queryByLabelText("Stream stats")).not.toBeInTheDocument()
    const sheet = await openSettings("Picture")
    // The HUD is up while the settings are open, and still shows no numbers with the switch off.
    expect(screen.queryByText(/1920×1080/)).not.toBeInTheDocument()
    await userEvent.click(sheet.getByRole("switch", { name: /Stats on screen/ }))
    const line = await screen.findByLabelText("Stream stats")
    expect(line).toHaveTextContent("1920×1080 · 0 fps · 0.0 Mbps · ping 12 ms · MetalFX · 0 lost frames")
  })

  it("tunes the picture from the HUD with a labelled split screen", async () => {
    const { core } = await startStreaming()
    expect(screen.queryByLabelText("Split-screen comparison")).not.toBeInTheDocument()
    const sheet = await openSettings("Picture")
    const view = within(sheet.getByRole("radiogroup", { name: "View" }))
    await userEvent.click(view.getByRole("radio", { name: "Original" }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(
      picture({ upscaler: "bilinear", sharpness: 0, mlUpscale: false, frameInterpolation: false, compare: false }),
    )
    expect(screen.queryByLabelText("Split-screen comparison")).not.toBeInTheDocument()
    await userEvent.click(view.getByRole("radio", { name: "Split" }))
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ compare: true }))
    const labels = screen.getByLabelText("Split-screen comparison")
    expect(labels).toHaveTextContent("Original")
    expect(labels).toHaveTextContent("Enhanced")
    // The keyboard drives the settings, not the console, while they're open.
    vi.mocked(core.service.setController).mockClear()
    fireEvent.keyDown(window, { code: "ArrowUp" })
    expect(core.service.setController).not.toHaveBeenCalled()
  })

  it("applies a new bitrate on its own, once the slider stays put", async () => {
    const { core } = await startStreaming()
    vi.mocked(core.service.startStream).mockClear()
    await openSettings("Stream")
    // Two steps up in a row (20 → 30 → 40 Mbps): one reconnect, with the last value.
    nudge("Bitrate", "ArrowRight", 2)
    expect(core.service.startStream).not.toHaveBeenCalled()
    await waitFor(
      () => {
        expect(core.service.startStream).toHaveBeenCalledTimes(1)
      },
      { timeout: 3000 },
    )
    expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.objectContaining({ bitrate: 40000 }), undefined)
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

  it("reconnects on its own when the picture stops while the stream goes on", async () => {
    const core = fakeCore()
    core.state.status = status({ framesDecoded: 100 }) // and never more: the video stopped getting through
    const { runtime } = await startStreaming(core, { testClock: true })
    vi.mocked(core.service.startStream).mockClear()
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    await wait(4)
    expect(core.service.startStream).not.toHaveBeenCalled() // not yet: a lost frame recovers within a second
    await wait(3)
    expect(screen.getByRole("banner")).toHaveTextContent("The picture stopped. Reconnecting…")
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
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
    await stopFromHud()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 1800)) // …past the retry delay: nothing restarts
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/Reconnect failed/)).not.toBeInTheDocument()
  })

  it("keeps the new session when a reconnect supersedes one under way", async () => {
    // A network change on top of a drop: the second reconnect replaces the first, which is interrupted before
    // the second starts. Stopping it on the side raced the new attempt: the stop could land after the new
    // session started and end it.
    const calls: string[] = []
    const core = fakeCore({
      startStream: vi.fn(() => Effect.sync(() => { calls.push("start") })),
      stopStream: Effect.sync(() => { calls.push("stop") }),
    })
    await startStreaming(core)
    calls.length = 0
    act(() => {
      core.emitStream({ type: "quit", reason: "Stream Connection Unknown", error: true, kind: "dropped" })
      core.emitStream({ type: "network", online: true }) // before the drop's reconnect has shown
    })
    expect(await screen.findByRole("region", { name: "Your network changed. Reconnecting to Living Room" })).toBeInTheDocument()
    await waitFor(() => {
      expect(calls.at(-1)).toBe("start")
    })
    // The app's own listener and the second attempt's: the first attempt is gone, not left waiting for an
    // answer (if it later failed or timed out, it would end the stream the second one brought up).
    expect(core.streamListeners()).toBe(2)
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(screen.getByRole("banner")).not.toHaveTextContent("Reconnecting")
    })
    expect(calls).not.toContain("stop") // the new session was never stopped
    expect(screen.getByRole("button", { name: "Stop" })).toBeInTheDocument()
  })

  it("waits out a console that's still busy when the stream starts", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
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

  it("asks PSN on the spot when Play came before the console list knew about PSN", async () => {
    const core = fakeCore()
    renderApp(core, { accountId, paired: [pairedPs5] })
    const item = await consoleItem()
    await userEvent.click(await item.findByRole("button", { name: "Play" })) // PSN not signed in yet: local only
    await waitFor(() => {
      expect(core.streamListeners()).toBe(1)
    })
    core.state.psnSignedIn = true
    core.state.psnConsoles = [{ name: "Living Room", duid: "aa", remotePlay: true }]
    act(() => {
      core.emitStream({ type: "quit", reason: "Unknown Session Request Error", error: true, kind: "final" })
    })
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.anything(), "aa")
    })
  })

  it("ends with advice when the console can't be reached at all", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
    act(() => {
      core.emitStream({ type: "quit", reason: "Unknown Session Request Error", error: true, kind: "final" })
    })
    expect(await screen.findByText(/^Couldn't reach the console on this network/)).toBeInTheDocument()
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
  })

  it("reconnects at once when the Mac's network changes", async () => {
    const { core } = await startStreaming()
    await waitFor(() => {
      expect(screen.queryByRole("region", { name: /Connecting/ })).not.toBeInTheDocument()
    })
    vi.mocked(core.service.startStream).mockClear()
    act(() => {
      core.emitStream({ type: "network", online: false }) // offline: nothing to do yet
    })
    expect(core.service.startStream).not.toHaveBeenCalled()
    act(() => {
      core.emitStream({ type: "network", online: true })
    })
    expect(await screen.findByRole("region", { name: "Your network changed. Reconnecting to Living Room" })).toBeInTheDocument()
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
  })

  it("offers to try again when a stream ends with an error", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
    act(() => {
      core.emitStream({ type: "quit", reason: "Remote Play on Console has crashed", error: true, kind: "final" })
    })
    expect(await screen.findByText("Remote Play stopped on the console. Try again in a moment.")).toBeInTheDocument()
    vi.mocked(core.service.startStream).mockClear()
    fireEvent.click(screen.getByRole("button", { name: "Try again" })) // (the toast's swipe handling needs pointer capture, which jsdom lacks)
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledWith(credentials, expect.anything(), undefined)
    })
  })

  it("types into the console's text field from the Mac", async () => {
    const { core } = await startStreaming()
    act(() => {
      core.emitStream({ type: "keyboard", change: "open", text: "" })
    })
    const field = await screen.findByRole("textbox", { name: "Text for Living Room" })
    expect(field).toHaveFocus()
    vi.mocked(core.service.setController).mockClear()
    await userEvent.type(field, "kiryu") // "k", "i" and "l" also drive the keyboard controller, but not now
    expect(core.service.keyboardSetText).toHaveBeenLastCalledWith("kiryu")
    expect(core.service.setController).not.toHaveBeenCalledWith(expect.objectContaining({ rightX: expect.anything() as number }))
    await userEvent.type(field, "{Enter}")
    expect(core.service.keyboardDone).toHaveBeenLastCalledWith(true)
    expect(screen.queryByRole("textbox", { name: "Text for Living Room" })).not.toBeInTheDocument()

    // Esc cancels; the console can also close it on its own.
    act(() => {
      core.emitStream({ type: "keyboard", change: "open", text: "majima" })
    })
    const again = await screen.findByRole("textbox", { name: "Text for Living Room" })
    expect(again).toHaveValue("majima")
    await userEvent.type(again, "{Escape}")
    expect(core.service.keyboardDone).toHaveBeenLastCalledWith(false)
    act(() => {
      core.emitStream({ type: "keyboard", change: "open", text: "" })
    })
    await screen.findByRole("textbox", { name: "Text for Living Room" })
    act(() => {
      core.emitStream({ type: "keyboard", change: "close", text: "" })
    })
    expect(screen.queryByRole("textbox", { name: "Text for Living Room" })).not.toBeInTheDocument()
  })

  it("gives the microphone button back when the request fails", async () => {
    const { core } = await startStreaming(fakeCore({ setMicrophone: vi.fn(() => Effect.fail(coreError("set_microphone", "gone"))) }))
    await userEvent.click(screen.getByRole("button", { name: "Mic" }))
    expect(await screen.findByText("gone")).toBeInTheDocument()
    await waitFor(() => { expect(screen.getByRole("button", { name: "Mic" })).toBeEnabled() })
    expect(core.service.setMicrophone).toHaveBeenCalledWith(true)
  })

  it("turns the microphone on for voice chat, and explains when it can't", async () => {
    const { core } = await startStreaming()
    await userEvent.click(screen.getByRole("button", { name: "Mic" }))
    expect(core.service.setMicrophone).toHaveBeenLastCalledWith(true)
    expect(screen.getByRole("button", { name: "Mic" })).toBeDisabled() // waiting for macOS
    act(() => {
      core.emitStream({ type: "microphone", state: "on" })
    })
    const live = screen.getByRole("button", { name: "Mic on" })
    expect(live).toHaveAttribute("aria-pressed", "true")
    await userEvent.click(live)
    expect(core.service.setMicrophone).toHaveBeenLastCalledWith(false)

    await userEvent.click(screen.getByRole("button", { name: "Mic" }))
    act(() => {
      core.emitStream({ type: "microphone", state: "denied" })
    })
    expect(await screen.findByText(/Allow it in System Settings › Privacy & Security › Microphone/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Mic" })).toBeEnabled()
  })

  it("can cancel while connecting", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
    const connecting = screen.getByRole("region", { name: "Connecting to Living Room" })
    expect(within(connecting).getByText("Contacting Living Room on your network")).toBeInTheDocument()
    await userEvent.click(within(connecting).getByRole("button", { name: "Cancel" }))
    expect(await screen.findByText("Consoles")).toBeInTheDocument()
    expect(core.counts.stopStream).toBe(1)
  })

  it("doesn't retry a drop before the stream ever connected", async () => {
    const { core } = await startStreaming(fakeCore(), { connected: false })
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

  it("hides the HUD after 2.5 s without mouse movement, at once, with no fade", async () => {
    await startStreaming()
    const hud = screen.getByRole("banner")
    const stop = screen.getByRole("button", { name: "Stop" })
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    fireEvent.mouseMove(window)
    expect(hud).toHaveAttribute("data-idle", "false")
    act(() => {
      vi.advanceTimersByTime(hudIdleMs - 1)
    })
    expect(hud).toHaveAttribute("data-idle", "false")
    expect(stop).not.toHaveClass("opacity-0")
    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(hud).toHaveAttribute("data-idle", "true")
    expect(stop).toHaveClass("opacity-0", "transition-none")
    expect(stop).not.toHaveClass("transition-all")
    fireEvent.mouseMove(window)
    expect(hud).toHaveAttribute("data-idle", "false")
    expect(stop).not.toHaveClass("opacity-0")
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

  it("keeps the fullscreen button right when the window changes on its own", async () => {
    const { core } = await startStreaming()
    expect(screen.getByRole("button", { name: "Fullscreen" })).toBeInTheDocument()
    core.state.fullscreen = true // the green button
    fireEvent(window, new Event("resize"))
    expect(await screen.findByRole("button", { name: "Exit fullscreen" })).toBeInTheDocument()
  })

  it("doesn't toggle fullscreen from a double click in the rest-mode dialog", async () => {
    const { core } = await startStreaming()
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    fireEvent.doubleClick(await screen.findByRole("alertdialog"))
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
    await stopFromHud()
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

  it("lets go of every key on a ⌘ shortcut, which never sends its key-up", async () => {
    const { core } = await startStreaming()
    fireEvent.keyDown(window, { code: "Digit4" }) // R2
    await waitFor(() => { expect(vi.mocked(core.service.setController).mock.lastCall?.[0].r2).toBe(255) })
    fireEvent.keyDown(window, { code: "Digit4", metaKey: true, shiftKey: true }) // ⌘⇧4: a screenshot
    await waitFor(() => { expect(vi.mocked(core.service.setController).mock.lastCall?.[0].r2).toBe(0) })
  })

  it("holds PS from the HUD's PS button while the pointer is down", async () => {
    const { core } = await startStreaming()
    const ps = 1 << 15
    const button = screen.getByRole("button", { name: "PS button" })
    fireEvent.keyDown(window, { code: "ArrowUp" }) // held on the keyboard meanwhile: merged, not replaced
    fireEvent.pointerDown(button)
    await waitFor(() => { expect(vi.mocked(core.service.setController).mock.lastCall?.[0].buttons).toBe(ps | (1 << 6)) })
    fireEvent.pointerUp(button)
    await waitFor(() => { expect(vi.mocked(core.service.setController).mock.lastCall?.[0].buttons).toBe(1 << 6) })
    vi.mocked(core.service.setController).mockClear()
    fireEvent.pointerLeave(button) // already let go: nothing more to send
    expect(core.service.setController).not.toHaveBeenCalled()
  })

  it("has no PS button while the settings take the input", async () => {
    await startStreaming()
    await userEvent.click(screen.getByRole("button", { name: /Settings/ }))
    expect(screen.queryByRole("button", { name: "PS button" })).not.toBeInTheDocument()
  })

  it("leaves the keyboard to the rest-mode dialog", async () => {
    const { core } = await startStreaming()
    await userEvent.click(screen.getByRole("button", { name: "Stop" }))
    await screen.findByRole("alertdialog")
    vi.mocked(core.service.setController).mockClear()
    fireEvent.keyDown(window, { code: "Enter" }) // the dialog's button, not ✕ on the console
    expect(core.service.setController).not.toHaveBeenCalledWith(expect.objectContaining({ buttons: 1 }))
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

describe("dev control port", () => {
  it("changes settings as the sheet would, and refuses invalid ones", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core)
    act(() => {
      core.emitDev({ type: "settings", patch: { view: "original", frameInterpolation: true } })
    })
    await waitFor(async () => {
      expect(await savedSettings(runtime)).toMatchObject({ view: "original", frameInterpolation: true })
    })
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(renderParams({ ...defaultSettings, view: "original", frameInterpolation: true }))
    act(() => {
      core.emitDev({ type: "settings", patch: { fps: 45 } })
    })
    expect(await screen.findByText("Dev control: those aren't valid settings")).toBeInTheDocument()
    expect((await savedSettings(runtime)).fps).toBe(60)
  })

  it("reconnects while streaming, and plays from the home screen", async () => {
    const core = fakeCore()
    renderApp(core, { accountId, paired: [pairedPs5] })
    await consoleItem()
    act(() => {
      core.emitDev({ type: "reconnect" }) // nothing to reconnect at home
      core.emitDev({ type: "play" })
    })
    await screen.findByRole("button", { name: "Stop" })
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
    act(() => {
      core.emitStream({ type: "connected" })
      core.emitDev({ type: "settings", patch: { fps: 30 } })
      core.emitDev({ type: "reconnect" })
    })
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(2)
    })
  })

  it("says when there's no console to play", async () => {
    const core = fakeCore()
    renderApp(core)
    await screen.findByRole("region", { name: "Consoles" })
    act(() => {
      core.emitDev({ type: "play" })
    })
    expect(await screen.findByText("Dev control: no paired console to play")).toBeInTheDocument()
  })
})

describe("settings profiles", () => {
  const savedProfiles = (runtime: ReturnType<typeof renderApp>["runtime"]) =>
    runtime.runPromise(Effect.gen(function* () {
      const prefs = yield* Preferences
      return yield* prefs.profiles
    }))

  it("starts on Recommended, saves the current settings under a name, switches and deletes", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core)
    const sheet = await openSettings("Picture")
    const profile = () => sheet.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(profile()).toHaveValue("Recommended")
    })
    expect(sheet.getByText("1080p60 · MetalFX · sharpness 0.3 · ML upscaling · Frame interpolation")).toBeInTheDocument()

    // A change of a picture setting makes it a custom mix.
    nudge("Sharpness", "ArrowRight", 2)
    expect(await sheet.findByText("Your own mix of settings. Save it to come back to it.")).toBeInTheDocument()

    // The built-in name is taken; a new one saves.
    await userEvent.click(sheet.getByRole("button", { name: "Save as…" }))
    await userEvent.type(sheet.getByRole("textbox", { name: "Profile name" }), "Recommended{Enter}")
    expect(await screen.findByText('"Recommended" is built in. Choose another name.')).toBeInTheDocument()
    await userEvent.clear(sheet.getByRole("textbox", { name: "Profile name" }))
    await userEvent.type(sheet.getByRole("textbox", { name: "Profile name" }), "Sharp{Enter}")
    expect(await screen.findByText('Saved "Sharp"')).toBeInTheDocument()
    await waitFor(() => {
      expect(profile()).toHaveValue("Sharp")
    })
    expect((await savedProfiles(runtime)).map((p) => p.name)).toEqual(["Sharp"])

    // Back to Recommended applies its settings.
    await userEvent.selectOptions(profile(), "Recommended")
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture())
    await userEvent.selectOptions(profile(), "Sharp")
    await waitFor(() => {
      expect(profile()).toHaveValue("Sharp")
    })

    await userEvent.click(sheet.getByRole("button", { name: "Delete Sharp" }))
    await waitFor(async () => {
      expect(await savedProfiles(runtime)).toEqual([])
    })
    expect(sheet.queryByRole("option", { name: "Sharp" })).not.toBeInTheDocument()
  })

  it("replaces a saved profile picked by name, keeping its place", async () => {
    const { runtime } = await startStreaming()
    const sheet = await openSettings("Picture")
    const profile = () => sheet.getByRole("combobox", { name: "Profile" })
    const nameBox = () => sheet.getByRole("textbox", { name: "Profile name" })
    await waitFor(() => {
      expect(profile()).toHaveValue("Recommended")
    })
    for (const name of ["Sharp", "Couch"]) {
      nudge("Sharpness", "ArrowRight", 1)
      await userEvent.click(await sheet.findByRole("button", { name: "Save as…" }))
      await userEvent.type(nameBox(), `${name}{Enter}`)
      expect(await screen.findByText(`Saved "${name}"`)).toBeInTheDocument()
    }

    // A new mix, saved over "Sharp" by picking it.
    nudge("Sharpness", "ArrowRight", 1)
    await userEvent.click(await sheet.findByRole("button", { name: "Save as…" }))
    expect(sheet.getByRole("button", { name: "Save" })).toBeInTheDocument()
    expect(sheet.queryByText(/with these settings/)).not.toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Sharp" }))
    expect(nameBox()).toHaveValue("Sharp")
    expect(nameBox()).toHaveFocus()
    expect(sheet.getByRole("button", { name: "Sharp" })).toHaveAttribute("aria-pressed", "true")
    expect(sheet.getByText('Replaces "Sharp" with these settings.')).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Replace" }))
    expect(await screen.findByText('Replaced "Sharp"')).toBeInTheDocument()
    await waitFor(() => {
      expect(profile()).toHaveValue("Sharp")
    })
    const saved = await savedProfiles(runtime)
    expect(saved.map((p) => p.name)).toEqual(["Sharp", "Couch"])
    expect(saved[0]?.settings.sharpness).toBeGreaterThan(saved[1]?.settings.sharpness ?? 1)
  })

  const profile = (name: string, overrides: Partial<Settings>): Profile => ({
    name,
    settings: profileSettings({ ...defaultSettings, ...overrides }),
  })

  it("turns Touchpad touches off and on mid-stream without asking to reconnect, from the switch or a profile", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, { profiles: [profile("Thumb rest", { touchpadTouches: false })] })
    await waitFor(() => {
      expect(core.service.setTouchpadTouches).toHaveBeenCalledWith(true) // saved settings applied at startup
    })
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")
    const touches = sheet.getByRole("switch", { name: /Touchpad touches/ })
    expect(touches).toBeChecked()
    expect(sheet.getByText(/in GTA VI it opens the map/)).toBeInTheDocument()

    await userEvent.click(touches)
    expect(touches).not.toBeChecked()
    await waitFor(() => {
      expect(core.service.setTouchpadTouches).toHaveBeenLastCalledWith(false)
    })
    await waitFor(async () => {
      expect((await savedSettings(runtime)).touchpadTouches).toBe(false)
    })
    expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    expect(sheet.getByRole("combobox", { name: "Profile" })).toHaveValue("Thumb rest") // the profile's mix
    await userEvent.click(touches)
    await waitFor(() => {
      expect(core.service.setTouchpadTouches).toHaveBeenLastCalledWith(true)
    })

    // A profile that turns them off applies at once too.
    const select = sheet.getByRole("combobox", { name: "Profile" })
    expect(within(select).getByRole("option", { name: "Thumb rest · applies now" })).toBeInTheDocument()
    await userEvent.selectOptions(select, "Thumb rest")
    expect(await screen.findByText("Switched to Thumb rest")).toBeInTheDocument()
    await waitFor(() => {
      expect(core.service.setTouchpadTouches).toHaveBeenLastCalledWith(false)
    })
    expect(sheet.getByRole("switch", { name: /Touchpad touches/ })).not.toBeChecked()
    expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    expect(core.service.startStream).not.toHaveBeenCalled()
  })

  it("switches to the built-in GTA VI profile: 30 fps after a reconnect, touchpad click only at once", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core)
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")
    const select = sheet.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(select).toHaveValue("Recommended")
    })
    expect(within(select).getByRole("option", { name: "GTA VI · needs a reconnect" })).toBeInTheDocument()

    await userEvent.selectOptions(select, "GTA VI")
    expect(await screen.findByText("Switched to GTA VI · reconnect to apply")).toBeInTheDocument()
    await waitFor(() => {
      expect(core.service.setTouchpadTouches).toHaveBeenLastCalledWith(false)
    })
    expect(sheet.getByRole("switch", { name: /Touchpad touches/ })).not.toBeChecked()
    expect(sheet.getByText("1080p30 · MetalFX · sharpness 0.3 · ML upscaling · Frame interpolation · touchpad click only")).toBeInTheDocument()
    await waitFor(async () => {
      expect(await savedSettings(runtime)).toEqual({ ...defaultSettings, fps: 30, touchpadTouches: false })
    })
    // Built in: no delete, and its name can't be saved over.
    expect(sheet.queryByRole("button", { name: "Delete GTA VI" })).not.toBeInTheDocument()
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnect to use the new stream settings.")
    expect(core.service.startStream).not.toHaveBeenCalled()
    await userEvent.click(sheet.getByRole("button", { name: "Reconnect" }))
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.objectContaining({ fps: 30, bitrate: 20000 }), undefined)
    })

    await userEvent.click(sheet.getByRole("button", { name: "Save as…" }))
    await userEvent.type(sheet.getByRole("textbox", { name: "Profile name" }), "GTA VI{Enter}")
    expect(await screen.findByText('"GTA VI" is built in. Choose another name.')).toBeInTheDocument()
  })

  it("keeps a profile saved as GTA VI before it was built in, as GTA VI (saved)", async () => {
    const { runtime } = await startStreaming(fakeCore(), { profiles: [profile("GTA VI", { touchpadTouches: false, sharpness: 0.6 })] })
    const sheet = await openSettings("Picture")
    const select = sheet.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(within(select).getAllByRole("option").map((o) => (o as HTMLOptionElement).value)).toEqual([
        "Recommended",
        "GTA VI",
        "GTA VI (saved)",
      ])
    })
    await userEvent.selectOptions(select, "GTA VI (saved)")
    expect(await screen.findByText("Switched to GTA VI (saved)")).toBeInTheDocument()
    expect(select).toHaveValue("GTA VI (saved)")

    // Only saved profiles to replace, under the name they show with.
    nudge("Sharpness", "ArrowRight")
    await userEvent.click(await sheet.findByRole("button", { name: "Save as…" }))
    const replace = within(sheet.getByRole("group", { name: "Replace a saved profile" }))
    expect(replace.getAllByRole("button").map((b) => b.textContent)).toEqual(["GTA VI (saved)"])
    await userEvent.click(replace.getByRole("button", { name: "GTA VI (saved)" }))
    await userEvent.click(sheet.getByRole("button", { name: "Replace" }))
    expect(await screen.findByText('Replaced "GTA VI (saved)"')).toBeInTheDocument()
    await waitFor(async () => {
      expect((await savedProfiles(runtime)).map((p) => [p.name, p.settings.sharpness])).toEqual([["GTA VI (saved)", 0.65]])
    })

    await userEvent.click(sheet.getByRole("button", { name: "Delete GTA VI (saved)" }))
    await waitFor(async () => {
      expect(await savedProfiles(runtime)).toEqual([])
    })
    expect(within(select).queryByRole("option", { name: /saved/ })).not.toBeInTheDocument()
  })

  it("can select and delete a profile saved as GTA VI with the built-in GTA VI's settings", async () => {
    const { runtime } = await startStreaming(fakeCore(), { profiles: [profile("GTA VI", { fps: 30, touchpadTouches: false })] })
    const sheet = await openSettings("Picture")
    const select = sheet.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(within(select).getAllByRole("option").map((o) => (o as HTMLOptionElement).value)).toEqual([
        "Recommended",
        "GTA VI",
        "GTA VI (saved)",
      ])
    })
    await userEvent.selectOptions(select, "GTA VI (saved)")
    expect(await screen.findByText(/Switched to GTA VI \(saved\)/)).toBeInTheDocument()
    expect(select).toHaveValue("GTA VI (saved)")

    await userEvent.click(sheet.getByRole("button", { name: "Delete GTA VI (saved)" }))
    await waitFor(async () => {
      expect(await savedProfiles(runtime)).toEqual([])
    })
    // The same settings now match the built-in, which can't be deleted.
    await waitFor(() => {
      expect(select).toHaveValue("GTA VI")
    })
    expect(sheet.queryByRole("button", { name: /^Delete/ })).not.toBeInTheDocument()
  })

  it("switches profiles from Home, sharing the saved ones with Settings", async () => {
    const { runtime } = renderApp(fakeCore(), { profiles: [profile("Couch", { height: 720, sharpness: 0 })] })
    const home = screen.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(home).toHaveValue("Recommended")
    })
    // Not streaming: the options are just the names.
    expect(within(home).getAllByRole("option").map((o) => o.textContent)).toEqual(["Recommended", "GTA VI", "Couch"])

    await userEvent.selectOptions(home, "Couch")
    expect(await screen.findByText("Switched to Couch")).toBeInTheDocument()
    expect(screen.getByText("720p · 60 fps · HEVC · 20 Mbps")).toBeInTheDocument()
    await waitFor(async () => {
      expect((await savedSettings(runtime)).height).toBe(720)
    })

    // A profile saved in Settings shows on Home too.
    const sheet = await openSettings("Picture")
    nudge("Sharpness", "ArrowRight", 2)
    await waitFor(() => {
      expect(home).toHaveValue("")
    })
    await userEvent.click(sheet.getByRole("button", { name: "Save as…" }))
    await userEvent.type(sheet.getByRole("textbox", { name: "Profile name" }), "Sharp{Enter}")
    await waitFor(() => {
      expect(home).toHaveValue("Sharp")
    })
  })

  it("shows Custom on Home when the settings match no profile", async () => {
    renderApp(fakeCore(), { settings: { ...defaultSettings, sharpness: 0.9 } })
    const home = screen.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(home).toHaveValue("")
    })
    expect(within(home).getByRole("option", { name: "Custom" })).toBeDisabled()
  })

  it("says what a switch costs while streaming, and waits for Reconnect even for a bitrate", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, {
      testClock: true,
      profiles: [profile("Sharp", { sharpness: 0.9 }), profile("Fast", { bitrate: 15000 })],
    })
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Picture")
    const select = sheet.getByRole("combobox", { name: "Profile" })
    await waitFor(() => {
      expect(within(select).getAllByRole("option").map((o) => o.textContent)).toEqual([
        "Recommended",
        "GTA VI · needs a reconnect",
        "Sharp · applies now",
        "Fast · needs a reconnect",
      ])
    })

    // Picture only: applied at once, nothing to reconnect.
    await userEvent.selectOptions(select, "Sharp")
    expect(await screen.findByText("Switched to Sharp")).toBeInTheDocument()
    expect(core.service.setRenderParams).toHaveBeenLastCalledWith(picture({ sharpness: 0.9 }))
    expect(sheet.queryByRole("status")).not.toBeInTheDocument()

    // Only the bitrate differs, but a profile asks first: the stream keeps going until Reconnect.
    await userEvent.selectOptions(select, "Fast")
    expect(await screen.findByText("Switched to Fast · reconnect to apply")).toBeInTheDocument()
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnect to use the new stream settings.")
    await wait(3)
    expect(core.service.startStream).not.toHaveBeenCalled()
    await userEvent.click(sheet.getByRole("button", { name: "Reconnect" }))
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.objectContaining({ bitrate: 15000 }), undefined)
    })
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    })

    // The bitrate slider still applies on its own after that.
    vi.mocked(core.service.startStream).mockClear()
    await userEvent.click(sheet.getByRole("tab", { name: "Stream" }))
    nudge("Bitrate", "ArrowRight")
    await wait(2)
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
  })

  it("holds a profile switch for Reconnect until the bitrate slider moves", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, { testClock: true, profiles: [profile("Fast", { bitrate: 10000 })] })
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")

    await userEvent.selectOptions(sheet.getByRole("combobox", { name: "Profile" }), "Fast")
    await wait(3)
    expect(core.service.startStream).not.toHaveBeenCalled()

    // Changed another way: the slider's bitrate applies on its own once it settles.
    nudge("Bitrate", "ArrowRight")
    await wait(2)
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
    expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.objectContaining({ bitrate: 15000 }), undefined)
  })

  it("holds a profile switch made while a bitrate is still settling on the slider", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, {
      testClock: true,
      profiles: [profile("Fast and sharp", { bitrate: 30000, sharpness: 0.9 })],
    })
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")

    // The slider reaches the profile's bitrate; before it settles, the profile changes only the picture
    // from here, but the stream started without that bitrate: the switch asks first.
    nudge("Bitrate", "ArrowRight")
    await userEvent.selectOptions(sheet.getByRole("combobox", { name: "Profile" }), "Fast and sharp")
    expect(await screen.findByText("Switched to Fast and sharp · reconnect to apply")).toBeInTheDocument()
    await wait(3)
    expect(core.service.startStream).not.toHaveBeenCalled()
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnect to use the new stream settings.")
  })

  it("measures a profile switch made during a bitrate reconnect against the bitrate it reconnects with", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, { testClock: true, profiles: [profile("Sharp", { sharpness: 0.9 })] })
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")

    // The slider's bitrate settles and the stream reconnects with it.
    nudge("Bitrate", "ArrowRight")
    await wait(2)
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })
    expect(core.service.startStream).toHaveBeenLastCalledWith(credentials, expect.objectContaining({ bitrate: 30000 }), undefined)

    // Before it's back, a profile with the bitrate the stream had: it differs from the one coming, so it asks first.
    const select = sheet.getByRole("combobox", { name: "Profile" })
    expect(within(select).getByRole("option", { name: "Sharp · needs a reconnect" })).toBeInTheDocument()
    await userEvent.selectOptions(select, "Sharp")
    expect(await screen.findByText("Switched to Sharp · reconnect to apply")).toBeInTheDocument()
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await wait(3)
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
    expect(sheet.getByRole("status")).toHaveTextContent("Reconnect to use the new stream settings.")
  })

  it("applies at once a profile switch matching the bitrate a reconnect under way starts with", async () => {
    const core = fakeCore()
    const { runtime } = await startStreaming(core, {
      testClock: true,
      profiles: [profile("Fast and sharp", { bitrate: 30000, sharpness: 0.9 })],
    })
    const wait = (seconds: number) => act(() => runtime.runPromise(TestClock.adjust(seconds * 1000)))
    vi.mocked(core.service.startStream).mockClear()
    const sheet = await openSettings("Stream")

    nudge("Bitrate", "ArrowRight")
    await wait(2)
    await waitFor(() => {
      expect(core.service.startStream).toHaveBeenCalledTimes(1)
    })

    // The profile's bitrate is the one the stream is reconnecting with: only its picture changes.
    const select = sheet.getByRole("combobox", { name: "Profile" })
    expect(within(select).getByRole("option", { name: "Fast and sharp · applies now" })).toBeInTheDocument()
    await userEvent.selectOptions(select, "Fast and sharp")
    expect(await screen.findByText("Switched to Fast and sharp")).toBeInTheDocument()
    act(() => {
      core.emitStream({ type: "connected" })
    })
    await waitFor(() => {
      expect(sheet.queryByRole("status")).not.toBeInTheDocument()
    })
    await wait(3)
    expect(core.service.startStream).toHaveBeenCalledTimes(1)
  })

  it("can cancel naming a profile, and refuses an empty name", async () => {
    await startStreaming()
    const sheet = await openSettings("Stream")
    await userEvent.click(sheet.getByRole("button", { name: "Save as…" }))
    // Nothing saved yet: nothing to replace.
    expect(sheet.queryByRole("group", { name: "Replace a saved profile" })).not.toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Save" }))
    expect(await screen.findByText("Give the profile a name of up to 40 characters.")).toBeInTheDocument()
    await userEvent.click(sheet.getByRole("button", { name: "Cancel" }))
    expect(sheet.queryByRole("textbox", { name: "Profile name" })).not.toBeInTheDocument()
  })
})

describe("console IP", () => {
  it("is folded under a list with consoles, refuses what isn't an IP, and saves on Enter", async () => {
    const core = fakeCore()
    const { runtime } = renderApp(core, { accountId, paired: [pairedPs5] })
    await consoleItem()
    expect(screen.queryByLabelText("Console IP address")).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Console missing? Add it by IP" }))
    const field = await screen.findByLabelText("Console IP address")
    await userEvent.type(field, "ps5.local")
    expect(screen.getByText("That isn't an IP address. It looks like 192.168.1.20.")).toBeInTheDocument()
    expect(field).toHaveAttribute("aria-invalid", "true")
    await userEvent.clear(field)
    await userEvent.type(field, " 192.168.1.20 {Enter}")
    await waitFor(async () => {
      expect((await savedSettings(runtime)).consoleAddress).toBe("192.168.1.20")
    })
    fireEvent.blur(field) // nothing new to save
  })

  it("keeps the last address typed for next time, shown open", async () => {
    renderApp(fakeCore(), { accountId, paired: [pairedPs5], settings: { ...defaultSettings, consoleAddress: "192.168.1.20" } })
    expect(await screen.findByLabelText("Console IP address")).toHaveValue("192.168.1.20")
  })

  it("asks the console at that address directly, lists it, and plays it in Automatic", async () => {
    const core = fakeCore({
      discover: Effect.succeed([]),
      discoverAt: vi.fn(() => Effect.succeed([{ ...ps5, address: "192.168.1.20" }])),
    })
    renderApp(core, { accountId, paired: [pairedPs5], settings: { ...defaultSettings, consoleAddress: "192.168.1.20" } })
    const item = await consoleItem()
    expect(core.service.discoverAt).toHaveBeenCalledWith("192.168.1.20")
    expect(await item.findByText("ready")).toBeInTheDocument()
    await userEvent.click(item.getByRole("button", { name: "Play" }))
    await waitFor(() => {
      // At the address it answered on, which the pairing now keeps.
      expect(core.service.startStream).toHaveBeenCalledWith({ ...credentials, address: "192.168.1.20" }, expect.anything(), undefined)
    })
  })

  it("keeps scanning when the direct ask fails", async () => {
    const core = fakeCore({ discoverAt: () => Effect.fail(coreError("discover", "no route")) })
    renderApp(core, { accountId, paired: [pairedPs5], settings: { ...defaultSettings, connection: "local", consoleAddress: "10.0.0.9" } })
    await consoleItem()
    expect(screen.queryByText(/Discovery failed/)).not.toBeInTheDocument()
  })
})
