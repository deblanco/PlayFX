import { describe, expect, it } from "vitest"
import { idleController } from "@/core/schema"
import { controllerStateFrom, isControllerKey, keyboardLayout } from "./keyboard"

const BUTTON = { cross: 1 << 0, square: 1 << 2, dpadUp: 1 << 6, options: 1 << 12, ps: 1 << 15 }

describe("isControllerKey", () => {
  it("recognises mapped buttons, axes and triggers", () => {
    expect(isControllerKey("Enter")).toBe(true)
    expect(isControllerKey("KeyW")).toBe(true)
    expect(isControllerKey("Digit3")).toBe(true)
    expect(isControllerKey("Tab")).toBe(true)
  })
  it("ignores unmapped keys", () => {
    expect(isControllerKey("KeyY")).toBe(false)
    expect(isControllerKey("Escape")).toBe(false)
  })
})

describe("controllerStateFrom", () => {
  it("is idle with nothing pressed", () => {
    expect(controllerStateFrom(new Set())).toEqual(idleController)
  })

  it("maps face and system buttons to their bits", () => {
    const s = controllerStateFrom(new Set(["Enter", "KeyP"]))
    expect(s.buttons & BUTTON.cross).toBe(BUTTON.cross)
    expect(s.buttons & BUTTON.ps).toBe(BUTTON.ps)
  })

  it("ORs multiple buttons together", () => {
    const s = controllerStateFrom(new Set(["ArrowUp", "Tab"]))
    expect(s.buttons & BUTTON.dpadUp).toBe(BUTTON.dpadUp)
    expect(s.buttons & BUTTON.options).toBe(BUTTON.options)
  })

  it("drives both sticks (up/left are negative)", () => {
    const s = controllerStateFrom(new Set(["KeyW", "KeyA", "KeyK", "KeyL"]))
    expect(s.leftY).toBeLessThan(0)
    expect(s.leftX).toBeLessThan(0)
    expect(s.rightY).toBeGreaterThan(0)
    expect(s.rightX).toBeGreaterThan(0)
  })

  it("maps triggers to full analog values", () => {
    const s = controllerStateFrom(new Set(["Digit3", "Digit4"]))
    expect(s.l2).toBe(255)
    expect(s.r2).toBe(255)
  })

  it("ignores unmapped keys", () => {
    expect(controllerStateFrom(new Set(["KeyY", "Escape"]))).toEqual(idleController)
  })
})

describe("keyboardLayout", () => {
  it("documents every row as a key/action pair", () => {
    expect(keyboardLayout.length).toBeGreaterThan(0)
    for (const row of keyboardLayout) expect(row).toHaveLength(2)
  })
})
