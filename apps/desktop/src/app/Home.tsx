import { Option } from "effect"
import { CircleQuestionMark, SlidersHorizontal } from "lucide-react"
import { useCallback, useEffect, useId, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Separator } from "@/components/ui/separator"
import type { PairedConsole, Settings } from "@/core/schema"
import * as actions from "./actions"
import { AccountSection } from "./AccountSection"
import { ConsoleList } from "./ConsoleList"
import { GetStarted } from "./GetStarted"
import { useRun } from "./runtime"
import { streamSummary, type Capabilities } from "./format"
import { ProfileSelect, type ChangeSettings } from "./ProfileSelect"
import { Segmented, SettingsSheet, type SettingsTab } from "./SettingsSheet"
import { SteadyWifiRow } from "./SteadyWifi"
import { UpdateBanner } from "./Updates"

const connectionDescription: Readonly<Record<Settings["connection"], string>> = {
  auto: "Tries your home network first, and goes through PSN if the console can't be reached there.",
  local: "Only on your home network. Fastest to connect.",
  internet: "Always through PSN, even at home. Needs a PSN sign-in; takes 20 to 40 seconds to connect.",
}

interface HomeProps {
  readonly settings: Settings
  readonly capabilities: Capabilities
  readonly onSettingsChange: ChangeSettings
  /** `psnFallback`: playing locally, the console's PSN device ID, if PSN can reach it too. */
  readonly onPlay: (console: PairedConsole, psnDuid?: string, psnFallback?: string) => void
}

export const Home = ({ settings, capabilities, onSettingsChange, onPlay }: HomeProps) => {
  const run = useRun()
  const [accountId, setAccountId] = useState<Option.Option<string>>(Option.none())
  const [settingsOpen, setSettingsOpen] = useState(false)
  // Unknown until the console list has loaded the pairings, so the guide never flashes for set-up users.
  const [hasPaired, setHasPaired] = useState<boolean | undefined>(undefined)
  // The guide shows while nothing is paired, and stays after pairing so its last step, Play, shows. Play
  // leaves Home, so it's gone on the way back.
  const [guide, setGuide] = useState(false)
  const pairedChanged = useCallback((paired: boolean) => {
    setHasPaired(paired)
    if (!paired) setGuide(true)
  }, [])
  const [tab, setTab] = useState<SettingsTab>("stream")
  const profileId = useId()

  useEffect(() => {
    run(actions.loadAccount, { onSuccess: setAccountId })
  }, [run])

  return (
    <main className="flex min-h-svh flex-col items-center justify-center gap-7 p-6">
      <header className="text-center">
        <h1 className="font-display text-6xl font-semibold tracking-[-0.01em] text-white [text-shadow:0_0_28px_var(--color-ribbon)]">
          PlayFX
        </h1>
      </header>
      <UpdateBanner />
      <Card className="w-full max-w-xl bg-card/70 shadow-2xl backdrop-blur-xl">
        <CardContent className="flex flex-col gap-4">
          {guide && (
            <>
              <GetStarted signedIn={Option.isSome(accountId)} paired={hasPaired === true} />
              <Separator />
            </>
          )}
          <AccountSection accountId={accountId} onChange={setAccountId} />
          <Separator />
          <ConsoleList
            accountId={accountId}
            connection={settings.connection}
            onPlay={onPlay}
            onPairedChange={pairedChanged}
            consoleAddress={settings.consoleAddress}
            onConsoleAddressChange={(consoleAddress) => { onSettingsChange({ ...settings, consoleAddress }) }}
          />
          <div className="flex flex-col gap-1.5">
            <Segmented
              label="Connect"
              value={settings.connection}
              options={[
                { value: "auto", label: "Automatic" },
                { value: "local", label: "Home network" },
                { value: "internet", label: "Internet" },
              ]}
              onChange={(connection) => { onSettingsChange({ ...settings, connection }) }}
            />
            <p className="text-xs text-muted-foreground">{connectionDescription[settings.connection]}</p>
          </div>
          <SteadyWifiRow />
          <Separator />
          <div className="flex items-center gap-3">
            <Label htmlFor={profileId} className="text-xs text-muted-foreground">Profile</Label>
            <ProfileSelect id={profileId} settings={settings} running={undefined} onChange={onSettingsChange} className="w-36 shrink-0" />
            <p className="min-w-0 flex-1 text-xs text-muted-foreground tabular-nums">{streamSummary(settings)}</p>
            <Button variant="ghost" size="sm" onClick={() => { run(actions.openHelp) }}>
              <CircleQuestionMark /> Help
            </Button>
            <Button variant="secondary" size="sm" onClick={() => { setSettingsOpen(true) }}>
              <SlidersHorizontal /> Settings
            </Button>
          </div>
        </CardContent>
      </Card>
      <SettingsSheet
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        tab={tab}
        onTabChange={setTab}
        settings={settings}
        capabilities={capabilities}
        onChange={onSettingsChange}
      />
    </main>
  )
}
