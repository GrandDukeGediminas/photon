import Foundation
import Metal
import PhotonCore

/// An offscreen target (docs/re/03 §6). Actual size is `max(2, requested / scale)`.
public final class RenderTarget {
    public let name: String
    public private(set) var requestedWidth: Int
    public private(set) var requestedHeight: Int
    public let scale: Int
    public let format: MTLPixelFormat
    public private(set) var texture: MTLTexture
    public let sampler: MTLSamplerState
    /// Full mip chain (`_rt_MipMappedFrameBuffer`, created with flag 0x10 at 0x140181cec).
    public let mipmapped: Bool
    var refCount = 0

    init(device: MTLDevice, name: String, width: Int, height: Int, scale: Int, format: MTLPixelFormat, sampler: MTLSamplerState,
         mipmapped: Bool = false) {
        self.mipmapped = mipmapped
        self.name = name
        self.requestedWidth = width
        self.requestedHeight = height
        self.scale = max(scale, 1)
        self.format = format
        self.sampler = sampler
        self.texture = Self.makeTexture(device: device, name: name, w: max(2, width / max(scale, 1)), h: max(2, height / max(scale, 1)), format: format,
                                        mipmapped: mipmapped)
    }

    public var width: Int { texture.width }
    public var height: Int { texture.height }

    /// `RT_Resize` (0x140161f40)
    func resize(device: MTLDevice, width: Int, height: Int) {
        guard width != requestedWidth || height != requestedHeight else { return }
        requestedWidth = width
        requestedHeight = height
        texture = Self.makeTexture(device: device, name: name, w: max(2, width / scale), h: max(2, height / scale), format: format,
                                   mipmapped: mipmapped)
        RenderTargetManager.markFresh(texture)
    }

    static func makeTexture(device: MTLDevice, name: String, w: Int, h: Int, format: MTLPixelFormat, mipmapped: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = name
        return t
    }
}

/// Named, refcounted render targets shared across layers (`RT_Find`/`RT_Create`/`RT_AcquireShared`).
public final class RenderTargetManager {
    /// Textures created since the last frame. D3D11 zero-fills new textures; Metal leaves garbage, which
    /// feedback effects (motion blur) would read, so these are cleared to transparent black first.
    /// Scenes can load on a background thread while another renders, so access is locked.
    private static var fresh: [MTLTexture] = []
    private static let freshLock = NSLock()
    static func markFresh(_ t: MTLTexture) { freshLock.withLock { fresh.append(t) } }
    static var hasFresh: Bool { freshLock.withLock { !fresh.isEmpty } }
    static func takeFresh() -> [MTLTexture] { freshLock.withLock { defer { fresh.removeAll() }; return fresh } }

    let device: MTLDevice
    private(set) var targets: [String: RenderTarget] = [:]
    private var samplers: [Int: MTLSamplerState] = [:]

    init(device: MTLDevice) { self.device = device }

    public func find(_ name: String) -> RenderTarget? { targets[name] }

    /// Sampler flags as in docs/re/01 §3.4: bit0 point filtering, bit1 clamp. Bit 4 (photon2's own) enables
    /// linear mip filtering for mipmapped targets.
    func sampler(flags: Int) -> MTLSamplerState {
        if let s = samplers[flags] { return s }
        let d = MTLSamplerDescriptor()
        if flags & 0x10 != 0 { d.mipFilter = .linear }
        let point = flags & 1 != 0
        d.minFilter = point ? .nearest : .linear
        d.magFilter = point ? .nearest : .linear
        let mode: MTLSamplerAddressMode = flags & 2 != 0 ? .clampToEdge : .repeat
        d.sAddressMode = mode; d.tAddressMode = mode
        let s = device.makeSamplerState(descriptor: d)!
        samplers[flags] = s
        return s
    }

    public func acquire(_ name: String, width: Int, height: Int, scale: Int = 1, format: MTLPixelFormat, samplerFlags: Int,
                        mipmapped: Bool = false) -> RenderTarget {
        if let rt = targets[name] {
            rt.refCount += 1
            return rt
        }
        let rt = RenderTarget(device: device, name: name, width: width, height: height, scale: scale, format: format,
                              sampler: sampler(flags: samplerFlags | (mipmapped ? 0x10 : 0)), mipmapped: mipmapped)
        rt.refCount = 1
        targets[name] = rt
        Self.markFresh(rt.texture)
        return rt
    }

    public func release(_ rt: RenderTarget) {
        rt.refCount -= 1
        if rt.refCount <= 0 { targets[rt.name] = nil }
    }
}

/// HDR scenes use rgba16f (format 0xE), otherwise rgba8888 (docs/re/03 §6 step 3).
func renderTargetFormat(hdr: Bool) -> MTLPixelFormat { hdr ? .rgba16Float : .rgba8Unorm }
