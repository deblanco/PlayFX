import { Option } from "effect"
import { SlidersHorizontal } from "lucide-react"
import { useEffect, useId, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Separator } from "@/components/ui/separator"
import type { PairedConsole, Settings } from "@/core/schema"
import * as actions from "./actions"
import { AccountSection } from "./AccountSection"
import { ConsoleList } from "./ConsoleList"
import { GetStarted } from "./GetStarted"
import { useRun } from "./runtime"
import { isIpv4, streamSummary, type Capabilities } from "./format"
import { Segmented, SettingsSheet, type SettingsTab } from "./SettingsSheet"

const connectionDescription: Readonly<Record<Settings["connection"], string>> = {
  auto: "Tries your home network first, and goes through PSN if the console can't be reached there.",
  local: "Only on your home network. Fastest to connect.",
  internet: "Always through PSN, even at home. Needs a PSN sign-in; takes 20 to 40 seconds to connect.",
}

interface HomeProps {
  readonly settings: Settings
  readonly capabilities: Capabilities
  readonly onSettingsChange: (next: Settings) => void
  /** `psnFallback`: playing locally, the console's PSN device ID, if PSN can reach it too. */
  readonly onPlay: (console: PairedConsole, psnDuid?: string, psnFallback?: string) => void
}

export const Home = ({ settings, capabilities, onSettingsChange, onPlay }: HomeProps) => {
  const run = useRun()
  const [accountId, setAccountId] = useState<Option.Option<string>>(Option.none())
  const [settingsOpen, setSettingsOpen] = useState(false)
  // Unknown until the console list has loaded the pairings, so the guide never flashes for set-up users.
  const [hasPaired, setHasPaired] = useState<boolean | undefined>(undefined)
  const [tab, setTab] = useState<SettingsTab>("stream")

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
      <Card className="w-full max-w-xl bg-card/70 shadow-2xl backdrop-blur-xl">
        <CardContent className="flex flex-col gap-4">
          {hasPaired === false && (
            <>
              <GetStarted signedIn={Option.isSome(accountId)} paired={false} />
              <Separator />
            </>
          )}
          <AccountSection accountId={accountId} onChange={setAccountId} />
          <Separator />
          <ConsoleList accountId={accountId} connection={settings.connection} onPlay={onPlay} onPairedChange={setHasPaired} />
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
            {settings.connection === "local" && (
              <ConsoleAddress
                value={settings.consoleAddress}
                onChange={(consoleAddress) => { onSettingsChange({ ...settings, consoleAddress }) }}
              />
            )}
          </div>
          <Separator />
          <div className="flex items-center justify-between gap-3">
            <p className="text-xs text-muted-foreground tabular-nums">{streamSummary(settings)}</p>
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

/** The console's IP on the home network, for when it doesn't show up on its own. Saved when the field
 * is left or Enter is pressed; an address that isn't one is pointed out instead. */
const ConsoleAddress = ({ value, onChange }: { readonly value: string; readonly onChange: (address: string) => void }) => {
  const id = useId()
  const [text, setText] = useState(value)
  const invalid = text.trim() !== "" && !isIpv4(text.trim())
  const commit = () => {
    const address = text.trim()
    if (!invalid && address !== value) onChange(address)
  }
  return (
    <div className="flex flex-col gap-1.5 pt-1">
      <Label htmlFor={id} className="text-xs text-muted-foreground">Console IP address</Label>
      <Input
        id={id}
        inputMode="decimal"
        placeholder="e.g. 192.168.1.20"
        value={text}
        aria-invalid={invalid}
        onChange={(event) => { setText(event.target.value) }}
        onBlur={commit}
        onKeyDown={(event) => { if (event.key === "Enter") commit() }}
        className="tabular-nums"
      />
      <p className="text-xs text-muted-foreground">
        {invalid
          ? "That isn't an IP address. It looks like 192.168.1.20."
          : "Only needed if your PS5 doesn't show up. On the PS5: Settings → Network → Connection Status."}
      </p>
    </div>
  )
}
