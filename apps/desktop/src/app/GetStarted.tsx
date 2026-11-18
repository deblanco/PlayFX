import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

type StepState = "done" | "current" | "waiting"

interface Step {
  readonly title: string
  readonly body: string
  readonly state: StepState
}

/** The steps to the first stream, in order, with where the user is. */
export const setupSteps = (signedIn: boolean, paired: boolean): readonly Step[] => [
  {
    title: "Sign in with PlayStation",
    body: "So your PS5 can tell it's you. You only do this once.",
    state: signedIn ? "done" : "current",
  },
  {
    title: "Pair your PS5",
    body: "On the PS5, go to Settings › System › Remote Play › Pair Device, then choose it below and type the code it shows.",
    state: paired ? "done" : signedIn ? "current" : "waiting",
  },
  {
    title: "Play",
    body: "Press Play. PlayFX wakes your PS5 if it's resting.",
    state: paired ? "current" : "waiting",
  },
]

/** First run: the three steps to a first stream. Gone once a console is paired. */
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
