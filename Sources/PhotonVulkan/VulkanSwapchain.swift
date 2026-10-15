import CVulkan
import Foundation
import PhotonGPU

/// Vulkan WSI presentation to an X11 window (VK_KHR_xlib_surface + VK_KHR_swapchain) or a Wayland surface
/// (VK_KHR_wayland_surface; the size then comes from the host, `resize`), the Linux counterpart of
/// CAMetalLayer: `nextDrawable()` acquires an image, the frame's command buffer copies the rendered texture into it
/// (`GPUCommandBuffer.present(_:to:)`) and the present is queued behind that submission. At most `framesInFlight` frames
/// are queued: acquiring the next drawable waits for the command buffer that used the same slot two frames ago, which
/// is what keeps the CPU from running further ahead of the GPU.
public final class VulkanSwapchain {
    let owner: VulkanDevice
    let surface: VkSurfaceKHR
    private var swapchain: VkSwapchainKHR?
    private var images: [VkImage] = []
    private(set) var format = VK_FORMAT_B8G8R8A8_UNORM
    public private(set) var width: Int
    public private(set) var height: Int
    /// Per swapchain image: signalled by the frame's submission, waited by its present.
    private var renderDone: [VkSemaphore] = []
    /// Per frame slot: signalled by the acquire, waited by the frame's submission.
    private var acquireSemaphores: [VkSemaphore] = []
    private var slotBuffers: [VulkanCommandBuffer?]
    private var frame = 0
    private var outOfDate = false
    public let vsync: Bool
    public private(set) var presentModeName = ""
    public let framesInFlight: Int

    /// `display` is the Xlib `Display*`, `window` the X window id. `vsync` picks FIFO; otherwise MAILBOX or IMMEDIATE
    /// when the driver has them (benchmarks).
    public convenience init(device: VulkanDevice, display: UnsafeMutableRawPointer, window: UInt, width: Int, height: Int, vsync: Bool = true,
                            framesInFlight: Int = 2) throws {
        guard device.supportsXlibPresentation else { throw GPUError.unsupported("VK_KHR_xlib_surface / VK_KHR_swapchain not available") }
        try self.init(device: device, width: width, height: height, vsync: vsync, framesInFlight: framesInFlight) { s in
            try vkCheck(photon_vkCreateXlibSurfaceKHR(device.instance, display, window, &s), "vkCreateXlibSurfaceKHR")
        }
    }

    /// `display` is the `struct wl_display *`, `surface` the `struct wl_surface *`; `width` × `height` is the buffer size
    /// (Wayland surfaces have no size of their own: the swapchain's extent is the buffer the compositor gets).
    /// `vsync` false picks MAILBOX or IMMEDIATE. Mesa's FIFO on Wayland waits for the compositor's frame callbacks, which
    /// a compositor may stop sending to a hidden background surface; the desktop host then uses MAILBOX and paces itself.
    public convenience init(device: VulkanDevice, waylandDisplay: UnsafeMutableRawPointer, surface: UnsafeMutableRawPointer, width: Int,
                            height: Int, vsync: Bool = true, framesInFlight: Int = 2) throws {
        guard device.supportsWaylandPresentation else { throw GPUError.unsupported("VK_KHR_wayland_surface / VK_KHR_swapchain not available") }
        try self.init(device: device, width: width, height: height, vsync: vsync, framesInFlight: framesInFlight) { s in
            try vkCheck(photon_vkCreateWaylandSurfaceKHR(device.instance, waylandDisplay, surface, &s), "vkCreateWaylandSurfaceKHR")
        }
    }

    private init(device: VulkanDevice, width: Int, height: Int, vsync: Bool, framesInFlight: Int,
                 makeSurface: (inout VkSurfaceKHR?) throws -> Void) throws {
        owner = device
        self.width = width
        self.height = height
        self.vsync = vsync
        self.framesInFlight = max(1, framesInFlight)
        slotBuffers = Array(repeating: nil, count: max(1, framesInFlight))
        var s: VkSurfaceKHR?
        try makeSurface(&s)
        surface = s!
        var supported: VkBool32 = 0
        vkGetPhysicalDeviceSurfaceSupportKHR(device.physicalDevice, device.queueFamily, surface, &supported)
        do {
            guard supported != 0 else { throw GPUError.unsupported("the graphics queue cannot present to this window") }
            for _ in 0..<self.framesInFlight { acquireSemaphores.append(try makeSemaphore()) }
            try create()
        } catch {
            destroy()
            throw error
        }
    }

    deinit { destroy() }

    private var destroyed = false

    private func destroy() {
        guard !destroyed else { return }
        destroyed = true
        for cb in slotBuffers { cb?.waitUntilCompleted() }
        owner.waitIdle()
        let dev = owner.device
        for sem in renderDone + acquireSemaphores { vkDestroySemaphore(dev, sem, nil) }
        renderDone.removeAll()
        acquireSemaphores.removeAll()
        if let swapchain { vkDestroySwapchainKHR(dev, swapchain, nil) }
        swapchain = nil
        vkDestroySurfaceKHR(owner.instance, surface, nil)
    }

    private func makeSemaphore() throws -> VkSemaphore {
        var sci = VkSemaphoreCreateInfo()
        sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        var sem: VkSemaphore?
        try vkCheck(vkCreateSemaphore(owner.device, &sci, nil, &sem), "vkCreateSemaphore")
        return sem!
    }

    /// (Re)creates the swapchain for the surface's current size.
    private func create() throws {
        let pd = owner.physicalDevice, dev = owner.device
        var caps = VkSurfaceCapabilitiesKHR()
        try vkCheck(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
        guard caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue != 0 else {
            throw GPUError.unsupported("swapchain images cannot be copy destinations")
        }
        var formatCount: UInt32 = 0
        vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &formatCount, nil)
        var formats = [VkSurfaceFormatKHR](repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
        vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &formatCount, &formats)
        // The renderer's output is gamma-encoded BGRA8 (UNORM, like the engine's swapchain): copy it as is.
        let preferred = [VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM]
        guard let chosen = preferred.lazy.compactMap({ f in formats.first { $0.format == f } }).first ?? formats.first else {
            throw GPUError.unsupported("surface has no formats")
        }
        format = chosen.format

        var modeCount: UInt32 = 0
        vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &modeCount, nil)
        var modes = [VkPresentModeKHR](repeating: VK_PRESENT_MODE_FIFO_KHR, count: Int(modeCount))
        vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &modeCount, &modes)
        var mode = VK_PRESENT_MODE_FIFO_KHR
        if !vsync { mode = [VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_MAILBOX_KHR].first(where: modes.contains) ?? mode }
        presentModeName = mode == VK_PRESENT_MODE_FIFO_KHR ? "fifo" : mode == VK_PRESENT_MODE_MAILBOX_KHR ? "mailbox" : "immediate"

        if caps.currentExtent.width != UInt32.max {
            width = Int(caps.currentExtent.width)
            height = Int(caps.currentExtent.height)
        }
        guard width > 0, height > 0 else { throw GPUError.failed("window has zero size") }
        var count = caps.minImageCount + 1
        if caps.maxImageCount > 0 { count = min(count, caps.maxImageCount) }

        var ci = VkSwapchainCreateInfoKHR()
        ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        ci.surface = surface
        ci.minImageCount = count
        ci.imageFormat = chosen.format
        ci.imageColorSpace = chosen.colorSpace
        ci.imageExtent = VkExtent2D(width: UInt32(width), height: UInt32(height))
        ci.imageArrayLayers = 1
        ci.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
        ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        ci.preTransform = caps.currentTransform
        let opaque = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        ci.compositeAlpha = caps.supportedCompositeAlpha & opaque.rawValue != 0 ? opaque : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
        ci.presentMode = mode
        ci.clipped = 1
        ci.oldSwapchain = swapchain
        var sc: VkSwapchainKHR?
        try vkCheck(vkCreateSwapchainKHR(dev, &ci, nil, &sc), "vkCreateSwapchainKHR")
        if let old = swapchain { vkDestroySwapchainKHR(dev, old, nil) }
        swapchain = sc
        var n: UInt32 = 0
        vkGetSwapchainImagesKHR(dev, sc, &n, nil)
        var imgs = [VkImage?](repeating: nil, count: Int(n))
        vkGetSwapchainImagesKHR(dev, sc, &n, &imgs)
        images = imgs.compactMap { $0 }
        for sem in renderDone { vkDestroySemaphore(dev, sem, nil) }
        renderDone = try images.map { _ in try makeSemaphore() }
        outOfDate = false
    }

    /// A new buffer size (Wayland: the layer surface was configured or its scale changed). The swapchain is recreated
    /// before the next acquire.
    public func resize(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        outOfDate = true
    }

    /// Waits for the frame slot to free up, then acquires an image. nil when the surface changed size (the swapchain is
    /// recreated and the caller skips presenting this frame).
    public func nextDrawable() throws -> VulkanDrawable? {
        let slot = frame % framesInFlight
        slotBuffers[slot]?.waitUntilCompleted()
        slotBuffers[slot] = nil
        if outOfDate {
            for cb in slotBuffers { cb?.waitUntilCompleted() }
            owner.waitIdle()
            try create()
        }
        var index: UInt32 = 0
        let r = vkAcquireNextImageKHR(owner.device, swapchain, UInt64.max, acquireSemaphores[slot], nil, &index)
        if r == VK_ERROR_OUT_OF_DATE_KHR {
            outOfDate = true
            return nil
        }
        if r == VK_SUBOPTIMAL_KHR { outOfDate = true } else { try vkCheck(r, "vkAcquireNextImageKHR") }
        frame += 1
        return VulkanDrawable(swapchain: self, slot: slot, index: index, image: images[Int(index)], acquired: acquireSemaphores[slot],
                              renderDone: renderDone[Int(index)])
    }

    /// Called right after the frame's submission (queue lock held).
    func present(_ d: VulkanDrawable, after cb: VulkanCommandBuffer) {
        slotBuffers[d.slot] = cb
        var pi = VkPresentInfoKHR()
        pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
        var wait: VkSemaphore? = d.renderDone
        var sc: VkSwapchainKHR? = swapchain
        var index = d.index
        let r = withUnsafePointer(to: &wait) { wp in
            withUnsafePointer(to: &sc) { sp in
                withUnsafePointer(to: &index) { ip -> VkResult in
                    pi.waitSemaphoreCount = 1
                    pi.pWaitSemaphores = wp
                    pi.swapchainCount = 1
                    pi.pSwapchains = sp
                    pi.pImageIndices = ip
                    return vkQueuePresentKHR(owner.queue, &pi)
                }
            }
        }
        if r == VK_ERROR_OUT_OF_DATE_KHR || r == VK_SUBOPTIMAL_KHR { outOfDate = true } else if r != VK_SUCCESS {
            NSLog("photon: vkQueuePresentKHR failed: %d", r.rawValue)
        }
    }
}

/// One acquired swapchain image (CAMetalDrawable's role).
public final class VulkanDrawable: GPUDrawable {
    let swapchain: VulkanSwapchain
    let slot: Int
    let index: UInt32
    let image: VkImage
    let acquired: VkSemaphore
    let renderDone: VkSemaphore
    public var width: Int { swapchain.width }
    public var height: Int { swapchain.height }
    var format: VkFormat { swapchain.format }

    init(swapchain: VulkanSwapchain, slot: Int, index: UInt32, image: VkImage, acquired: VkSemaphore, renderDone: VkSemaphore) {
        self.swapchain = swapchain
        self.slot = slot
        self.index = index
        self.image = image
        self.acquired = acquired
        self.renderDone = renderDone
    }

    func present(after cb: VulkanCommandBuffer) { swapchain.present(self, after: cb) }
}
