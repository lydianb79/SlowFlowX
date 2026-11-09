// Metal Shading Language source, compiled at runtime with `MTLDevice.makeLibrary(source:)`.
// Compiling at runtime keeps the Swift package buildable with just the command line tools
// (no separate Metal toolchain / .metallib build step required).

enum MetalShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// ───────────────────────────── Compute: chroma folding ─────────────────────────────
// mags:    [frames * bins] normalised magnitude spectrum
// binPC:   pitch class (0-11) for each bin, -1 = ignored
// binW:    weight of each bin (distance from the nearest semitone centre)
// chroma:  [frames * 12] output
kernel void fold_chroma(device const float* mags   [[buffer(0)]],
                        device const int*   binPC  [[buffer(1)]],
                        device const float* binW   [[buffer(2)]],
                        device float*       chroma [[buffer(3)]],
                        constant uint2&     dims   [[buffer(4)]],   // x = frames, y = bins
                        uint2 gid [[thread_position_in_grid]])
{
    uint frame = gid.x;
    uint pc = gid.y;
    if (frame >= dims.x || pc >= 12) return;
    device const float* row = mags + frame * dims.y;
    float acc = 0.0;
    for (uint k = 0; k < dims.y; ++k) {
        if (binPC[k] == int(pc)) {
            acc += log(1.0 + 1000.0 * row[k]) * binW[k];
        }
    }
    chroma[frame * 12 + pc] = acc;
}

// ───────────────────────────── Compute: chord template scoring ─────────────────────────────
// Cosine similarity of every chroma frame against every chord template.
kernel void score_chords(device const float* chroma    [[buffer(0)]],
                         device const float* templates [[buffer(1)]],   // [numTemplates * 12], L2-normalised
                         device float*       scores    [[buffer(2)]],   // [frames * numTemplates]
                         constant uint2&     dims      [[buffer(3)]],   // x = frames, y = numTemplates
                         uint2 gid [[thread_position_in_grid]])
{
    uint f = gid.x;
    uint t = gid.y;
    if (f >= dims.x || t >= dims.y) return;
    float dotv = 0.0;
    float norm = 0.0;
    for (uint i = 0; i < 12; ++i) {
        float c = chroma[f * 12 + i];
        dotv += c * templates[t * 12 + i];
        norm += c * c;
    }
    scores[f * dims.y + t] = norm > 1e-9 ? dotv / sqrt(norm) : 0.0;
}

// ───────────────────────────── Render: shared full-screen triangle ─────────────────────────────
struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = float2((pos[vid].x + 1.0) * 0.5, 1.0 - (pos[vid].y + 1.0) * 0.5);
    return o;
}

// ───────────────────────────── Render: zoomable waveform ─────────────────────────────
// All time values are normalised song positions (0..1). The visible window is [viewStart, viewEnd].
struct WaveUniforms {
    float4 waveColor;
    float4 playedColor;
    float4 playheadColor;
    float4 bgColor;
    float4 loopColor;
    float2 size;        // drawable size in pixels
    float  progress;    // 0..1
    float  loopA;       // 0..1, or -1
    float  loopB;       // 0..1, or -1
    float  peakCount;
    float  scale;       // backing scale factor
    float  hover;       // 0..1, or -1
    float  viewStart;   // 0..1
    float  viewEnd;     // 0..1
    float  gridStep;    // seconds-grid spacing in normalised units (0 = off)
    float  _pad;
};

fragment float4 waveform_fragment(VOut in [[stage_in]],
                                  constant WaveUniforms& u [[buffer(0)]],
                                  device const float* peaks [[buffer(1)]])
{
    float px = in.position.x;
    float py = in.position.y;
    float W = u.size.x;
    float H = u.size.y;
    float span = max(u.viewEnd - u.viewStart, 1e-6);
    float barW = 2.0 * u.scale;
    float gap  = 1.2 * u.scale;
    float cell = barW + gap;

    // Bars are anchored to absolute time so they don't shimmer while panning.
    float pxPerUnit = W / span;
    float absPx = px + u.viewStart * pxPerUnit;
    float idx  = floor(absPx / cell);
    float local = absPx - idx * cell;
    float t0 = (idx * cell) / pxPerUnit;
    float t1 = ((idx + 1.0) * cell) / pxPerUnit;

    uint n = uint(u.peakCount);
    float amp = 0.0;
    if (n > 0 && t1 > 0.0 && t0 < 1.0) {
        uint i0 = min(uint(max(t0, 0.0) * float(n)), n - 1);
        uint i1 = min(uint(min(t1, 1.0) * float(n)), n - 1);
        for (uint i = i0; i <= i1 && i < i0 + 512; ++i) amp = max(amp, peaks[i]);
    }

    float tc = (t0 + t1) * 0.5;
    float t  = u.viewStart + (px / W) * span;
    float mid = H * 0.5;
    float dy = abs(py - mid) / mid;
    float h = max(amp, 0.012) * 0.92;

    float3 col = u.bgColor.rgb;

    // time grid
    if (u.gridStep > 0.0) {
        float g = t / u.gridStep;
        float distPx = abs(g - round(g)) * u.gridStep * pxPerUnit;
        if (distPx < 0.5 * u.scale) col = mix(col, u.waveColor.rgb, 0.12);
    }

    if (u.loopB > u.loopA && u.loopA >= 0.0 && t >= u.loopA && t <= u.loopB) {
        col = mix(col, u.loopColor.rgb, u.loopColor.a);
        // selection edges
        float ax = (u.loopA - u.viewStart) / span * W;
        float bx = (u.loopB - u.viewStart) / span * W;
        if (abs(px - ax) < 1.0 * u.scale || abs(px - bx) < 1.0 * u.scale) col = mix(col, u.loopColor.rgb, 0.9);
    }

    if (abs(py - mid) < 0.5 * u.scale) col = mix(col, u.waveColor.rgb, 0.15);

    if (local < barW && t0 >= 0.0 && t1 <= 1.0 + 1e-4) {
        float aa = 1.5 * u.scale / mid;
        float edge = 1.0 - smoothstep(h - aa, h, dy);
        if (edge > 0.0) {
            float4 base = (tc <= u.progress) ? u.playedColor : u.waveColor;
            float shade = 1.0 - 0.40 * (dy / max(h, 0.001));
            col = mix(col, base.rgb * (0.62 + 0.38 * shade), base.a * edge);
        }
    }

    if (u.hover >= 0.0) {
        float hx = (u.hover - u.viewStart) / span * W;
        if (abs(px - hx) < 0.75 * u.scale) col = mix(col, u.playheadColor.rgb, 0.45);
    }

    float phx = (u.progress - u.viewStart) / span * W;
    float d = abs(px - phx);
    col += u.playheadColor.rgb * exp(-d / (7.0 * u.scale)) * 0.16;
    if (d < 1.0 * u.scale) col = u.playheadColor.rgb;

    return float4(col, 1.0);
}

// ───────────────────────────── Render: live spectrum ─────────────────────────────
struct SpecUniforms {
    float4 colorA;
    float4 colorB;
    float4 bgColor;
    float2 size;
    float  bandCount;
    float  scale;
};

fragment float4 spectrum_fragment(VOut in [[stage_in]],
                                  constant SpecUniforms& u [[buffer(0)]],
                                  device const float* bands [[buffer(1)]])
{
    float W = u.size.x;
    float H = u.size.y;
    uint n = max(uint(u.bandCount), 1u);
    float px = in.position.x;
    float py = in.position.y;
    float cell = W / float(n);
    uint i = min(uint(px / cell), n - 1);
    float local = px - float(i) * cell;
    float gap = max(cell * 0.30, 1.0 * u.scale);
    float bw = cell - gap;
    float x = local - gap * 0.5;

    float3 col = u.bgColor.rgb;
    float baseY = H * 0.80;
    float v = clamp(bands[i], 0.0, 1.0);
    float barH = max(v * baseY * 0.95, 1.5 * u.scale);
    float top = baseY - barH;

    if (x >= 0.0 && x <= bw) {
        float r = min(bw * 0.5, 3.0 * u.scale);
        bool inside = false;
        if (py >= top + r && py <= baseY) {
            inside = true;
        } else if (py >= top && py < top + r) {
            float cx = clamp(x, r, bw - r);
            float2 dd = float2(x - cx, py - (top + r));
            inside = length(dd) <= r;
        }
        float g = clamp((baseY - py) / baseY, 0.0, 1.0);
        float3 barCol = mix(u.colorA.rgb, u.colorB.rgb, g);
        if (inside) {
            col = barCol;
        } else if (py > baseY + 1.5 * u.scale) {
            float ry = py - baseY - 1.5 * u.scale;
            float rh = barH * 0.45;
            if (ry <= rh) {
                float a = (1.0 - ry / rh) * 0.25;
                col = mix(col, u.colorA.rgb, a);
            }
        }
    }
    return float4(col, 1.0);
}
"""#
}
