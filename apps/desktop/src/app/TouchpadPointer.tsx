import { Effect } from "effect"
import { useEffect, useRef, useState } from "react"
import { cn } from "@/lib/utils"
import * as actions from "./actions"
import { useRuntime } from "./runtime"
import { noTouch, pointerTouch, toTouchpad, videoRect, type Rect } from "./touchpad"

interface Pointer {
  /** ⌥ Option is held: the video is the touchpad. */
  readonly held: boolean
  readonly rect: Rect
  /** The finger, in window coordinates, while it's over the video. */
  readonly finger: { readonly x: number; readonly y: number } | undefined
  readonly pressed: boolean
}

/** Holding ⌥ Option turns the pointer into a touchpad finger over the video; a click presses the
 * touchpad. Sends at most one update per animation frame. */
const useTouchpadPointer = (enabled: boolean): Pointer => {
  const runtime = useRuntime()
  const [pointer, setPointer] = useState<Pointer>(() => ({
    held: false,
    rect: videoRect(window.innerWidth, window.innerHeight),
    finger: undefined,
    pressed: false,
  }))
  const last = useRef({ x: 0, y: 0 })
  useEffect(() => {
    if (!enabled) return
    let held = false
    let pressed = false
    let frame = 0
    const current = () => {
      const rect = videoRect(window.innerWidth, window.innerHeight)
      return { rect, at: held ? toTouchpad(last.current.x, last.current.y, rect) : undefined }
    }
    const update = () => {
      const { rect, at } = current()
      setPointer({ held, rect, finger: at && { x: last.current.x, y: last.current.y }, pressed: pressed && at !== undefined })
      if (frame !== 0) return
      // One send per frame, with the state as it is then (not as it was when the frame was asked for).
      frame = window.requestAnimationFrame(() => {
        frame = 0
        runtime.runFork(Effect.ignore(actions.setPointerTouch(held ? pointerTouch(current().at, pressed) : noTouch)))
      })
    }
    const hold = (on: boolean) => {
      if (held === on) return
      held = on
      if (!on) pressed = false
      update()
    }
    const key = (event: KeyboardEvent) => { if (event.key === "Alt") hold(event.type === "keydown") }
    const move = (event: MouseEvent) => {
      last.current = { x: event.clientX, y: event.clientY }
      held = event.altKey
      update()
    }
    const press = (event: MouseEvent) => {
      if (event.button !== 0 || !event.altKey) return
      event.preventDefault()
      pressed = event.type === "mousedown"
      update()
    }
    const release = () => {
      pressed = false
      hold(false)
    }
    window.addEventListener("keydown", key)
    window.addEventListener("keyup", key)
    window.addEventListener("mousemove", move)
    window.addEventListener("mousedown", press)
    window.addEventListener("mouseup", press)
    window.addEventListener("blur", release)
    window.addEventListener("resize", update)
    return () => {
      window.removeEventListener("keydown", key)
      window.removeEventListener("keyup", key)
      window.removeEventListener("mousemove", move)
      window.removeEventListener("mousedown", press)
      window.removeEventListener("mouseup", press)
      window.removeEventListener("blur", release)
      window.removeEventListener("resize", update)
      window.cancelAnimationFrame(frame)
      runtime.runFork(Effect.ignore(actions.setPointerTouch(noTouch)))
    }
  }, [enabled, runtime])
  return enabled ? pointer : { ...pointer, held: false, finger: undefined, pressed: false }
}

/** While ⌥ is held: the video outlined as the touchpad, and the finger as a glowing dot that ripples
 * when the touchpad is pressed. */
export const TouchpadPointer = ({ enabled }: { readonly enabled: boolean }) => {
  const { held, rect, finger, pressed } = useTouchpadPointer(enabled)
  return (
    <div
      aria-hidden={!held}
      role="status"
      aria-label={held ? "Touchpad: the pointer is your finger, click to press" : undefined}
      className={cn(
        "pointer-events-none fixed rounded-[28px] border border-ice/45 shadow-[inset_0_0_40px_rgb(30_91_255/0.18),0_0_24px_rgb(30_91_255/0.25)] transition-opacity duration-200",
        held ? "opacity-100" : "opacity-0",
      )}
      style={{ left: rect.x + 6, top: rect.y + 6, width: rect.width - 12, height: rect.height - 12 }}
    >
      <span className="absolute top-3 left-1/2 -translate-x-1/2 rounded-full bg-black/45 px-2.5 py-0.5 text-[11px] text-ice/90 backdrop-blur">
        Touchpad
      </span>
      {finger && (
        <span
          className="absolute size-0"
          style={{ left: finger.x - rect.x - 6, top: finger.y - rect.y - 6 }}
        >
          <span
            className={cn(
              "absolute -top-2.5 -left-2.5 size-5 rounded-full bg-ice/85 shadow-[0_0_14px_4px_rgb(30_91_255/0.7)] transition-transform duration-100",
              pressed && "scale-75",
            )}
          />
          {pressed && (
            <span className="absolute -top-5 -left-5 size-10 animate-ping rounded-full border border-ice/80 motion-reduce:hidden" />
          )}
        </span>
      )}
    </div>
  )
}
