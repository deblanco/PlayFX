import { describe, expect, it } from "@effect/vitest"
import { noTouch, pointerTouch, toTouchpad, videoRect } from "./touchpad"

describe("touchpad", () => {
  it("finds the letterboxed video in the window", () => {
    expect(videoRect(1920, 1080)).toEqual({ x: 0, y: 0, width: 1920, height: 1080 })
    expect(videoRect(2000, 1080)).toEqual({ x: 40, y: 0, width: 1920, height: 1080 }) // bars left and right
    expect(videoRect(1920, 1200)).toEqual({ x: 0, y: 60, width: 1920, height: 1080 }) // bars top and bottom
  })

  it("maps pointer positions over the video to the touchpad", () => {
    const rect = videoRect(2000, 1080)
    expect(toTouchpad(40, 0, rect)).toEqual({ x: 0, y: 0 })
    expect(toTouchpad(1000, 540, rect)).toEqual({ x: 0.5, y: 0.5 })
    expect(toTouchpad(20, 540, rect)).toBeUndefined() // on the black bar
  })

  it("touches only over the video, pressing when clicked", () => {
    expect(pointerTouch({ x: 0.25, y: 0.75 }, true)).toEqual({ down: true, x: 0.25, y: 0.75, pressed: true })
    expect(pointerTouch(undefined, true)).toEqual(noTouch)
  })
})
