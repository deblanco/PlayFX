import { ChevronRight, LoaderCircle, Network, Power, ShieldOff, Wifi, type LucideIcon } from "lucide-react"
import { useId, useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { isIpv4 } from "./format"

interface AddressProps {
  /** The saved console IP ("" for none). */
  readonly address: string
  readonly onAddressChange: (address: string) => void
}

/** No console on this network (paired ones may still be `listed`). Calm while the first scan runs; after it,
 * what to check and the console's IP. */
export const NoConsoles = ({
  scanned,
  listed,
  address,
  onAddressChange,
  onOpenLocalNetwork,
}: AddressProps & { readonly scanned: boolean; readonly listed: boolean; readonly onOpenLocalNetwork: () => void }) => {
  if (!scanned) {
    return (
      <div className="flex items-center gap-2 rounded-lg border border-dashed border-white/15 p-3 text-xs text-muted-foreground">
        <LoaderCircle className="size-3.5 animate-spin motion-reduce:animate-none" aria-hidden="true" />
        Looking for consoles on this network…
      </div>
    )
  }
  return (
    <section
      aria-labelledby="no-consoles"
      className="flex flex-col gap-3 rounded-lg border border-dashed border-white/15 p-3 animate-in fade-in duration-300 motion-reduce:animate-none"
    >
      <div className="flex flex-col gap-0.5">
        <h3 id="no-consoles" className="text-sm text-white">{listed ? "No consoles on this network yet" : "No consoles found yet"}</h3>
        <p className="text-xs text-muted-foreground">PlayFX keeps looking. If your PS5 doesn't show up, check that:</p>
      </div>
      <ul className="flex flex-col gap-2">
        <CheckItem icon={Power}>It's on, or in rest mode with Stay Connected to the Internet turned on.</CheckItem>
        <CheckItem icon={Wifi}>It's on the same network as this Mac, not a guest Wi-Fi.</CheckItem>
        <CheckItem icon={ShieldOff}>Any VPN on this Mac is off.</CheckItem>
        <CheckItem icon={Network}>
          PlayFX is allowed on the local network. If you chose Don't Allow, turn PlayFX on in System Settings.
          <Button variant="outline" size="sm" className="mt-1.5 self-start" onClick={onOpenLocalNetwork}>
            Open Local Network settings
          </Button>
        </CheckItem>
      </ul>
      <div className="flex flex-col gap-1.5 border-t border-white/10 pt-3">
        <p className="text-xs text-white">Your PS5 on another network or behind a second router? Enter its IP.</p>
        <ConsoleAddress
          // Keyed by the saved address: when it changes underneath (settings loading), the field restarts from it.
          key={address}
          value={address}
          onChange={onAddressChange}
        />
      </div>
    </section>
  )
}

const CheckItem = ({ icon: Icon, children }: { readonly icon: LucideIcon; readonly children: ReactNode }) => (
  <li className="flex gap-2.5 text-xs text-muted-foreground">
    <Icon className="mt-px size-3.5 shrink-0 text-ice/70" aria-hidden="true" />
    <span className="flex flex-col">{children}</span>
  </li>
)

/** Under a list with consoles: the IP field for one that doesn't show up, folded away unless an IP is saved. */
export const AddByIp = ({ address, onAddressChange }: AddressProps) => (
  <Collapsible defaultOpen={address !== ""}>
    <CollapsibleTrigger className="group flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground">
      <ChevronRight className="size-3.5 transition-transform group-data-[state=open]:rotate-90" />
      Console missing? Add it by IP
    </CollapsibleTrigger>
    <CollapsibleContent className="pt-2">
      <ConsoleAddress key={address} value={address} onChange={onAddressChange} />
    </CollapsibleContent>
  </Collapsible>
)

/** The console's IP, for when it doesn't show up on its own. Saved when the field is left or Enter is
 * pressed; an address that isn't one is pointed out instead. */
const ConsoleAddress = ({ value, onChange }: { readonly value: string; readonly onChange: (address: string) => void }) => {
  const id = useId()
  const [text, setText] = useState(value)
  const invalid = text.trim() !== "" && !isIpv4(text.trim())
  const commit = () => {
    const address = text.trim()
    if (!invalid && address !== value) onChange(address)
  }
  return (
    <div className="flex flex-col gap-1.5">
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
          : "Find it on the PS5: Settings › Network › Connection Status. PlayFX asks that address on every scan."}
      </p>
    </div>
  )
}
