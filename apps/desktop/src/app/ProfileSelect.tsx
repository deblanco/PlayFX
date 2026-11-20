import { Option } from "effect"
import { createContext, use, useEffect, useState, type ReactNode } from "react"
import { toast } from "sonner"
import { NativeSelect, NativeSelectOption } from "@/components/ui/native-select"
import type { Profile, Settings, StreamOptions } from "@/core/schema"
import * as actions from "./actions"
import { allProfiles, applyProfile, matchingProfile, needsReconnect } from "./profiles"
import { useRun } from "./runtime"

/** A settings change, and whether it came from a profile switch: that one waits for Reconnect, even when
 * only the bitrate differs (a bitrate moved on the slider is applied on its own). */
export type ChangeSettings = (next: Settings, from?: "profile") => void

interface SavedProfiles {
  readonly saved: readonly Profile[]
  readonly setSaved: (saved: readonly Profile[]) => void
}

const SavedProfilesContext = createContext<SavedProfiles | null>(null)

/** One list of saved profiles for the whole app: the Home switcher and the Settings Profile bar (on Home
 * and while streaming) show the same profiles, and one saved or deleted in either shows in both. */
export const ProfilesProvider = ({ children }: { readonly children: ReactNode }) => {
  const run = useRun()
  const [saved, setSaved] = useState<readonly Profile[]>([])
  useEffect(() => { run(actions.loadProfiles, { onSuccess: setSaved }) }, [run])
  return <SavedProfilesContext value={{ saved, setSaved }}>{children}</SavedProfilesContext>
}

export const useSavedProfiles = (): SavedProfiles => {
  const profiles = use(SavedProfilesContext)
  if (profiles === null) throw new Error("Profiles need a <ProfilesProvider> above them")
  return profiles
}

/** Picks a profile to apply its stream and picture settings; "Custom" when the settings match none.
 * While streaming (`running`: the options the stream runs with), each other profile says what
 * switching to it costs: "applies now" (picture only) or "needs a reconnect" (stream settings). */
export const ProfileSelect = ({ id, settings, running, onChange, className }: {
  readonly id: string
  readonly settings: Settings
  readonly running: StreamOptions | undefined
  readonly onChange: ChangeSettings
  readonly className?: string
}) => {
  const { saved } = useSavedProfiles()
  const profiles = allProfiles(saved)
  const selected = Option.getOrUndefined(matchingProfile(settings, profiles))
  const label = (profile: Profile): string => {
    if (running === undefined || profile.name === selected?.name) return profile.name
    return `${profile.name} · ${needsReconnect(settings, profile, running) ? "needs a reconnect" : "applies now"}`
  }
  return (
    <NativeSelect
      id={id}
      value={selected?.name ?? ""}
      onChange={(event) => {
        const profile = profiles.find((p) => p.name === event.target.value)
        if (!profile) return
        const reconnect = running !== undefined && needsReconnect(settings, profile, running)
        onChange(applyProfile(settings, profile), "profile")
        toast.success(`Switched to ${profile.name}${reconnect ? " · reconnect to apply" : ""}`)
      }}
      className={className}
    >
      {selected === undefined && <NativeSelectOption value="" disabled>Custom</NativeSelectOption>}
      {profiles.map((p) => <NativeSelectOption key={p.name} value={p.name}>{label(p)}</NativeSelectOption>)}
    </NativeSelect>
  )
}
