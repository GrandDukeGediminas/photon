// PhotonGPU: the backend-neutral GPU interface photon2 renders through (docs/linux-port.md §2).
// Value types only; no platform imports. Every name is prefixed GPU to stay clear of PhotonRender's own types
// (`GPUTexture` there is the loaded-.tex wrapper, so the texture protocol here is `GPUTextureResource`).

/// Pixel formats the engine uses (docs/re/01 §3.4 TEX formats, render-target formats in docs/re/frame-graph.md §4).
/// Colour formats are UNORM/float: the engine renders gamma-naive on D3D11 and photon2 matches it. The two sRGB formats
/// exist only as views (`.pixelFormatView`) for the final encode of linear HDR output (SceneRenderer/ColorCorrection).
public enum GPUPixelFormat: Hashable, Sendable {
    case rgba8Unorm, bgra8Unorm, rg8Unorm, r8Unorm, rgba8UnormSRGB, bgra8UnormSRGB
    case rgba16Float, rg16Float, r16Float, rgba32Float, r32Float
    case rgba16Unorm, rgba16Snorm, rgb10a2Unorm
    case bc1, bc2, bc3, bc7
    case depth32Float, depth24Stencil8

    /// (bytes per block, block edge in texels).
    public var block: (bytes: Int, size: Int) {
        switch self {
        case .rgba8Unorm, .bgra8Unorm, .rgba8UnormSRGB, .bgra8UnormSRGB, .rg16Float, .r32Float, .rgb10a2Unorm, .depth32Float, .depth24Stencil8: return (4, 1)
        case .rg8Unorm, .r16Float: return (2, 1)
        case .r8Unorm: return (1, 1)
        case .rgba16Float, .rgba16Unorm, .rgba16Snorm: return (8, 1)
        case .rgba32Float: return (16, 1)
        case .bc1: return (8, 4)
        case .bc2, .bc3, .bc7: return (16, 4)
        }
    }

    public var isDepth: Bool { self == .depth32Float || self == .depth24Stencil8 }
    public var isCompressed: Bool { block.size > 1 }

    /// Bytes of one row of blocks for a mip of width `w`.
    public func bytesPerRow(width w: Int) -> Int { ((max(w, 1) + block.size - 1) / block.size) * block.bytes }
    public func bytesPerImage(width w: Int, height h: Int) -> Int { bytesPerRow(width: w) * ((max(h, 1) + block.size - 1) / block.size) }
}

public struct GPUTextureUsage: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shaderRead = GPUTextureUsage(rawValue: 1)
    public static let renderTarget = GPUTextureUsage(rawValue: 2)
    /// Source of copies, blits and readbacks.
    public static let copySource = GPUTextureUsage(rawValue: 4)
    /// Views with another format may be made (`makeView(format:)`, the sRGB encode views).
    public static let pixelFormatView = GPUTextureUsage(rawValue: 8)
}

public enum GPUTextureType: Hashable, Sendable { case type2D, type3D }

public struct GPUTextureDescriptor: Hashable, Sendable {
    public var type: GPUTextureType = .type2D
    public var format: GPUPixelFormat
    public var width: Int
    public var height: Int
    public var depth: Int = 1
    public var mipLevels: Int = 1
    public var sampleCount: Int = 1
    public var usage: GPUTextureUsage = [.shaderRead]
    public var label: String = ""

    public init(format: GPUPixelFormat, width: Int, height: Int, mipLevels: Int = 1, sampleCount: Int = 1,
                usage: GPUTextureUsage = [.shaderRead], label: String = "") {
        self.format = format
        self.width = width
        self.height = height
        self.mipLevels = mipLevels
        self.sampleCount = sampleCount
        self.usage = usage
        self.label = label
    }

    /// The engine's render targets (`RT_Create` 0x1401aadb0): drawable, sampled, copyable.
    public static func renderTarget(_ format: GPUPixelFormat, _ w: Int, _ h: Int, mipLevels: Int = 1, sampleCount: Int = 1,
                                    label: String = "") -> GPUTextureDescriptor {
        GPUTextureDescriptor(format: format, width: w, height: h, mipLevels: mipLevels, sampleCount: sampleCount,
                             usage: [.shaderRead, .renderTarget, .copySource], label: label)
    }
}

public enum GPUFilter: Hashable, Sendable { case nearest, linear }
public enum GPUMipFilter: Hashable, Sendable { case none, nearest, linear }
public enum GPUAddressMode: Hashable, Sendable {
    case `repeat`, clampToEdge, mirrorRepeat
    /// Border colour transparent black (Metal clampToBorderColor/.transparentBlack, D3D11 BORDER with (0,0,0,0)).
    case clampToBorder
}
public enum GPUCompareFunction: Hashable, Sendable { case never, less, equal, lessEqual, greater, notEqual, greaterEqual, always }

public struct GPUSamplerDescriptor: Hashable, Sendable {
    public var minFilter: GPUFilter = .linear
    public var magFilter: GPUFilter = .linear
    public var mipFilter: GPUMipFilter = .none
    public var addressU: GPUAddressMode = .repeat
    public var addressV: GPUAddressMode = .repeat
    public var addressW: GPUAddressMode = .repeat
    public var maxAnisotropy = 1
    /// Comparison sampler (`_rt_shadowAtlas`, SamplerComparisonState).
    public var compare: GPUCompareFunction?
    public init() {}

    /// `sub_140099980` (docs/re/01 §3.4): flag 1 point filtering, flag 2 clamp, otherwise wrap; non-point textures
    /// are trilinear with 8× anisotropy unless `anisotropic` is false (user textures). Mirrors TextureLoader.sampler.
    public static func engine(point: Bool, clamp: Bool, mipmapped: Bool, anisotropic: Bool) -> GPUSamplerDescriptor {
        var d = GPUSamplerDescriptor()
        d.minFilter = point ? .nearest : .linear
        d.magFilter = point ? .nearest : .linear
        d.mipFilter = mipmapped ? (point ? .nearest : .linear) : .none
        if !point && anisotropic { d.maxAnisotropy = 8 }
        let mode: GPUAddressMode = clamp ? .clampToEdge : .repeat
        d.addressU = mode; d.addressV = mode; d.addressW = mode
        return d
    }
}

public enum GPUBlendFactor: Hashable, Sendable {
    case zero, one, sourceColor, oneMinusSourceColor, sourceAlpha, oneMinusSourceAlpha
    case destinationColor, oneMinusDestinationColor, destinationAlpha, oneMinusDestinationAlpha
}
public enum GPUBlendOperation: Hashable, Sendable { case add, subtract, reverseSubtract, min, max }

public struct GPUColorWriteMask: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let red = GPUColorWriteMask(rawValue: 1), green = GPUColorWriteMask(rawValue: 2)
    public static let blue = GPUColorWriteMask(rawValue: 4), alpha = GPUColorWriteMask(rawValue: 8)
    public static let rgb: GPUColorWriteMask = [.red, .green, .blue]
    public static let all: GPUColorWriteMask = [.red, .green, .blue, .alpha]
}

/// One colour attachment's blend state (D3D11_RENDER_TARGET_BLEND_DESC).
public struct GPUBlendDescriptor: Hashable, Sendable {
    public var enabled = false
    public var sourceRGB = GPUBlendFactor.one, destinationRGB = GPUBlendFactor.zero, rgbOperation = GPUBlendOperation.add
    public var sourceAlpha = GPUBlendFactor.one, destinationAlpha = GPUBlendFactor.zero, alphaOperation = GPUBlendOperation.add
    public var writeMask = GPUColorWriteMask.all
    public init() {}
}

public struct GPUDepthStencilDescriptor: Hashable, Sendable {
    public var compare: GPUCompareFunction = .always
    public var write = false
    public init(compare: GPUCompareFunction = .always, write: Bool = false) {
        self.compare = compare
        self.write = write
    }
}

public enum GPUCullMode: Hashable, Sendable { case none, front, back }
public enum GPUWinding: Hashable, Sendable { case clockwise, counterClockwise }
public enum GPUPrimitiveType: Hashable, Sendable { case triangle, triangleStrip, line, point }
public enum GPUIndexType: Hashable, Sendable { case uint16, uint32 }

public enum GPUVertexFormat: Hashable, Sendable {
    case float, float2, float3, float4, uchar4Normalized, uchar4, ushort2, ushort4, short2Normalized, short4Normalized, uint, uint4
    public var size: Int {
        switch self {
        case .float, .uchar4Normalized, .uchar4, .ushort2, .short2Normalized, .uint: return 4
        case .float2, .ushort4, .short4Normalized: return 8
        case .float3: return 12
        case .float4, .uint4: return 16
        }
    }
}

public struct GPUVertexAttribute: Hashable, Sendable {
    /// SPIR-V input location (the engine attribute id, pinned by the translator: docs/re/02 §6).
    public var location: Int
    public var format: GPUVertexFormat
    public var offset: Int
    public init(location: Int, format: GPUVertexFormat, offset: Int) {
        self.location = location
        self.format = format
        self.offset = offset
    }
}

/// One interleaved vertex stream (photon2 binds all vertex data at one slot, like `ShaderCompiler.vertexBufferIndex`).
public struct GPUVertexLayout: Hashable, Sendable {
    public var stride: Int
    public var attributes: [GPUVertexAttribute]
    /// One element per instance (the particle point lists fed to geometry shaders, docs/re/05 §5.3).
    public var perInstance: Bool
    public init(stride: Int, attributes: [GPUVertexAttribute], perInstance: Bool = false) {
        self.stride = stride
        self.attributes = attributes
        self.perInstance = perInstance
    }

    /// float3 a_Position (location 0) + float2 a_TexCoord (location 7): `Mesh_CreateQuad` (docs/re/03 §5).
    public static let quad = GPUVertexLayout(stride: 20, attributes: [
        GPUVertexAttribute(location: 0, format: .float3, offset: 0), GPUVertexAttribute(location: 7, format: .float2, offset: 12),
    ])
}

/// D3D11_VIEWPORT. Origin top-left, y down, depth range [minDepth, maxDepth]. Backends map it so that NDC +y is up
/// and row 0 is the top of the target on every API (Vulkan: negative-height viewport).
public struct GPUViewport: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double, minDepth: Double, maxDepth: Double
    public init(x: Double = 0, y: Double = 0, width: Double, height: Double, minDepth: Double = 0, maxDepth: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.minDepth = minDepth; self.maxDepth = maxDepth
    }
}

public struct GPUClearColor: Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public enum GPULoadAction: Hashable, Sendable { case load, clear, dontCare }

public enum GPUShaderStage: Hashable, Sendable, CaseIterable { case vertex, geometry, fragment }

public struct GPUShaderStages: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vertex = GPUShaderStages(rawValue: 1), geometry = GPUShaderStages(rawValue: 2), fragment = GPUShaderStages(rawValue: 4)
    public static let all: GPUShaderStages = [.vertex, .geometry, .fragment]
}

/// What a backend can do; the renderer picks paths from it (e.g. native geometry shaders vs GeometryEmulation).
public struct GPUCapabilities: Sendable {
    public var deviceName = ""
    public var geometryShaders = false
    public var bcTextureCompression = false
    public var maxAnisotropy: Double = 1
    public var maxSampleCount = 1
    /// Every colour/depth sample count the device supports for render targets (Metal supportsTextureSampleCount).
    public var sampleCounts: Set<Int> = [1]
    public var multiViewport = false
    public init() {}
}

public enum GPUError: Error, CustomStringConvertible {
    case unsupported(String)
    case failed(String)
    public var description: String {
        switch self {
        case .unsupported(let s): return "unsupported: \(s)"
        case .failed(let s): return s
        }
    }
}
