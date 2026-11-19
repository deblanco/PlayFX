// Metal shaders compiled at runtime (no offline `metal` compiler needed, works with
// Command Line Tools only).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// The idle backdrop between streams: slow light ribbons over a deep blue field. A fine grid lies
// underneath and only shows where a ribbon's glow passes over it (and in a few drifting patches),
// so the grid is always partly revealed and moves with the waves.
static float ribbonY(float x, float t, float base, float amp, float freq, float speed, float phase) {
    return base + amp * sin(x * freq + t * speed + phase) + amp * 0.45 * sin(x * freq * 2.1 - t * speed * 0.7 + phase * 1.7);
}

static float ribbonSlope(float x, float t, float amp, float freq, float speed, float phase) {
    return amp * freq * cos(x * freq + t * speed + phase)
         + amp * 0.45 * freq * 2.1 * cos(x * freq * 2.1 - t * speed * 0.7 + phase * 1.7);
}

kernel void testPattern(texture2d<float, access::write> out [[texture(0)]],
                        constant float &t [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float aspect = float(w) / float(h);
    float2 p = float2(uv.x * aspect, uv.y);          // height-normalized, y down

    // Field: abyss at the top, indigo rising from the bottom, a soft bloom low on the right.
    float3 abyss = float3(0.012, 0.024, 0.102);
    float3 indigo = float3(0.031, 0.102, 0.310);
    float3 col = mix(abyss, indigo, smoothstep(0.15, 1.1, uv.y) * 0.85);
    col += float3(0.06, 0.16, 0.55) * 0.35 * exp(-3.0 * length(p - float2(aspect * 0.78, 0.92)));

    // Three ribbons: shape (base, amplitude, frequency, speed), look (core width, glow width, brightness).
    const float4 shape[3] = { float4(0.52, 0.11, 1.9, 0.21), float4(0.68, 0.07, 1.4, -0.16),
                              float4(0.82, 0.12, 0.9, 0.12) };
    const float3 look[3] = { float3(0.0022, 0.05, 1.0), float3(0.0016, 0.035, 0.7), float3(0.0028, 0.07, 0.55) };
    float3 ribbonBlue = float3(0.118, 0.357, 1.0);
    float3 crest = float3(0.66, 0.78, 1.0);
    float reveal = 0.0;
    for (int i = 0; i < 3; i++) {
        float4 s = shape[i];
        float y = ribbonY(p.x, t, s.x, s.y, s.z, s.w, float(i) * 2.1);
        float slope = ribbonSlope(p.x, t, s.y, s.z, s.w, float(i) * 2.1);
        float d = (p.y - y) / sqrt(1.0 + slope * slope);   // ≈ perpendicular distance
        float core = exp(-(d * d) / (look[i].x * look[i].x));
        float glow = exp(-(d * d) / (look[i].y * look[i].y));
        // A faint sheet trailing below each ribbon gives it body.
        float sheet = smoothstep(0.0, 0.02, d) * exp(-d * 9.0) * 0.18;
        col += ribbonBlue * (glow * 0.32 + sheet) * look[i].z + crest * core * 0.85 * look[i].z;
        // The grid surfaces just above each ribbon, where its light falls.
        reveal = max(reveal, exp(-(d * d) / 0.0035) * look[i].z);
    }

    // Drifting patches where the grid surfaces on its own.
    float patches = smoothstep(0.82, 1.0, (0.5 + 0.5 * sin(p.x * 3.1 + t * 0.11)) * (0.5 + 0.5 * sin(p.y * 4.3 - t * 0.08 + 1.3)) * 1.25);
    reveal = max(reveal, patches * 0.6);

    // The grid: 1px anti-aliased lines, 18 cells per screen height.
    float cell = float(h) / 18.0;
    float2 g = abs(fract(float2(gid) / cell + 0.5) - 0.5) * cell;
    float line = 1.0 - smoothstep(0.4, 1.3, min(g.x, g.y));
    col += float3(0.43, 0.545, 1.0) * line * reveal * 0.3;

    // Vignette, then a little noise so 8-bit gradients don't band.
    col *= 1.0 - 0.35 * smoothstep(0.45, 1.25, length((uv - 0.5) * float2(1.3, 1.0)) * 1.4);
    float n = fract(sin(dot(float2(gid), float2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) / 255.0;
    out.write(float4(saturate(col), 1.0), gid);
}

// YCbCrConversion in Color.swift: range = (luma offset, luma scale, chroma offset, chroma scale),
// coef = (R←Cr, G←Cb, G←Cr, B←Cb), chroma = (siting shift x, y in chroma texels, bicubic, -).
struct YCbCrParams { float4 range; float4 coef; float4 chroma; };

// Catmull-Rom weights for the 4 taps around a sample at fraction t.
static float4 catmullRom(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0,
                  -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2);
}

// Decoded video (NV12) → RGBA, the input to the upscaler. Matrix, range and chroma siting come
// from the frame (or the user's overrides); chroma is upsampled bilinearly or with Catmull-Rom.
// SMPTE ST 2084 (PQ) EOTF: signal 0–1 → linear light 0–1 (= 0–10000 nits).
static float3 pqToLinear(float3 e) {
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 p = pow(e, 1.0 / m2);
    return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}

kernel void nv12ToRGB(texture2d<float, access::read> lumaTex [[texture(0)]],
                      texture2d<float, access::sample> chromaTex [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      constant YCbCrParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 csize = float2(chromaTex.get_width(), chromaTex.get_height());
    // This pixel's position in chroma texel coordinates (texel centers at integers).
    float2 c = (float2(gid) + 0.5) * csize / float2(w, h) - 0.5 + p.chroma.xy;
    float2 cbcr;
    if (p.chroma.z > 0.5) {
        float2 base = floor(c);
        float4 wx = catmullRom(c.x - base.x), wy = catmullRom(c.y - base.y);
        int2 last = int2(csize) - 1;
        cbcr = float2(0.0);
        for (int j = 0; j < 4; j++) {
            float2 row = float2(0.0);
            for (int i = 0; i < 4; i++) {
                int2 q = clamp(int2(base) + int2(i - 1, j - 1), int2(0), last);
                row += chromaTex.read(uint2(q)).rg * wx[i];
            }
            cbcr += row * wy[j];
        }
    } else {
        constexpr sampler s(filter::linear, coord::normalized, address::clamp_to_edge);
        cbcr = chromaTex.sample(s, (c + 0.5) / csize).rg;
    }
    float y = (lumaTex.read(gid).r - p.range.x) * p.range.y;
    float2 cc = (cbcr - p.range.z) * p.range.w;
    float3 rgb = float3(y + p.coef.x * cc.y,
                        y - p.coef.y * cc.x - p.coef.z * cc.y,
                        y + p.coef.w * cc.x);
    if (p.chroma.w > 0.5) {
        // HDR10: PQ → linear light, scaled so 203 nits (the HDR reference white) is 1.0 — the EDR
        // layer shows values above 1 as brighter-than-white, up to the display's headroom.
        out.write(float4(pqToLinear(saturate(rgb)) * (10000.0 / 203.0), 1.0), gid);
        return;
    }
    out.write(float4(saturate(rgb), 1.0), gid);
}

// ---- Cleanup before the upscale (deblock + deband), at stream resolution ----

static float3 texel(texture2d<float, access::read> t, int2 q, int2 size) {
    return t.read(uint2(clamp(q, int2(0), size - 1))).rgb;
}

// Small deterministic per-pixel noise in [0, 1).
static float hash(int2 p, float salt) {
    return fract(sin(dot(float2(p), float2(12.9898, 78.233)) + salt) * 43758.5453);
}

// H.264/HEVC-style deblocking of the 8×8 grid along one axis: when the step across a grid line
// is small and both sides are flat (a coding artifact, not a real edge), pull the two pixels
// next to the line toward each other.
static float3 deblockAxis(texture2d<float, access::read> t, int2 pos, int2 size, int2 axis, float3 c, float s, int grid) {
    int k = (axis.x != 0 ? pos.x : pos.y) % grid;
    int along = axis.x != 0 ? pos.x : pos.y;
    bool isP = k == grid - 1, isQ = k == 0 && along > 0;
    if (!isP && !isQ) return c;
    int2 p0 = isP ? pos : pos - axis;
    float3 vp1 = texel(t, p0 - axis, size), vp0 = texel(t, p0, size);
    float3 vq0 = texel(t, p0 + axis, size), vq1 = texel(t, p0 + 2 * axis, size);
    float alpha = 0.10 * s, beta = 0.03 * s, tc = 0.03 * s;
    bool artifact = all(abs(vp0 - vq0) < alpha) && all(abs(vp1 - vp0) < beta) && all(abs(vq1 - vq0) < beta);
    if (!artifact) return c;
    float3 delta = clamp(((vq0 - vp0) * 4.0 + (vp1 - vq1)) / 8.0, -tc, tc);
    return isP ? c + delta : c - delta; // on top of the other axis' correction
}

// Debanding: average four samples on a randomly rotated cross; use it only where every sample is
// within a small threshold of this pixel (a smooth gradient, not detail), then add faint dither.
static float3 deband(texture2d<float, access::read> t, int2 pos, int2 size, float3 c, float s) {
    float radius = 4.0 + 12.0 * s, threshold = 0.004 + 0.012 * s;
    float angle = hash(pos, 1.0) * 6.2831853;
    float2 dir = float2(cos(angle), sin(angle)) * radius * (0.5 + 0.5 * hash(pos, 2.0));
    float3 a = texel(t, pos + int2(round(dir)), size);
    float3 b = texel(t, pos - int2(round(dir)), size);
    float3 d = texel(t, pos + int2(round(float2(-dir.y, dir.x))), size);
    float3 e = texel(t, pos - int2(round(float2(-dir.y, dir.x))), size);
    float3 spread = max(max(abs(a - c), abs(b - c)), max(abs(d - c), abs(e - c)));
    if (all(spread < threshold)) c = (a + b + d + e) * 0.25;
    return c + (hash(pos, 3.0) - 0.5) * (s / 255.0);
}

// strengths = (deblock, deband, block grid in px — 8, or more after an ML upscale, ceiling): the ceiling is
// 1 in SDR and unbounded in HDR, where linear light goes far above SDR white (1.0 = 203 nits).
kernel void cleanup(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float4 &strengths [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    int2 size = int2(src.get_width(), src.get_height());
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    int2 pos = int2(gid);
    float3 c = texel(src, pos, size);
    if (strengths.x > 0.0) {
        int grid = max(int(strengths.z), 8);
        c = deblockAxis(src, pos, size, int2(1, 0), c, strengths.x, grid);
        c = deblockAxis(src, pos, size, int2(0, 1), c, strengths.x, grid);
    }
    if (strengths.y > 0.0) c = deband(src, pos, size, c, strengths.y);
    dst.write(float4(clamp(c, 0.0, strengths.w), 1.0), gid);
}

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 presentFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}

// Contrast-adaptive sharpening (AMD FidelityFX CAS, MIT), sharpen-only variant, on the
// presented image: neighbors are one output pixel apart, so it works the same after MetalFX
// (texel-exact) or bilinear. `peak` = -1 / lerp(8, 5, sharpness). `ceiling` is 1 in SDR; in HDR (linear
// light, 1.0 = SDR white) it's unbounded, and the neighbourhood is scaled to 0–1 by its own peak for CAS's
// contrast maths, so highlights keep their headroom.
fragment float4 sharpenFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]],
                                constant float2 &step [[buffer(0)]],
                                constant float &peak [[buffer(1)]],
                                constant float &ceiling [[buffer(2)]]) {
    float2 uv = in.uv;
    float3 a = tex.sample(s, uv + float2(-step.x, -step.y)).rgb;
    float3 b = tex.sample(s, uv + float2(0.0, -step.y)).rgb;
    float3 c = tex.sample(s, uv + float2(step.x, -step.y)).rgb;
    float3 d = tex.sample(s, uv + float2(-step.x, 0.0)).rgb;
    float3 e = tex.sample(s, uv).rgb;
    float3 f = tex.sample(s, uv + float2(step.x, 0.0)).rgb;
    float3 g = tex.sample(s, uv + float2(-step.x, step.y)).rgb;
    float3 h = tex.sample(s, uv + float2(0.0, step.y)).rgb;
    float3 i = tex.sample(s, uv + float2(step.x, step.y)).rgb;

    // HDR: bring the neighbourhood into 0–1 by its brightest sample (1 in SDR, so nothing changes there).
    float3 brightest = max(max(max(a, b), max(c, d)), max(max(e, f), max(max(g, h), i)));
    float scale = max(1.0, max(brightest.r, max(brightest.g, brightest.b)));
    a /= scale; b /= scale; c /= scale; d /= scale; e /= scale; f /= scale; g /= scale; h /= scale; i /= scale;

    // Soft min/max over the cross plus the corners.
    float3 mn = min(min(min(d, e), min(f, b)), h);
    mn += min(mn, min(min(a, c), min(g, i)));
    float3 mx = max(max(max(d, e), max(f, b)), h);
    mx += max(mx, max(max(a, c), max(g, i)));

    // Less sharpening where the neighborhood already spans the full range (avoids ringing).
    float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, float3(1e-5))));
    float3 w = amp * peak;
    float3 sharp = (b * w + d * w + f * w + h * w + e) / (1.0 + 4.0 * w);
    return float4(clamp(saturate(sharp) * scale, 0.0, ceiling), 1.0);
}

// The line between the two halves of the compare view.
fragment float4 dividerFragment(VOut in [[stage_in]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}
"""
