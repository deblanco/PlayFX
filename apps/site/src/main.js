// The site's behaviour: the app's ribbon backdrop, the feature tabs, and the latest release's download link.

const shader = `
precision highp float;
uniform vec2 res;
uniform float t;

// Ported from StreamCore's idle backdrop (packages/streamcore/Sources/StreamCore/Shaders.swift): slow light
// ribbons over a deep blue field, and a fine grid that shows only where their glow passes over it.
float ribbonY(float x, float base, float amp, float freq, float speed, float phase) {
  return base + amp * sin(x * freq + t * speed + phase) + amp * 0.45 * sin(x * freq * 2.1 - t * speed * 0.7 + phase * 1.7);
}
float ribbonSlope(float x, float amp, float freq, float speed, float phase) {
  return amp * freq * cos(x * freq + t * speed + phase)
       + amp * 0.45 * freq * 2.1 * cos(x * freq * 2.1 - t * speed * 0.7 + phase * 1.7);
}

vec3 col;
float reveal;
void ribbon(vec2 p, vec4 s, vec3 look, float phase) {
  float y = ribbonY(p.x, s.x, s.y, s.z, s.w, phase);
  float slope = ribbonSlope(p.x, s.y, s.z, s.w, phase);
  float d = (p.y - y) / sqrt(1.0 + slope * slope);
  float core = exp(-(d * d) / (look.x * look.x));
  float glow = exp(-(d * d) / (look.y * look.y));
  float sheet = smoothstep(0.0, 0.02, d) * exp(-d * 9.0) * 0.18;
  col += vec3(0.118, 0.357, 1.0) * (glow * 0.32 + sheet) * look.z + vec3(0.66, 0.78, 1.0) * core * 0.85 * look.z;
  reveal = max(reveal, exp(-(d * d) / 0.0035) * look.z);
}

void main() {
  vec2 gid = vec2(gl_FragCoord.x, res.y - gl_FragCoord.y) - 0.5;
  vec2 uv = (gid + 0.5) / res;
  float aspect = res.x / res.y;
  vec2 p = vec2(uv.x * aspect, uv.y);

  col = mix(vec3(0.012, 0.024, 0.102), vec3(0.031, 0.102, 0.310), smoothstep(0.15, 1.1, uv.y) * 0.85);
  col += vec3(0.06, 0.16, 0.55) * 0.35 * exp(-3.0 * length(p - vec2(aspect * 0.78, 0.92)));
  reveal = 0.0;
  ribbon(p, vec4(0.52, 0.11, 1.9, 0.21), vec3(0.0022, 0.05, 1.0), 0.0);
  ribbon(p, vec4(0.68, 0.07, 1.4, -0.16), vec3(0.0016, 0.035, 0.7), 2.1);
  ribbon(p, vec4(0.82, 0.12, 0.9, 0.12), vec3(0.0028, 0.07, 0.55), 4.2);

  float patches = smoothstep(0.82, 1.0, (0.5 + 0.5 * sin(p.x * 3.1 + t * 0.11)) * (0.5 + 0.5 * sin(p.y * 4.3 - t * 0.08 + 1.3)) * 1.25);
  reveal = max(reveal, patches * 0.6);

  float cell = res.y / 18.0;
  vec2 g = abs(fract(gid / cell + 0.5) - 0.5) * cell;
  float line = 1.0 - smoothstep(0.4, 1.3, min(g.x, g.y));
  col += vec3(0.43, 0.545, 1.0) * line * reveal * 0.3;

  col *= 1.0 - 0.35 * smoothstep(0.45, 1.25, length((uv - 0.5) * vec2(1.3, 1.0)) * 1.4);
  float n = fract(sin(dot(gid, vec2(12.9898, 78.233))) * 43758.5453);
  col += (n - 0.5) / 255.0;
  gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`

const ribbons = (canvas) => {
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false })
  if (!gl) return // the page's own deep blue shows instead
  const compile = (type, source) => {
    const s = gl.createShader(type)
    gl.shaderSource(s, source)
    gl.compileShader(s)
    return s
  }
  const program = gl.createProgram()
  gl.attachShader(program, compile(gl.VERTEX_SHADER, "attribute vec2 a; void main() { gl_Position = vec4(a, 0.0, 1.0); }"))
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, shader))
  gl.linkProgram(program)
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return
  gl.useProgram(program)
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer())
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW)
  gl.enableVertexAttribArray(0)
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
  const res = gl.getUniformLocation(program, "res")
  const time = gl.getUniformLocation(program, "t")

  // Sharp enough for the grid's 1-pixel lines, without drawing every pixel of a 3× phone screen.
  const resize = () => {
    const scale = Math.min(window.devicePixelRatio || 1, 2)
    canvas.width = Math.round(canvas.clientWidth * scale)
    canvas.height = Math.round(canvas.clientHeight * scale)
    gl.viewport(0, 0, canvas.width, canvas.height)
  }
  const draw = (seconds) => {
    gl.uniform2f(res, canvas.width, canvas.height)
    gl.uniform1f(time, seconds)
    gl.drawArrays(gl.TRIANGLES, 0, 3)
  }

  const still = window.matchMedia("(prefers-reduced-motion: reduce)")
  const start = performance.now() - 20_000 // a moment in, where the ribbons have spread out
  let frame = 0
  const loop = (now) => {
    draw((now - start) / 1000)
    frame = still.matches || document.hidden ? 0 : requestAnimationFrame(loop)
  }
  const restart = () => {
    cancelAnimationFrame(frame)
    loop(performance.now())
  }
  resize()
  new ResizeObserver(() => { resize(); restart() }).observe(canvas)
  document.addEventListener("visibilitychange", restart)
  still.addEventListener("change", restart)
  restart()
}

// Tabs, with the arrow keys moving between them as in the app's Settings.
const tabs = (list) => {
  const all = [...list.querySelectorAll('[role="tab"]')]
  const select = (tab) => {
    for (const t of all) {
      const on = t === tab
      t.setAttribute("aria-selected", String(on))
      t.tabIndex = on ? 0 : -1
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on
    }
  }
  list.addEventListener("click", (e) => {
    const tab = e.target.closest('[role="tab"]')
    if (tab) select(tab)
  })
  list.addEventListener("keydown", (e) => {
    const i = all.indexOf(document.activeElement)
    const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: all.length - 1 }[e.key]
    if (i < 0 || next === undefined) return
    e.preventDefault()
    const tab = all[(next + all.length) % all.length]
    select(tab)
    tab.focus()
  })
}

// The before/after comparison, as in the app's Split view: drag the line (or use the arrow keys on it), or pick
// Original, Split or Enhanced under Picture.
const comparison = (frame, range, view, hint) => {
  const hints = {
    original: "The stream as it arrives.",
    split: "Left of the line as it arrives, right of it with the steps below.",
    enhanced: "With ML upscaling, MetalFX and sharpening.",
  }
  const show = (split) => {
    const at = Math.min(100, Math.max(0, split))
    frame.style.setProperty("--split", `${at}%`)
    range.value = String(Math.round(at))
    const mode = at >= 100 ? "original" : at <= 0 ? "enhanced" : "split"
    range.setAttribute("aria-valuetext", mode === "split" ? `Line at ${Math.round(at)}%` : `${mode[0].toUpperCase()}${mode.slice(1)} only`)
    for (const button of view.querySelectorAll("button")) {
      const target = Number(button.dataset.split)
      const pressed = mode === "split" ? target === 50 : target === at
      button.setAttribute("aria-pressed", String(pressed))
    }
    hint.textContent = hints[mode]
  }
  const fromPointer = (e) => {
    const box = frame.getBoundingClientRect()
    show(((e.clientX - box.left) / box.width) * 100)
  }
  frame.addEventListener("pointerdown", (e) => {
    frame.setPointerCapture(e.pointerId)
    fromPointer(e)
    range.focus({ preventScroll: true })
  })
  frame.addEventListener("pointermove", (e) => {
    if (frame.hasPointerCapture(e.pointerId)) fromPointer(e)
  })
  range.addEventListener("input", () => { show(Number(range.value)) })
  view.addEventListener("click", (e) => {
    const button = e.target.closest("button")
    if (button) show(Number(button.dataset.split))
  })
  show(50)
}

// The download button goes straight to the latest DMG once GitHub says which it is; until then (or without
// the network), to the latest release's page.
const latestRelease = async (link, version) => {
  try {
    const reply = await fetch("https://api.github.com/repos/deblanco/PlayFX/releases/latest")
    if (!reply.ok) return
    const release = await reply.json()
    const dmg = release.assets?.find((a) => a.name.endsWith(".dmg"))
    if (dmg) link.href = dmg.browser_download_url
    if (typeof release.tag_name === "string") version.textContent = `Version ${release.tag_name.replace(/^v/, "")}. `
  } catch {
    // The release page link stays.
  }
}

ribbons(document.getElementById("ribbons"))
tabs(document.querySelector('[role="tablist"]'))
comparison(document.getElementById("compare"), document.getElementById("compare-range"),
  document.getElementById("view"), document.getElementById("view-hint"))
latestRelease(document.getElementById("download"), document.getElementById("version"))
