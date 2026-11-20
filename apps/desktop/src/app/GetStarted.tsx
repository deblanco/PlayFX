import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

/** `info`: a check the app can't make (the PS5's own settings), so it stays open until pairing works. */
type StepState = "done" | "current" | "info" | "waiting"

interface Step {
  readonly title: string
  readonly body: string
  readonly state: StepState
}

/** The steps to the first stream, in order, with where the user is. */
export const setupSteps = (signedIn: boolean, paired: boolean): readonly Step[] => [
  {
    title: "Get your PS5 ready",
    body: "On the PS5, turn on Settings › System › Remote Play › Enable Remote Play. So PlayFX can wake it from rest mode, also turn on Stay Connected to the Internet and Enable Turning On PS5 from Network in Settings › System › Power Saving › Features Available in Rest Mode.",
    // The app can't see the PS5's settings: only a pairing that works shows they're right.
    state: paired ? "done" : signedIn ? "info" : "current",
  },
  {
    title: "Sign in with PlayStation",
    body: "So your PS5 can tell it's you. You only do this once.",
    state: signedIn ? "done" : "waiting",
  },
  {
    title: "Pair your PS5",
    body:
      "Choose Pair (no code needed) next to your PS5 below. If it isn't offered, open Settings › System › Remote Play › Pair Device (Link Device on some versions) on the PS5, then choose Pair below and type the 8-digit code it shows.",
    state: paired ? "done" : signedIn ? "current" : "waiting",
  },
  {
    title: "Play",
    body: "Press Play. PlayFX wakes your PS5 if it's in rest mode.",
    state: paired ? "current" : "waiting",
  },
]

/** First run: the steps to a first stream. Gone after the first Play. */
export const GetStarted = ({ signedIn, paired }: { readonly signedIn: boolean; readonly paired: boolean }) => (
  <section aria-labelledby="get-started" className="flex flex-col gap-3">
    <h2 id="get-started" className="text-sm font-medium">Get started</h2>
    <ol className="flex flex-col gap-3">
      {setupSteps(signedIn, paired).map((step, i) => (
        <li key={step.title} className="flex gap-3" aria-current={step.state === "current" ? "step" : undefined}>
          <span
            className={cn(
              "mt-px grid size-6 shrink-0 place-items-center rounded-full text-xs font-medium tabular-nums transition-colors duration-500",
              step.state === "done" && "bg-ice text-black",
              step.state === "current" && "border border-ice text-ice",
              step.state === "info" && "border border-white/30 text-white/70",
              step.state === "waiting" && "border border-white/15 text-white/40",
            )}
          >
            {step.state === "done" ? (
              <Check aria-label="Done" className="size-3.5 animate-in zoom-in-50 duration-300 motion-reduce:animate-none" strokeWidth={3} />
            ) : (
              i + 1
            )}
          </span>
          <div className="flex flex-col gap-0.5">
            <span className={cn("text-sm", step.state === "waiting" ? "text-white/45" : "text-white", step.state === "done" && "text-white/60 line-through decoration-white/30")}>
              {step.title}
            </span>
            {step.state !== "done" && <span className="text-xs text-muted-foreground">{step.body}</span>}
          </div>
        </li>
      ))}
    </ol>
  </section>
)
