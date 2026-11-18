import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { App } from "./app/App"
import { seedDevStorage } from "./app/devSeed"
import { RuntimeProvider } from "./app/runtime"
import { makeAppRuntime } from "./core/runtime"
import "./index.css"

const mount = (): void => {
  const root = document.getElementById("root")
  if (!root) return
  createRoot(root).render(
    <StrictMode>
      <RuntimeProvider runtime={makeAppRuntime()}>
        <App />
      </RuntimeProvider>
    </StrictMode>,
  )
}

// Dev E2E seeding (no-op in production); then mount.
void seedDevStorage().then(mount, mount)
