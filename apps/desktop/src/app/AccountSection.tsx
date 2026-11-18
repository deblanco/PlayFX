import { Option } from "effect"
import { useId, useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { PsnAccountEvent } from "@/core/schema"
import * as actions from "./actions"
import { useFork, useRun } from "./runtime"

interface AccountSectionProps {
  readonly accountId: Option.Option<string>
  readonly onChange: (accountId: Option.Option<string>) => void
}

export const AccountSection = ({ accountId, onChange }: AccountSectionProps) => {
  const run = useRun()
  const inputId = useId()
  const [manual, setManual] = useState("")

  useFork(
    useMemo(
      () =>
        actions.onPsnAccount((event: PsnAccountEvent) => {
          run(actions.receivePsnAccount(event), { onSuccess: (id) => { onChange(Option.some(id)); } })
        }),
      [run, onChange],
    ),
  )

  return Option.match(accountId, {
    onSome: (id) => (
      <section aria-label="PSN account" className="flex items-center justify-between gap-3">
        <div className="min-w-0 text-sm">
          PSN account linked <span className="text-muted-foreground">({id})</span>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={() => { run(actions.signOut, { onSuccess: () => { onChange(Option.none()); } }); }}
        >
          Sign out
        </Button>
      </section>
    ),
    onNone: () => (
      <section aria-label="PSN account" className="flex flex-col gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <Button onClick={() => { run(actions.signIn); }}>Sign in with PlayStation</Button>
          <form
            className="flex flex-1 items-center gap-2"
            onSubmit={(event) => {
              event.preventDefault()
              run(actions.saveAccountId(manual), {
                onSuccess: (id) => {
                  setManual("")
                  onChange(Option.some(id))
                },
              })
            }}
          >
            <Label htmlFor={inputId} className="sr-only">
              Account ID
            </Label>
            <Input
              id={inputId}
              className="min-w-40 flex-1"
              placeholder="or paste account ID (base64)"
              value={manual}
              onChange={(event) => { setManual(event.target.value); }}
            />
            <Button type="submit" variant="outline">
              Save
            </Button>
          </form>
        </div>
        <p className="text-xs text-muted-foreground">
          Needed once to pair with a console. Only the account ID is kept, in this app&apos;s local storage.
        </p>
      </section>
    ),
  })
}
