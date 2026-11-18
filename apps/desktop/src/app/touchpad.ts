// The Mac's pointer as the DualSense touchpad: hold ⌥ Option over the video to touch, click to press.
import type { PointerTouch } from "@/core/schema"

export interface Rect {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

/** Where the video sits in the window: the largest rect of its aspect ratio, centered (as the
 * renderer letterboxes it). */
export const videoRect = (windowWidth: number, windowHeight: number, aspect = 16 / 9): Rect => {
  const width = Math.min(windowWidth, windowHeight * aspect)
  const height = width / aspect
  return { x: (windowWidth - width) / 2, y: (windowHeight - height) / 2, width, height }
}

/** A window point as a touchpad position (0–1 from the top-left), or undefined outside the video. */
export const toTouchpad = (px: number, py: number, rect: Rect): { readonly x: number; readonly y: number } | undefined => {
  const x = (px - rect.x) / rect.width
  const y = (py - rect.y) / rect.height
  return x < 0 || x > 1 || y < 0 || y > 1 ? undefined : { x, y }
}

export const noTouch: PointerTouch = { down: false, x: 0, y: 0, pressed: false }

/** The touch for the pointer at a touchpad position (undefined = off the video) while ⌥ is held. */
export const pointerTouch = (at: { readonly x: number; readonly y: number } | undefined, pressed: boolean): PointerTouch =>
  at === undefined ? noTouch : { down: true, x: at.x, y: at.y, pressed }
