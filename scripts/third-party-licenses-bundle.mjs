// Builds the desktop web UI with Vite into a temporary folder (the real `dist` is left alone) and writes, as
// JSON, the npm packages whose code, styles or assets end up in that bundle. Used by
// third-party-licenses.py; run with Bun: bun scripts/third-party-licenses-bundle.mjs <apps/desktop> <out.json>
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, isAbsolute, join, resolve } from "node:path"

const appDir = resolve(process.argv[2] ?? "apps/desktop")
const outFile = resolve(process.argv[3] ?? "bundle-packages.json")

/** The nearest enclosing directory whose package.json has a name and version (a published package). */
const packageRoot = (file) => {
  for (let dir = dirname(realpathSync(file)); dir !== dirname(dir); dir = dirname(dir)) {
    const manifest = join(dir, "package.json")
    if (existsSync(manifest)) {
      const pkg = JSON.parse(readFileSync(manifest, "utf8"))
      if (pkg.name && pkg.version) return dir
    }
  }
  return null
}

const vitePath = Bun.resolveSync("vite", appDir)
const viteDir = packageRoot(vitePath)
const { build } = await import(vitePath)

const roots = new Set()
const add = (file) => {
  const root = packageRoot(file)
  if (root && root.includes("/node_modules/")) roots.add(root)
}
const cssFiles = new Set()

const outDir = mkdtempSync(join(tmpdir(), "playfx-bundle-"))
try {
  await build({
    root: appDir,
    logLevel: "error",
    build: { outDir, emptyOutDir: true },
    plugins: [{
      name: "playfx-collect-packages",
      generateBundle(_options, bundle) {
        for (const file of Object.values(bundle)) {
          if (file.type === "chunk") {
            for (const raw of file.moduleIds) {
              const id = raw.split("?")[0]
              if (id.startsWith("\0")) {
                // Bundler runtime helpers (e.g. "\0rolldown/runtime.js", "\0vite/modulepreload-polyfill.js").
                const spec = id.slice(1).split("/")[0]
                add(spec === "vite" ? vitePath : Bun.resolveSync(spec, viteDir))
              } else if (isAbsolute(id) && existsSync(id)) {
                add(id)
                if (id.endsWith(".css") && !id.includes("/node_modules/")) cssFiles.add(id)
              }
            }
          } else {
            for (const name of file.originalFileNames ?? []) add(resolve(appDir, name))
          }
        }
      },
    }],
  })
} finally {
  rmSync(outDir, { recursive: true, force: true })
}

// Tailwind inlines the app stylesheet's package @imports itself, so the bundler never sees them as modules.
// Found by package name: some of them export only CSS, which a JS resolver doesn't match.
for (const css of cssFiles) {
  for (const [, spec] of readFileSync(css, "utf8").matchAll(/@import\s+["']([^"'.][^"']*)["']/g)) {
    const name = spec.split("/").slice(0, spec.startsWith("@") ? 2 : 1).join("/")
    let dir = dirname(css)
    while (!existsSync(join(dir, "node_modules", name, "package.json"))) {
      if (dir === dirname(dir)) throw new Error(`${css}: can't find package ${name}`)
      dir = dirname(dir)
    }
    add(join(dir, "node_modules", name, "package.json"))
  }
}

const packages = [...roots].map((dir) => {
  const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"))
  return { name: pkg.name, version: pkg.version, dir }
}).sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version))
writeFileSync(outFile, JSON.stringify(packages, null, 2))
