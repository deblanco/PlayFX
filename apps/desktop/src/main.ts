import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// ---------- Types (mirror StreamCore's JSON) ----------

type DiscoveredConsole = {
  address: string;
  name: string;
  hostId: string;
  systemVersion: string;
  runningApp?: string;
  ps5: boolean;
  state: "ready" | "standby" | "unknown";
};

type Credentials = {
  address: string;
  ps5: boolean;
  nickname: string;
  mac: string;
  registKey: string;
  rpKey: string;
  accountId: string;
};

type PairedConsole = { hostId: string; name: string; credentials: Credentials };

type StreamEvent =
  | { type: "connected" }
  | { type: "quit"; reason: string; error: boolean }
  | { type: "loginPin"; incorrect: boolean }
  | { type: "nickname"; name: string };

type RendererStatus = {
  metalfxSupported: boolean;
  activeMode: "bilinear" | "metalfx" | "none";
  stream: { active: boolean; framesDecoded?: number; decodeErrors?: number; width?: number; height?: number };
};

// ---------- Local storage (pairing keys never leave this machine) ----------

const store = {
  get accountId(): string | null {
    return localStorage.getItem("psrp.accountId");
  },
  set accountId(v: string | null) {
    v ? localStorage.setItem("psrp.accountId", v) : localStorage.removeItem("psrp.accountId");
  },
  get paired(): Record<string, PairedConsole> {
    try {
      return JSON.parse(localStorage.getItem("psrp.consoles") ?? "{}");
    } catch {
      return {};
    }
  },
  savePaired(p: Record<string, PairedConsole>) {
    localStorage.setItem("psrp.consoles", JSON.stringify(p));
  },
  get settings() {
    try {
      return JSON.parse(localStorage.getItem("psrp.settings") ?? "{}");
    } catch {
      return {};
    }
  },
  saveSettings(s: object) {
    localStorage.setItem("psrp.settings", JSON.stringify(s));
  },
};

// ---------- DOM ----------

const $ = <T extends HTMLElement>(sel: string) => document.querySelector<T>(sel)!;
const home = $("#home");
const hud = $("#hud");
const accountEl = $("#account");
const consolesEl = $<HTMLUListElement>("#consoles");
const scanEl = $("#scan");
const messageEl = $("#message");
const res = $<HTMLSelectElement>("#res");
const fps = $<HTMLSelectElement>("#fps");
const codec = $<HTMLSelectElement>("#codec");
const upscalers = [...document.querySelectorAll<HTMLSelectElement>(".upscaler")];

let discovered: DiscoveredConsole[] = [];
let pairingHostId: string | null = null;
let streaming: PairedConsole | null = null;

function message(text: string, kind: "error" | "info" = "error") {
  messageEl.hidden = !text;
  messageEl.textContent = text;
  messageEl.className = `message ${kind === "info" ? "info" : ""}`;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...children: (Node | string)[]) {
  const e = Object.assign(document.createElement(tag), props) as HTMLElementTagNameMap[K];
  e.append(...children);
  return e;
}

// ---------- Account ----------

function renderAccount() {
  accountEl.replaceChildren();
  const id = store.accountId;
  if (id) {
    accountEl.append(
      el("div", { className: "row" },
        el("span", {}, "PSN account linked "),
        el("span", { className: "muted" }, `(${id})`),
        el("button", { textContent: "Sign out", onclick: () => { store.accountId = null; renderAccount(); renderConsoles(); } }),
      ),
    );
    return;
  }
  const manual = el("input", { placeholder: "or paste account ID (base64)", size: 24 });
  accountEl.append(
    el("div", { className: "row" },
      el("button", { className: "primary", textContent: "Sign in with PlayStation", onclick: () => invoke("psn_login").catch((e) => message(String(e))) }),
      manual,
      el("button", {
        textContent: "Save",
        onclick: () => {
          const v = manual.value.trim();
          if (atob(v).length !== 8) return message("An account ID is 8 bytes in base64 (12 characters ending in '=')");
          store.accountId = v;
          renderAccount();
          renderConsoles();
        },
      }),
    ),
    el("p", { className: "muted", textContent: "Needed once to pair with a console. Only the account ID is kept, in this app's local storage." }),
  );
}

listen<{ accountId?: string; error?: string }>("psn-account", ({ payload }) => {
  if (payload.accountId) {
    store.accountId = payload.accountId;
    message("");
  } else message(`PSN sign-in failed: ${payload.error}`);
  renderAccount();
  renderConsoles();
});

// ---------- Consoles ----------

async function scan() {
  try {
    discovered = await invoke<DiscoveredConsole[]>("discover");
    scanEl.textContent = discovered.length ? "" : "No consoles found on this network";
    // Keep saved addresses current if the console's IP changed.
    const paired = store.paired;
    let changed = false;
    for (const d of discovered) {
      const p = paired[d.hostId];
      if (p && p.credentials.address !== d.address) {
        p.credentials.address = d.address;
        changed = true;
      }
    }
    if (changed) store.savePaired(paired);
  } catch (e) {
    scanEl.textContent = `Discovery failed: ${e}`;
  }
  renderConsoles();
}

function renderConsoles() {
  const paired = store.paired;
  const ids = new Set([...discovered.map((d) => d.hostId), ...Object.keys(paired)]);
  const items = [...ids].map((id) => {
    const d = discovered.find((x) => x.hostId === id);
    const p = paired[id];
    const state = d?.state ?? "offline";
    const name = d?.name ?? p?.name ?? id;
    const address = d?.address ?? p?.credentials.address ?? "";

    const actions = el("div", { className: "actions" });
    if (p) {
      if (state === "standby") actions.append(el("button", { textContent: "Wake", onclick: () => wake(p) }));
      actions.append(el("button", { className: "primary", textContent: "Play", disabled: state !== "ready", onclick: () => play(p) }));
      actions.append(el("button", { textContent: "Forget", onclick: () => forget(id) }));
    } else if (d) {
      actions.append(el("button", { textContent: "Pair", disabled: !store.accountId, title: store.accountId ? "" : "Sign in first", onclick: () => { pairingHostId = id; renderConsoles(); } }));
    }

    const li = el("li", { className: "console" },
      el("div", { className: "name" }, name, el("span", { className: `badge ${state}`, textContent: state })),
      actions,
      el("div", { className: "meta", textContent: `${d?.ps5 === false ? "PS4" : "PS5"} · ${address}${d?.runningApp ? ` · ${d.runningApp}` : ""}${p ? " · paired" : ""}` }),
    );
    if (pairingHostId === id && d) li.append(pairForm(d));
    return li;
  });
  consolesEl.replaceChildren(...items);
}

function pairForm(d: DiscoveredConsole) {
  const pin = el("input", { placeholder: "8-digit PIN", inputMode: "numeric", maxLength: 9, size: 10 });
  const go = el("button", { className: "primary", textContent: "Pair" });
  go.onclick = async () => {
    go.disabled = true;
    message("Pairing…", "info");
    try {
      const credentials = await invoke<Credentials>("register_console", {
        request: { address: d.address, ps5: d.ps5, accountId: store.accountId, pin: pin.value },
      });
      const paired = store.paired;
      paired[d.hostId] = { hostId: d.hostId, name: credentials.nickname || d.name, credentials };
      store.savePaired(paired);
      pairingHostId = null;
      message("");
    } catch (e) {
      message(String(e));
    }
    go.disabled = false;
    renderConsoles();
  };
  return el("div", { className: "pair row" },
    el("span", { className: "muted", textContent: "On the PS5: Settings → System → Remote Play → Pair Device" }),
    pin, go,
    el("button", { textContent: "Cancel", onclick: () => { pairingHostId = null; renderConsoles(); } }),
  );
}

async function wake(p: PairedConsole) {
  const ok = await invoke<boolean>("wakeup", { credentials: p.credentials });
  message(ok ? "Wake-up sent; the console takes ~20 s to start." : "Wake-up failed", ok ? "info" : "error");
}

function forget(id: string) {
  const paired = store.paired;
  delete paired[id];
  store.savePaired(paired);
  renderConsoles();
}

// ---------- Streaming ----------

async function play(p: PairedConsole) {
  message("Connecting…", "info");
  try {
    await invoke("start_stream", {
      request: {
        credentials: p.credentials,
        options: { height: Number(res.value), fps: Number(fps.value), hevc: codec.value === "hevc", bitrate: 0, audio: true },
      },
    });
    streaming = p;
    $("#hud-title").textContent = p.name;
    home.hidden = true;
    hud.hidden = false;
    pokeHud();
  } catch (e) {
    message(String(e));
  }
}

async function stop() {
  await invoke("stop_stream");
  endStream();
}

function endStream(reason?: string) {
  streaming = null;
  hud.hidden = true;
  home.hidden = false;
  if (reason) message(reason);
  scan();
}

listen<StreamEvent>("stream-event", ({ payload: e }) => {
  if (!streaming) return;
  switch (e.type) {
    case "connected":
      message("");
      break;
    case "quit":
      endStream(e.error ? `Disconnected: ${e.reason}` : undefined);
      break;
    case "loginPin": {
      const pin = prompt(e.incorrect ? "Wrong PIN. Enter the console's login PIN:" : "Enter the console's login PIN:");
      if (pin) invoke("set_login_pin", { pin });
      break;
    }
    case "nickname":
      $("#hud-title").textContent = e.name;
      break;
  }
});

$("#stop").onclick = stop;

// HUD: stats + auto-hide after inactivity.
let hudTimer = 0;
function pokeHud() {
  hud.classList.remove("idle");
  clearTimeout(hudTimer);
  hudTimer = window.setTimeout(() => hud.classList.add("idle"), 2500);
}
window.addEventListener("mousemove", () => streaming && pokeHud());

let lastFrames = 0;
let lastTime = performance.now();
async function refreshStatus() {
  const s = await invoke<RendererStatus>("renderer_status");
  for (const u of upscalers) {
    u.querySelector<HTMLOptionElement>('option[value="metalfx"]')!.disabled = !s.metalfxSupported;
  }
  if (streaming && s.stream.active) {
    const now = performance.now();
    const frames = s.stream.framesDecoded ?? 0;
    const rate = ((frames - lastFrames) * 1000) / (now - lastTime);
    lastFrames = frames;
    lastTime = now;
    const size = s.stream.width ? `${s.stream.width}×${s.stream.height}` : "waiting for video";
    const upscaler = s.activeMode === "metalfx" ? "MetalFX" : "Bilinear";
    $("#hud-stats").textContent = `${size} · ${rate.toFixed(0)} fps · ${upscaler}${s.stream.decodeErrors ? ` · ${s.stream.decodeErrors} decode errors` : ""}`;
  }
}

// ---------- Settings ----------

function applySettings() {
  const s = store.settings;
  if (s.res) res.value = s.res;
  if (s.fps) fps.value = s.fps;
  if (s.codec) codec.value = s.codec;
  if (s.upscaler) upscalers.forEach((u) => (u.value = s.upscaler));
  invoke("set_upscaler", { mode: upscalers[0].value });
}

function saveSettings() {
  store.saveSettings({ res: res.value, fps: fps.value, codec: codec.value, upscaler: upscalers[0].value });
}

for (const s of [res, fps, codec]) s.addEventListener("change", saveSettings);
for (const u of upscalers) {
  u.addEventListener("change", () => {
    upscalers.forEach((o) => (o.value = u.value));
    invoke("set_upscaler", { mode: u.value });
    saveSettings();
  });
}

// ---------- Start ----------

applySettings();
renderAccount();
renderConsoles();
scan();
setInterval(() => !streaming && scan(), 5000);
setInterval(refreshStatus, 1000);
