/// How the engine's D3D11 state maps onto PhotonGPU, in one place so both backends get the same answers.
/// Sources are the renderer init and state functions cited in Draw.swift / ShaderProgram.swift / RenderContext.swift.
public enum D3D11Conventions {
    /// Reverse-Z (projection 0x14009a360 swaps near/far): depth clears to 0, tests GREATER (0x140099096).
    public static let depthClear: Double = 0
    public static let depthCompare: GPUCompareFunction = .greater
    /// Rasterizer states (0x140099119–0x14009920e): FrontCounterClockwise = TRUE, judged in the render target
    /// (NDC +y up, rows top-down). Metal `.counterClockwise`; Vulkan with the negative-height viewport, CCW too.
    public static let frontFace: GPUWinding = .counterClockwise
    /// Depth-bias rasterizer state for the shadow caster pass (0x1400991bd): bias 0, clamp 0, slope −4.
    public static let casterSlopeScale: Float = -4

    /// `R_FlushState` 0x140099f60 depth-stencil index: translucent and additive draws never write depth.
    public static func depthState(test: Bool, write: Bool, blendWritesDepth: Bool) -> GPUDepthStencilDescriptor {
        GPUDepthStencilDescriptor(compare: test ? depthCompare : .always, write: test && write && blendWritesDepth)
    }

    /// The engine blend modes (docs/re/03 §2) with their modifiers, exactly as `BlendState.apply` (ShaderProgram.swift)
    /// builds the Metal colour attachment: mode 0 normal / 3 alpha-to-coverage (no blending), 1 translucent, 2 additive;
    /// `colorWrite` false = pseudo-mode 4 (alpha-only writes); `destColor` = state bit 0x100 (SrcBlend DEST_COLOR);
    /// `alphaMax` = the passthrough-group alpha MAX state (vt+0xe8).
    public static func blend(mode: Int, colorWrite: Bool = true, alphaWrite: Bool = false, alphaMax: Bool = false,
                             destColor: Bool = false) -> GPUBlendDescriptor {
        var d = GPUBlendDescriptor()
        guard colorWrite else {
            d.writeMask = .alpha
            d.enabled = false
            return d
        }
        switch mode {
        case 1:
            d.enabled = true
            d.sourceRGB = .sourceAlpha; d.destinationRGB = .oneMinusSourceAlpha
            d.sourceAlpha = .sourceAlpha; d.destinationAlpha = .oneMinusSourceAlpha
        case 2:
            d.enabled = true
            d.sourceRGB = .sourceAlpha; d.destinationRGB = .one
            d.sourceAlpha = .sourceAlpha; d.destinationAlpha = .one
        default:
            d.enabled = false
        }
        if destColor && d.enabled { d.sourceRGB = .destinationColor }
        d.rgbOperation = .add
        d.alphaOperation = .add
        d.writeMask = .rgb
        if alphaWrite || alphaMax { d.writeMask = .all }
        if alphaMax {
            d.enabled = true
            if mode == 0 || mode == 3 { d.sourceRGB = .one; d.destinationRGB = .zero }
            d.alphaOperation = .max
            d.sourceAlpha = .one; d.destinationAlpha = .one
        }
        return d
    }
}

/// Where HLSL registers land in SPIR-V for the Vulkan backend: one descriptor set (0), bindings shifted per class so
/// the vertex and pixel `$Globals`/`b0` blocks (different layouts, same register) do not collide. Passed to glslang as
/// `--shift-UBO-binding` / `--shift-texture-binding` / `--shift-sampler-binding`.
public enum HLSLRegisterMap {
    /// Constant-buffer registers per stage. 12 = Vulkan's guaranteed maxPerStageDescriptorUniformBuffers; the engine's
    /// shaders use b0–b3.
    public static let uniformRegisters = 12
    /// Texture / sampler slots (the engine binds t0–t9; Vulkan guarantees 16 sampled images and samplers per stage).
    public static let slots = 16
    public static func uniformBase(_ stage: GPUShaderStage) -> Int {
        switch stage {
        case .vertex: return 0
        case .fragment: return 16
        case .geometry: return 64
        }
    }
    public static let textureBase = 32
    public static let samplerBase = 48
    public static let bindingCount = 80
}
