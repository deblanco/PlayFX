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
"""
