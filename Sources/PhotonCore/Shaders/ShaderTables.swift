/// Tables lifted from wallpaper64.exe (docs/re/02 §2.3, §6, Appendix B).
enum ShaderTables {
    /// Dialect type → HLSL type, in the order the declaration regexes are tried (0x140482eb0).
    static let types: [(glsl: String, hlsl: String)] = [
        ("float", "float"), ("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
        ("mat3", "float3x3"), ("mat4x3", "float4x3"), ("mat4", "float4x4"),
        ("sampler2D", "sampler"), ("sampler2DBackBuffer", "sampler"), ("sampler2DComparison", "samplerComparison"),
        ("sampler3D", "sampler"), ("int", "int"), ("ivec4", "int4"), ("uint", "uint"), ("uvec4", "uint4"),
    ]
    static let typeFloat = 0, typeVec2 = 1, typeVec4 = 3
    static let typeSampler2D = 7, typeBackBuffer = 8, typeComparison = 9, typeSampler3D = 10
    static let typeInt = 11, typeUint = 13

    /// Packed-array element types for float/vec2/int/uint uniforms (0x140482e30).
    static func packedElement(_ type: Int) -> String {
        switch type {
        case typeInt: return "int4"
        case typeUint: return "uint4"
        default: return "float4"
        }
    }

    /// Vertex attributes: name, HLSL type, semantic with index (0x140484a90 / 0x140482fa0).
    static let attributes: [(name: String, hlsl: String, semantic: String)] = [
        ("a_Position", "float3", "POSITION0"), ("a_PositionVec4", "float4", "POSITION0"),
        ("a_PositionC1", "float3", "POSITION1"), ("a_Normal", "float3", "NORMAL0"),
        ("a_Tangent4", "float4", "TANGENT0"), ("a_BlendIndices", "uint4", "BLENDINDICES0"),
        ("a_BlendWeights", "float4", "BLENDWEIGHT0"),
        ("a_TexCoord", "float2", "TEXCOORD0"), ("a_TexCoordVec3", "float3", "TEXCOORD0"), ("a_TexCoordVec4", "float4", "TEXCOORD0"),
        ("a_TexCoordC1", "float2", "TEXCOORD1"), ("a_TexCoordVec3C1", "float3", "TEXCOORD1"), ("a_TexCoordVec4C1", "float4", "TEXCOORD1"),
        ("a_TexCoordC2", "float2", "TEXCOORD2"), ("a_TexCoordVec3C2", "float3", "TEXCOORD2"), ("a_TexCoordVec4C2", "float4", "TEXCOORD2"),
        ("a_TexCoordC3", "float2", "TEXCOORD3"), ("a_TexCoordVec3C3", "float3", "TEXCOORD3"), ("a_TexCoordVec4C3", "float4", "TEXCOORD3"),
        ("a_TexCoordC4", "float2", "TEXCOORD4"), ("a_TexCoordVec3C4", "float3", "TEXCOORD4"), ("a_TexCoordVec4C4", "float4", "TEXCOORD4"),
        ("a_TexCoordC5", "float2", "TEXCOORD5"), ("a_TexCoordVec3C5", "float3", "TEXCOORD5"), ("a_TexCoordVec4C5", "float4", "TEXCOORD5"),
        ("a_Color", "float4", "COLOR0"),
    ]

    /// Constant buffer for each built-in uniform (0x1400f8494). Names absent from this map are material
    /// uniforms and go to b0.
    enum Buffer: Int { case statics = 0, dynamic = 1, animation = 2, lights = 3 }

    static let builtinBuffers: [String: Buffer] = {
        var m: [String: Buffer] = [:]
        let dynamic = [
            "g_Alpha", "g_Color", "g_Color4", "g_Time", "g_Frametime", "g_Daytime",
            "g_ModelMatrix", "g_ModelMatrixInverse", "g_ViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse",
            "g_ModelViewProjectionMatrix", "g_NormalModelMatrix", "g_AltModelMatrix", "g_AltNormalModelMatrix",
            "g_AltViewProjectionMatrix", "g_ViewportViewProjectionMatrices", "g_EffectModelMatrix",
            "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
            "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse", "g_LayerModelMatrix",
            "g_EyePosition", "g_ViewForward", "g_ViewRight", "g_ViewUp",
            "g_OrientationForward", "g_OrientationRight", "g_OrientationUp",
            "g_LightsColorRadius", "g_LightsColorPremultiplied", "g_LightsPosition", "g_LightAmbientColor", "g_LightSkylightColor",
            "g_AudioSpectrum16Left", "g_AudioSpectrum16Right", "g_AudioSpectrum32Left", "g_AudioSpectrum32Right",
            "g_AudioSpectrum64Left", "g_AudioSpectrum64Right",
            "g_PointerPositionLast", "g_PointerPosition", "g_PointerState", "g_ParallaxPosition",
            "g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3", "g_RenderVar4",
            "g_BonesAlpha", "g_BlendMap", "g_MorphOffsets", "g_MorphWeights", "g_MorphBoneTransform", "g_MorphBoneRules",
            "g_FogDistanceColor", "g_FogDistanceParams", "g_FogHeightColor", "g_FogHeightParams",
        ]
        for n in dynamic { m[n] = .dynamic }
        for i in 0..<10 {
            for s in ["Rotation", "Translation", "Resolution", "Texel", "MipMapInfo"] { m["g_Texture\(i)\(s)"] = .dynamic }
        }
        for n in ["g_TexelSizeHalf", "g_TexelSize", "g_Screen", "g_TextureReductionScale", "g_HDRParams"] { m[n] = .statics }
        m["g_Bones"] = .animation
        for n in ["g_LPoint_Color", "g_LPoint_Origin", "g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction",
                  "g_LSpot_Exponent", "g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB", "g_LDirectional_Color",
                  "g_LDirectional_Direction", "g_LFeature_ShadowProjection", "g_LFeature_ShadowProjectionTransform",
                  "g_LFeature_ShadowPointProjection", "g_LFeature_ShadowPointProjectionTransform"] { m[n] = .lights }
        return m
    }()

    static func isBuiltin(_ name: String) -> Bool {
        builtinBuffers[name] != nil || (name.hasPrefix("g_Texture") && name.count == 10 && name.last!.isNumber)
    }

    /// The fixed HLSL header (0x140487d10, 0x46c bytes), followed by one of two backbuffer macros.
    static let prelude = """
    #define vec2 float2
    #define vec3 float3
    #define vec4 float4
    #define uvec4 uint4
    #define mat4 float4x4
    #define mat4x3 float4x3
    #define mat3 float3x3
    #define mat2 float2x2
    #define mix lerp
    #define mod(x, y) ((x)-(y)*floor((x)/(y)))
    #define CASTI(x) ((int)(x))
    #define CASTU(x) ((uint)(x))
    #define CASTF(x) ((float)(x))
    #define CAST2(x) ((float2)(x))
    #define CAST3(x) ((float3)(x))
    #define CAST4U(x) ((uint4)(x))
    #define CAST4(x) ((float4)(x))
    #define CAST3X3(x) ((float3x3)(x))
    #define DECLARE_SAMPLER2D_PARAMETER(t) Texture2D t, SamplerState t ## SamplerState
    #define MAKE_SAMPLER2D_ARGUMENT(t) t, t ## SamplerState
    #define DECLARE_SAMPLER2D_COMPARE_PARAMETER(t) Texture2D t, SamplerComparisonState t ## SamplerComparisonState
    #define MAKE_SAMPLER2D_COMPARE_ARGUMENT(t) t, t ## SamplerComparisonState
    #define texSample2D(s, u) s.Sample(s ## SamplerState, u)
    #define texSample2DLod(s, u, m) s.SampleLevel(s  ## SamplerState, u, m)
    #define texSample2DCompare(s, u, d) s.SampleCmpLevelZero(s ## SamplerComparisonState, u, d)
    #define texLoad2D(s, u, r) s.Load(int3((u) * (r), 0))
    #define texSample3D(s, u) s.Sample(s ## SamplerState, u)

    """
    static let backBufferMS = "#define texSample2DBackBuffer(s, u, r) s.Load(int2((u) * (r)), 0)\n"
    static let backBuffer = "#define texSample2DBackBuffer(s, u, r) texSample2D(s, (u))\n"
}
