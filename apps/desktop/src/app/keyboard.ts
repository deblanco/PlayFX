import { idleController, type ControllerState } from "@/core/schema"

// Keyboard-as-controller, mainly for testing gameplay without a physical pad. Maps
// KeyboardEvent.code values to a ControllerState. Button bits match StreamCore
// (sc_session_set_controller / ChiakiControllerButton).

const BUTTON = {
  cross: 1 << 0,
  circle: 1 << 1,
  square: 1 << 2,
  triangle: 1 << 3,
  dpadLeft: 1 << 4,
  dpadRight: 1 << 5,
  dpadUp: 1 << 6,
  dpadDown: 1 << 7,
  l1: 1 << 8,
  r1: 1 << 9,
  l3: 1 << 10,
  r3: 1 << 11,
  options: 1 << 12,
  share: 1 << 13,
  touchpad: 1 << 14,
  ps: 1 << 15,
} as const

const AXIS_MAX = 32767

/** code → button bit. */
const BUTTON_KEYS: Readonly<Record<string, number>> = {
  Enter: BUTTON.cross,
  NumpadEnter: BUTTON.cross,
  Space: BUTTON.cross,
  Backspace: BUTTON.circle,
  KeyQ: BUTTON.square,
  KeyE: BUTTON.triangle,
  ArrowLeft: BUTTON.dpadLeft,
  ArrowRight: BUTTON.dpadRight,
  ArrowUp: BUTTON.dpadUp,
  ArrowDown: BUTTON.dpadDown,
  Digit1: BUTTON.l1,
  Digit2: BUTTON.r1,
  KeyZ: BUTTON.l3,
  KeyX: BUTTON.r3,
  Tab: BUTTON.options,
  ShiftLeft: BUTTON.share,
  KeyP: BUTTON.ps,
  KeyT: BUTTON.touchpad,
}

/** code → ["leftX"|"leftY"|"rightX"|"rightY", value]. */
const AXIS_KEYS: Readonly<Record<string, readonly [keyof ControllerState, number]>> = {
  KeyW: ["leftY", -AXIS_MAX],
  KeyS: ["leftY", AXIS_MAX],
  KeyA: ["leftX", -AXIS_MAX],
  KeyD: ["leftX", AXIS_MAX],
  KeyI: ["rightY", -AXIS_MAX],
  KeyK: ["rightY", AXIS_MAX],
  KeyJ: ["rightX", -AXIS_MAX],
  KeyL: ["rightX", AXIS_MAX],
}

/** code → "l2"|"r2" (analog triggers, pressed = full). */
const TRIGGER_KEYS: Readonly<Record<string, "l2" | "r2">> = {
  Digit3: "l2",
  Digit4: "r2",
}

/** True if this key maps to any control (so the caller can preventDefault, e.g. Tab/Space/arrows). */
export const isControllerKey = (code: string): boolean =>
  code in BUTTON_KEYS || code in AXIS_KEYS || code in TRIGGER_KEYS

/** Builds the controller state from the currently-pressed key codes. */
export const controllerStateFrom = (pressed: ReadonlySet<string>): ControllerState => {
  const state = { ...idleController }
  for (const code of pressed) {
    const button = BUTTON_KEYS[code]
    if (button !== undefined) state.buttons |= button
    const axis = AXIS_KEYS[code]
    if (axis !== undefined) state[axis[0]] = axis[1]
    const trigger = TRIGGER_KEYS[code]
    if (trigger !== undefined) state[trigger] = 255
  }
  return state
}

/** Human-readable layout, shown in the HUD help. */
export const keyboardLayout: readonly (readonly [string, string])[] = [
  ["Enter / Space", "✕"],
  ["Backspace", "◯"],
  ["Q / E", "□ / △"],
  ["Arrows", "D-pad"],
  ["W A S D", "Left stick"],
  ["I J K L", "Right stick"],
  ["1 / 2", "L1 / R1"],
  ["3 / 4", "L2 / R2"],
  ["Z / X", "L3 / R3"],
  ["Tab / Shift", "Options / Share"],
  ["P / T", "PS / Touchpad"],
  ["⌥ + pointer", "Touchpad finger"],
  ["⌥ + click", "Press touchpad"],
]
