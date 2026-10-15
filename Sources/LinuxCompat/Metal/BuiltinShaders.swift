import Foundation
import PhotonGPU

/// HLSL ports of the MSL utility shaders PhotonRender writes inline (RenderContext.Blitter, ParticleLayerImage's
/// downsample, WallpaperTransition.Composite). `makeLibrary(source:)` finds them by the function names the MSL declares;
/// each port keeps the original's bindings (texture(N) → tN, sampler(N) → sN, buffer(N) → bN) and arithmetic.
enum BuiltinShaders {
    struct Shader {
        let stage: GPUShaderStage
        let hlsl: String
    }

    /// `vertex|fragment <type> <name>(` declarations in an MSL source.
    static func functionNames(inMSL source: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\b(?:vertex|fragment)\s+[A-Za-z_][A-Za-z0-9_]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Fullscreen triangle from the vertex id, uv (0,0) at the top-left (MSL `blitV`/`dsV`).
    static let fullscreenUV = Shader(stage: .vertex, hlsl: """
    struct V { float4 p : SV_Position; float2 uv : TEXCOORD0; };
    V main(uint i : SV_VertexID) {
        float2 uv = float2((i << 1) & 2, i & 2);
        V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o;
    }
    """)

    /// Position-only fullscreen triangle (MSL `compV`).
    static let fullscreen = Shader(stage: .vertex, hlsl: """
    float4 main(uint i : SV_VertexID) : SV_Position {
        float2 uv = float2((i << 1) & 2, i & 2);
        return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    }
    """)

    static let all: [String: Shader] = [
        "blitV": fullscreenUV,
        "dsV": fullscreenUV,
        "compV": fullscreen,
        "blitF": Shader(stage: .fragment, hlsl: """
        Texture2D t : register(t0);
        SamplerState s : register(s0);
        float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return t.Sample(s, uv); }
        """),
        // depth2d<float>.read: the depth texel at the pixel, clamped to the texture.
        "depthF": Shader(stage: .fragment, hlsl: """
        Texture2D<float> t : register(t0);
        float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
            uint w, h; t.GetDimensions(w, h);
            uint2 c = min(uint2(p.xy), uint2(w - 1, h - 1));
            return float4(t.Load(int3(c, 0)), 0, 0, 1);
        }
        """),
        "depthMSF": Shader(stage: .fragment, hlsl: """
        Texture2DMS<float> t : register(t0);
        float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
            uint w, h, n; t.GetDimensions(w, h, n);
            uint2 c = min(uint2(p.xy), uint2(w - 1, h - 1));
            return float4(t.Load(int2(c), 0), 0, 0, 1);
        }
        """),
        // downsample_quarter: four bilinear taps at ±2 texels, ×0.25; k.z > 0 multiplies alpha by the mask's red.
        "dsF": Shader(stage: .fragment, hlsl: """
        Texture2D t : register(t0);
        Texture2D m : register(t1);
        SamplerState s : register(s0);
        cbuffer K : register(b0) { float4 k; };
        float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
            float2 tx = k.xy;
            float4 a = t.Sample(s, uv - tx * 2) + t.Sample(s, uv + tx * 2)
                     + t.Sample(s, uv + float2(-tx.x, tx.y) * 2) + t.Sample(s, uv + float2(tx.x, -tx.y) * 2);
            a *= 0.25;
            if (k.z > 0) a.a *= m.Sample(s, uv).r;
            return a;
        }
        """),
        "compF": Shader(stage: .fragment, hlsl: """
        Texture2D t : register(t0);
        float4 main(float4 p : SV_Position) : SV_Target {
            uint w, h; t.GetDimensions(w, h);
            uint2 c = min(uint2(p.xy), uint2(w - 1, h - 1));
            return t.Load(int3(c, 0));
        }
        """),
        "compLinearF": Shader(stage: .fragment, hlsl: """
        Texture2D t : register(t0);
        float4 main(float4 p : SV_Position) : SV_Target {
            uint w, h; t.GetDimensions(w, h);
            uint2 c = min(uint2(p.xy), uint2(w - 1, h - 1));
            float4 o = t.Load(int3(c, 0));
            if (o.a <= 0) return float4(0, 0, 0, 0);
            float3 e = saturate(o.rgb / o.a);
            float3 l = (e <= 0.04045) ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4);
            return float4(l * o.a, o.a);
        }
        """),
        "snapF": Shader(stage: .fragment, hlsl: """
        Texture2D t : register(t0);
        cbuffer H : register(b0) { float2 hdr; };
        float4 main(float4 p : SV_Position) : SV_Target {
            uint w, h; t.GetDimensions(w, h);
            uint2 c = min(uint2(p.xy), uint2(w - 1, h - 1));
            float3 v = t.Load(int3(c, 0)).rgb;
            if (hdr.y > 0) v = max(1.055 * pow(v / hdr.x, 0.416666667) - 0.055, 0.0);
            return float4(v, 1);
        }
        """),
    ]
}
