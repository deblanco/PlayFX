import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { App } from "./app/App"
import { RuntimeProvider } from "./app/runtime"
import { makeAppRuntime } from "./core/runtime"
import "./index.css"

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(
    <StrictMode>
      <RuntimeProvider runtime={makeAppRuntime()}>
        <App />
      </RuntimeProvider>
    </StrictMode>,
  )
}
