// Metal shaders compiled at runtime (no offline `metal` compiler needed, works with
// Command Line Tools only).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Placeholder video source until the PS5 stream is wired in: a moving zone plate with
// spokes and a 1px grid — fine detail that makes upscaling quality easy to judge.
kernel void testPattern(texture2d<float, access::write> out [[texture(0)]],
                        constant float &t [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 p = (uv - 0.5) * float2(float(w) / float(h), 1.0);
    float r = length(p);

    float zone = 0.5 + 0.5 * cos(180.0 * r * r - t * 2.0);
    float3 col = mix(float3(0.04, 0.06, 0.12), float3(0.15, 0.5, 1.0), zone);

    float spokes = step(0.0, sin(atan2(p.y, p.x) * 24.0 + t * 0.5));
    col = mix(col, float3(1.0), spokes * step(0.25, r) * step(r, 0.42));

    bool grid = (gid.x % 32 == 0) || (gid.y % 32 == 0);
    col = max(col, grid ? float3(0.6) : float3(0.0));
    out.write(float4(col, 1.0), gid);
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
    out.write(float4(saturate(rgb), 1.0), gid);
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
// (texel-exact) or bilinear. `peak` = -1 / lerp(8, 5, sharpness).
fragment float4 sharpenFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]],
                                constant float2 &step [[buffer(0)]],
                                constant float &peak [[buffer(1)]]) {
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

    // Soft min/max over the cross plus the corners.
    float3 mn = min(min(min(d, e), min(f, b)), h);
    mn += min(mn, min(min(a, c), min(g, i)));
    float3 mx = max(max(max(d, e), max(f, b)), h);
    mx += max(mx, max(max(a, c), max(g, i)));

    // Less sharpening where the neighborhood already spans the full range (avoids ringing).
    float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, float3(1e-5))));
    float3 w = amp * peak;
    float3 sharp = (b * w + d * w + f * w + h * w + e) / (1.0 + 4.0 * w);
    return float4(saturate(sharp), 1.0);
}

// The line between the two halves of the compare view.
fragment float4 dividerFragment(VOut in [[stage_in]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}
"""
