import PhotonGPU

// Metal value types and enums, with Apple's raw values where code could observe them. Only what PhotonRender uses.

public enum MTLPixelFormat: UInt, Hashable, Sendable {
    case invalid = 0
    case r8Unorm = 10
    case r16Unorm = 20
    case r16Float = 25
    case rg8Unorm = 30
    case r32Float = 55
    case rg16Float = 65
    case rgba8Unorm = 70
    case rgba8Unorm_srgb = 71
    case bgra8Unorm = 80
    case bgra8Unorm_srgb = 81
    case rgb10a2Unorm = 90
    case rgba16Unorm = 110
    case rgba16Snorm = 112
    case rgba16Float = 115
    case rgba32Float = 125
    case bc1_rgba = 130
    case bc2_rgba = 132
    case bc3_rgba = 134
    case bc7_rgbaUnorm = 152
    case depth32Float = 252
    case depth24Unorm_stencil8 = 255
    case depth32Float_stencil8 = 260

    /// The PhotonGPU format, nil when the facade has no backend format for it.
    public var gpu: GPUPixelFormat? {
        switch self {
        case .invalid, .r16Unorm: return nil
        case .r8Unorm: return .r8Unorm
        case .r16Float: return .r16Float
        case .rg8Unorm: return .rg8Unorm
        case .r32Float: return .r32Float
        case .rg16Float: return .rg16Float
        case .rgba8Unorm: return .rgba8Unorm
        case .rgba8Unorm_srgb: return .rgba8UnormSRGB
        case .bgra8Unorm: return .bgra8Unorm
        case .bgra8Unorm_srgb: return .bgra8UnormSRGB
        case .rgb10a2Unorm: return .rgb10a2Unorm
        case .rgba16Unorm: return .rgba16Unorm
        case .rgba16Snorm: return .rgba16Snorm
        case .rgba16Float: return .rgba16Float
        case .rgba32Float: return .rgba32Float
        case .bc1_rgba: return .bc1
        case .bc2_rgba: return .bc2
        case .bc3_rgba: return .bc3
        case .bc7_rgbaUnorm: return .bc7
        case .depth32Float, .depth32Float_stencil8: return .depth32Float
        case .depth24Unorm_stencil8: return .depth24Stencil8
        }
    }
}

public enum MTLTextureType: UInt, Sendable {
    case type1D = 0, type1DArray = 1, type2D = 2, type2DArray = 3, type2DMultisample = 4, typeCube = 5, typeCubeArray = 6, type3D = 7
}

public struct MTLTextureUsage: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let unknown = MTLTextureUsage([])
    public static let shaderRead = MTLTextureUsage(rawValue: 1)
    public static let shaderWrite = MTLTextureUsage(rawValue: 2)
    public static let renderTarget = MTLTextureUsage(rawValue: 4)
    public static let pixelFormatView = MTLTextureUsage(rawValue: 0x10)
}

public enum MTLStorageMode: UInt, Sendable { case shared = 0, managed = 1, `private` = 2, memoryless = 3 }
public enum MTLCPUCacheMode: UInt, Sendable { case defaultCache = 0, writeCombined = 1 }

public struct MTLResourceOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let cpuCacheModeWriteCombined = MTLResourceOptions(rawValue: 1)
    public static let storageModeShared = MTLResourceOptions([])
    public static let storageModeManaged = MTLResourceOptions(rawValue: 1 << 4)
    public static let storageModePrivate = MTLResourceOptions(rawValue: 2 << 4)
}

public struct MTLOrigin: Hashable, Sendable {
    public var x: Int, y: Int, z: Int
    public init() { x = 0; y = 0; z = 0 }
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
}

public struct MTLSize: Hashable, Sendable {
    public var width: Int, height: Int, depth: Int
    public init() { width = 0; height = 0; depth = 0 }
    public init(width: Int, height: Int, depth: Int) { self.width = width; self.height = height; self.depth = depth }
}

public struct MTLRegion: Hashable, Sendable {
    public var origin: MTLOrigin
    public var size: MTLSize
    public init() { origin = MTLOrigin(); size = MTLSize() }
    public init(origin: MTLOrigin, size: MTLSize) { self.origin = origin; self.size = size }
}

public func MTLRegionMake2D(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: width, height: height, depth: 1))
}

public func MTLRegionMake3D(_ x: Int, _ y: Int, _ z: Int, _ width: Int, _ height: Int, _ depth: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: z), size: MTLSize(width: width, height: height, depth: depth))
}

public func MTLOriginMake(_ x: Int, _ y: Int, _ z: Int) -> MTLOrigin { MTLOrigin(x: x, y: y, z: z) }
public func MTLSizeMake(_ w: Int, _ h: Int, _ d: Int) -> MTLSize { MTLSize(width: w, height: h, depth: d) }

public struct MTLClearColor: Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init() { red = 0; green = 0; blue = 0; alpha = 1 }
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public func MTLClearColorMake(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> MTLClearColor {
    MTLClearColor(red: r, green: g, blue: b, alpha: a)
}

public struct MTLViewport: Hashable, Sendable {
    public var originX: Double, originY: Double, width: Double, height: Double, znear: Double, zfar: Double
    public init() { originX = 0; originY = 0; width = 0; height = 0; znear = 0; zfar = 1 }
    public init(originX: Double, originY: Double, width: Double, height: Double, znear: Double, zfar: Double) {
        self.originX = originX; self.originY = originY; self.width = width; self.height = height; self.znear = znear; self.zfar = zfar
    }
    var gpu: GPUViewport { GPUViewport(x: originX, y: originY, width: width, height: height, minDepth: znear, maxDepth: zfar) }
}

public struct MTLScissorRect: Hashable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public enum MTLSamplerMinMagFilter: UInt, Sendable { case nearest = 0, linear = 1 }
public enum MTLSamplerMipFilter: UInt, Sendable { case notMipmapped = 0, nearest = 1, linear = 2 }
public enum MTLSamplerAddressMode: UInt, Sendable {
    case clampToEdge = 0, mirrorClampToEdge = 1, `repeat` = 2, mirrorRepeat = 3, clampToZero = 4, clampToBorderColor = 5
    var gpu: GPUAddressMode {
        switch self {
        case .clampToEdge, .mirrorClampToEdge: return .clampToEdge
        case .repeat: return .repeat
        case .mirrorRepeat: return .mirrorRepeat
        case .clampToZero, .clampToBorderColor: return .clampToBorder
        }
    }
}
public enum MTLSamplerBorderColor: UInt, Sendable { case transparentBlack = 0, opaqueBlack = 1, opaqueWhite = 2 }

public enum MTLCompareFunction: UInt, Sendable {
    case never = 0, less = 1, equal = 2, lessEqual = 3, greater = 4, notEqual = 5, greaterEqual = 6, always = 7
    var gpu: GPUCompareFunction {
        switch self {
        case .never: return .never
        case .less: return .less
        case .equal: return .equal
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .notEqual: return .notEqual
        case .greaterEqual: return .greaterEqual
        case .always: return .always
        }
    }
}

public enum MTLVertexFormat: UInt, Hashable, Sendable {
    case invalid = 0
    case uchar4 = 3
    case ushort2 = 13, ushort4 = 15
    case uchar4Normalized = 9
    case short2Normalized = 19, short4Normalized = 21
    case float = 28, float2 = 29, float3 = 30, float4 = 31
    case uint = 36, uint4 = 39
    var gpu: GPUVertexFormat? {
        switch self {
        case .invalid: return nil
        case .uchar4: return .uchar4
        case .ushort2: return .ushort2
        case .ushort4: return .ushort4
        case .uchar4Normalized: return .uchar4Normalized
        case .short2Normalized: return .short2Normalized
        case .short4Normalized: return .short4Normalized
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .float4: return .float4
        case .uint: return .uint
        case .uint4: return .uint4
        }
    }
}

public enum MTLVertexStepFunction: UInt, Sendable { case constant = 0, perVertex = 1, perInstance = 2 }

public enum MTLBlendFactor: UInt, Sendable {
    case zero = 0, one = 1, sourceColor = 2, oneMinusSourceColor = 3, sourceAlpha = 4, oneMinusSourceAlpha = 5
    case destinationColor = 6, oneMinusDestinationColor = 7, destinationAlpha = 8, oneMinusDestinationAlpha = 9
    var gpu: GPUBlendFactor {
        switch self {
        case .zero: return .zero
        case .one: return .one
        case .sourceColor: return .sourceColor
        case .oneMinusSourceColor: return .oneMinusSourceColor
        case .sourceAlpha: return .sourceAlpha
        case .oneMinusSourceAlpha: return .oneMinusSourceAlpha
        case .destinationColor: return .destinationColor
        case .oneMinusDestinationColor: return .oneMinusDestinationColor
        case .destinationAlpha: return .destinationAlpha
        case .oneMinusDestinationAlpha: return .oneMinusDestinationAlpha
        }
    }
}

public enum MTLBlendOperation: UInt, Sendable {
    case add = 0, subtract = 1, reverseSubtract = 2, min = 3, max = 4
    var gpu: GPUBlendOperation {
        switch self {
        case .add: return .add
        case .subtract: return .subtract
        case .reverseSubtract: return .reverseSubtract
        case .min: return .min
        case .max: return .max
        }
    }
}

public struct MTLColorWriteMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let alpha = MTLColorWriteMask(rawValue: 1)
    public static let blue = MTLColorWriteMask(rawValue: 2)
    public static let green = MTLColorWriteMask(rawValue: 4)
    public static let red = MTLColorWriteMask(rawValue: 8)
    public static let all = MTLColorWriteMask(rawValue: 15)
    var gpu: GPUColorWriteMask {
        var m = GPUColorWriteMask()
        if contains(.red) { m.insert(.red) }
        if contains(.green) { m.insert(.green) }
        if contains(.blue) { m.insert(.blue) }
        if contains(.alpha) { m.insert(.alpha) }
        return m
    }
}

public enum MTLLoadAction: UInt, Sendable { case dontCare = 0, load = 1, clear = 2 }
public enum MTLStoreAction: UInt, Sendable {
    case dontCare = 0, store = 1, multisampleResolve = 2, storeAndMultisampleResolve = 3, unknown = 4, customSampleDepthStore = 5
}

public enum MTLPrimitiveType: UInt, Sendable { case point = 0, line = 1, lineStrip = 2, triangle = 3, triangleStrip = 4 }
public enum MTLPrimitiveTopologyClass: UInt, Sendable { case unspecified = 0, point = 1, line = 2, triangle = 3 }
public enum MTLIndexType: UInt, Sendable { case uint16 = 0, uint32 = 1 }
public enum MTLCullMode: UInt, Sendable { case none = 0, front = 1, back = 2 }
public enum MTLWinding: UInt, Sendable { case clockwise = 0, counterClockwise = 1 }
public enum MTLTriangleFillMode: UInt, Sendable { case fill = 0, lines = 1 }
public enum MTLVisibilityResultMode: UInt, Sendable { case disabled = 0, boolean = 1, counting = 2 }
public enum MTLFunctionType: UInt, Sendable { case vertex = 1, fragment = 2, kernel = 3 }

public enum MTLCommandBufferStatus: UInt, Sendable {
    case notEnqueued = 0, enqueued = 1, committed = 2, scheduled = 3, completed = 4, error = 5
}

public enum MTLPurgeableState: UInt, Sendable { case keepCurrent = 1, nonVolatile = 2, volatile = 3, empty = 4 }

public struct MTLLibraryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ s: String) { description = s }
}
