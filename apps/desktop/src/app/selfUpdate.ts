import { Effect, Option, Schedule } from "effect"
import type { StorageError } from "@/core/errors"
import { Preferences } from "@/core/preferences"
import { finishPlaying, UpdateDeferred, Updater, type UpdateCheck, type UpdaterError } from "@/core/updater"

// Telling the user about a new release and updating in one click (the Home banner, Settings › Diagnostics).

/** The background check runs this long after launch, then every `checkInterval` while the app is open. */
export const firstCheckDelay = "5 seconds"
export const checkInterval = "6 hours"

/** The background check: each result goes to `report`; a failure is left for the next one (the native
 * side logs it). In development builds the native side answers "off" without asking. */
export const checkPeriodically = (report: (check: UpdateCheck) => void): Effect.Effect<unknown, never, Updater> =>
  Effect.flatMap(Updater, (updater) =>
    Effect.andThen(
      Effect.sleep(firstCheckDelay),
      updater.check(true).pipe(
        Effect.flatMap((check) => Effect.sync(() => { report(check) })),
        Effect.ignore,
        Effect.repeat(Schedule.spaced(checkInterval)),
      ),
    ),
  )

/** Checking by hand (Settings › Diagnostics). */
export const checkForUpdates: Effect.Effect<UpdateCheck, UpdaterError, Updater> = Effect.flatMap(Updater, (u) => u.check(false))

/** What a check by hand found, as the Diagnostics panel says it. */
export const checkLine = (check: UpdateCheck): string => {
  switch (check.status) {
    case "available":
      return `PlayFX ${check.version} is available.`
    case "upToDate":
      return `PlayFX is up to date (${check.currentVersion})`
    case "off":
      return `Automatic update checks are off in this build (${check.currentVersion})`
  }
}

/** Downloads, verifies and installs the update. While a stream runs or starts nothing installs: UpdateDeferred. */
export const installUpdate = (
  onProgress: (percent: number | undefined) => void,
): Effect.Effect<void, UpdaterError | UpdateDeferred, Updater> => Effect.flatMap(Updater, (updater) => updater.install(onProgress))

/** Restarts into the installed update, `onRestarting` first. While `playing()` says the app is playing, or the
 * native side finds a stream, it doesn't (UpdateDeferred): the update waits for a restart. */
export const restartIntoUpdate = (
  playing: () => boolean,
  onRestarting: () => void,
): Effect.Effect<void, UpdaterError | UpdateDeferred, Updater> =>
  Effect.flatMap(Updater, (updater) =>
    Effect.suspend(() =>
      playing() ? Effect.fail(new UpdateDeferred({ message: finishPlaying })) : Effect.andThen(Effect.sync(onRestarting), updater.restart),
    ),
  )

/** Whether the app is playing, from Play until it's back home: the native side installs and restarts only when not. */
export const setPlaying = (playing: boolean): Effect.Effect<void, UpdaterError, Updater> =>
  Effect.flatMap(Updater, (u) => u.setPlaying(playing))

export const openReleasePage = (version: string): Effect.Effect<void, UpdaterError, Updater> =>
  Effect.flatMap(Updater, (u) => u.openReleasePage(version))

/** The version the user put off with "Later" (none when it can't be read). */
export const loadDismissedUpdate: Effect.Effect<Option.Option<string>, never, Preferences> = Effect.flatMap(
  Preferences,
  (prefs) => Effect.orElseSucceed(prefs.dismissedUpdate, () => Option.none()),
)

export const dismissUpdate = (version: string): Effect.Effect<void, StorageError, Preferences> =>
  Effect.flatMap(Preferences, (prefs) => prefs.saveDismissedUpdate(version))
