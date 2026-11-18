import "@testing-library/jest-dom/vitest"
import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

// jsdom has no ResizeObserver; Radix (sliders) only needs it to exist.
class NoResizeObserver {
  observe = () => undefined
  unobserve = () => undefined
  disconnect = () => undefined
}
if (!("ResizeObserver" in globalThis)) Object.assign(globalThis, { ResizeObserver: NoResizeObserver })

afterEach(() => {
  cleanup()
  localStorage.clear()
})
