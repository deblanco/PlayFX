import { invoke } from "@tauri-apps/api/core";

type RendererStatus = {
  metalfxSupported: boolean;
  activeMode: "bilinear" | "metalfx" | "none";
};

const upscaler = document.querySelector<HTMLSelectElement>("#upscaler")!;
const source = document.querySelector<HTMLSelectElement>("#source")!;
const status = document.querySelector<HTMLSpanElement>("#status")!;

async function refreshStatus() {
  const s = await invoke<RendererStatus>("renderer_status");
  if (!s.metalfxSupported) upscaler.querySelector<HTMLOptionElement>('option[value="metalfx"]')!.disabled = true;
  status.textContent =
    s.activeMode === "none" ? "renderer unavailable" : `active: ${s.activeMode === "metalfx" ? "MetalFX" : "Bilinear"}`;
}

upscaler.addEventListener("change", async () => {
  await invoke("set_upscaler", { mode: upscaler.value });
});

source.addEventListener("change", async () => {
  const [width, height] = source.value.split("x").map(Number);
  await invoke("set_input_size", { width, height });
});

setInterval(refreshStatus, 500);
refreshStatus();
