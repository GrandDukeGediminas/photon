import CVulkan
import Foundation
import PhotonGPU

/// Host-visible upload memory for one submission: uniforms, vertex and index bytes passed by value, and texture upload
/// staging. Chunks are kept when the context is recycled, so a steady frame allocates nothing.
final class UploadRing {
    unowned let device: VulkanDevice
    private var chunks: [VulkanBuffer] = []
    private var current = 0
    private var offset = 0
    static let chunkSize = 4 << 20
    /// Standard-size chunks kept across reuse; larger one-off chunks (big texture uploads) are released.
    static let keptChunks = 4

    init(device: VulkanDevice) { self.device = device }

    func allocate(_ bytes: UnsafeRawBufferPointer, alignment: Int) throws -> (buffer: VulkanBuffer, offset: Int) {
        let size = max(bytes.count, 16)
        var start = (offset + alignment - 1) / alignment * alignment
        while current < chunks.count, start + size > chunks[current].length {
            current += 1
            offset = 0
            start = 0
        }
        if current == chunks.count {
            let usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue
                | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue
            chunks.append(try VulkanBuffer(device: device, length: max(Self.chunkSize, size), usage: usage))
            start = 0
        }
        let chunk = chunks[current]
        if let base = bytes.baseAddress, !bytes.isEmpty { memcpy(chunk.contents + start, base, bytes.count) }
        if size > bytes.count { memset(chunk.contents + start + bytes.count, 0, size - bytes.count) }
        offset = start + size
        return (chunk, start)
    }

    func reset() {
        chunks = Array(chunks.filter { $0.length == Self.chunkSize }.prefix(Self.keptChunks))
        current = 0
        offset = 0
    }
}

/// Descriptor sets for one submission, one per draw (Metal's per-draw setVertexBytes/setFragmentTexture model). The pools
/// are reset, not destroyed, when the context is recycled.
final class DescriptorAllocator {
    unowned let device: VulkanDevice
    let handles: VulkanHandles
    private var pools: [VkDescriptorPool] = []
    private var current = 0

    init(device: VulkanDevice) {
        self.device = device
        handles = device.handles
    }

    deinit { for p in pools { vkDestroyDescriptorPool(handles.device, p, nil) } }

    private func newPool() throws -> VkDescriptorPool {
        let sets: UInt32 = 1024
        var sizes = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: sets * 6),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: sets * UInt32(HLSLRegisterMap.slots)),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: sets * UInt32(HLSLRegisterMap.slots)),
        ]
        var ci = VkDescriptorPoolCreateInfo()
        ci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        ci.maxSets = sets
        ci.poolSizeCount = UInt32(sizes.count)
        var pool: VkDescriptorPool?
        try sizes.withUnsafeMutableBufferPointer { p in
            ci.pPoolSizes = UnsafePointer(p.baseAddress)
            try vkCheck(vkCreateDescriptorPool(device.device, &ci, nil, &pool), "vkCreateDescriptorPool")
        }
        pools.append(pool!)
        return pool!
    }

    func allocate() throws -> VkDescriptorSet {
        while current < pools.count {
            if let s = try? allocate(from: pools[current]) { return s }
            current += 1
        }
        return try allocate(from: newPool())
    }

    func reset() {
        for p in pools { vkResetDescriptorPool(device.device, p, 0) }
        current = 0
    }

    private func allocate(from pool: VkDescriptorPool) throws -> VkDescriptorSet {
        var layout: VkDescriptorSetLayout? = device.descriptorSetLayout
        var ai = VkDescriptorSetAllocateInfo()
        ai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        ai.descriptorPool = pool
        ai.descriptorSetCount = 1
        var set: VkDescriptorSet?
        try withUnsafePointer(to: &layout) { p in
            ai.pSetLayouts = p
            try vkCheck(vkAllocateDescriptorSets(device.device, &ai, &set), "vkAllocateDescriptorSets")
        }
        return set!
    }
}

/// What one submission needs on the device: a command buffer, its fence, upload memory and descriptor pools. Contexts are
/// recycled once their fence has signalled, so frames in flight reuse a small fixed set of them.
final class CommandContext {
    unowned let device: VulkanDevice
    let handles: VulkanHandles
    let pool: VkCommandPool
    let cb: VkCommandBuffer
    let fence: VkFence
    let ring: UploadRing
    let descriptors: DescriptorAllocator

    init(device: VulkanDevice) throws {
        self.device = device
        handles = device.handles
        pool = device.commandPool
        var ai = VkCommandBufferAllocateInfo()
        ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        ai.commandPool = device.commandPool
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        ai.commandBufferCount = 1
        var c: VkCommandBuffer?
        try vkCheck(vkAllocateCommandBuffers(device.device, &ai, &c), "vkAllocateCommandBuffers")
        cb = c!
        var fci = VkFenceCreateInfo()
        fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var f: VkFence?
        try vkCheck(vkCreateFence(device.device, &fci, nil, &f), "vkCreateFence")
        fence = f!
        ring = UploadRing(device: device)
        descriptors = DescriptorAllocator(device: device)
    }

    func reset() {
        ring.reset()
        descriptors.reset()
    }

    deinit {
        vkDestroyFence(handles.device, fence, nil)
        var c: VkCommandBuffer? = cb
        vkFreeCommandBuffers(handles.device, pool, 1, &c)
    }
}

// MARK: - Hazard tracking

/// Pipeline stages and accesses of the two kinds of operation photon2 records.
enum VulkanOp {
    case render, transfer

    var stages: VkPipelineStageFlags {
        switch self {
        case .render: return VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT.rawValue
        case .transfer: return VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue
        }
    }

    var writeAccess: VkAccessFlags {
        switch self {
        case .render: return VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT.rawValue
        case .transfer: return VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        }
    }
}

/// Inserts a barrier only where an operation touches an image an earlier operation of the same command buffer wrote
/// (read-after-write, write-after-write) or read (write-after-read) since the last barrier. Each barrier waits for the
/// stages of the operations recorded since the previous one and makes everything visible to every later graphics and
/// transfer access, so clearing the sets after it is exact. The first operation of a command buffer gets a full barrier
/// (earlier submissions and texture uploads are not tracked). This replaces the two `ALL_COMMANDS` barriers that used to
/// surround every pass and copy; Metal's automatic hazard tracking gives the same ordering.
struct HazardTracker {
    private var written = Set<UInt>()
    private var read = Set<UInt>()
    private var pendingStages: VkPipelineStageFlags = 0
    private var pendingWrites: VkAccessFlags = 0
    private var started = false
    private(set) var barriers = 0

    static func key(_ t: VulkanTexture) -> UInt { UInt(bitPattern: t.image) }

    mutating func prepare(_ cb: VkCommandBuffer, op: VulkanOp, reads: [VulkanTexture], writes: [VulkanTexture]) {
        let r = reads.map(Self.key), w = writes.map(Self.key)
        if !started {
            started = true
            fullBarrier(cb)
            barriers += 1
        } else if r.contains(where: written.contains) || w.contains(where: written.contains) || w.contains(where: read.contains) {
            var mb = VkMemoryBarrier()
            mb.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
            mb.srcAccessMask = pendingWrites
            mb.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
            let dst = VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT.rawValue | VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue
            vkCmdPipelineBarrier(cb, pendingStages, dst, 0, 1, &mb, 0, nil, 0, nil)
            barriers += 1
        } else {
            written.formUnion(w)
            read.formUnion(r)
            pendingStages |= op.stages
            pendingWrites |= op.writeAccess
            return
        }
        written = Set(w)
        read = Set(r)
        pendingStages = op.stages
        pendingWrites = op.writeAccess
    }

    /// Transfer → transfer dependency inside one operation (mip chains: level n is read after level n − 1 is written).
    func transferStep(_ cb: VkCommandBuffer) {
        var mb = VkMemoryBarrier()
        mb.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
        mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        mb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT.rawValue | VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 1, &mb, 0, nil, 0, nil)
    }
}

// MARK: - Command buffer

public final class VulkanCommandBuffer: GPUCommandBuffer {
    let owner: VulkanDevice
    let context: CommandContext
    var cb: VkCommandBuffer { context.cb }
    var ring: UploadRing { context.ring }
    var descriptors: DescriptorAllocator { context.descriptors }
    private var encoderOpen = false
    private var hazards = HazardTracker()
    /// The CPU reads buffers this submission writes (readbacks): end with a device → host barrier.
    private var writesHostBuffers = false
    private var drawable: VulkanDrawable?
    private var presentSource: VulkanTexture?
    /// `present(_:region:to:)`: the source rectangle (nil: the whole texture).
    private var presentRegion: GPUBlitRect?
    private(set) var committed = false
    private let stateLock = NSLock()
    private var completed = false
    private var handlers: [() -> Void] = []
    /// Objects the recorded commands reference; released when the GPU has finished with them.
    var retained: [AnyObject] = []

    init(device: VulkanDevice) throws {
        owner = device
        context = try device.acquireContext()
        var bi = VkCommandBufferBeginInfo()
        bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
        vkBeginCommandBuffer(context.cb, &bi)
    }

    deinit {
        // Committed buffers are released by the device after completion; one that was never committed hands its context back.
        if !committed {
            vkEndCommandBuffer(context.cb)
            owner.recycle(context)
        }
    }

    func texture(_ t: GPUTextureResource) -> VulkanTexture {
        guard let v = t as? VulkanTexture else { fatalError("texture from another backend") }
        retained.append(v)
        return v
    }

    func prepare(_ op: VulkanOp, reads: [VulkanTexture], writes: [VulkanTexture]) {
        hazards.prepare(cb, op: op, reads: reads, writes: writes)
    }

    /// Barriers recorded so far (diagnostics: `PHOTON_VK_STATS`).
    var barrierCount: Int { hazards.barriers }

    public func beginRenderPass(_ d: GPURenderPassDescriptor) throws -> GPURenderEncoder {
        precondition(!encoderOpen, "one encoder at a time")
        let color = texture(d.color)
        let depth = d.depth.map(texture)
        let resolve = d.resolve.map(texture)
        let queries = d.occlusionQueries as? VulkanQuerySet
        if let q = queries { retained.append(q) }
        encoderOpen = true
        return VulkanRenderEncoder(commandBuffer: self, pass: d, color: color, depth: depth, resolve: resolve, queries: queries)
    }

    /// Records a finished render pass: the barrier its attachments and sampled textures need, then the pass itself. The
    /// encoder buffers its commands until `end()` because the textures a pass samples are only known once it is encoded,
    /// and Vulkan allows no barriers for them inside the pass.
    func recordPass(_ e: VulkanRenderEncoder) {
        let d = e.pass
        if let q = e.queries { vkCmdResetQueryPool(cb, q.pool, 0, UInt32(q.count)) }
        prepare(.render, reads: Array(e.sampled.values), writes: [e.color] + (e.depth.map { [$0] } ?? []) + (e.resolve.map { [$0] } ?? []))
        func load(_ a: GPULoadAction) -> VkAttachmentLoadOp {
            a == .clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : (a == .load ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_DONT_CARE)
        }
        var ca = VkRenderingAttachmentInfo()
        ca.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
        ca.imageView = e.color.view
        ca.imageLayout = VK_IMAGE_LAYOUT_GENERAL
        ca.loadOp = load(d.colorLoad)
        ca.storeOp = VK_ATTACHMENT_STORE_OP_STORE
        ca.clearValue.color.float32 = (Float(d.clearColor.red), Float(d.clearColor.green), Float(d.clearColor.blue), Float(d.clearColor.alpha))
        if let r = e.resolve {
            ca.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT
            ca.resolveImageView = r.view
            ca.resolveImageLayout = VK_IMAGE_LAYOUT_GENERAL
        }
        var da = VkRenderingAttachmentInfo()
        da.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
        if let dt = e.depth {
            da.imageView = dt.view
            da.imageLayout = VK_IMAGE_LAYOUT_GENERAL
            da.loadOp = load(d.depthLoad)
            da.storeOp = VK_ATTACHMENT_STORE_OP_STORE
            da.clearValue.depthStencil = VkClearDepthStencilValue(depth: Float(d.clearDepth), stencil: 0)
        }
        var ri = VkRenderingInfo()
        ri.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
        ri.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(e.color.width), height: UInt32(e.color.height)))
        ri.layerCount = 1
        ri.colorAttachmentCount = 1
        withUnsafePointer(to: &ca) { cap in
            withUnsafePointer(to: &da) { dap in
                ri.pColorAttachments = cap
                ri.pDepthAttachment = e.depth != nil ? dap : nil
                ri.pStencilAttachment = e.depth?.format == .depth24Stencil8 ? dap : nil
                vkCmdBeginRendering(cb, &ri)
            }
        }
        e.replay(cb)
        vkCmdEndRendering(cb)
        encoderOpen = false
    }

    public func copyTexture(_ source: GPUTextureResource, level: Int, to destination: GPUTextureResource, destinationLevel: Int) {
        let w = max(1, source.width >> level), h = max(1, source.height >> level)
        let d = source.descriptor.type == .type3D ? max(1, source.descriptor.depth >> level) : 1
        copyTexture(source, level: level, origin: (0, 0, 0), size: (w, h, d), to: destination, destinationLevel: destinationLevel,
                    destinationOrigin: (0, 0, 0))
    }

    public func copyTexture(_ source: GPUTextureResource, level: Int, origin: (x: Int, y: Int, z: Int), size: (width: Int, height: Int, depth: Int),
                            to destination: GPUTextureResource, destinationLevel: Int, destinationOrigin: (x: Int, y: Int, z: Int)) {
        let s = texture(source), d = texture(destination)
        var region = VkImageCopy()
        region.srcSubresource = VkImageSubresourceLayers(aspectMask: s.format.aspect, mipLevel: UInt32(s.baseLevel + level), baseArrayLayer: 0, layerCount: 1)
        region.dstSubresource = VkImageSubresourceLayers(aspectMask: d.format.aspect, mipLevel: UInt32(d.baseLevel + destinationLevel),
                                                         baseArrayLayer: 0, layerCount: 1)
        region.srcOffset = VkOffset3D(x: Int32(origin.x), y: Int32(origin.y), z: Int32(origin.z))
        region.dstOffset = VkOffset3D(x: Int32(destinationOrigin.x), y: Int32(destinationOrigin.y), z: Int32(destinationOrigin.z))
        region.extent = VkExtent3D(width: UInt32(size.width), height: UInt32(size.height), depth: UInt32(max(size.depth, 1)))
        prepare(.transfer, reads: [s], writes: [d])
        vkCmdCopyImage(cb, s.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
    }

    public func resolve(_ source: GPUTextureResource, into destination: GPUTextureResource) {
        let s = texture(source), d = texture(destination)
        var region = VkImageResolve()
        region.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(s.baseLevel), baseArrayLayer: 0, layerCount: 1)
        region.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(d.baseLevel), baseArrayLayer: 0, layerCount: 1)
        region.extent = VkExtent3D(width: UInt32(s.width), height: UInt32(s.height), depth: 1)
        prepare(.transfer, reads: [s], writes: [d])
        vkCmdResolveImage(cb, s.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
    }

    public func generateMipmaps(_ t: GPUTextureResource) {
        let tex = texture(t)
        guard tex.descriptor.mipLevels > 1 else { return }
        prepare(.transfer, reads: [tex], writes: [tex])
        var w = Int32(tex.width), h = Int32(tex.height)
        for level in 1..<tex.descriptor.mipLevels {
            let nw = max(1, w / 2), nh = max(1, h / 2)
            var blit = VkImageBlit()
            blit.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(tex.baseLevel + level - 1), baseArrayLayer: 0, layerCount: 1)
            blit.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(tex.baseLevel + level), baseArrayLayer: 0, layerCount: 1)
            blit.srcOffsets = (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: w, y: h, z: 1))
            blit.dstOffsets = (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: nw, y: nh, z: 1))
            if level > 1 { hazards.transferStep(cb) }
            vkCmdBlitImage(cb, tex.image, VK_IMAGE_LAYOUT_GENERAL, tex.image, VK_IMAGE_LAYOUT_GENERAL, 1, &blit, VK_FILTER_LINEAR)
            w = nw; h = nh
        }
    }

    public func copyTextureToBuffer(_ t: GPUTextureResource, level: Int, buffer: GPUBuffer) {
        let tex = texture(t)
        guard let b = buffer as? VulkanBuffer else { fatalError("buffer from another backend") }
        retained.append(b)
        var region = VkBufferImageCopy()
        region.imageSubresource = VkImageSubresourceLayers(aspectMask: tex.format.aspect, mipLevel: UInt32(tex.baseLevel + level), baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: UInt32(max(1, tex.width >> level)), height: UInt32(max(1, tex.height >> level)), depth: 1)
        prepare(.transfer, reads: [tex], writes: [])
        vkCmdCopyImageToBuffer(cb, tex.image, VK_IMAGE_LAYOUT_GENERAL, b.buffer, 1, &region)
        writesHostBuffers = true
    }

    public func copyTextureToBuffer(_ t: GPUTextureResource, level: Int, origin: (x: Int, y: Int), size: (width: Int, height: Int),
                                    buffer: GPUBuffer, offset: Int, bytesPerRow: Int) {
        let tex = texture(t)
        guard let b = buffer as? VulkanBuffer else { fatalError("buffer from another backend") }
        retained.append(b)
        var region = VkBufferImageCopy()
        region.bufferOffset = VkDeviceSize(offset)
        region.bufferRowLength = UInt32(bytesPerRow / tex.format.block.bytes * tex.format.block.size)
        region.imageSubresource = VkImageSubresourceLayers(aspectMask: tex.format.aspect, mipLevel: UInt32(tex.baseLevel + level), baseArrayLayer: 0, layerCount: 1)
        region.imageOffset = VkOffset3D(x: Int32(origin.x), y: Int32(origin.y), z: 0)
        region.imageExtent = VkExtent3D(width: UInt32(size.width), height: UInt32(size.height), depth: 1)
        prepare(.transfer, reads: [tex], writes: [])
        vkCmdCopyImageToBuffer(cb, tex.image, VK_IMAGE_LAYOUT_GENERAL, b.buffer, 1, &region)
        writesHostBuffers = true
    }

    /// Texture upload / readback recorded by `VulkanTexture` into its own submission.
    func recordTransfer(_ body: (VkCommandBuffer) -> Void, hostReads: Bool) {
        fullBarrier(cb)
        body(cb)
        writesHostBuffers = writesHostBuffers || hostReads
    }

    public func present(_ texture: GPUTextureResource, to drawable: GPUDrawable) {
        guard let d = drawable as? VulkanDrawable else { fatalError("drawable from another backend") }
        precondition(self.drawable == nil, "one present per command buffer")
        self.drawable = d
        presentSource = self.texture(texture)
        retained.append(d)
    }

    public func present(_ texture: GPUTextureResource, region: GPUBlitRect, to drawable: GPUDrawable) {
        present(texture, to: drawable)
        presentRegion = region == GPUBlitRect(width: texture.width, height: texture.height) ? nil : region
    }

    public func blit(_ source: GPUTextureResource, from: GPUBlitRect, to destination: GPUTextureResource, at: GPUBlitRect) {
        let s = texture(source), d = texture(destination)
        var blit = VkImageBlit()
        blit.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(s.baseLevel), baseArrayLayer: 0, layerCount: 1)
        blit.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(d.baseLevel), baseArrayLayer: 0, layerCount: 1)
        blit.srcOffsets = (VkOffset3D(x: Int32(from.x0), y: Int32(from.y0), z: 0), VkOffset3D(x: Int32(from.x1), y: Int32(from.y1), z: 1))
        blit.dstOffsets = (VkOffset3D(x: Int32(at.x0), y: Int32(at.y0), z: 0), VkOffset3D(x: Int32(at.x1), y: Int32(at.y1), z: 1))
        prepare(.transfer, reads: [s], writes: [d])
        let same = from.width == at.width && from.height == at.height
        vkCmdBlitImage(cb, s.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_GENERAL, 1, &blit, same ? VK_FILTER_NEAREST : VK_FILTER_LINEAR)
    }

    /// The copy of the presented texture into the swapchain image, with the layout transitions WSI images need
    /// (photon2's own images stay in GENERAL).
    private func recordPresentCopy(_ src: VulkanTexture, _ d: VulkanDrawable) {
        prepare(.transfer, reads: [src], writes: [])
        let range = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
        var toDst = VkImageMemoryBarrier()
        toDst.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        toDst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED
        toDst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        toDst.srcQueueFamilyIndex = UInt32.max
        toDst.dstQueueFamilyIndex = UInt32.max
        toDst.image = d.image
        toDst.subresourceRange = range
        toDst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        // Source stage = the stage the acquire semaphore is waited at, so the transition follows the acquire.
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 0, nil, 0, nil, 1, &toDst)
        let sameSize = src.width == d.width && src.height == d.height
        if let r = presentRegion {
            // A region of the source (stretch / clone layouts): scaled or mirrored onto the whole image.
            var blit = VkImageBlit()
            blit.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(src.baseLevel), baseArrayLayer: 0, layerCount: 1)
            blit.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            blit.srcOffsets = (VkOffset3D(x: Int32(r.x0), y: Int32(r.y0), z: 0), VkOffset3D(x: Int32(r.x1), y: Int32(r.y1), z: 1))
            blit.dstOffsets = (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: Int32(d.width), y: Int32(d.height), z: 1))
            let same = r.width == d.width && r.height == d.height
            vkCmdBlitImage(cb, src.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                           same ? VK_FILTER_NEAREST : VK_FILTER_LINEAR)
        } else if sameSize && src.format.vk == d.format {
            var region = VkImageCopy()
            region.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(src.baseLevel), baseArrayLayer: 0, layerCount: 1)
            region.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            region.extent = VkExtent3D(width: UInt32(d.width), height: UInt32(d.height), depth: 1)
            vkCmdCopyImage(cb, src.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        } else {
            // Other swapchain format or size (a window resized under the renderer): blit, which converts and scales.
            var blit = VkImageBlit()
            blit.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: UInt32(src.baseLevel), baseArrayLayer: 0, layerCount: 1)
            blit.dstSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            blit.srcOffsets = (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: Int32(src.width), y: Int32(src.height), z: 1))
            blit.dstOffsets = (VkOffset3D(x: 0, y: 0, z: 0), VkOffset3D(x: Int32(d.width), y: Int32(d.height), z: 1))
            vkCmdBlitImage(cb, src.image, VK_IMAGE_LAYOUT_GENERAL, d.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                           sameSize ? VK_FILTER_NEAREST : VK_FILTER_LINEAR)
        }
        var toPresent = toDst
        toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
        toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        toPresent.dstAccessMask = 0
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT.rawValue, 0, 0, nil, 0, nil, 1, &toPresent)
    }

    public func commit() {
        precondition(!encoderOpen, "end the encoder before commit")
        guard !committed else { return }
        if let d = drawable, let src = presentSource { recordPresentCopy(src, d) }
        if writesHostBuffers {
            var mb = VkMemoryBarrier()
            mb.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
            mb.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
            mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT.rawValue
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_HOST_BIT.rawValue, 0, 1, &mb, 0, nil, 0, nil)
        }
        vkEndCommandBuffer(cb)
        committed = true
        owner.submit(self, drawable: drawable)
    }

    public func waitUntilCompleted() {
        guard committed else { return }
        var f: VkFence? = context.fence
        while !isCompleted {
            let r = vkWaitForFences(owner.device, 1, &f, 1, 1_000_000_000)
            if r == VK_SUCCESS {
                owner.poll()
            } else if r != VK_TIMEOUT {
                NSLog("photon: vkWaitForFences failed: %d", r.rawValue) // device lost: do not hang
                return
            }
        }
    }

    public func addCompletedHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        if completed {
            stateLock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        stateLock.unlock()
    }

    public var isCompleted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completed
    }

    /// Called by the device once the fence has signalled: completed handlers, then the references and the context go.
    func finish() {
        stateLock.lock()
        completed = true
        let hs = handlers
        handlers.removeAll()
        stateLock.unlock()
        for h in hs { h() }
        retained.removeAll()
        drawable = nil
        presentSource = nil
        owner.recycle(context)
    }
}

// MARK: - Render encoder

/// One recorded command of a render pass, replayed into the command buffer when the pass ends.
enum RenderCommand {
    case pipeline(VkPipeline)
    case viewports([VkViewport], [VkRect2D])
    case cull(VkCullModeFlags)
    case frontFace(VkFrontFace)
    case depth(test: Bool, write: Bool, compare: VkCompareOp)
    case depthBias(enabled: Bool, constant: Float, clamp: Float, slope: Float)
    case descriptors(VkDescriptorSet)
    case vertexBuffer(VkBuffer, VkDeviceSize)
    case draw(vertexCount: UInt32, instanceCount: UInt32, firstVertex: UInt32)
    case drawIndexed(VkBuffer, VkDeviceSize, VkIndexType, indexCount: UInt32, instanceCount: UInt32)
    case beginQuery(VkQueryPool, UInt32, VkQueryControlFlags)
    case endQuery(VkQueryPool, UInt32)
}

final class VulkanRenderEncoder: GPURenderEncoder {
    let owner: VulkanCommandBuffer
    let pass: GPURenderPassDescriptor
    let color: VulkanTexture
    let depth: VulkanTexture?
    let resolve: VulkanTexture?
    let queries: VulkanQuerySet?
    /// Every texture a draw of this pass bound (the pass's reads, for the barrier before it).
    private(set) var sampled: [UInt: VulkanTexture] = [:]
    private var commands: [RenderCommand] = []
    private var pipeline: VulkanPipeline?
    private var uniforms: [GPUShaderStage: [Int: (VulkanBuffer, Int, Int)]] = [:]
    private var textures: [Int: VulkanTexture] = [:]
    private var samplers: [Int: VulkanSampler] = [:]
    private var vertex: (VulkanBuffer, Int)?
    private var boundVertex: (VkBuffer, Int)?

    init(commandBuffer: VulkanCommandBuffer, pass: GPURenderPassDescriptor, color: VulkanTexture, depth: VulkanTexture?,
         resolve: VulkanTexture?, queries: VulkanQuerySet?) {
        owner = commandBuffer
        self.pass = pass
        self.color = color
        self.depth = depth
        self.resolve = resolve
        self.queries = queries
        commands.reserveCapacity(64)
        resetState()
    }

    /// Metal render-encoder defaults: full-target viewport, no culling, no depth test, no bias.
    func resetState() {
        setViewport(GPUViewport(width: Double(color.width), height: Double(color.height)))
        setCullMode(.none)
        setFrontFace(D3D11Conventions.frontFace)
        setDepthStencil(GPUDepthStencilDescriptor())
        setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    func setPipeline(_ p: GPURenderPipeline) {
        guard let vp = p as? VulkanPipeline else { fatalError("pipeline from another backend") }
        owner.retained.append(vp)
        pipeline = vp
        commands.append(.pipeline(vp.pipeline))
    }

    /// D3D11/Metal viewports put NDC +y at the top row; Vulkan puts −y there. A negative-height viewport (core since
    /// 1.1) flips it, so the same clip-space positions, UVs and winding land on the same pixels as on D3D11.
    static func vkViewport(_ v: GPUViewport) -> VkViewport {
        VkViewport(x: Float(v.x), y: Float(v.y + v.height), width: Float(v.width), height: Float(-v.height),
                   minDepth: Float(v.minDepth), maxDepth: Float(v.maxDepth))
    }

    func setViewport(_ v: GPUViewport) { setViewports([v]) }

    /// Pipelines use VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT / SCISSOR_WITH_COUNT (core 1.3), so the count is per draw like
    /// D3D11 RSSetViewports. Scissors stay the whole target (D3D11 ScissorEnable = FALSE).
    func setViewports(_ list: [GPUViewport]) {
        guard !list.isEmpty else { return }
        let n = owner.owner.capabilities.multiViewport ? list.count : 1
        let vps = list.prefix(n).map(Self.vkViewport)
        let scissors = [VkRect2D](repeating: VkRect2D(offset: VkOffset2D(x: 0, y: 0),
                                                       extent: VkExtent2D(width: UInt32(color.width), height: UInt32(color.height))), count: n)
        commands.append(.viewports(vps, scissors))
    }

    func setCullMode(_ mode: GPUCullMode) {
        let m: VkCullModeFlagBits = mode == .none ? VK_CULL_MODE_NONE : (mode == .front ? VK_CULL_MODE_FRONT_BIT : VK_CULL_MODE_BACK_BIT)
        commands.append(.cull(m.rawValue))
    }

    func setFrontFace(_ w: GPUWinding) {
        commands.append(.frontFace(w == .counterClockwise ? VK_FRONT_FACE_COUNTER_CLOCKWISE : VK_FRONT_FACE_CLOCKWISE))
    }

    func setDepthStencil(_ s: GPUDepthStencilDescriptor) {
        commands.append(.depth(test: s.compare != .always || s.write, write: s.write, compare: s.compare.vk))
    }

    func setDepthBias(_ bias: Float, slopeScale: Float, clamp: Float) {
        commands.append(.depthBias(enabled: bias != 0 || slopeScale != 0, constant: bias, clamp: clamp, slope: slopeScale))
    }

    func setUniformBytes(_ bytes: UnsafeRawBufferPointer, stage: GPUShaderStage, register: Int) {
        guard let (b, off) = try? owner.ring.allocate(bytes, alignment: owner.owner.uniformAlignment) else { return }
        uniforms[stage, default: [:]][register] = (b, off, max(bytes.count, 16))
    }

    func setTexture(_ t: GPUTextureResource?, slot: Int) { textures[slot] = t.map(owner.texture) }

    func setSampler(_ s: GPUSampler?, slot: Int) {
        guard let s else { samplers[slot] = nil; return }
        guard let vs = s as? VulkanSampler else { fatalError("sampler from another backend") }
        owner.retained.append(vs)
        samplers[slot] = vs
    }

    func setVertexBytes(_ bytes: UnsafeRawBufferPointer) {
        vertex = try? owner.ring.allocate(bytes, alignment: 16)
    }

    func setVertexBuffer(_ buffer: GPUBuffer, offset: Int) {
        guard let b = buffer as? VulkanBuffer else { fatalError("buffer from another backend") }
        owner.retained.append(b)
        vertex = (b, offset)
    }

    /// Writes this draw's descriptor set: every register/slot the pipeline's SPIR-V declares, unfilled ones getting the
    /// D3D11 NULL-binding equivalents (zero cbuffer, zero texture, default sampler).
    private func flush() throws {
        guard let p = pipeline else { throw GPUError.failed("draw without pipeline") }
        let dev = owner.owner
        let set = try owner.descriptors.allocate()
        var bufferInfos: [VkDescriptorBufferInfo] = [], imageInfos: [VkDescriptorImageInfo] = [], samplerInfos: [VkDescriptorImageInfo] = []
        bufferInfos.reserveCapacity(p.uniformRegisters.count)
        imageInfos.reserveCapacity(p.textureSlots.count)
        samplerInfos.reserveCapacity(p.samplerSlots.count + 1)
        var targets: [(binding: Int, kind: Int, index: Int)] = []
        for (stage, reg) in p.uniformRegisters {
            // Geometry-stage registers fall back to the vertex stage's bytes (see GPURenderEncoder.setUniformBytes).
            if let (b, off, size) = uniforms[stage]?[reg] ?? (stage == .geometry ? uniforms[.vertex]?[reg] : nil) {
                bufferInfos.append(VkDescriptorBufferInfo(buffer: b.buffer, offset: VkDeviceSize(off), range: VkDeviceSize(size)))
            } else {
                bufferInfos.append(VkDescriptorBufferInfo(buffer: dev.zeroBuffer.buffer, offset: 0, range: VkDeviceSize(dev.zeroBuffer.length)))
            }
            targets.append((HLSLRegisterMap.uniformBase(stage) + reg, 0, bufferInfos.count - 1))
        }
        for slot in p.textureSlots {
            let t = textures[slot] ?? dev.nullTexture!
            if textures[slot] != nil { sampled[HazardTracker.key(t)] = t }
            imageInfos.append(VkDescriptorImageInfo(sampler: nil, imageView: t.view, imageLayout: VK_IMAGE_LAYOUT_GENERAL))
            targets.append((HLSLRegisterMap.textureBase + slot, 1, imageInfos.count - 1))
        }
        for slot in p.samplerSlots {
            let s = samplers[slot] ?? dev.defaultSampler!
            samplerInfos.append(VkDescriptorImageInfo(sampler: s.sampler, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED))
            targets.append((HLSLRegisterMap.samplerBase + slot, 2, samplerInfos.count - 1))
        }
        if dev.writesAllSamplers, p.samplerSlots.count < HLSLRegisterMap.slots {
            // Lavapipe before Mesa 23.2 reads every sampler binding of the layout (VulkanDevice.writesAllSamplers).
            samplerInfos.append(VkDescriptorImageInfo(sampler: dev.defaultSampler!.sampler, imageView: nil, imageLayout: VK_IMAGE_LAYOUT_UNDEFINED))
            for slot in 0..<HLSLRegisterMap.slots where !p.samplerSlots.contains(slot) {
                targets.append((HLSLRegisterMap.samplerBase + slot, 2, samplerInfos.count - 1))
            }
        }
        bufferInfos.withUnsafeBufferPointer { bp in
            imageInfos.withUnsafeBufferPointer { ip in
                samplerInfos.withUnsafeBufferPointer { sp in
                    var writes: [VkWriteDescriptorSet] = targets.map { t in
                        var w = VkWriteDescriptorSet()
                        w.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                        w.dstSet = set
                        w.dstBinding = UInt32(t.binding)
                        w.descriptorCount = 1
                        switch t.kind {
                        case 0: w.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; w.pBufferInfo = bp.baseAddress! + t.index
                        case 1: w.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE; w.pImageInfo = ip.baseAddress! + t.index
                        default: w.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER; w.pImageInfo = sp.baseAddress! + t.index
                        }
                        return w
                    }
                    vkUpdateDescriptorSets(dev.device, UInt32(writes.count), &writes, 0, nil)
                }
            }
        }
        commands.append(.descriptors(set))
        if let (b, off) = vertex, boundVertex.map({ $0.0 != b.buffer || $0.1 != off }) ?? true {
            commands.append(.vertexBuffer(b.buffer, VkDeviceSize(off)))
            boundVertex = (b.buffer, off)
        }
    }

    func draw(vertexStart: Int, vertexCount: Int, instanceCount: Int) {
        do { try flush() } catch { NSLog("photon: %@", "\(error)"); return }
        commands.append(.draw(vertexCount: UInt32(vertexCount), instanceCount: UInt32(max(instanceCount, 1)), firstVertex: UInt32(vertexStart)))
    }

    func drawIndexed(indices: UnsafeRawBufferPointer, type: GPUIndexType, indexCount: Int, instanceCount: Int) {
        do { try flush() } catch { NSLog("photon: %@", "\(error)"); return }
        guard let (b, off) = try? owner.ring.allocate(indices, alignment: 16) else { return }
        commands.append(.drawIndexed(b.buffer, VkDeviceSize(off), type == .uint32 ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16,
                                     indexCount: UInt32(indexCount), instanceCount: UInt32(max(instanceCount, 1))))
    }

    func beginOcclusionQuery(_ index: Int) {
        guard let q = queries else { return }
        commands.append(.beginQuery(q.pool, UInt32(index), owner.owner.preciseOcclusion ? VK_QUERY_CONTROL_PRECISE_BIT.rawValue : 0))
    }

    func endOcclusionQuery(_ index: Int) {
        guard let q = queries else { return }
        commands.append(.endQuery(q.pool, UInt32(index)))
    }

    func end() { owner.recordPass(self) }

    func replay(_ cb: VkCommandBuffer) {
        for c in commands {
            switch c {
            case .pipeline(let p): vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, p)
            case .viewports(var v, var s):
                vkCmdSetViewportWithCount(cb, UInt32(v.count), &v)
                vkCmdSetScissorWithCount(cb, UInt32(s.count), &s)
            case .cull(let m): vkCmdSetCullMode(cb, m)
            case .frontFace(let f): vkCmdSetFrontFace(cb, f)
            case .depth(let test, let write, let compare):
                vkCmdSetDepthTestEnable(cb, test ? 1 : 0)
                vkCmdSetDepthWriteEnable(cb, write ? 1 : 0)
                vkCmdSetDepthCompareOp(cb, compare)
            case .depthBias(let on, let constant, let clamp, let slope):
                vkCmdSetDepthBiasEnable(cb, on ? 1 : 0)
                vkCmdSetDepthBias(cb, constant, clamp, slope)
            case .descriptors(let set):
                var s: VkDescriptorSet? = set
                vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, owner.owner.pipelineLayout, 0, 1, &s, 0, nil)
            case .vertexBuffer(let b, let off):
                var buf: VkBuffer? = b
                var o = off
                vkCmdBindVertexBuffers(cb, 0, 1, &buf, &o)
            case .draw(let n, let instances, let first):
                vkCmdDraw(cb, n, instances, first, 0)
            case .drawIndexed(let b, let off, let type, let n, let instances):
                vkCmdBindIndexBuffer(cb, b, off, type)
                vkCmdDrawIndexed(cb, n, instances, 0, 0, 0)
            case .beginQuery(let pool, let i, let flags): vkCmdBeginQuery(cb, pool, i, flags)
            case .endQuery(let pool, let i): vkCmdEndQuery(cb, pool, i)
            }
        }
        commands.removeAll()
    }
}
