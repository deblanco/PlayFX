import { Effect } from "effect"
import { Keyboard } from "lucide-react"
import { useState, type ReactNode } from "react"
import * as actions from "./actions"
import { useRuntime } from "./runtime"

interface ConsoleKeyboardProps {
  readonly consoleName: string
  /** The console field's text when the keyboard opened (or as the console last changed it). */
  readonly text: string
  /** Sent or cancelled: the bar goes away. */
  readonly onDone: () => void
}

const Keycap = ({ children }: { readonly children: ReactNode }) => (
  <kbd className="rounded-[5px] border border-white/20 bg-white/[0.06] px-1.5 py-px font-sans text-[11px] text-white/80 shadow-[inset_0_-1px_0_rgb(255_255_255/0.08)]">
    {children}
  </kbd>
)

/** When the console focuses a text field: a bar at the bottom of the video to type into from the Mac.
 * Every change mirrors into the console's field; Return sends it, Esc cancels. */
export const ConsoleKeyboard = ({ consoleName, text, onDone }: ConsoleKeyboardProps) => {
  const runtime = useRuntime()
  // The console's text seeds the field; afterwards the Mac's typing is the source of truth.
  const [value, setValue] = useState(text)
  const finish = (accept: boolean) => {
    runtime.runFork(Effect.ignore(actions.keyboardDone(accept)))
    onDone()
  }
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-14 flex justify-center px-6">
      <form
        aria-label={`Typing for ${consoleName}`}
        className="pointer-events-auto flex w-full max-w-xl animate-in items-center gap-3 rounded-2xl border border-white/12 bg-glass py-2.5 pr-3 pl-4 text-white shadow-2xl backdrop-blur-xl duration-300 fade-in slide-in-from-bottom-4 motion-reduce:animate-none"
        onSubmit={(event) => {
          event.preventDefault()
          finish(true)
        }}
      >
        <Keyboard aria-hidden className="size-5 shrink-0 text-ice" />
        <input
          aria-label={`Text for ${consoleName}`}
          // The bar only exists while the console waits for text, so taking focus is what the user wants.
          autoFocus
          value={value}
          placeholder={`Type for ${consoleName}`}
          spellCheck={false}
          className="min-w-0 flex-1 bg-transparent text-lg caret-ice outline-none placeholder:text-white/35"
          onChange={(event) => {
            setValue(event.target.value)
            runtime.runFork(Effect.ignore(actions.keyboardSetText(event.target.value)))
          }}
          onKeyDown={(event) => {
            if (event.key !== "Escape") return
            event.preventDefault()
            finish(false)
          }}
        />
        <span aria-hidden className="flex shrink-0 items-center gap-1.5 text-xs text-white/55">
          <Keycap>return</Keycap> Send
          <span className="w-1.5" />
          <Keycap>esc</Keycap> Cancel
        </span>
      </form>
    </div>
  )
}
