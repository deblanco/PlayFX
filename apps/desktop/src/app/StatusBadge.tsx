import { cn } from "@/lib/utils"
import type { ConsoleStatus } from "./format"

// Adapted from @shadcn-studio badge-05 (dot badge).

const dot: Record<ConsoleStatus, string> = {
  ready: "bg-emerald-500",
  standby: "bg-amber-500",
  offline: "bg-muted-foreground",
}

export const StatusBadge = ({ status }: { status: ConsoleStatus }) => (
  <span
    data-status={status}
    className="inline-flex w-fit shrink-0 items-center justify-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium whitespace-nowrap text-muted-foreground"
  >
    <span className={cn("size-2 rounded-full", dot[status])} aria-hidden="true" />
    {status}
  </span>
)
