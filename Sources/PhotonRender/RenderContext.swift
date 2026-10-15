import Foundation
import Metal
import simd

/// A texture plus the sampler to read it with: either a loaded `.tex` or a render target.
public struct BoundTexture {
    public let texture: MTLTexture
    public let sampler: MTLSamplerState
    /// (textureWidth, textureHeight, imageWidth, imageHeight) for g_TextureNResolution.
    public let resolution: SIMD4<Float>
    public let gpu: GPUTexture?
    /// `tex+0xd0` → g_TextureNMipMapInfo (0x1400d98f4): the texture base ctor sets 1 (0x14015ec0b) and only render
    /// targets overwrite it with their mip-level count (0x1400eb4fd); file textures stay 1 whatever their mip chain.
    public var mipInfo: Float { gpu != nil ? 1 : Float(texture.mipmapLevelCount) }

    public init(gpu: GPUTexture) {
        texture = gpu.texture
        sampler = gpu.sampler
        resolution = gpu.resolution
        self.gpu = gpu
    }

    public init(texture: MTLTexture, sampler: MTLSamplerState) {
        self.texture = texture
        self.sampler = sampler
        let w = Float(texture.width), h = Float(texture.height)
        resolution = [w, h, w, h]
        gpu = nil
    }

    public init(target: RenderTarget) {
        texture = target.texture
        sampler = target.sampler
        let w = Float(target.texture.width), h = Float(target.texture.height)
        resolution = [w, h, w, h]
        gpu = nil
    }
}

/// Encodes a frame. Mirrors the engine renderer's render-target stack: bind pushes, unbind pops and
/// resumes the previous target, keeping its contents.
public final class RenderContext {
    public let device: MTLDevice
    public let commandBuffer: MTLCommandBuffer
    private var stack: [MTLTexture] = []
    private var encoder: MTLRenderCommandEncoder?
    private var clearPending: [ObjectIdentifier: MTLClearColor] = [:]
    public private(set) var drawCount = 0
    /// Depth buffer of the scene back buffer (perspective scenes). Only draws into the back buffer use it.
    private(set) var backBuffer: MTLTexture
    var depth: MTLTexture?
    /// Back-face culling for back-buffer draws (perspective scenes only, see Draw.swift).
    var applyCulling = ProcessInfo.processInfo.environment["PHOTON_NOCULL"] != "1"
    private var depthClearPending = false
    /// Renderer vt+0xc0 (0x14009afa0): toggles the cull-FRONT bit (R+0x25 bit 0); the volumetrics back pass uses it.
    var cullFront = false
    /// `_rt_shadowAtlas` for this frame (docs/re/06 §6.5b), bound to any material slot that names it.
    var shadowAtlas: BoundTexture?
    /// `_alias_lightCookie` for this frame (docs/re/06 §6.5c), bound to any material slot that names it.
    var lightCookie: BoundTexture?
    /// The engine's error texture (docs/re/03 §1.2), bound to declared slots nothing else filled.
    var errorTexture: BoundTexture?
    /// The scene's persistent built-in state (stale uniforms, frame counter), owned by `SceneRenderer`; nil = zeros.
    public var builtinState: StaleBuiltins?
    /// Renderer colour-write state (vt+0xd8): while a passthrough group draws its children, alpha writes are on for
    /// every draw (`SetColorWrite(1, 1)`, Layer_Render 0x1401e900b). Depth counter.
    var forceAlphaWrite = 0
    /// Renderer alpha-MAX state (vt+0xe8, refcounted in `scene+0x1c9`): on while a passthrough group without
    /// `copybackground` draws its children (0x1401ecd3f–0x1401ecd5f). Depth counter.
    var alphaMaxMode = 0
    /// Depth textures attached to targets other than the back buffer (the volumetrics back-face pass).
    private var attachedDepth: [ObjectIdentifier: MTLTexture] = [:]
    private var attachedDepthClear: Set<ObjectIdentifier> = []

    public init(device: MTLDevice, commandBuffer: MTLCommandBuffer, backBuffer: MTLTexture) {
        self.device = device
        self.commandBuffer = commandBuffer
        self.backBuffer = backBuffer
        stack = [backBuffer]
    }

    /// Depth format of the pass the next draw lands in (pipelines must match it).
    var currentDepthFormat: MTLPixelFormat {
        current === backBuffer ? (depth?.pixelFormat ?? .invalid) : (attachedDepth[ObjectIdentifier(current)]?.pixelFormat ?? .invalid)
    }

    /// Pairs `depthTexture` with the colour target `color` for every later pass on it; `clear` clears it to 0 (far,
    /// reverse-Z) on the next pass.
    func attachDepth(_ depthTexture: MTLTexture, to color: MTLTexture, clear: Bool) {
        endEncoder()
        attachedDepth[ObjectIdentifier(color)] = depthTexture
        if clear { attachedDepthClear.insert(ObjectIdentifier(color)) }
    }

    /// `Clear(depth)` (renderer vt+0x120 → ClearDepthStencilView): the engine renders reverse-Z (projection
    /// 0x14009a360 is PerspectiveFovRH with near/far swapped; depth states compare GREATER, 0x140099096), so 0 is far.
    public func clearDepth() {
        guard depth != nil else { return }
        endEncoder()
        depthClearPending = true
    }

    private static var depthStates: [Int: MTLDepthStencilState] = [:]
    private static let depthLock = NSLock()
    /// Depth-stencil states built at renderer init (0x140099050): +0xc0 test+write, +0xc8 test, +0xd0 off; func GREATER.
    func depthState(test: Bool, write: Bool) -> MTLDepthStencilState {
        let key = (test ? 1 : 0) | (write ? 2 : 0)
        return Self.depthLock.withLock {
            if let s = Self.depthStates[key] { return s }
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = test ? .greater : .always
            d.isDepthWriteEnabled = test && write
            let s = device.makeDepthStencilState(descriptor: d)!
            Self.depthStates[key] = s
            return s
        }
    }

    public var current: MTLTexture { stack.last! }

    /// Swaps the back buffer (and its depth) under any bound targets; Multisample.swift binds the MSAA scene target
    /// this way for the main pass (Scene_DrawObjects 0x140183550).
    func replaceBackBuffer(_ texture: MTLTexture, depth newDepth: MTLTexture?) {
        endEncoder()
        for i in stack.indices where stack[i] === backBuffer { stack[i] = texture }
        backBuffer = texture
        depth = newDepth
    }

    public func bind(_ texture: MTLTexture) {
        endEncoder()
        stack.append(texture)
    }

    public func unbind() {
        endEncoder()
        if stack.count > 1 { stack.removeLast() }
    }

    /// `Clear(color)`: applied as a load action on the next encoder for the current target.
    public func clear(_ color: MTLClearColor) {
        endEncoder()
        clearPending[ObjectIdentifier(current)] = color
        _ = renderEncoder() // make sure the clear happens even if nothing is drawn
    }

    /// Render target vt+8: copy the currently bound target into `dst` (scaled if sizes differ).
    public func copyCurrent(into dst: MTLTexture) {
        endEncoder()
        let src = current
        // Render target vt+8 on a multisampled target is ResolveSubresource (0x1400d3310; Multisample.swift).
        if src.sampleCount > 1 {
            Multisample.resolve(src, into: dst, commandBuffer: commandBuffer, device: device)
            return
        }
        if src.width == dst.width && src.height == dst.height && src.pixelFormat == dst.pixelFormat {
            let blit = commandBuffer.makeBlitCommandEncoder()!
            if src.mipmapLevelCount == dst.mipmapLevelCount {
                blit.copy(from: src, to: dst)
            } else { // level 0 only (mip-mapped snapshot)
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, to: dst, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
            }
            blit.endEncoding()
        } else {
            Blitter.shared(device).draw(src, into: dst, commandBuffer: commandBuffer)
        }
    }

    /// D3D11 occlusion queries map to a Metal visibility result buffer; set it, end the open encoder, draw, end again.
    var visibilityBuffer: MTLBuffer?

    public func renderEncoder() -> MTLRenderCommandEncoder {
        if let e = encoder { return e }
        let target = current
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        if let c = clearPending.removeValue(forKey: ObjectIdentifier(target)) {
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = c
        } else {
            pass.colorAttachments[0].loadAction = .load
        }
        pass.colorAttachments[0].storeAction = .store
        if target === backBuffer, let depth {
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = depthClearPending ? .clear : .load
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            depthClearPending = false
        } else if let d = attachedDepth[ObjectIdentifier(target)] {
            pass.depthAttachment.texture = d
            pass.depthAttachment.loadAction = attachedDepthClear.remove(ObjectIdentifier(target)) != nil ? .clear : .load
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
        }
        // Occlusion queries (Sprite.swift): a visibility buffer attached for the next encoder only.
        if let vb = visibilityBuffer { pass.visibilityResultBuffer = vb }
        let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        e.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder = e
        return e
    }

    public func endEncoder() {
        encoder?.endEncoding()
        encoder = nil
    }

    func countDraw() { drawCount += 1 }
}

/// Fullscreen-triangle copy used when a copy needs scaling or format conversion.
final class Blitter {
    private static var instances: [ObjectIdentifier: Blitter] = [:]
    private static let lock = NSLock()
    static func shared(_ device: MTLDevice) -> Blitter {
        lock.withLock {
            if let b = instances[ObjectIdentifier(device)] { return b }
            let b = Blitter(device: device)
            instances[ObjectIdentifier(device)] = b
            return b
        }
    }

    let device: MTLDevice
    let library: MTLLibrary
    let sampler: MTLSamplerState
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) {
        self.device = device
        library = try! device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V blitV(uint i [[vertex_id]]) {
            float2 uv = float2((i << 1) & 2, i & 2);
            V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o;
        }
        fragment float4 blitF(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
            return t.sample(s, in.uv);
        }
        fragment float4 depthF(V in [[stage_in]], depth2d<float> t [[texture(0)]]) {
            uint2 c = min(uint2(in.p.xy), uint2(t.get_width() - 1, t.get_height() - 1));
            return float4(t.read(c), 0, 0, 1);
        }
        fragment float4 depthMSF(V in [[stage_in]], depth2d_ms<float> t [[texture(0)]]) {
            uint2 c = min(uint2(in.p.xy), uint2(t.get_width() - 1, t.get_height() - 1));
            return float4(t.read(c, 0), 0, 0, 1);
        }
        """, options: nil)
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: d)!
    }

    func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState {
        if let p = pipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "blitV")
        d.fragmentFunction = library.makeFunction(name: "blitF")
        d.colorAttachments[0].pixelFormat = format
        let p = try! device.makeRenderPipelineState(descriptor: d)
        pipelines[format] = p
        return p
    }

    private var depthPipeline: MTLRenderPipelineState?
    private var depthMSPipeline: MTLRenderPipelineState?
    /// Platform difference: D3D11 copies the depth resource itself (render target vt+8, 0x1400d3310 → CopyResource)
    /// into an R32_TYPELESS texture that shaders read as R32F. Metal cannot read a depth texture through the
    /// `texture2d<float>` the translated shaders declare, so the depth is copied texel for texel into an r32Float
    /// target of the same size.
    /// A multisampled depth source (the MSAA scene target's D32) reads sample 0.
    func copyDepth(_ src: MTLTexture, into dst: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let ms = src.sampleCount > 1
        if (ms ? depthMSPipeline : depthPipeline) == nil {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "blitV")
            d.fragmentFunction = library.makeFunction(name: ms ? "depthMSF" : "depthF")
            d.colorAttachments[0].pixelFormat = dst.pixelFormat
            if ms { depthMSPipeline = try? device.makeRenderPipelineState(descriptor: d) } else { depthPipeline = try? device.makeRenderPipelineState(descriptor: d) }
        }
        guard let p = ms ? depthMSPipeline : depthPipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        e.setRenderPipelineState(p)
        e.setFragmentTexture(src, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    func draw(_ src: MTLTexture, into dst: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        e.setRenderPipelineState(pipeline(dst.pixelFormat))
        e.setFragmentTexture(src, index: 0)
        e.setFragmentSamplerState(sampler, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}
