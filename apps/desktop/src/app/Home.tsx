import { Option } from "effect"
import { useEffect, useState } from "react"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import type { PairedConsole, Settings } from "@/core/schema"
import * as actions from "./actions"
import { AccountSection } from "./AccountSection"
import { ConsoleList } from "./ConsoleList"
import { useRun } from "./runtime"
import { SettingsRow } from "./Settings"

interface HomeProps {
  readonly settings: Settings
  readonly metalfxSupported: boolean
  readonly onSettingsChange: (next: Settings) => void
  readonly onPlay: (console: PairedConsole) => void
}

export const Home = ({ settings, metalfxSupported, onSettingsChange, onPlay }: HomeProps) => {
  const run = useRun()
  const [accountId, setAccountId] = useState<Option.Option<string>>(Option.none())

  useEffect(() => {
    run(actions.loadAccount, { onSuccess: setAccountId })
  }, [run])

  return (
    <main className="flex min-h-svh items-center justify-center p-6">
      <Card className="w-full max-w-xl bg-card/70 shadow-2xl backdrop-blur-xl">
        <CardHeader>
          <CardTitle className="text-lg">Remote Play</CardTitle>
          <CardDescription>Stream your PlayStation over the local network.</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <AccountSection accountId={accountId} onChange={setAccountId} />
          <Separator />
          <ConsoleList accountId={accountId} onPlay={onPlay} />
          <Separator />
          <SettingsRow settings={settings} metalfxSupported={metalfxSupported} onChange={onSettingsChange} />
        </CardContent>
      </Card>
    </main>
  )
}
