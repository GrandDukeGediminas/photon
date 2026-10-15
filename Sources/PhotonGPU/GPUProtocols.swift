// The device/command interface every backend implements (Metal today in PhotonRender, Vulkan in PhotonVulkan).
//
// The binding model is the engine's D3D11 one, because that is what the translated HLSL declares: constant buffers by
// (stage, register bN), textures by slot tN and samplers by slot sN, shared by every stage. Each backend owns the
// mapping from those registers to its own binding points (Metal: buffer/texture/sampler index; Vulkan: one descriptor
// set laid out by `HLSLRegisterMap`). Uniform data is passed by value per draw (`setUniformBytes`), like Metal's
// setVertexBytes and the engine's per-draw cbuffer Map/WRITE_DISCARD, so callers never manage uniform buffers.

public protocol GPUDevice: AnyObject {
    var capabilities: GPUCapabilities { get }
    func makeBuffer(length: Int) throws -> GPUBuffer
    func makeTexture(_ descriptor: GPUTextureDescriptor) throws -> GPUTextureResource
    func makeSampler(_ descriptor: GPUSamplerDescriptor) throws -> GPUSampler
    /// `spirv` is glslang output for one stage (HLSL front end, entry point `main`). Backends that cannot consume SPIR-V
    /// translate it (Metal: SPIRV-Cross → MSL, as PhotonRender's ShaderCompiler does today).
    func makeShaderModule(stage: GPUShaderStage, spirv: [UInt32], entryPoint: String, label: String) throws -> GPUShaderModule
    func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> GPURenderPipeline
    /// D3D11 occlusion queries (sprite objects, docs/re/04): `count` slots, results read after the command buffer completes.
    func makeOcclusionQuerySet(count: Int) throws -> GPUOcclusionQuerySet
    func makeCommandBuffer() throws -> GPUCommandBuffer
}

/// CPU-visible buffer (shared storage). Writes are visible to commands committed afterwards.
public protocol GPUBuffer: AnyObject {
    var length: Int { get }
    var contents: UnsafeMutableRawPointer { get }
}

public protocol GPUTextureResource: AnyObject {
    var descriptor: GPUTextureDescriptor { get }
    /// Synchronous upload of one mip level (MTLTexture.replace semantics: complete when the call returns).
    /// `bytes` holds `depth` images of `bytesPerImage`, rows of `bytesPerRow` (blocks for compressed formats).
    func replace(level: Int, x: Int, y: Int, width: Int, height: Int, depth: Int,
                 bytes: UnsafeRawBufferPointer, bytesPerRow: Int, bytesPerImage: Int) throws
    /// Synchronous readback of a region of one mip (MTLTexture.getBytes semantics: the contents after every committed
    /// command buffer that wrote it). Rows of `bytesPerRow`, `depth` images of `bytesPerImage`.
    func read(level: Int, x: Int, y: Int, width: Int, height: Int, depth: Int, into bytes: UnsafeMutableRawBufferPointer,
              bytesPerRow: Int, bytesPerImage: Int) throws
    /// A view of `levelCount` mips from `baseLevel`, optionally with another format of the same size class (needs
    /// `.pixelFormatView` for a different format). Views share storage with the texture; copies, render passes and
    /// bindings of a view address only its mips.
    func makeView(format: GPUPixelFormat, baseLevel: Int, levelCount: Int) throws -> GPUTextureResource
}

extension GPUTextureResource {
    public var width: Int { descriptor.width }
    public var height: Int { descriptor.height }
    public var format: GPUPixelFormat { descriptor.format }
    public var sampleCount: Int { descriptor.sampleCount }

    /// Whole-level upload of a 2D mip.
    public func replace(level: Int, bytes: UnsafeRawBufferPointer) throws {
        let w = max(1, width >> level), h = max(1, height >> level)
        try replace(level: level, x: 0, y: 0, width: w, height: h, depth: 1, bytes: bytes,
                    bytesPerRow: format.bytesPerRow(width: w), bytesPerImage: format.bytesPerImage(width: w, height: h))
    }
}

public protocol GPUSampler: AnyObject {
    var descriptor: GPUSamplerDescriptor { get }
}

public protocol GPUShaderModule: AnyObject {
    var stage: GPUShaderStage { get }
    /// Reflection of the module's SPIR-V (cbuffer layouts by register, texture/sampler slots, input locations).
    var reflection: SPIRVReflection { get }
}

public struct GPURenderPipelineDescriptor {
    public var vertex: GPUShaderModule
    public var geometry: GPUShaderModule?
    public var fragment: GPUShaderModule
    public var vertexLayout: GPUVertexLayout
    public var colorFormat: GPUPixelFormat
    public var depthFormat: GPUPixelFormat?
    public var sampleCount: Int = 1
    public var blend = GPUBlendDescriptor()
    public var alphaToCoverage = false
    public var primitive: GPUPrimitiveType = .triangle
    public var label = ""

    public init(vertex: GPUShaderModule, geometry: GPUShaderModule? = nil, fragment: GPUShaderModule, vertexLayout: GPUVertexLayout,
                colorFormat: GPUPixelFormat, depthFormat: GPUPixelFormat? = nil, sampleCount: Int = 1) {
        self.vertex = vertex
        self.geometry = geometry
        self.fragment = fragment
        self.vertexLayout = vertexLayout
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
    }
}

public protocol GPURenderPipeline: AnyObject {}

public protocol GPUOcclusionQuerySet: AnyObject {
    var count: Int { get }
    /// Samples passed per slot; valid after the command buffer that wrote them has completed.
    func results() -> [UInt64]
}

public struct GPURenderPassDescriptor {
    public var color: GPUTextureResource
    public var colorLoad: GPULoadAction = .load
    public var clearColor = GPUClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    public var depth: GPUTextureResource?
    public var depthLoad: GPULoadAction = .load
    /// Reverse-Z: the engine clears depth to 0 (far), docs/re/03 "Depth".
    public var clearDepth: Double = 0
    public var occlusionQueries: GPUOcclusionQuerySet?
    /// Multisample resolve target written at the end of the pass (Metal storeAndMultisampleResolve, D3D11
    /// ResolveSubresource): the box average of the samples.
    public var resolve: GPUTextureResource?
    public init(color: GPUTextureResource) { self.color = color }
}

public protocol GPUCommandBuffer: AnyObject {
    /// Opens a render pass. Only one encoder is open at a time; end it before the next pass or copy.
    func beginRenderPass(_ descriptor: GPURenderPassDescriptor) throws -> GPURenderEncoder
    /// Same-size, same-format copy of mip `level` (render target vt+8 → CopyResource / CopySubresourceRegion).
    func copyTexture(_ source: GPUTextureResource, level: Int, to destination: GPUTextureResource, destinationLevel: Int)
    /// Region copy (CopySubresourceRegion / MTLBlitCommandEncoder.copy(from:sourceSlice:sourceLevel:sourceOrigin:…)).
    /// Origins and size in texels; `depth` slices of a 3D texture.
    func copyTexture(_ source: GPUTextureResource, level: Int, origin: (x: Int, y: Int, z: Int), size: (width: Int, height: Int, depth: Int),
                     to destination: GPUTextureResource, destinationLevel: Int, destinationOrigin: (x: Int, y: Int, z: Int))
    /// MSAA resolve (ResolveSubresource): the box average of all samples.
    func resolve(_ source: GPUTextureResource, into destination: GPUTextureResource)
    /// GenerateMips on `_rt_MipMappedFrameBuffer` (frame-graph F18): each level a 2×2 box filter of the previous.
    func generateMipmaps(_ texture: GPUTextureResource)
    /// Copies mip `level` into `buffer` as tightly packed rows (readback, transition snapshots).
    func copyTextureToBuffer(_ texture: GPUTextureResource, level: Int, buffer: GPUBuffer)
    /// Region readback into `buffer` at `offset`, rows `bytesPerRow` apart (MTLBlitCommandEncoder texture → buffer).
    func copyTextureToBuffer(_ texture: GPUTextureResource, level: Int, origin: (x: Int, y: Int), size: (width: Int, height: Int),
                             buffer: GPUBuffer, offset: Int, bytesPerRow: Int)
    /// Copies `texture` (same size and format class as the drawable, or blitted when they differ) into `drawable` at the
    /// end of this command buffer and presents it after the buffer executes (Metal `present(_:)`). One per buffer.
    func present(_ texture: GPUTextureResource, to drawable: GPUDrawable)
    /// Submits the recorded commands and returns without waiting (Metal semantics). Commands of later command buffers and
    /// later texture uploads execute after these.
    func commit()
    /// Blocks until the GPU has executed the buffer, then runs its completed handlers (and those of earlier buffers).
    func waitUntilCompleted()
    /// Runs once the GPU has executed the buffer, on the thread that next commits, waits or polls (`GPUDevice` users
    /// call `waitUntilCompleted` or commit more work; there is no background thread).
    func addCompletedHandler(_ handler: @escaping () -> Void)
    var isCompleted: Bool { get }
    /// Scaled copy of `from` (a rectangle of `source`'s first level) onto `to` of `destination` (vkCmdBlitImage, linear
    /// filtering, nearest when the two rectangles have the same size). A rectangle given right to left (x1 < x0) mirrors
    /// the copy horizontally. The desktop hosts' stretch / clone layouts (docs/linux-port.md §5.4).
    func blit(_ source: GPUTextureResource, from: GPUBlitRect, to destination: GPUTextureResource, at: GPUBlitRect)
    /// `present(_:to:)` of a region of `texture`, scaled onto the whole drawable (or mirrored, as `blit`).
    func present(_ texture: GPUTextureResource, region: GPUBlitRect, to drawable: GPUDrawable)
}

/// A texel rectangle by its corners, for `GPUCommandBuffer.blit` (x1 < x0 mirrors).
public struct GPUBlitRect: Equatable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    public init(width: Int, height: Int) { self.init(x0: 0, y0: 0, x1: width, y1: height) }
    public var width: Int { abs(x1 - x0) }
    public var height: Int { abs(y1 - y0) }
}

/// A presentable image from a host's swapchain (Vulkan WSI): written by `GPUCommandBuffer.present(_:to:)`.
public protocol GPUDrawable: AnyObject {
    var width: Int { get }
    var height: Int { get }
}

public protocol GPURenderEncoder: AnyObject {
    func setPipeline(_ pipeline: GPURenderPipeline)
    func setViewport(_ viewport: GPUViewport)
    /// Several viewports (the shadow caster pass, `SV_ViewportArrayIndex`); needs `capabilities.multiViewport`.
    func setViewports(_ viewports: [GPUViewport])
    func setCullMode(_ mode: GPUCullMode)
    func setFrontFace(_ winding: GPUWinding)
    func setDepthStencil(_ state: GPUDepthStencilDescriptor)
    func setDepthBias(_ bias: Float, slopeScale: Float, clamp: Float)
    /// Constant buffer `register(bN)` of `stage`, by value. A geometry-stage register nothing was set for reads the vertex
    /// stage's value: photon2 compiles native geometry shaders with the vertex stage's merged cbuffer layout
    /// (`GeometryEmulation.buildNative`), and the engine fills both stages' b0/b1 from the same values by name.
    func setUniformBytes(_ bytes: UnsafeRawBufferPointer, stage: GPUShaderStage, register: Int)
    /// Texture slot tN for every stage (Draw.swift binds the same textures to VS and PS).
    func setTexture(_ texture: GPUTextureResource?, slot: Int)
    func setSampler(_ sampler: GPUSampler?, slot: Int)
    /// Vertex data by value (small meshes; Metal setVertexBytes) or from a buffer.
    func setVertexBytes(_ bytes: UnsafeRawBufferPointer)
    func setVertexBuffer(_ buffer: GPUBuffer, offset: Int)
    func draw(vertexStart: Int, vertexCount: Int, instanceCount: Int)
    func drawIndexed(indices: UnsafeRawBufferPointer, type: GPUIndexType, indexCount: Int, instanceCount: Int)
    func beginOcclusionQuery(_ index: Int)
    func endOcclusionQuery(_ index: Int)
    func end()
}
