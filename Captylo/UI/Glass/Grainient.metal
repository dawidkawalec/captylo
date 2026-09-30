#include <metal_stdlib>
using namespace metal;

// "Grainient" (React Bits, Copyright (c) 2026 David Haz, MIT + Commons Clause, not covered by
// Captylo's GPLv3; see NOTICE.md) ported from GLSL to Metal for the Captylo window background
// (`GrainientBackdrop`, parameters in `GlassTokens.Grainient`). Same maths as the web version the
// owner approved in docs/design/lab/brand; only the coordinate origin differs (Metal is top-left,
// GL bottom-left, so y is flipped once below).

struct GrainientUniforms {
    float4 color1;
    float4 color2;
    float4 color3;
    float2 resolution;
    float2 centerOffset;
    float time;
    float timeSpeed;
    float colorBalance;
    float warpStrength;
    float warpFrequency;
    float warpSpeed;
    float warpAmplitude;
    float blendAngle;
    float blendSoftness;
    float rotationAmount;
    float noiseScale;
    float grainAmount;
    float grainScale;
    float grainAnimated;
    float contrast;
    float gamma;
    float saturation;
    float zoom;
};

struct GrainientVertexOut {
    float4 position [[position]];
};

vertex GrainientVertexOut grainientVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the whole viewport.
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GrainientVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}

static float2x2 grainientRot(float a) {
    float s = sin(a), c = cos(a);
    return float2x2(float2(c, -s), float2(s, c));
}

static float2 grainientHash(float2 p) {
    p = float2(dot(p, float2(2127.1, 81.17)), dot(p, float2(1269.5, 283.37)));
    // `precise::sin`: Metal's fast-math sin loses the low bits these hashes live on (visible
    // stripes in the grain instead of noise).
    return fract(precise::sin(p) * 43758.5453);
}

static float grainientNoise(float2 p) {
    float2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
    float n = mix(
        mix(dot(-1.0 + 2.0 * grainientHash(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
            dot(-1.0 + 2.0 * grainientHash(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
        mix(dot(-1.0 + 2.0 * grainientHash(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
            dot(-1.0 + 2.0 * grainientHash(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x),
        u.y);
    return 0.5 + 0.5 * n;
}

fragment float4 grainientFragment(GrainientVertexOut in [[stage_in]],
                                  constant GrainientUniforms &u [[buffer(0)]]) {
    float2 res = u.resolution;
    float2 C = float2(in.position.x, res.y - in.position.y);
    float t = u.time * u.timeSpeed;
    float2 uv = C / res;
    float ratio = res.x / res.y;
    float2 tuv = uv - 0.5 + u.centerOffset;
    tuv /= max(u.zoom, 0.001);

    float degree = grainientNoise(float2(t * 0.1, tuv.x * tuv.y) * u.noiseScale);
    tuv.y *= 1.0 / ratio;
    tuv = tuv * grainientRot((degree - 0.5) * u.rotationAmount * M_PI_F / 180.0 + M_PI_F);
    tuv.y *= ratio;

    float ws = max(u.warpStrength, 0.001);
    float amplitude = u.warpAmplitude / ws;
    float warpTime = t * u.warpSpeed;
    tuv.x += sin(tuv.y * u.warpFrequency + warpTime) / amplitude;
    tuv.y += sin(tuv.x * (u.warpFrequency * 1.5) + warpTime) / (amplitude * 0.5);

    float3 colLav = u.color1.rgb;
    float3 colOrg = u.color2.rgb;
    float3 colDark = u.color3.rgb;
    float b = u.colorBalance;
    float s = max(u.blendSoftness, 0.0);
    float blendX = (tuv * grainientRot(u.blendAngle * M_PI_F / 180.0)).x;
    float edge0 = -0.3 - b - s;
    float edge1 = 0.2 - b + s;
    float v0 = 0.5 - b + s;
    float v1 = -0.3 - b - s;
    float3 layer1 = mix(colDark, colOrg, smoothstep(edge0, edge1, blendX));
    float3 layer2 = mix(colOrg, colLav, smoothstep(edge0, edge1, blendX));
    float3 col = mix(layer1, layer2, smoothstep(v0, v1, tuv.y));

    float2 grainUv = uv * max(u.grainScale, 0.001);
    if (u.grainAnimated > 0.5) {
        grainUv += float2(u.time * 0.05);
    }
    float grain = fract(precise::sin(dot(grainUv, float2(12.9898, 78.233))) * 43758.5453);
    col += (grain - 0.5) * u.grainAmount;

    col = (col - 0.5) * u.contrast + 0.5;
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = mix(float3(luma), col, u.saturation);
    col = pow(max(col, 0.0), float3(1.0 / max(u.gamma, 0.001)));
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
