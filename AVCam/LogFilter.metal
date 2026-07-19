#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Vertex stage
// Fullscreen triangle generated procedurally from vertex_id — no vertex
// buffer needed. Standard trick for post-process / image passes.
// =============================================================================

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut logFilterVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2( 3, -1), float2(-1,  3) };
    const float2 texCoords[3] = { float2( 0,  1), float2( 2,  1), float2( 0, -1) };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// =============================================================================
// Fragment stage
// Reads the Y (luma) and CbCr (chroma) planes of a 10-bit biplanar HLG
// buffer as two textures and writes both planes back out via multiple
// render targets (MRT), so a single pass produces a complete graded frame.
// =============================================================================

struct FragmentOut {
    float  y    [[color(0)]]; // luma plane
    float2 cbcr [[color(1)]]; // chroma plane
};

// Rec.2020/HLG "video range" legal range constants for 10-bit signals
// (luma nominal range 64-940 out of 1023).
constant float kLumaMin = 64.0  / 1023.0;
constant float kLumaMax = 940.0 / 1023.0;

inline float logStyleCurve(float x, float blackLift, float whiteCeiling, float g) {
    float p = pow(clamp(x, 0.0, 1.0), g);
    return blackLift + p * (whiteCeiling - blackLift);
}

/// Reshapes normalized (0-1, full range) luma with a curve that mimics the
/// general SHAPE of a flat log profile: lifted blacks, compressed highlights,
/// boosted mid-tones. These constants are hand-tuned to taste — this is NOT
/// a reverse-engineered reproduction of Sony S-Log or Canon C-Log's actual
/// (proprietary, sensor-specific) transfer functions. Treat it as a starting
/// point to dial in by eye against real footage.
inline float applyLogCurve(float x, float profileType) {
    float blackLift, whiteCeiling, g;
    if (profileType < 0.5) {
        // "sLog"-inspired: deeper lift, flatter mid-tones
        blackLift = 0.06; whiteCeiling = 0.90; g = 0.55;
    } else {
        // "cLog"-inspired: slightly punchier
        blackLift = 0.08; whiteCeiling = 0.88; g = 0.62;
    }
    return logStyleCurve(x, blackLift, whiteCeiling, g);
}

fragment FragmentOut logFilterFragment(VertexOut in [[stage_in]],
                                        texture2d<float, access::sample> yTexture [[texture(0)]],
                                        texture2d<float, access::sample> cbcrTexture [[texture(1)]],
                                        constant float &profileType [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float  yVideo    = yTexture.sample(s, in.texCoord).r;
    float2 cbcrVideo = cbcrTexture.sample(s, in.texCoord).rg;

    // Legal (video) range -> full 0-1 range for the curve math.
    float yFull = clamp((yVideo - kLumaMin) / (kLumaMax - kLumaMin), 0.0, 1.0);

    // This is where the actual "Log math" happens — reshaping the
    // HLG-encoded luma directly rather than linearizing first. That's
    // enough to mimic the look cheaply in real time. If you need
    // colorimetric accuracy instead of a look, invert the HLG OETF to
    // scene-linear before this step and re-apply an OETF afterwards.
    float yGraded = applyLogCurve(yFull, profileType);

    // Back to legal range for the HEVC encoder.
    float yOut = yGraded * (kLumaMax - kLumaMin) + kLumaMin;

    // Mild desaturation so chroma doesn't look artificially punchy sitting
    // under flattened luma — log footage reads as low-contrast AND low-sat.
    float2 chromaOut = (cbcrVideo - 0.5) * 0.85 + 0.5;

    FragmentOut out;
    out.y = yOut;
    out.cbcr = chromaOut;
    return out;
}

// =============================================================================
// RGB-domain variant
// For frames that arrive already debayered (e.g. from a RAW-photo-capture +
// demosaic pipeline) rather than as HLG YCbCr. Shares the vertex stage and
// the applyLogCurve() math above — this is the mathematically correct place
// for a log OETF to happen, since the input here is approximately linear
// scene-referred data, not an already-HLG-encoded signal like the path
// above. Same caveat as before applies to the curve constants: hand-tuned,
// not a byte-for-byte reproduction of a specific vendor's published curve.
// No highlight roll-off here — values above 1.0 hard-clip inside
// logStyleCurve's clamp(). Fine as a starting point; a soft knee is the
// obvious next improvement if you're seeing clipped highlights.
// =============================================================================

fragment half4 logFilterRGBFragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> rgbTexture [[texture(0)]],
                                     constant float &profileType [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 linearColor = rgbTexture.sample(s, in.texCoord);

    float r = applyLogCurve(linearColor.r, profileType);
    float g = applyLogCurve(linearColor.g, profileType);
    float b = applyLogCurve(linearColor.b, profileType);

    return half4(half3(r, g, b), half(linearColor.a));
}
