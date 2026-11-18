import { mergeConfig } from "vite"
import { defineConfig } from "vitest/config"
import viteConfig from "./vite.config"

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: "jsdom",
      globals: true,
      setupFiles: ["./src/test/setup.ts"],
      include: ["src/**/*.test.{ts,tsx}"],
      coverage: {
        provider: "v8",
        include: ["src/**/*.{ts,tsx}"],
        // shadcn/ui primitives are generated, vendored code; entry/test files aren't app logic.
        exclude: ["src/components/ui/**", "src/main.tsx", "src/test/**", "src/**/*.test.{ts,tsx}", "src/vite-env.d.ts"],
        thresholds: { lines: 80, branches: 80, functions: 80, statements: 80 },
        reporter: ["text", "text-summary"],
      },
    },
  }),
)
