import { act, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { Deferred, Effect, Option } from "effect"
import { TestClock } from "effect/testing"
import { describe, expect, it, vi } from "vitest"
import { Preferences } from "@/core/preferences"
import { UpdaterError } from "@/core/updater"
import { accountId, fakeCore, fakeUpdater, pairedPs5, renderApp, type FakeCore, type FakeUpdater, type StoredPrefs } from "./testing"
import { useUpdates } from "./Updates"

/** An updater that finds `version`. */
const finding = (version = "0.2.5", overrides: Parameters<typeof fakeUpdater>[0] = {}): FakeUpdater => {
  const updater = fakeUpdater(overrides)
  updater.state.check = { status: "available", version, currentVersion: "0.2.4" }
  return updater
}

/** Opens the app and lets the launch check run (5 s in). */
const launch = async (updater: FakeUpdater, prefs: StoredPrefs = {}, core: FakeCore = fakeCore()) => {
  const app = renderApp(core, prefs, { testClock: true, updater })
  const wait = (ms: number) => act(() => app.runtime.runPromise(TestClock.adjust(ms)))
  await screen.findByRole("region", { name: "Consoles" })
  await wait(5000)
  return { ...app, core, wait }
}

const banner = async () => within(await screen.findByRole("region", { name: "PlayFX update" }))
const noBanner = () => {
  expect(screen.queryByRole("region", { name: "PlayFX update" })).not.toBeInTheDocument()
}

/** A deferred step for an install the test lets go on. */
const step = () => Effect.runSync(Deferred.make<boolean>())
const go = (deferred: Deferred.Deferred<boolean>) => {
  act(() => { Effect.runSync(Deferred.succeed(deferred, true)) })
}

describe("the update banner", () => {
  it("shows a newer release on Home once the launch check finds it", async () => {
    const updater = finding()
    const app = renderApp(fakeCore(), {}, { testClock: true, updater })
    await screen.findByRole("region", { name: "Consoles" })
    await act(() => app.runtime.runPromise(TestClock.adjust(4999)))
    noBanner()
    expect(updater.calls.checks).toEqual([])
    await act(() => app.runtime.runPromise(TestClock.adjust(1)))
    const b = await banner()
    expect(b.getByText("PlayFX 0.2.5 is available.")).toBeInTheDocument()
    expect(updater.calls.checks).toEqual([true])
    await userEvent.click(b.getByRole("button", { name: "What's new" }))
    expect(updater.calls.opened).toEqual(["0.2.5"])
    expect(b.getByRole("button", { name: "Update" })).toBeEnabled()
  })

  it("stays away while PlayFX is up to date", async () => {
    const updater = fakeUpdater()
    await launch(updater)
    expect(updater.calls.checks).toEqual([true])
    noBanner()
  })

  it("downloads with progress, then restarts", async () => {
    const [sized, done] = [step(), step()]
    const updater = finding("0.2.5", {
      install: (onProgress) =>
        Effect.gen(function* () {
          onProgress(undefined)
          yield* Deferred.await(sized)
          onProgress(42)
          yield* Deferred.await(done)
        }),
    })
    await launch(updater)
    await userEvent.click((await banner()).getByRole("button", { name: "Update" }))
    const b = await banner()
    expect(await b.findByText("Downloading…")).toBeInTheDocument()
    expect(b.queryByRole("button", { name: "Update" })).not.toBeInTheDocument()
    expect(b.queryByRole("button", { name: "Later" })).not.toBeInTheDocument()
    go(sized)
    expect(await b.findByText("Downloading… 42%")).toBeInTheDocument()
    go(done)
    expect(await b.findByText("Restarting…")).toBeInTheDocument()
    await waitFor(() => {
      expect(updater.calls.restarts).toBe(1)
    })
  })

  it("says why an update failed and offers the download from GitHub", async () => {
    const updater = finding("0.2.5", { install: () => Effect.fail(new UpdaterError({ message: "Permission denied (os error 13)" })) })
    await launch(updater)
    await userEvent.click((await banner()).getByRole("button", { name: "Update" }))
    const b = await banner()
    expect(await b.findByText("Couldn't update to PlayFX 0.2.5.")).toBeInTheDocument()
    expect(b.getByText("Permission denied (os error 13)")).toBeInTheDocument()
    expect(updater.calls.restarts).toBe(0)
    await userEvent.click(b.getByRole("button", { name: "Download from GitHub" }))
    expect(updater.calls.opened).toEqual(["0.2.5"])
    await userEvent.click(b.getByRole("button", { name: "Later" }))
    noBanner()
  })

  it("Later hides that version only: a newer one shows it again", async () => {
    const updater = finding("0.2.5")
    const { runtime, wait } = await launch(updater)
    await userEvent.click((await banner()).getByRole("button", { name: "Later" }))
    noBanner()
    const stored = await runtime.runPromise(Effect.flatMap(Preferences, (prefs) => prefs.dismissedUpdate))
    expect(stored).toEqual(Option.some("0.2.5"))
    await wait(6 * 3600_000)
    expect(updater.calls.checks).toHaveLength(2)
    noBanner()
    updater.state.check = { status: "available", version: "0.2.6", currentVersion: "0.2.4" }
    await wait(6 * 3600_000)
    expect((await banner()).getByText("PlayFX 0.2.6 is available.")).toBeInTheDocument()
  })

  it("waits for a stream to finish: Update is off while one starts, and the banner never covers the stream", async () => {
    const updater = finding()
    const core = fakeCore({ startStream: () => Effect.never })
    await launch(updater, { accountId, paired: [pairedPs5] }, core)
    const consoles = within(await screen.findByRole("region", { name: "Consoles" }))
    await userEvent.click(await consoles.findByRole("button", { name: "Play" }))
    const b = await banner()
    expect(await b.findByText("Finish playing to update")).toBeInTheDocument()
    expect(b.getByRole("button", { name: "Update" })).toBeDisabled()
    expect(updater.calls.installs).toBe(0)
  })

  it("isn't over the stream", async () => {
    const updater = finding()
    await launch(updater, { accountId, paired: [pairedPs5] })
    await banner()
    const consoles = within(await screen.findByRole("region", { name: "Consoles" }))
    await userEvent.click(await consoles.findByRole("button", { name: "Play" }))
    await screen.findByRole("button", { name: "Stop" })
    noBanner()
  })
})

/** Opens Settings › Diagnostics from Home. */
const diagnostics = async () => {
  await userEvent.click(screen.getByRole("button", { name: /Settings/ }))
  const sheet = within(await screen.findByRole("dialog", { name: "Settings" }))
  await userEvent.click(sheet.getByRole("tab", { name: "Diagnostics" }))
  return sheet
}

describe("Check for updates (Settings › Diagnostics)", () => {
  it("says PlayFX is up to date", async () => {
    const updater = fakeUpdater()
    updater.state.check = { status: "upToDate", currentVersion: "0.2.4" }
    renderApp(fakeCore(), {}, { updater })
    const sheet = await diagnostics()
    await userEvent.click(sheet.getByRole("button", { name: "Check for updates" }))
    expect(await sheet.findByRole("status", { name: "Update check" })).toHaveTextContent("PlayFX is up to date (0.2.4)")
    expect(updater.calls.checks).toEqual([false])
  })

  it("says plainly when it couldn't check", async () => {
    const updater = fakeUpdater()
    updater.state.checkError = "error sending request for url"
    renderApp(fakeCore(), {}, { updater })
    const sheet = await diagnostics()
    await userEvent.click(sheet.getByRole("button", { name: "Check for updates" }))
    expect(await sheet.findByRole("status", { name: "Update check" })).toHaveTextContent(
      "Couldn't check for updates: error sending request for url",
    )
    expect(sheet.getByRole("button", { name: "Check for updates" })).toBeEnabled()
  })

  it("shows a release put off with Later again", async () => {
    const updater = finding("0.2.5")
    await launch(updater, { dismissedUpdate: "0.2.5" })
    noBanner()
    const sheet = await diagnostics()
    await userEvent.click(sheet.getByRole("button", { name: "Check for updates" }))
    expect(await sheet.findByRole("status", { name: "Update check" })).toHaveTextContent("PlayFX 0.2.5 is available.")
    await userEvent.keyboard("{Escape}")
    expect((await banner()).getByText("PlayFX 0.2.5 is available.")).toBeInTheDocument()
  })
})

describe("useUpdates", () => {
  it("needs an UpdatesProvider", () => {
    const Probe = () => {
      useUpdates()
      return null
    }
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    expect(() => render(<Probe />)).toThrow(/UpdatesProvider/)
  })
})
