import Foundation

struct Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

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

    struct FragmentOut {
        float  y    [[color(0)]];
        float2 cbcr [[color(1)]];
    };

    constant float kLumaMin = 64.0  / 1023.0;
    constant float kLumaMax = 940.0 / 1023.0;

    inline float logStyleCurve(float x, float blackLift, float whiteCeiling, float g) {
        float p = pow(clamp(x, 0.0, 1.0), g);
        return blackLift + p * (whiteCeiling - blackLift);
    }

    inline float applyLogCurve(float x, float profileType) {
        float blackLift, whiteCeiling, g;
        if (profileType < 0.5) {
            blackLift = 0.06; whiteCeiling = 0.90; g = 0.55;
        } else {
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
        float yFull = clamp((yVideo - kLumaMin) / (kLumaMax - kLumaMin), 0.0, 1.0);
        float yGraded = applyLogCurve(yFull, profileType);
        float yOut = yGraded * (kLumaMax - kLumaMin) + kLumaMin;
        float2 chromaOut = (cbcrVideo - 0.5) * 0.85 + 0.5;
        FragmentOut out;
        out.y = yOut;
        out.cbcr = chromaOut;
        return out;
    }

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
    """
}