import CVulkan
import Foundation
import PhotonGPU

/// Owns the VkInstance/VkDevice lifetime. Every resource keeps a strong reference, so the device is destroyed only
/// after the last image, buffer or pipeline made from it.
final class VulkanHandles {
    let instance: VkInstance
    var device: VkDevice!
    var destroyers: [() -> Void] = []
    init(instance: VkInstance) { self.instance = instance }
    deinit {
        if let device {
            vkDeviceWaitIdle(device)
            for d in destroyers.reversed() { d() }
            vkDestroyDevice(device, nil)
        }
        vkDestroyInstance(instance, nil)
    }
}

/// The Vulkan implementation of `GPUDevice`. Needs Vulkan 1.3 (dynamic rendering, extended dynamic state); headless
/// (no surface) unless a host adds one. Lavapipe in CI, any desktop driver at runtime, MoltenVK on macOS for testing.
public final class VulkanDevice: GPUDevice {
    let handles: VulkanHandles
    public var instance: VkInstance { handles.instance }
    public let physicalDevice: VkPhysicalDevice
    public let device: VkDevice
    public let queue: VkQueue
    public let queueFamily: UInt32
    public private(set) var capabilities = GPUCapabilities()
    let commandPool: VkCommandPool
    let descriptorSetLayout: VkDescriptorSetLayout
    let pipelineLayout: VkPipelineLayout
    let memoryProperties: VkPhysicalDeviceMemoryProperties
    let uniformAlignment: Int
    private(set) var maxAnisotropy: Float
    let preciseOcclusion: Bool
    /// Bound for declared slots nothing filled: a D3D11 NULL SRV samples (0, 0, 0, 0); a NULL cbuffer reads zeros.
    private(set) var nullTexture: VulkanTexture!
    private(set) var defaultSampler: VulkanSampler!
    private(set) var zeroBuffer: VulkanBuffer!
    /// VK_KHR_xlib_surface + VK_KHR_swapchain are enabled: `VulkanSwapchain` can present to an X11 window.
    public let supportsXlibPresentation: Bool
    /// VK_KHR_wayland_surface + VK_KHR_swapchain are enabled: `VulkanSwapchain` can present to a wl_surface.
    public let supportsWaylandPresentation: Bool
    /// VK_EXT_memory_budget is enabled: `memoryBudget()` reports this process's device-local usage and budget.
    public let supportsMemoryBudget: Bool
    /// Every sampler binding of the shared set layout gets a descriptor, not only the slots the pipeline declares.
    /// Lavapipe before Mesa 23.2 copies the sampler of every binding in the layout at bind time
    /// (lvp_execute.c fill_sampler_stage: `state->ss[...] = *descriptor->sampler`) and segfaults on one that was never
    /// written, which Vulkan allows for bindings the pipeline does not use. Debian 12 ships Mesa 22.3. The extra
    /// descriptors are never sampled, so the output is the same; other drivers skip the writes.
    /// PHOTON_VK_WRITE_ALL_SAMPLERS=1|0 forces it on or off.
    public let writesAllSamplers: Bool
    /// The driver as VkPhysicalDeviceDriverProperties names it, e.g. "llvmpipe / Mesa 22.3.6".
    public let driverDescription: String
    /// vkQueueSubmit / vkQueuePresentKHR need external synchronisation.
    let queueLock = NSLock()
    /// Submissions the GPU has not been seen to finish, in submission order, and the contexts ready for reuse.
    private let trackLock = NSLock()
    private var inFlight: [VulkanCommandBuffer] = []
    private var freeContexts: [CommandContext] = []
    /// Metal's default `maxCommandBufferCount`: committing more than this many unfinished buffers waits for the oldest.
    static let maxInFlight = 64
    /// PHOTON_VK_STATS=1: submissions and barriers per command buffer on stderr.
    static let stats = ProcessInfo.processInfo.environment["PHOTON_VK_STATS"] == "1"

    public convenience init() throws { try self.init(preferredDevice: ProcessInfo.processInfo.environment["PHOTON_VK_DEVICE"]) }

    public init(preferredDevice: String?) throws {
        let arena = Arena()
        // Instance
        var extCount: UInt32 = 0
        vkEnumerateInstanceExtensionProperties(nil, &extCount, nil)
        var exts = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(extCount))
        vkEnumerateInstanceExtensionProperties(nil, &extCount, &exts)
        let available = Set(exts.map { cString($0.extensionName) })
        var instanceExts: [String] = []
        var flags: VkInstanceCreateFlags = 0
        if available.contains("VK_KHR_portability_enumeration") { // MoltenVK
            instanceExts.append("VK_KHR_portability_enumeration")
            flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR.rawValue
        }
        // Window-system integration for hosts that present (X11 desktop host): surface + Xlib surface when the loader has
        // them. PHOTON_VK_WSI=0 leaves them off (pure headless).
        let wantWSI = ProcessInfo.processInfo.environment["PHOTON_VK_WSI"] != "0"
        let xlibSurface = wantWSI && available.contains("VK_KHR_surface") && available.contains("VK_KHR_xlib_surface")
        if xlibSurface { instanceExts += ["VK_KHR_surface", "VK_KHR_xlib_surface"] }
        let waylandSurface = wantWSI && available.contains("VK_KHR_surface") && available.contains("VK_KHR_wayland_surface")
        if waylandSurface { instanceExts += (xlibSurface ? [] : ["VK_KHR_surface"]) + ["VK_KHR_wayland_surface"] }
        var layers: [String] = []
        if ProcessInfo.processInfo.environment["PHOTON_VK_VALIDATION"] == "1" { layers.append("VK_LAYER_KHRONOS_validation") }

        var app = VkApplicationInfo()
        app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        app.pApplicationName = arena.cstr("photon2")
        app.pEngineName = arena.cstr("photon2")
        app.apiVersion = vkVersion(1, 3)
        var ici = VkInstanceCreateInfo()
        ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        ici.flags = flags
        ici.pApplicationInfo = UnsafePointer(arena.ptr(app))
        ici.enabledExtensionCount = UInt32(instanceExts.count)
        ici.ppEnabledExtensionNames = arena.cstrs(instanceExts)
        ici.enabledLayerCount = UInt32(layers.count)
        ici.ppEnabledLayerNames = arena.cstrs(layers)
        var inst: VkInstance?
        try vkCheck(vkCreateInstance(&ici, nil, &inst), "vkCreateInstance")
        let instance = inst!
        handles = VulkanHandles(instance: instance)

        // Physical device: PHOTON_VK_DEVICE picks by name substring, else the first 1.3 device.
        var pdCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &pdCount, nil)
        var pds = [VkPhysicalDevice?](repeating: nil, count: Int(pdCount))
        vkEnumeratePhysicalDevices(instance, &pdCount, &pds)
        var chosen: (VkPhysicalDevice, VkPhysicalDeviceProperties)?
        for case let pd? in pds {
            var props = VkPhysicalDeviceProperties()
            vkGetPhysicalDeviceProperties(pd, &props)
            let name = cString(props.deviceName)
            guard props.apiVersion >= vkVersion(1, 3) else { continue }
            if let want = preferredDevice, !name.localizedCaseInsensitiveContains(want) { continue }
            chosen = (pd, props)
            break
        }
        guard let (pd, props) = chosen else { throw GPUError.unsupported("no Vulkan 1.3 device\(preferredDevice.map { " matching \($0)" } ?? "")") }
        physicalDevice = pd
        uniformAlignment = max(16, Int(props.limits.minUniformBufferOffsetAlignment))

        var driver = VkPhysicalDeviceDriverProperties()
        driver.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES
        var props2 = VkPhysicalDeviceProperties2()
        props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        withUnsafeMutablePointer(to: &driver) { p in
            props2.pNext = UnsafeMutableRawPointer(p)
            vkGetPhysicalDeviceProperties2(pd, &props2)
        }
        let driverName = cString(driver.driverName), driverInfo = cString(driver.driverInfo)
        driverDescription = driverInfo.isEmpty ? driverName : "\(driverName) / \(driverInfo)"
        switch ProcessInfo.processInfo.environment["PHOTON_VK_WRITE_ALL_SAMPLERS"] {
        case "1": writesAllSamplers = true
        case "0": writesAllSamplers = false
        default:
            // The Mesa version comes from driverInfo ("Mesa 22.3.6 (LLVM 15.0.6)"): lavapipe reported driverVersion 1
            // until Mesa 25.x. Unparseable means written (the extra descriptors change no output).
            let mesa = mesaVersion(driverInfo)
            writesAllSamplers = driver.driverID == VK_DRIVER_ID_MESA_LLVMPIPE && mesa.map { $0 < (23, 2) } ?? true
        }

        var features = VkPhysicalDeviceFeatures()
        vkGetPhysicalDeviceFeatures(pd, &features)
        var mem = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(pd, &mem)
        memoryProperties = mem

        var qfCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfCount, nil)
        var qfs = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(qfCount))
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &qfCount, &qfs)
        guard let qf = qfs.firstIndex(where: { $0.queueFlags & VK_QUEUE_GRAPHICS_BIT.rawValue != 0 }) else {
            throw GPUError.unsupported("no graphics queue")
        }
        queueFamily = UInt32(qf)

        // Device
        var devExtCount: UInt32 = 0
        vkEnumerateDeviceExtensionProperties(pd, nil, &devExtCount, nil)
        var devExts = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(devExtCount))
        vkEnumerateDeviceExtensionProperties(pd, nil, &devExtCount, &devExts)
        let devAvailable = Set(devExts.map { cString($0.extensionName) })
        var deviceExts: [String] = []
        if devAvailable.contains("VK_KHR_portability_subset") { deviceExts.append("VK_KHR_portability_subset") }
        let swapchain = (xlibSurface || waylandSurface) && devAvailable.contains("VK_KHR_swapchain")
        if swapchain { deviceExts.append("VK_KHR_swapchain") }
        // The `pausevram` playback rule's input (docs/re/09 §1.3, docs/linux-port.md §5): DXGI's QueryVideoMemoryInfo on
        // the engine's side, VkPhysicalDeviceMemoryBudgetPropertiesEXT here. Enabling it changes nothing else.
        supportsMemoryBudget = devAvailable.contains("VK_EXT_memory_budget")
        if supportsMemoryBudget { deviceExts.append("VK_EXT_memory_budget") }
        if let extra = ProcessInfo.processInfo.environment["PHOTON_VK_DEVICE_EXTENSIONS"] {
            deviceExts += extra.split(separator: ",").map(String.init).filter { devAvailable.contains($0) }
        }

        var enabled = VkPhysicalDeviceFeatures()
        enabled.geometryShader = features.geometryShader
        enabled.samplerAnisotropy = features.samplerAnisotropy
        enabled.textureCompressionBC = features.textureCompressionBC
        enabled.multiViewport = features.multiViewport
        enabled.occlusionQueryPrecise = features.occlusionQueryPrecise
        enabled.depthBiasClamp = features.depthBiasClamp
        enabled.shaderClipDistance = features.shaderClipDistance
        enabled.independentBlend = features.independentBlend
        // SV_ViewportArrayIndex written by the vertex stage (the shadow caster pass, Draw.swift `viewports`).
        var have12 = VkPhysicalDeviceVulkan12Features()
        have12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
        var query = VkPhysicalDeviceFeatures2()
        query.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        withUnsafeMutablePointer(to: &have12) { p in
            query.pNext = UnsafeMutableRawPointer(p)
            vkGetPhysicalDeviceFeatures2(pd, &query)
        }
        var v12 = VkPhysicalDeviceVulkan12Features()
        v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
        v12.shaderOutputViewportIndex = have12.shaderOutputViewportIndex
        v12.shaderOutputLayer = have12.shaderOutputLayer
        let viewportIndexFromVS = have12.shaderOutputViewportIndex != 0
        var v13 = VkPhysicalDeviceVulkan13Features()
        v13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
        v13.dynamicRendering = 1
        v13.pNext = UnsafeMutableRawPointer(arena.ptr(v12))
        var f2 = VkPhysicalDeviceFeatures2()
        f2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
        f2.features = enabled
        f2.pNext = UnsafeMutableRawPointer(arena.ptr(v13))
        let priority = arena.ptr(Float(1))
        var qci = VkDeviceQueueCreateInfo()
        qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        qci.queueFamilyIndex = queueFamily
        qci.queueCount = 1
        qci.pQueuePriorities = UnsafePointer(priority)
        var dci = VkDeviceCreateInfo()
        dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        dci.pNext = UnsafeRawPointer(arena.ptr(f2))
        dci.queueCreateInfoCount = 1
        dci.pQueueCreateInfos = UnsafePointer(arena.ptr(qci))
        dci.enabledExtensionCount = UInt32(deviceExts.count)
        dci.ppEnabledExtensionNames = arena.cstrs(deviceExts)
        var dev: VkDevice?
        try vkCheck(vkCreateDevice(pd, &dci, nil, &dev), "vkCreateDevice")
        device = dev!
        handles.device = dev!
        var q: VkQueue?
        vkGetDeviceQueue(device, queueFamily, 0, &q)
        queue = q!

        var cpci = VkCommandPoolCreateInfo()
        cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
        cpci.queueFamilyIndex = queueFamily
        var pool: VkCommandPool?
        try vkCheck(vkCreateCommandPool(device, &cpci, nil, &pool), "vkCreateCommandPool")
        commandPool = pool!
        handles.destroyers.append { vkDestroyCommandPool(dev, pool, nil) }

        // One descriptor set layout for every pipeline: HLSL registers at fixed bindings (HLSLRegisterMap), like
        // Metal's fixed buffer/texture/sampler indices.
        let gs = features.geometryShader != 0
        let vsStages = VK_SHADER_STAGE_VERTEX_BIT.rawValue
        let texStages = VK_SHADER_STAGE_VERTEX_BIT.rawValue | VK_SHADER_STAGE_FRAGMENT_BIT.rawValue | (gs ? VK_SHADER_STAGE_GEOMETRY_BIT.rawValue : 0)
        var bindings: [VkDescriptorSetLayoutBinding] = []
        func add(_ base: Int, _ count: Int, _ type: VkDescriptorType, _ stages: UInt32) {
            for i in 0..<count {
                var b = VkDescriptorSetLayoutBinding()
                b.binding = UInt32(base + i)
                b.descriptorType = type
                b.descriptorCount = 1
                b.stageFlags = stages
                bindings.append(b)
            }
        }
        add(HLSLRegisterMap.uniformBase(.vertex), HLSLRegisterMap.uniformRegisters, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, vsStages)
        add(HLSLRegisterMap.uniformBase(.fragment), HLSLRegisterMap.uniformRegisters, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
        if gs {
            add(HLSLRegisterMap.uniformBase(.geometry), HLSLRegisterMap.uniformRegisters, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                VK_SHADER_STAGE_GEOMETRY_BIT.rawValue)
        }
        add(HLSLRegisterMap.textureBase, HLSLRegisterMap.slots, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, texStages)
        add(HLSLRegisterMap.samplerBase, HLSLRegisterMap.slots, VK_DESCRIPTOR_TYPE_SAMPLER, texStages)
        var dslci = VkDescriptorSetLayoutCreateInfo()
        dslci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
        dslci.bindingCount = UInt32(bindings.count)
        dslci.pBindings = UnsafePointer(arena.array(bindings))
        var dsl: VkDescriptorSetLayout?
        try vkCheck(vkCreateDescriptorSetLayout(device, &dslci, nil, &dsl), "vkCreateDescriptorSetLayout")
        descriptorSetLayout = dsl!
        handles.destroyers.append { vkDestroyDescriptorSetLayout(dev, dsl, nil) }
        var plci = VkPipelineLayoutCreateInfo()
        plci.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        plci.setLayoutCount = 1
        plci.pSetLayouts = UnsafePointer(arena.ptr(Optional(descriptorSetLayout)))
        var pl: VkPipelineLayout?
        try vkCheck(vkCreatePipelineLayout(device, &plci, nil, &pl), "vkCreatePipelineLayout")
        pipelineLayout = pl!
        handles.destroyers.append { vkDestroyPipelineLayout(dev, pl, nil) }

        supportsXlibPresentation = swapchain && xlibSurface
        supportsWaylandPresentation = swapchain && waylandSurface
        maxAnisotropy = features.samplerAnisotropy != 0 ? props.limits.maxSamplerAnisotropy : 1
        // PHOTON_VK_MAX_ANISOTROPY=n caps sampler anisotropy (diagnostics: lavapipe's anisotropic filtering is its most
        // expensive sampling path; output then differs from the engine's 8×).
        if let cap = ProcessInfo.processInfo.environment["PHOTON_VK_MAX_ANISOTROPY"].flatMap(Float.init) { maxAnisotropy = min(maxAnisotropy, max(cap, 1)) }
        preciseOcclusion = features.occlusionQueryPrecise != 0
        capabilities.deviceName = cString(props.deviceName)
        capabilities.geometryShaders = gs
        capabilities.bcTextureCompression = features.textureCompressionBC != 0
        capabilities.maxAnisotropy = Double(maxAnisotropy)
        capabilities.multiViewport = features.multiViewport != 0 && viewportIndexFromVS
        let counts = props.limits.framebufferColorSampleCounts
        let both = counts & props.limits.framebufferDepthSampleCounts & props.limits.sampledImageColorSampleCounts
        capabilities.maxSampleCount = [8, 4, 2, 1].first { both & UInt32($0) != 0 } ?? 1
        capabilities.sampleCounts = Set([1, 2, 4, 8, 16].filter { both & UInt32($0) != 0 })

        nullTexture = try VulkanTexture(device: self, descriptor: GPUTextureDescriptor(format: .rgba8Unorm, width: 1, height: 1,
                                                                                       label: "null"))
        defaultSampler = try VulkanSampler(device: self, descriptor: GPUSamplerDescriptor())
        zeroBuffer = try VulkanBuffer(device: self, length: 65536, usage: VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
        memset(zeroBuffer.contents, 0, 65536)
    }

    deinit { vkDeviceWaitIdle(device) }

    func memoryType(bits: UInt32, flags: VkMemoryPropertyFlags) throws -> UInt32 {
        var props = memoryProperties
        let count = Int(props.memoryTypeCount)
        return try withUnsafePointer(to: &props.memoryTypes) { p in
            try p.withMemoryRebound(to: VkMemoryType.self, capacity: 32) { types in
                for i in 0..<count where bits & (1 << UInt32(i)) != 0 && types[i].propertyFlags & flags == flags { return UInt32(i) }
                throw GPUError.failed("no memory type for flags \(flags)")
            }
        }
    }

    func allocate(_ req: VkMemoryRequirements, flags: VkMemoryPropertyFlags) throws -> VkDeviceMemory {
        var ai = VkMemoryAllocateInfo()
        ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        ai.allocationSize = req.size
        ai.memoryTypeIndex = try memoryType(bits: req.memoryTypeBits, flags: flags)
        var m: VkDeviceMemory?
        try vkCheck(vkAllocateMemory(device, &ai, nil, &m), "vkAllocateMemory(\(req.size))")
        return m!
    }

    /// Records `body` into its own submission (texture uploads, initial clears, readbacks). The submission is ordered
    /// after every earlier one and before every later one on the single queue, which gives `MTLTexture.replace` /
    /// `getBytes` semantics without stalling: only `wait` (readbacks) blocks until the GPU has run it.
    func transfer(retaining: [AnyObject] = [], wait: Bool, hostReads: Bool = false,
                  _ body: (VulkanCommandBuffer, VkCommandBuffer) throws -> Void) throws {
        let cb = try VulkanCommandBuffer(device: self)
        cb.retained += retaining
        var thrown: Error?
        cb.recordTransfer({ c in do { try body(cb, c) } catch { thrown = error } }, hostReads: hostReads)
        cb.commit()
        if wait { cb.waitUntilCompleted() }
        if let thrown { throw thrown }
    }

    func acquireContext() throws -> CommandContext {
        poll()
        trackLock.lock()
        if let c = freeContexts.popLast() {
            trackLock.unlock()
            return c
        }
        let oldest = inFlight.count >= Self.maxInFlight ? inFlight.first : nil
        trackLock.unlock()
        if let oldest {
            oldest.waitUntilCompleted()
            trackLock.lock()
            if let c = freeContexts.popLast() { trackLock.unlock(); return c }
            trackLock.unlock()
        }
        return try CommandContext(device: self)
    }

    func recycle(_ c: CommandContext) {
        c.reset()
        trackLock.lock()
        freeContexts.append(c)
        trackLock.unlock()
    }

    /// Submits a finished command buffer: waits for the drawable's acquire, signals its render-done semaphore and queues
    /// the present after it.
    func submit(_ cb: VulkanCommandBuffer, drawable: VulkanDrawable?) {
        var c: VkCommandBuffer? = cb.cb
        var si = VkSubmitInfo()
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        si.commandBufferCount = 1
        var waitSem: VkSemaphore? = drawable?.acquired
        var signalSem: VkSemaphore? = drawable?.renderDone
        var waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue
        var fence: VkFence? = cb.context.fence
        vkResetFences(device, 1, &fence)
        trackLock.lock()
        inFlight.append(cb)
        trackLock.unlock()
        queueLock.lock()
        defer { queueLock.unlock() }
        withUnsafePointer(to: &c) { cp in
            withUnsafePointer(to: &waitSem) { wp in
                withUnsafePointer(to: &signalSem) { sp in
                    withUnsafePointer(to: &waitStage) { stp in
                        si.pCommandBuffers = cp
                        if drawable != nil {
                            si.waitSemaphoreCount = 1
                            si.pWaitSemaphores = wp
                            si.pWaitDstStageMask = stp
                            si.signalSemaphoreCount = 1
                            si.pSignalSemaphores = sp
                        }
                        let r = vkQueueSubmit(queue, 1, &si, cb.context.fence)
                        if r != VK_SUCCESS { NSLog("photon: vkQueueSubmit failed: %d", r.rawValue) }
                    }
                }
            }
        }
        if Self.stats { FileHandle.standardError.write(Data("vk: submit \(cb.barrierCount) barrier(s)\(drawable != nil ? " + present" : "")\n".utf8)) }
        drawable?.present(after: cb)
    }

    /// Finishes every submission whose fence has signalled (completed handlers run here, in submission order).
    public func poll() {
        trackLock.lock()
        var done: [VulkanCommandBuffer] = []
        inFlight.removeAll { cb in
            guard vkGetFenceStatus(device, cb.context.fence) == VK_SUCCESS else { return false }
            done.append(cb)
            return true
        }
        trackLock.unlock()
        for cb in done { cb.finish() }
    }

    /// Device-local memory this process uses and its budget, summed over the DEVICE_LOCAL heaps
    /// (VK_EXT_memory_budget; the engine reads DXGI_QUERY_VIDEO_MEMORY_INFO CurrentUsage / Budget). nil without the
    /// extension.
    public func memoryBudget() -> (used: UInt64, budget: UInt64)? {
        guard supportsMemoryBudget else { return nil }
        var budget = VkPhysicalDeviceMemoryBudgetPropertiesEXT()
        budget.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT
        var props = VkPhysicalDeviceMemoryProperties2()
        props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2
        withUnsafeMutablePointer(to: &budget) { b in
            props.pNext = UnsafeMutableRawPointer(b)
            vkGetPhysicalDeviceMemoryProperties2(physicalDevice, &props)
        }
        let heaps = props.memoryProperties
        let n = Int(heaps.memoryHeapCount)
        var used: UInt64 = 0, total: UInt64 = 0
        withUnsafeBytes(of: heaps.memoryHeaps) { hp in
            let h = hp.bindMemory(to: VkMemoryHeap.self)
            withUnsafeBytes(of: budget.heapUsage) { up in
                withUnsafeBytes(of: budget.heapBudget) { bp in
                    let u = up.bindMemory(to: VkDeviceSize.self), b = bp.bindMemory(to: VkDeviceSize.self)
                    for i in 0..<min(n, h.count) where h[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT.rawValue != 0 {
                        used += u[i]
                        total += b[i]
                    }
                }
            }
        }
        return (used, total)
    }

    /// Waits for every submission so far and runs their handlers.
    public func waitIdle() {
        queueLock.lock()
        vkQueueWaitIdle(queue)
        queueLock.unlock()
        poll()
    }

    // MARK: GPUDevice

    public func makeBuffer(length: Int) throws -> GPUBuffer {
        try VulkanBuffer(device: self, length: length, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue
            | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
    }

    public func makeTexture(_ descriptor: GPUTextureDescriptor) throws -> GPUTextureResource {
        try VulkanTexture(device: self, descriptor: descriptor)
    }

    public func makeSampler(_ descriptor: GPUSamplerDescriptor) throws -> GPUSampler {
        try VulkanSampler(device: self, descriptor: descriptor)
    }

    public func makeShaderModule(stage: GPUShaderStage, spirv: [UInt32], entryPoint: String, label: String) throws -> GPUShaderModule {
        try VulkanShaderModule(device: self, stage: stage, spirv: spirv)
    }

    public func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> GPURenderPipeline {
        try VulkanPipeline(device: self, descriptor: descriptor)
    }

    public func makeOcclusionQuerySet(count: Int) throws -> GPUOcclusionQuerySet {
        try VulkanQuerySet(device: self, count: count)
    }

    public func makeCommandBuffer() throws -> GPUCommandBuffer {
        try VulkanCommandBuffer(device: self)
    }
}

/// Full execution + memory dependency: the start of every submission (earlier submissions are not tracked). Inside a
/// command buffer `HazardTracker` places narrower ones.
func fullBarrier(_ cb: VkCommandBuffer) {
    var mb = VkMemoryBarrier()
    mb.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
    mb.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    mb.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, 0, 1, &mb, 0, nil, 0, nil)
}

// MARK: - Resources

final class VulkanBuffer: GPUBuffer {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let buffer: VkBuffer
    let memory: VkDeviceMemory
    let length: Int
    let contents: UnsafeMutableRawPointer

    init(device: VulkanDevice, length: Int, usage: VkBufferUsageFlags) throws {
        owner = device
        handles = device.handles
        self.length = length
        var bci = VkBufferCreateInfo()
        bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        bci.size = VkDeviceSize(max(length, 4))
        bci.usage = usage
        bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        var b: VkBuffer?
        try vkCheck(vkCreateBuffer(device.device, &bci, nil, &b), "vkCreateBuffer")
        buffer = b!
        var req = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(device.device, buffer, &req)
        memory = try device.allocate(req, flags: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)
        vkBindBufferMemory(device.device, buffer, memory, 0)
        var p: UnsafeMutableRawPointer?
        try vkCheck(vkMapMemory(device.device, memory, 0, VkDeviceSize(UInt64.max), 0, &p), "vkMapMemory")
        contents = p!
    }

    deinit {
        vkUnmapMemory(handles.device, memory)
        vkDestroyBuffer(handles.device, buffer, nil)
        vkFreeMemory(handles.device, memory, nil)
    }
}

/// Images live in VK_IMAGE_LAYOUT_GENERAL for their whole life, so they can be attachments, sampled and copied without
/// per-use layout tracking (barriers: `HazardTracker`).
final class VulkanTexture: GPUTextureResource {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let descriptor: GPUTextureDescriptor
    let image: VkImage
    /// nil for a view: the storage belongs to `parent`.
    let memory: VkDeviceMemory?
    let view: VkImageView
    /// A view's first mip within `image` (0 for a texture); copies and attachments add it to their levels.
    let baseLevel: Int
    /// The texture a view was made from (kept alive while the view is).
    let parent: VulkanTexture?

    init(device: VulkanDevice, descriptor d: GPUTextureDescriptor) throws {
        owner = device
        handles = device.handles
        descriptor = d
        baseLevel = 0
        parent = nil
        var ici = VkImageCreateInfo()
        ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        ici.imageType = d.type == .type3D ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D
        ici.format = d.format.vk
        if d.usage.contains(.pixelFormatView) { ici.flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT.rawValue }
        ici.extent = VkExtent3D(width: UInt32(d.width), height: UInt32(d.height), depth: UInt32(max(d.depth, 1)))
        ici.mipLevels = UInt32(max(d.mipLevels, 1))
        ici.arrayLayers = 1
        ici.samples = VkSampleCountFlagBits(rawValue: UInt32(max(d.sampleCount, 1)))
        ici.tiling = VK_IMAGE_TILING_OPTIMAL
        var usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
        if d.usage.contains(.renderTarget) {
            usage |= d.format.isDepth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue
        }
        ici.usage = usage
        ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var img: VkImage?
        try vkCheck(vkCreateImage(device.device, &ici, nil, &img), "vkCreateImage \(d.label) \(d.format) \(d.width)x\(d.height)")
        image = img!
        var req = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device.device, image, &req)
        let mem = try device.allocate(req, flags: VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)

        memory = mem
        vkBindImageMemory(device.device, image, mem, 0)
        view = try Self.makeView(device: device, image: image, descriptor: d, format: d.format, baseLevel: 0, levelCount: Int(ici.mipLevels))

        // GENERAL layout, contents zeroed: D3D11 zero-fills new resources (photon2's Metal path clears new render
        // targets to transparent black for the same reason, RenderTargetManager.markFresh).
        let image = self.image, format = d.format, levels = ici.mipLevels
        try device.transfer(retaining: [self], wait: false) { _, cb in
            var b = VkImageMemoryBarrier()
            b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
            b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED
            b.newLayout = VK_IMAGE_LAYOUT_GENERAL
            b.srcQueueFamilyIndex = UInt32.max
            b.dstQueueFamilyIndex = UInt32.max
            b.image = image
            b.subresourceRange = VkImageSubresourceRange(aspectMask: format.aspect, baseMipLevel: 0, levelCount: levels, baseArrayLayer: 0, layerCount: 1)
            b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT.rawValue, VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue, 0, 0, nil, 0, nil, 1, &b)
            var range = b.subresourceRange
            if format.isDepth {
                var c = VkClearDepthStencilValue(depth: 0, stencil: 0)
                vkCmdClearDepthStencilImage(cb, image, VK_IMAGE_LAYOUT_GENERAL, &c, 1, &range)
            } else if !format.isCompressed {
                var c = VkClearColorValue()
                c.float32 = (0, 0, 0, 0)
                vkCmdClearColorImage(cb, image, VK_IMAGE_LAYOUT_GENERAL, &c, 1, &range)
            }
        }
    }

    /// A view of `parent` (see `GPUTextureResource.makeView`).
    init(viewOf parent: VulkanTexture, format: GPUPixelFormat, baseLevel: Int, levelCount: Int) throws {
        owner = parent.owner
        handles = parent.handles
        self.parent = parent
        image = parent.image
        memory = nil
        self.baseLevel = parent.baseLevel + baseLevel
        var d = parent.descriptor
        d.format = format
        d.width = max(1, parent.descriptor.width >> baseLevel)
        d.height = max(1, parent.descriptor.height >> baseLevel)
        if d.type == .type3D { d.depth = max(1, parent.descriptor.depth >> baseLevel) }
        d.mipLevels = levelCount
        descriptor = d
        view = try Self.makeView(device: parent.owner, image: parent.image, descriptor: d, format: format,
                                 baseLevel: self.baseLevel, levelCount: levelCount)
    }

    static func makeView(device: VulkanDevice, image: VkImage, descriptor d: GPUTextureDescriptor, format: GPUPixelFormat,
                         baseLevel: Int, levelCount: Int) throws -> VkImageView {
        var vci = VkImageViewCreateInfo()
        vci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        vci.image = image
        vci.viewType = d.type == .type3D ? VK_IMAGE_VIEW_TYPE_3D : VK_IMAGE_VIEW_TYPE_2D
        vci.format = format.vk
        // A depth+stencil view for sampling must name one aspect; attachments use the same view (depth only).
        let aspect = format.isDepth ? VK_IMAGE_ASPECT_DEPTH_BIT.rawValue : format.aspect
        vci.subresourceRange = VkImageSubresourceRange(aspectMask: aspect, baseMipLevel: UInt32(baseLevel), levelCount: UInt32(levelCount),
                                                       baseArrayLayer: 0, layerCount: 1)
        var v: VkImageView?
        try vkCheck(vkCreateImageView(device.device, &vci, nil, &v), "vkCreateImageView")
        return v!
    }

    deinit {
        vkDestroyImageView(handles.device, view, nil)
        if let memory {
            vkDestroyImage(handles.device, image, nil)
            vkFreeMemory(handles.device, memory, nil)
        }
    }

    func makeView(format: GPUPixelFormat, baseLevel: Int, levelCount: Int) throws -> GPUTextureResource {
        try VulkanTexture(viewOf: self, format: format, baseLevel: baseLevel, levelCount: levelCount)
    }

    private func bufferRegion(level: Int, x: Int, y: Int, width: Int, height: Int, depth: Int, bytesPerRow: Int,
                              bytesPerImage: Int) -> VkBufferImageCopy {
        let f = descriptor.format
        let rows = (height + f.block.size - 1) / f.block.size
        var region = VkBufferImageCopy()
        region.bufferOffset = 0
        // Row length / image height in texels (blocks × block size for compressed formats).
        region.bufferRowLength = UInt32(bytesPerRow / f.block.bytes * f.block.size)
        region.bufferImageHeight = UInt32((bytesPerImage / max(bytesPerRow, 1)) * f.block.size)
        if region.bufferImageHeight < UInt32(rows * f.block.size) { region.bufferImageHeight = 0 }
        region.imageSubresource = VkImageSubresourceLayers(aspectMask: f.isDepth ? VK_IMAGE_ASPECT_DEPTH_BIT.rawValue : f.aspect,
                                                           mipLevel: UInt32(baseLevel + level), baseArrayLayer: 0, layerCount: 1)
        region.imageOffset = VkOffset3D(x: Int32(x), y: Int32(y), z: 0)
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: UInt32(max(depth, 1)))
        return region
    }

    /// Staged through the upload submission's ring; the copy runs after every earlier submission and before every later
    /// one, so the call returns without waiting for the GPU (see `VulkanDevice.transfer`).
    func replace(level: Int, x: Int, y: Int, width: Int, height: Int, depth: Int, bytes: UnsafeRawBufferPointer,
                 bytesPerRow: Int, bytesPerImage: Int) throws {
        let size = bytesPerImage * max(depth, 1)
        guard bytes.count >= size else { throw GPUError.failed("replace: \(bytes.count) bytes, need \(size)") }
        var region = bufferRegion(level: level, x: x, y: y, width: width, height: height, depth: depth, bytesPerRow: bytesPerRow,
                                  bytesPerImage: bytesPerImage)
        let image = self.image
        let alignment = max(16, descriptor.format.block.bytes)
        try owner.transfer(retaining: [self], wait: false) { vcb, cb in
            let (staging, offset) = try vcb.ring.allocate(UnsafeRawBufferPointer(rebasing: bytes[0..<size]), alignment: alignment)
            region.bufferOffset = VkDeviceSize(offset)
            vkCmdCopyBufferToImage(cb, staging.buffer, image, VK_IMAGE_LAYOUT_GENERAL, 1, &region)
        }
    }

    func read(level: Int, x: Int, y: Int, width: Int, height: Int, depth: Int, into bytes: UnsafeMutableRawBufferPointer,
              bytesPerRow: Int, bytesPerImage: Int) throws {
        let size = bytesPerImage * max(depth, 1)
        guard bytes.count >= size else { throw GPUError.failed("read: \(bytes.count) bytes, need \(size)") }
        let staging = try VulkanBuffer(device: owner, length: size, usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)
        var region = bufferRegion(level: level, x: x, y: y, width: width, height: height, depth: depth, bytesPerRow: bytesPerRow,
                                  bytesPerImage: bytesPerImage)
        let image = self.image
        try owner.transfer(retaining: [self, staging], wait: true, hostReads: true) { _, cb in
            vkCmdCopyImageToBuffer(cb, image, VK_IMAGE_LAYOUT_GENERAL, staging.buffer, 1, &region)
        }
        memcpy(bytes.baseAddress!, staging.contents, size)
    }
}

final class VulkanSampler: GPUSampler {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let descriptor: GPUSamplerDescriptor
    let sampler: VkSampler

    init(device: VulkanDevice, descriptor d: GPUSamplerDescriptor) throws {
        owner = device
        handles = device.handles
        descriptor = d
        var sci = VkSamplerCreateInfo()
        sci.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        sci.magFilter = d.magFilter == .linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
        sci.minFilter = d.minFilter == .linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST
        sci.mipmapMode = d.mipFilter == .linear ? VK_SAMPLER_MIPMAP_MODE_LINEAR : VK_SAMPLER_MIPMAP_MODE_NEAREST
        sci.addressModeU = d.addressU.vk
        sci.addressModeV = d.addressV.vk
        sci.addressModeW = d.addressW.vk
        sci.mipLodBias = 0
        // No mip filter = level 0 only (Metal .notMipmapped): the standard Vulkan idiom is NEAREST with maxLod 0.
        sci.minLod = 0
        sci.maxLod = d.mipFilter == .none ? 0 : 1000
        if d.maxAnisotropy > 1 && device.maxAnisotropy > 1 {
            sci.anisotropyEnable = 1
            sci.maxAnisotropy = min(Float(d.maxAnisotropy), device.maxAnisotropy)
        }
        if let c = d.compare {
            sci.compareEnable = 1
            sci.compareOp = c.vk
        }
        sci.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK
        var s: VkSampler?
        try vkCheck(vkCreateSampler(device.device, &sci, nil, &s), "vkCreateSampler")
        sampler = s!
    }

    deinit { vkDestroySampler(handles.device, sampler, nil) }
}

final class VulkanShaderModule: GPUShaderModule {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let stage: GPUShaderStage
    let module: VkShaderModule
    let reflection: SPIRVReflection

    init(device: VulkanDevice, stage: GPUShaderStage, spirv: [UInt32]) throws {
        owner = device
        handles = device.handles
        self.stage = stage
        reflection = try SPIRVReflection(words: spirv)
        var smci = VkShaderModuleCreateInfo()
        smci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        smci.codeSize = spirv.count * 4
        var m: VkShaderModule?
        try spirv.withUnsafeBufferPointer { p in
            smci.pCode = p.baseAddress
            try vkCheck(vkCreateShaderModule(device.device, &smci, nil, &m), "vkCreateShaderModule")
        }
        module = m!
    }

    deinit { vkDestroyShaderModule(handles.device, module, nil) }

    var vkStage: VkShaderStageFlagBits {
        switch stage {
        case .vertex: return VK_SHADER_STAGE_VERTEX_BIT
        case .fragment: return VK_SHADER_STAGE_FRAGMENT_BIT
        case .geometry: return VK_SHADER_STAGE_GEOMETRY_BIT
        }
    }
}

final class VulkanPipeline: GPURenderPipeline {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let pipeline: VkPipeline
    /// Registers each stage's SPIR-V declares (descriptors written per draw).
    let uniformRegisters: [(stage: GPUShaderStage, register: Int)]
    let textureSlots: [Int]
    let samplerSlots: [Int]

    init(device: VulkanDevice, descriptor d: GPURenderPipelineDescriptor) throws {
        owner = device
        handles = device.handles
        let arena = Arena()
        let modules = ([d.vertex, d.geometry, d.fragment] as [GPUShaderModule?]).compactMap { $0 as? VulkanShaderModule }
        guard modules.count == (d.geometry == nil ? 2 : 3) else { throw GPUError.failed("pipeline: modules from another backend") }
        var ubos: [(GPUShaderStage, Int)] = [], tex = Set<Int>(), smp = Set<Int>()
        for m in modules {
            for b in m.reflection.uniformBlocks { ubos.append((m.stage, b.binding - HLSLRegisterMap.uniformBase(m.stage))) }
            for i in m.reflection.images { tex.insert(i.binding - HLSLRegisterMap.textureBase) }
            for s in m.reflection.samplers { smp.insert(s.binding - HLSLRegisterMap.samplerBase) }
        }
        uniformRegisters = ubos
        textureSlots = tex.sorted()
        samplerSlots = smp.sorted()

        let stages: [VkPipelineShaderStageCreateInfo] = modules.map { m in
            var s = VkPipelineShaderStageCreateInfo()
            s.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            s.stage = m.vkStage
            s.module = m.module
            s.pName = arena.cstr(m.reflection.entryPoint.isEmpty ? "main" : m.reflection.entryPoint)
            return s
        }
        let vsInputs = (d.vertex as! VulkanShaderModule).reflection.inputs.map(\.location)
        let attrs: [VkVertexInputAttributeDescription] = d.vertexLayout.attributes(forInputs: vsInputs).map {
            VkVertexInputAttributeDescription(location: UInt32($0.location), binding: 0, format: $0.format.vk, offset: UInt32($0.offset))
        }
        let vb = VkVertexInputBindingDescription(binding: 0, stride: UInt32(d.vertexLayout.stride),
                                                 inputRate: d.vertexLayout.perInstance ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX)
        var vi = VkPipelineVertexInputStateCreateInfo()
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        if !attrs.isEmpty {
            vi.vertexBindingDescriptionCount = 1
            vi.pVertexBindingDescriptions = UnsafePointer(arena.ptr(vb))
            vi.vertexAttributeDescriptionCount = UInt32(attrs.count)
            vi.pVertexAttributeDescriptions = UnsafePointer(arena.array(attrs))
        }
        var ia = VkPipelineInputAssemblyStateCreateInfo()
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        switch d.primitive {
        case .triangle: ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        case .triangleStrip: ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        case .line: ia.topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST
        case .point: ia.topology = VK_PRIMITIVE_TOPOLOGY_POINT_LIST
        }
        var vp = VkPipelineViewportStateCreateInfo()
        vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        vp.viewportCount = 0 // VIEWPORT_WITH_COUNT / SCISSOR_WITH_COUNT
        vp.scissorCount = 0
        var rs = VkPipelineRasterizationStateCreateInfo()
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        rs.polygonMode = VK_POLYGON_MODE_FILL
        rs.lineWidth = 1
        var ms = VkPipelineMultisampleStateCreateInfo()
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        ms.rasterizationSamples = VkSampleCountFlagBits(rawValue: UInt32(max(d.sampleCount, 1)))
        ms.alphaToCoverageEnable = d.alphaToCoverage ? 1 : 0
        var ds = VkPipelineDepthStencilStateCreateInfo()
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        var att = VkPipelineColorBlendAttachmentState()
        att.blendEnable = d.blend.enabled ? 1 : 0
        att.srcColorBlendFactor = d.blend.sourceRGB.vk
        att.dstColorBlendFactor = d.blend.destinationRGB.vk
        att.colorBlendOp = d.blend.rgbOperation.vk
        att.srcAlphaBlendFactor = d.blend.sourceAlpha.vk
        att.dstAlphaBlendFactor = d.blend.destinationAlpha.vk
        att.alphaBlendOp = d.blend.alphaOperation.vk
        att.colorWriteMask = d.blend.writeMask.vk
        var cbs = VkPipelineColorBlendStateCreateInfo()
        cbs.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        cbs.attachmentCount = 1
        cbs.pAttachments = UnsafePointer(arena.ptr(att))
        let dynamics: [VkDynamicState] = [
            VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT, VK_DYNAMIC_STATE_SCISSOR_WITH_COUNT, VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE,
            VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE, VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, VK_DYNAMIC_STATE_DEPTH_COMPARE_OP,
            VK_DYNAMIC_STATE_DEPTH_BIAS, VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE,
        ]
        var dyn = VkPipelineDynamicStateCreateInfo()
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dyn.dynamicStateCount = UInt32(dynamics.count)
        dyn.pDynamicStates = UnsafePointer(arena.array(dynamics))
        var rendering = VkPipelineRenderingCreateInfo()
        rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
        rendering.colorAttachmentCount = 1
        rendering.pColorAttachmentFormats = UnsafePointer(arena.ptr(d.colorFormat.vk))
        rendering.depthAttachmentFormat = d.depthFormat?.vk ?? VK_FORMAT_UNDEFINED
        rendering.stencilAttachmentFormat = d.depthFormat == .depth24Stencil8 ? VK_FORMAT_D24_UNORM_S8_UINT : VK_FORMAT_UNDEFINED

        var gpci = VkGraphicsPipelineCreateInfo()
        gpci.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        gpci.pNext = UnsafeRawPointer(arena.ptr(rendering))
        gpci.stageCount = UInt32(stages.count)
        gpci.pStages = UnsafePointer(arena.array(stages))
        gpci.pVertexInputState = UnsafePointer(arena.ptr(vi))
        gpci.pInputAssemblyState = UnsafePointer(arena.ptr(ia))
        gpci.pViewportState = UnsafePointer(arena.ptr(vp))
        gpci.pRasterizationState = UnsafePointer(arena.ptr(rs))
        gpci.pMultisampleState = UnsafePointer(arena.ptr(ms))
        gpci.pDepthStencilState = UnsafePointer(arena.ptr(ds))
        gpci.pColorBlendState = UnsafePointer(arena.ptr(cbs))
        gpci.pDynamicState = UnsafePointer(arena.ptr(dyn))
        gpci.layout = device.pipelineLayout
        var p: VkPipeline?
        try vkCheck(vkCreateGraphicsPipelines(device.device, nil, 1, &gpci, nil, &p), "vkCreateGraphicsPipelines \(d.label)")
        pipeline = p!
    }

    deinit { vkDestroyPipeline(handles.device, pipeline, nil) }
}

final class VulkanQuerySet: GPUOcclusionQuerySet {
    unowned let owner: VulkanDevice
    let handles: VulkanHandles
    let pool: VkQueryPool
    let count: Int

    init(device: VulkanDevice, count: Int) throws {
        owner = device
        handles = device.handles
        self.count = count
        var qci = VkQueryPoolCreateInfo()
        qci.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
        qci.queryType = VK_QUERY_TYPE_OCCLUSION
        qci.queryCount = UInt32(count)
        var p: VkQueryPool?
        try vkCheck(vkCreateQueryPool(device.device, &qci, nil, &p), "vkCreateQueryPool")
        pool = p!
    }

    deinit { vkDestroyQueryPool(handles.device, pool, nil) }

    func results() -> [UInt64] {
        var out = [UInt64](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { raw in
            vkGetQueryPoolResults(handles.device, pool, 0, UInt32(count), raw.count, raw.baseAddress, 8,
                                  VK_QUERY_RESULT_64_BIT.rawValue | VK_QUERY_RESULT_WAIT_BIT.rawValue)
        }
        return out
    }
}

/// (major, minor) of "Mesa X.Y…" in a driverInfo string.
func mesaVersion(_ info: String) -> (Int, Int)? {
    guard let r = info.range(of: "Mesa ") else { return nil }
    let parts = info[r.upperBound...].prefix { $0.isNumber || $0 == "." }.split(separator: ".")
    guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
    return (major, minor)
}
