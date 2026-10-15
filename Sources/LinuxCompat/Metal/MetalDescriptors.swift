import PhotonGPU

// Metal descriptor classes (reference types, like their Objective-C originals: `d.colorAttachments[0].texture = t`
// mutates the descriptor in place).

public final class MTLTextureDescriptor {
    public var textureType: MTLTextureType = .type2D
    public var pixelFormat: MTLPixelFormat = .rgba8Unorm
    public var width = 1
    public var height = 1
    public var depth = 1
    public var mipmapLevelCount = 1
    public var sampleCount = 1
    public var arrayLength = 1
    public var usage: MTLTextureUsage = .shaderRead
    public var storageMode: MTLStorageMode = .shared
    public var cpuCacheMode: MTLCPUCacheMode = .defaultCache
    public var resourceOptions: MTLResourceOptions = []
    public var allowGPUOptimizedContents = true
    public init() {}

    /// Metal: mipmapped → the full chain, floor(log2(max(width, height))) + 1 levels.
    public static func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = pixelFormat
        d.width = width
        d.height = height
        if mipmapped {
            var n = 1, m = max(width, height)
            while m > 1 { m >>= 1; n += 1 }
            d.mipmapLevelCount = n
        }
        return d
    }
}

public final class MTLSamplerDescriptor {
    public var minFilter: MTLSamplerMinMagFilter = .nearest
    public var magFilter: MTLSamplerMinMagFilter = .nearest
    public var mipFilter: MTLSamplerMipFilter = .notMipmapped
    public var sAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var tAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var rAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var maxAnisotropy = 1
    public var compareFunction: MTLCompareFunction = .never
    public var borderColor: MTLSamplerBorderColor = .transparentBlack
    public var lodMinClamp: Float = 0
    public var lodMaxClamp: Float = .greatestFiniteMagnitude
    public var normalizedCoordinates = true
    public var supportArgumentBuffers = false
    public var label: String?
    public init() {}

    var gpu: GPUSamplerDescriptor {
        var d = GPUSamplerDescriptor()
        d.minFilter = minFilter == .linear ? .linear : .nearest
        d.magFilter = magFilter == .linear ? .linear : .nearest
        switch mipFilter {
        case .notMipmapped: d.mipFilter = .none
        case .nearest: d.mipFilter = .nearest
        case .linear: d.mipFilter = .linear
        }
        d.addressU = sAddressMode.gpu
        d.addressV = tAddressMode.gpu
        d.addressW = rAddressMode.gpu
        d.maxAnisotropy = maxAnisotropy
        // Metal: compareFunction .never on a sampler means "not a comparison sampler" unless the shader samples with
        // compare; a non-never function makes it one (Shadows.swift sets .greater).
        d.compare = compareFunction == .never ? nil : compareFunction.gpu
        return d
    }
}

public final class MTLDepthStencilDescriptor {
    public var depthCompareFunction: MTLCompareFunction = .always
    public var isDepthWriteEnabled = false
    public var label: String?
    public init() {}
}

public final class MTLVertexAttributeDescriptor {
    public var format: MTLVertexFormat = .invalid
    public var offset = 0
    public var bufferIndex = 0
    public init() {}
}

public final class MTLVertexBufferLayoutDescriptor {
    public var stride = 0
    public var stepFunction: MTLVertexStepFunction = .perVertex
    public var stepRate = 1
    public init() {}
}

public final class MTLVertexAttributeDescriptorArray {
    var items: [Int: MTLVertexAttributeDescriptor] = [:]
    public subscript(index: Int) -> MTLVertexAttributeDescriptor! {
        get {
            if let a = items[index] { return a }
            let a = MTLVertexAttributeDescriptor()
            items[index] = a
            return a
        }
        set { items[index] = newValue }
    }
}

public final class MTLVertexBufferLayoutDescriptorArray {
    var items: [Int: MTLVertexBufferLayoutDescriptor] = [:]
    public subscript(index: Int) -> MTLVertexBufferLayoutDescriptor! {
        get {
            if let a = items[index] { return a }
            let a = MTLVertexBufferLayoutDescriptor()
            items[index] = a
            return a
        }
        set { items[index] = newValue }
    }
}

public final class MTLVertexDescriptor {
    public let attributes = MTLVertexAttributeDescriptorArray()
    public let layouts = MTLVertexBufferLayoutDescriptorArray()
    public init() {}
    public static func vertexDescriptor() -> MTLVertexDescriptor { MTLVertexDescriptor() }

    /// The single interleaved stream at `MetalFacade.vertexBufferIndex` as a PhotonGPU layout.
    var gpu: GPUVertexLayout {
        let index = MetalFacade.vertexBufferIndex
        let layout = layouts.items[index]
        var attrs: [GPUVertexAttribute] = []
        for (loc, a) in attributes.items.sorted(by: { $0.key < $1.key }) where a.bufferIndex == index {
            guard let f = a.format.gpu else { continue }
            attrs.append(GPUVertexAttribute(location: loc, format: f, offset: a.offset))
        }
        return GPUVertexLayout(stride: layout?.stride ?? 0, attributes: attrs, perInstance: layout?.stepFunction == .perInstance)
    }
}

public final class MTLRenderPipelineColorAttachmentDescriptor {
    public var pixelFormat: MTLPixelFormat = .invalid
    public var isBlendingEnabled = false
    public var sourceRGBBlendFactor: MTLBlendFactor = .one
    public var destinationRGBBlendFactor: MTLBlendFactor = .zero
    public var rgbBlendOperation: MTLBlendOperation = .add
    public var sourceAlphaBlendFactor: MTLBlendFactor = .one
    public var destinationAlphaBlendFactor: MTLBlendFactor = .zero
    public var alphaBlendOperation: MTLBlendOperation = .add
    public var writeMask: MTLColorWriteMask = .all
    public init() {}

    var gpu: GPUBlendDescriptor {
        var b = GPUBlendDescriptor()
        b.enabled = isBlendingEnabled
        b.sourceRGB = sourceRGBBlendFactor.gpu
        b.destinationRGB = destinationRGBBlendFactor.gpu
        b.rgbOperation = rgbBlendOperation.gpu
        b.sourceAlpha = sourceAlphaBlendFactor.gpu
        b.destinationAlpha = destinationAlphaBlendFactor.gpu
        b.alphaOperation = alphaBlendOperation.gpu
        b.writeMask = writeMask.gpu
        return b
    }
}

public final class MTLRenderPipelineColorAttachmentDescriptorArray {
    var items: [Int: MTLRenderPipelineColorAttachmentDescriptor] = [:]
    public subscript(index: Int) -> MTLRenderPipelineColorAttachmentDescriptor! {
        get {
            if let a = items[index] { return a }
            let a = MTLRenderPipelineColorAttachmentDescriptor()
            items[index] = a
            return a
        }
        set { items[index] = newValue }
    }
}

public final class MTLRenderPipelineDescriptor {
    public var label: String?
    public var vertexFunction: MTLFunction?
    public var fragmentFunction: MTLFunction?
    public var vertexDescriptor: MTLVertexDescriptor?
    public let colorAttachments = MTLRenderPipelineColorAttachmentDescriptorArray()
    public var depthAttachmentPixelFormat: MTLPixelFormat = .invalid
    public var stencilAttachmentPixelFormat: MTLPixelFormat = .invalid
    public var rasterSampleCount = 1
    public var sampleCount: Int { get { rasterSampleCount } set { rasterSampleCount = newValue } }
    public var isAlphaToCoverageEnabled = false
    public var isAlphaToOneEnabled = false
    public var isRasterizationEnabled = true
    public var inputPrimitiveTopology: MTLPrimitiveTopologyClass = .unspecified
    /// Linux only (Metal has no geometry stage): a native geometry function. The pipeline then takes a point list, one
    /// vertex per point, and the facade turns the emulated draw (`listVertexCount` vertices × one instance per point,
    /// GeometryEmulation) into a draw of the points (ShaderProgram, `PHOTON_NATIVE_GS`).
    public var geometryFunction: MTLFunction?
    /// `.triangle`: the geometry function takes the emulated draw's triangles instead (the pass-through check,
    /// GeometryEmulation.buildNative); the draw is left as encoded.
    public var geometryInput: MTLPrimitiveTopologyClass = .point
    public init() {}
}

public final class MTLRenderPassColorAttachmentDescriptor {
    public var texture: MTLTexture?
    public var level = 0
    public var slice = 0
    public var depthPlane = 0
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .store
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    public var resolveTexture: MTLTexture?
    public var resolveLevel = 0
    public init() {}
}

public final class MTLRenderPassColorAttachmentDescriptorArray {
    var items: [Int: MTLRenderPassColorAttachmentDescriptor] = [:]
    public subscript(index: Int) -> MTLRenderPassColorAttachmentDescriptor! {
        get {
            if let a = items[index] { return a }
            let a = MTLRenderPassColorAttachmentDescriptor()
            items[index] = a
            return a
        }
        set { items[index] = newValue }
    }
}

public final class MTLRenderPassDepthAttachmentDescriptor {
    public var texture: MTLTexture?
    public var level = 0
    public var slice = 0
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .dontCare
    public var clearDepth: Double = 1
    public var resolveTexture: MTLTexture?
    public init() {}
}

public final class MTLRenderPassStencilAttachmentDescriptor {
    public var texture: MTLTexture?
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .dontCare
    public var clearStencil: UInt32 = 0
    public init() {}
}

public final class MTLRenderPassDescriptor {
    public let colorAttachments = MTLRenderPassColorAttachmentDescriptorArray()
    public var depthAttachment = MTLRenderPassDepthAttachmentDescriptor()
    public var stencilAttachment = MTLRenderPassStencilAttachmentDescriptor()
    public var visibilityResultBuffer: MTLBuffer?
    public var renderTargetWidth = 0
    public var renderTargetHeight = 0
    public var defaultRasterSampleCount = 0
    public init() {}
    public static func renderPassDescriptor() -> MTLRenderPassDescriptor { MTLRenderPassDescriptor() }
}

public final class MTLCompileOptions {
    public var preprocessorMacros: [String: Any]?
    public var fastMathEnabled = true
    public init() {}
}

/// A vertex-stage input as Metal reflects it (`MTLFunction.vertexAttributes`).
public final class MTLVertexAttribute {
    public let name: String
    public let attributeIndex: Int
    public let isActive: Bool
    init(name: String, attributeIndex: Int, isActive: Bool) {
        self.name = name
        self.attributeIndex = attributeIndex
        self.isActive = isActive
    }
}
