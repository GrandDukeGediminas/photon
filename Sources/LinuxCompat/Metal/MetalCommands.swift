import Foundation
import PhotonGPU

public typealias MTLCommandBufferHandler = (MTLCommandBuffer) -> Void

public protocol MTLCommandQueue: AnyObject {
    var label: String? { get set }
    var device: MTLDevice { get }
    func makeCommandBuffer() -> MTLCommandBuffer?
    func makeCommandBufferWithUnretainedReferences() -> MTLCommandBuffer?
}

public protocol MTLCommandEncoder: AnyObject {
    var label: String? { get set }
    var device: MTLDevice { get }
    func endEncoding()
    func pushDebugGroup(_ string: String)
    func popDebugGroup()
    func insertDebugSignpost(_ string: String)
}

public extension MTLCommandEncoder {
    func pushDebugGroup(_ string: String) {}
    func popDebugGroup() {}
    func insertDebugSignpost(_ string: String) {}
}

public protocol MTLCommandBuffer: AnyObject {
    var label: String? { get set }
    var device: MTLDevice { get }
    var commandQueue: MTLCommandQueue { get }
    var status: MTLCommandBufferStatus { get }
    var error: Error? { get }
    func makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder?
    func makeBlitCommandEncoder() -> MTLBlitCommandEncoder?
    func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler)
    func addScheduledHandler(_ block: @escaping MTLCommandBufferHandler)
    func enqueue()
    func commit()
    func present(_ drawable: MTLDrawable)
    func waitUntilScheduled()
    func waitUntilCompleted()
    /// The PhotonGPU command buffer underneath (Linux-only: hosts present through it).
    var gpuCommandBuffer: GPUCommandBuffer { get }
}

public protocol MTLRenderCommandEncoder: MTLCommandEncoder {
    func setRenderPipelineState(_ pipelineState: MTLRenderPipelineState)
    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setVertexBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setFragmentBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setVertexTexture(_ texture: MTLTexture?, index: Int)
    func setFragmentTexture(_ texture: MTLTexture?, index: Int)
    func setVertexSamplerState(_ sampler: MTLSamplerState?, index: Int)
    func setFragmentSamplerState(_ sampler: MTLSamplerState?, index: Int)
    func setViewport(_ viewport: MTLViewport)
    func setViewports(_ viewports: [MTLViewport])
    func setScissorRect(_ rect: MTLScissorRect)
    func setCullMode(_ cullMode: MTLCullMode)
    func setFrontFacing(_ frontFacingWinding: MTLWinding)
    func setTriangleFillMode(_ fillMode: MTLTriangleFillMode)
    func setDepthStencilState(_ depthStencilState: MTLDepthStencilState?)
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float)
    func setBlendColor(red: Float, green: Float, blue: Float, alpha: Float)
    func setVisibilityResultMode(_ mode: MTLVisibilityResultMode, offset: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int, instanceCount: Int)
}

public protocol MTLBlitCommandEncoder: MTLCommandEncoder {
    func copy(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture)
    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, to destinationTexture: MTLTexture, destinationSlice: Int,
              destinationLevel: Int, sliceCount: Int, levelCount: Int)
    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize,
              to destinationTexture: MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin)
    func copy(from sourceBuffer: MTLBuffer, sourceOffset: Int, to destinationBuffer: MTLBuffer, destinationOffset: Int, size: Int)
    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize,
              to destinationBuffer: MTLBuffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int)
    func generateMipmaps(for texture: MTLTexture)
    func synchronize(resource: MTLResource)
    func fill(buffer: MTLBuffer, range: Range<Int>, value: UInt8)
}

// MARK: - Queue and command buffer

final class MetalCommandQueue: MTLCommandQueue {
    let owner: MetalDevice
    var label: String?
    init(device: MetalDevice) { owner = device }
    var device: MTLDevice { owner }
    func makeCommandBuffer() -> MTLCommandBuffer? {
        do { return MetalCommandBuffer(queue: self, gpu: try owner.gpu.makeCommandBuffer()) } catch {
            NSLog("photon: Metal facade: makeCommandBuffer failed: %@", "\(error)")
            return nil
        }
    }
    func makeCommandBufferWithUnretainedReferences() -> MTLCommandBuffer? { makeCommandBuffer() }
}

final class MetalCommandBuffer: MTLCommandBuffer {
    let queue: MetalCommandQueue
    let gpu: GPUCommandBuffer
    var label: String?
    private(set) var status: MTLCommandBufferStatus = .notEnqueued
    private(set) var error: Error?
    private var completed: [MTLCommandBufferHandler] = []
    private var scheduled: [MTLCommandBufferHandler] = []
    /// Occlusion query sets standing in for visibility result buffers, copied into the buffers on completion.
    var visibility: [(buffer: MTLBuffer, queries: GPUOcclusionQuerySet, written: Set<Int>)] = []
    var encoderOpen = false

    init(queue: MetalCommandQueue, gpu: GPUCommandBuffer) {
        self.queue = queue
        self.gpu = gpu
    }

    var device: MTLDevice { queue.owner }
    var commandQueue: MTLCommandQueue { queue }
    var gpuCommandBuffer: GPUCommandBuffer { gpu }

    func makeRenderCommandEncoder(descriptor d: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder? {
        let ca = d.colorAttachments[0]!
        guard let colorTex = ca.texture as? MetalTexture else {
            NSLog("photon: Metal facade: render pass without a colour attachment is not supported")
            return nil
        }
        do {
            var pass = GPURenderPassDescriptor(color: try colorTex.attachment(level: ca.level))
            switch ca.loadAction {
            case .clear: pass.colorLoad = .clear
            case .load: pass.colorLoad = .load
            case .dontCare: pass.colorLoad = .dontCare
            }
            pass.clearColor = GPUClearColor(red: ca.clearColor.red, green: ca.clearColor.green, blue: ca.clearColor.blue, alpha: ca.clearColor.alpha)
            if ca.storeAction == .storeAndMultisampleResolve || ca.storeAction == .multisampleResolve,
               let r = ca.resolveTexture as? MetalTexture {
                pass.resolve = try r.attachment(level: ca.resolveLevel)
            }
            if let dt = d.depthAttachment.texture as? MetalTexture {
                pass.depth = try dt.attachment(level: d.depthAttachment.level)
                switch d.depthAttachment.loadAction {
                case .clear: pass.depthLoad = .clear
                case .load: pass.depthLoad = .load
                case .dontCare: pass.depthLoad = .dontCare
                }
                pass.clearDepth = d.depthAttachment.clearDepth
            }
            var vis: MTLBuffer?
            if let vb = d.visibilityResultBuffer {
                let q = try queue.owner.gpu.makeOcclusionQuerySet(count: max(vb.length / 8, 1))
                pass.occlusionQueries = q
                visibility.append((vb, q, []))
                vis = vb
            }
            let e = try gpu.beginRenderPass(pass)
            encoderOpen = true
            return MetalRenderEncoder(commandBuffer: self, gpu: e, target: colorTex, visibilitySlot: vis == nil ? nil : visibility.count - 1)
        } catch {
            NSLog("photon: Metal facade: render pass failed: %@", "\(error)")
            return nil
        }
    }

    func makeBlitCommandEncoder() -> MTLBlitCommandEncoder? { MetalBlitEncoder(commandBuffer: self) }

    func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler) {
        if status == .completed { block(self) } else { completed.append(block) }
    }

    func addScheduledHandler(_ block: @escaping MTLCommandBufferHandler) {
        if status.rawValue >= MTLCommandBufferStatus.scheduled.rawValue { block(self) } else { scheduled.append(block) }
    }

    func enqueue() { if status == .notEnqueued { status = .enqueued } }

    /// Submits without waiting (Metal semantics). On completion the occlusion results are copied into the visibility
    /// buffers and the completed handlers run, on the thread that next commits or waits (PhotonVulkan has no callback
    /// thread).
    func commit() {
        guard status.rawValue < MTLCommandBufferStatus.committed.rawValue else { return }
        status = .committed
        let vis = visibility
        visibility.removeAll()
        gpu.addCompletedHandler { [self] in
            for v in vis {
                let results = v.queries.results()
                let p = v.buffer.contents().assumingMemoryBound(to: UInt64.self)
                for i in v.written where i < results.count && (i + 1) * 8 <= v.buffer.length { p[i] = results[i] }
            }
            status = .completed
            let handlers = completed
            completed.removeAll()
            for h in handlers { h(self) }
        }
        gpu.commit()
        if status != .completed { status = .scheduled }
        for h in scheduled { h(self) }
        scheduled.removeAll()
    }

    func waitUntilScheduled() {}
    func waitUntilCompleted() {
        guard status.rawValue >= MTLCommandBufferStatus.committed.rawValue else { return }
        gpu.waitUntilCompleted()
    }
    /// Presented after the buffer completes (hosts present through their own drawables, docs/linux-port.md §6).
    func present(_ drawable: MTLDrawable) { addCompletedHandler { _ in drawable.present() } }
}

// MARK: - Render encoder

final class MetalRenderEncoder: MTLRenderCommandEncoder {
    let commandBuffer: MetalCommandBuffer
    let gpu: GPURenderEncoder
    let target: MetalTexture
    let visibilitySlot: Int?
    var label: String?
    private var activeQuery: Int?
    private var ended = false

    init(commandBuffer: MetalCommandBuffer, gpu: GPURenderEncoder, target: MetalTexture, visibilitySlot: Int?) {
        self.commandBuffer = commandBuffer
        self.gpu = gpu
        self.target = target
        self.visibilitySlot = visibilitySlot
    }

    var device: MTLDevice { commandBuffer.device }

    /// The bound pipeline has a native geometry stage: draws are of the input points (see `drawPrimitives`).
    private var nativeGeometry = false

    func setRenderPipelineState(_ pipelineState: MTLRenderPipelineState) {
        guard let p = pipelineState as? MetalPipeline else { return }
        nativeGeometry = p.nativeGeometry
        gpu.setPipeline(p.gpu)
    }

    private func uniform(_ bytes: UnsafeRawPointer, _ length: Int, _ stage: GPUShaderStage, _ index: Int) {
        if index == MetalFacade.vertexBufferIndex {
            gpu.setVertexBytes(UnsafeRawBufferPointer(start: bytes, count: length))
        } else if index < HLSLRegisterMap.uniformRegisters {
            gpu.setUniformBytes(UnsafeRawBufferPointer(start: bytes, count: length), stage: stage, register: index)
        }
    }

    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { uniform(bytes, length, .vertex, index) }
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { uniform(bytes, length, .fragment, index) }

    private func buffer(_ buffer: MTLBuffer?, _ offset: Int, _ stage: GPUShaderStage, _ index: Int) {
        guard let b = buffer as? MetalBuffer else { return }
        if index == MetalFacade.vertexBufferIndex && stage == .vertex {
            gpu.setVertexBuffer(b.gpu, offset: offset)
        } else if index < HLSLRegisterMap.uniformRegisters {
            // Constant buffers are passed by value; Metal reads them at execution, but photon2 never writes a bound
            // buffer after encoding it.
            let n = min(b.length - offset, 65536)
            guard n > 0 else { return }
            gpu.setUniformBytes(UnsafeRawBufferPointer(start: b.contents() + offset, count: n), stage: stage, register: index)
        }
    }

    func setVertexBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { self.buffer(buffer, offset, .vertex, index) }
    func setFragmentBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { self.buffer(buffer, offset, .fragment, index) }

    func setVertexTexture(_ texture: MTLTexture?, index: Int) { gpu.setTexture((texture as? MetalTexture)?.gpu, slot: index) }
    func setFragmentTexture(_ texture: MTLTexture?, index: Int) { gpu.setTexture((texture as? MetalTexture)?.gpu, slot: index) }
    func setVertexSamplerState(_ sampler: MTLSamplerState?, index: Int) { gpu.setSampler((sampler as? MetalSampler)?.gpu, slot: index) }
    func setFragmentSamplerState(_ sampler: MTLSamplerState?, index: Int) { gpu.setSampler((sampler as? MetalSampler)?.gpu, slot: index) }

    func setViewport(_ viewport: MTLViewport) { gpu.setViewport(viewport.gpu) }
    func setViewports(_ viewports: [MTLViewport]) { gpu.setViewports(viewports.map(\.gpu)) }
    func setScissorRect(_ rect: MTLScissorRect) {}
    func setCullMode(_ cullMode: MTLCullMode) {
        gpu.setCullMode(cullMode == .none ? .none : cullMode == .front ? .front : .back)
    }
    func setFrontFacing(_ frontFacingWinding: MTLWinding) {
        gpu.setFrontFace(frontFacingWinding == .counterClockwise ? .counterClockwise : .clockwise)
    }
    func setTriangleFillMode(_ fillMode: MTLTriangleFillMode) {}
    func setDepthStencilState(_ depthStencilState: MTLDepthStencilState?) {
        gpu.setDepthStencil((depthStencilState as? MetalDepthStencil)?.state ?? GPUDepthStencilDescriptor())
    }
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float) { gpu.setDepthBias(depthBias, slopeScale: slopeScale, clamp: clamp) }
    func setBlendColor(red: Float, green: Float, blue: Float, alpha: Float) {}

    func setVisibilityResultMode(_ mode: MTLVisibilityResultMode, offset: Int) {
        guard let slot = visibilitySlot else { return }
        if let q = activeQuery { gpu.endOcclusionQuery(q); activeQuery = nil }
        guard mode != .disabled else { return }
        let index = offset / 8
        gpu.beginOcclusionQuery(index)
        activeQuery = index
        commandBuffer.visibility[slot].written.insert(index)
    }

    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int) {
        drawPrimitives(type: primitiveType, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: 1)
    }

    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
        guard vertexCount > 0, instanceCount > 0 else { return }
        if nativeGeometry {
            // Draw.swift encodes a GS program's draw for GeometryEmulation: the GS strips as a triangle list, one instance
            // per input point. With the native stage the same points go through the pipeline as a point list.
            gpu.draw(vertexStart: 0, vertexCount: instanceCount, instanceCount: 1)
            return
        }
        gpu.draw(vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: instanceCount)
    }

    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int) {
        drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                              indexBufferOffset: indexBufferOffset, instanceCount: 1)
    }

    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int, instanceCount: Int) {
        guard indexCount > 0, instanceCount > 0 else { return }
        let size = indexType == .uint32 ? 4 : 2
        gpu.drawIndexed(indices: UnsafeRawBufferPointer(start: indexBuffer.contents() + indexBufferOffset, count: indexCount * size),
                        type: indexType == .uint32 ? .uint32 : .uint16, indexCount: indexCount, instanceCount: instanceCount)
    }

    func endEncoding() {
        guard !ended else { return }
        ended = true
        if let q = activeQuery { gpu.endOcclusionQuery(q); activeQuery = nil }
        gpu.end()
        commandBuffer.encoderOpen = false
    }
}

// MARK: - Blit encoder

final class MetalBlitEncoder: MTLBlitCommandEncoder {
    let commandBuffer: MetalCommandBuffer
    var label: String?
    init(commandBuffer: MetalCommandBuffer) { self.commandBuffer = commandBuffer }
    var device: MTLDevice { commandBuffer.device }
    private var gpu: GPUCommandBuffer { commandBuffer.gpu }

    func copy(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture) {
        let n = min(sourceTexture.mipmapLevelCount, destinationTexture.mipmapLevelCount)
        copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0, to: destinationTexture, destinationSlice: 0, destinationLevel: 0,
             sliceCount: 1, levelCount: n)
    }

    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, to destinationTexture: MTLTexture, destinationSlice: Int,
              destinationLevel: Int, sliceCount: Int, levelCount: Int) {
        guard let s = sourceTexture as? MetalTexture, let d = destinationTexture as? MetalTexture else { return }
        for i in 0..<levelCount {
            gpu.copyTexture(s.gpu, level: sourceLevel + i, to: d.gpu, destinationLevel: destinationLevel + i)
        }
    }

    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize,
              to destinationTexture: MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin) {
        guard let s = sourceTexture as? MetalTexture, let d = destinationTexture as? MetalTexture else { return }
        gpu.copyTexture(s.gpu, level: sourceLevel, origin: (sourceOrigin.x, sourceOrigin.y, sourceOrigin.z),
                        size: (sourceSize.width, sourceSize.height, max(sourceSize.depth, 1)), to: d.gpu, destinationLevel: destinationLevel,
                        destinationOrigin: (destinationOrigin.x, destinationOrigin.y, destinationOrigin.z))
    }

    /// Buffers are host memory; photon2 copies only buffers the GPU is not using, so the copy is done when it is encoded.
    func copy(from sourceBuffer: MTLBuffer, sourceOffset: Int, to destinationBuffer: MTLBuffer, destinationOffset: Int, size: Int) {
        memmove(destinationBuffer.contents() + destinationOffset, sourceBuffer.contents() + sourceOffset, size)
    }

    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize,
              to destinationBuffer: MTLBuffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int) {
        guard let s = sourceTexture as? MetalTexture, let b = destinationBuffer as? MetalBuffer else { return }
        gpu.copyTextureToBuffer(s.gpu, level: sourceLevel, origin: (sourceOrigin.x, sourceOrigin.y), size: (sourceSize.width, sourceSize.height),
                                buffer: b.gpu, offset: destinationOffset, bytesPerRow: destinationBytesPerRow)
    }

    func generateMipmaps(for texture: MTLTexture) {
        guard let t = texture as? MetalTexture else { return }
        gpu.generateMipmaps(t.gpu)
    }

    func synchronize(resource: MTLResource) {}

    func fill(buffer: MTLBuffer, range: Range<Int>, value: UInt8) {
        memset(buffer.contents() + range.lowerBound, Int32(value), range.count)
    }

    func endEncoding() {}
}

// MARK: - Drawables

public protocol MTLDrawable: AnyObject {
    func present()
}

/// QuartzCore's drawable, for hosts that present SceneRenderer frames (the X11 host implements one over its window).
public protocol CAMetalDrawable: MTLDrawable {
    var texture: MTLTexture { get }
}
