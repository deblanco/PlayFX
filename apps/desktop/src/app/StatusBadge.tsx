import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { ConsoleStatus } from "./format"

// shadcn/ui's Badge (outline) with a coloured dot for the console's state.

const dot: Record<ConsoleStatus, string> = {
  ready: "bg-emerald-500",
  standby: "bg-amber-500",
  offline: "bg-muted-foreground",
  internet: "bg-sky-400",
}

export const StatusBadge = ({ status }: { status: ConsoleStatus }) => (
  <Badge variant="outline" data-status={status} className="rounded-full text-muted-foreground">
    <span className={cn("size-2 rounded-full", dot[status])} aria-hidden="true" />
    {status}
  </Badge>
)
