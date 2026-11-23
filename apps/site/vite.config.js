// The project's GitHub Pages site (https://deblanco.github.io/PlayFX/), deployed by .github/workflows/pages.yml.
import tailwindcss from "@tailwindcss/vite"
import { defineConfig } from "vite"

export default defineConfig({
  // Relative URLs: the site is served from /PlayFX/, and works from any folder in `vite preview` too.
  base: "./",
  plugins: [tailwindcss()],
})
