import Foundation
import Metal
import PhotonCore

/// The engine's `msaa` setting (docs/re/09 §8.1).
///
/// - Config (`Project_Prescan` 0x14010ecb1 and 0x14010f08f): `msaa` "x2" → 1, "x4" → 2, "x8" → 3, anything else 0, into
///   the wallpaper's device params W+0x240. The settings default is "x2" (0x140047248).
/// - Gate: the device is created with W+0x240 only when W+0x1b8 bit 0x100 is set, else 0 (`cmove eax, r12d`, r12 = 0,
///   0x140110881 and 0x140110e63). The prescan sets that bit when an entry of the scene's `objects` array has a non-null
///   `model` key (0x14010e777–0x14010e7c7). So only scenes with 3D model objects are multisampled.
/// - Device (`Device_Create` 0x14012ac60, 0x14012b6ab–0x14012b735): level 1/2/3/4 → sample count 2/4/8/16, quality
///   D3D11_STANDARD_MULTISAMPLE_PATTERN when the device flag allows it; `CheckMultisampleQualityLevels` (vt+0xf0) failing
///   or returning 0 drops back to 1 sample and level 0. The swap chain itself is single-sampled (SampleDesc 1, 0).
/// - Target (`Renderer_SceneLoaded` 0x140181dcc–0x140181e49): with MSAA, `_rt_FullFrameBufferMultiSampled` at scene size,
///   colour format HDR ? 0xF (rgb161616f) : 1, depth 0x18 (D32), flags 0x20 (multisampled) and sampler flags 2; without,
///   the target is released.
/// - Use (`Scene_DrawObjects` 0x140183550): pass 0 binds the MSAA target (vt+0x48), clears colour and depth when
///   `clearenabled`, draws the list, unbinds, and resolves it into the back buffer (RT vt+0x10). The reflection pass
///   (pass 1), layer composites, effect FBOs and the post chain stay single-sampled; copies of a multisampled target
///   (`_rt_FullFrameBuffer` snapshots inside the pass, RT vt+8 0x1400d3310) are ResolveSubresource.
public final class Multisample {
    /// Requested sample count from the setting ("x2"/"x4"/"x8"; "none"/"disabled"/other → 1).
    public static var setting: String = ProcessInfo.processInfo.environment["PHOTON_MSAA"] ?? "x2"

    static func sampleCount(setting: String, device: MTLDevice) -> Int {
        let level: Int
        switch setting { case "x2": level = 1; case "x4": level = 2; case "x8": level = 3; default: level = 0 }
        var n = level == 0 ? 1 : 1 << level
        // CheckMultisampleQualityLevels: an unsupported count falls back to 1 (the engine does not try a lower one).
        if !device.supportsTextureSampleCount(n) { n = 1 }
        return n
    }

    /// 0x14010e777–0x14010e7c7: an object with a non-null `model`.
    static func sceneHasModel(_ scene: [String: Any]) -> Bool {
        ((scene["objects"] as? [[String: Any]]) ?? []).contains { o in
            guard let m = o["model"] else { return false }
            return !(m is NSNull)
        }
    }

    var sceneHasModel = false
    private var color: MTLTexture?
    private var depth: MTLTexture?
    private var savedBackBuffer: MTLTexture?
    private var savedDepth: MTLTexture?

    var activeSampleCount: Int = 1

    /// Binds the multisampled scene target in place of the back buffer for the main pass.
    func begin(_ ctx: RenderContext, device: MTLDevice) {
        let n = sceneHasModel ? Self.sampleCount(setting: Self.setting, device: device) : 1
        activeSampleCount = n
        guard n > 1 else { color = nil; depth = nil; return }
        let back = ctx.backBuffer
        if color == nil || color!.width != back.width || color!.height != back.height || color!.pixelFormat != back.pixelFormat
            || color!.sampleCount != n {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: back.pixelFormat, width: back.width, height: back.height, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = n
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            color = device.makeTexture(descriptor: d)
            let z = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: back.width, height: back.height, mipmapped: false)
            z.textureType = .type2DMultisample
            z.sampleCount = n
            z.usage = [.renderTarget, .shaderRead]
            z.storageMode = .private
            depth = device.makeTexture(descriptor: z)
        }
        guard let color else { return }
        savedBackBuffer = back
        savedDepth = ctx.depth
        ctx.replaceBackBuffer(color, depth: ctx.depth == nil ? nil : depth)
    }

    /// Unbinds and resolves into the real back buffer (RT vt+0x10).
    func end(_ ctx: RenderContext) {
        guard let back = savedBackBuffer, let color else { return }
        ctx.replaceBackBuffer(back, depth: savedDepth)
        savedBackBuffer = nil
        savedDepth = nil
        Self.resolve(color, into: back, commandBuffer: ctx.commandBuffer, device: ctx.device)
    }

    /// Single-sampled resolve targets by MSAA source. The source is held weakly: a scene's MSAA target goes with the
    /// scene, and its entry (a full-size texture) is dropped on the next insert instead of living forever.
    private struct Scratch { weak var source: MTLTexture?; let texture: MTLTexture }
    private static var scratch: [ObjectIdentifier: Scratch] = [:]
    private static let lock = NSLock()
    static var scratchCount: Int { lock.withLock { scratch.values.filter { $0.source != nil }.count } }

    /// ResolveSubresource: box-filters the samples into `dst`. A destination of another size or format goes through
    /// a single-sampled scratch texture and the blitter.
    static func resolve(_ src: MTLTexture, into dst: MTLTexture, commandBuffer: MTLCommandBuffer, device: MTLDevice) {
        var target = dst
        let direct = src.width == dst.width && src.height == dst.height && src.pixelFormat == dst.pixelFormat
            && dst.usage.contains(.renderTarget) && dst.mipmapLevelCount == 1
        if !direct {
            let key = ObjectIdentifier(src)
            target = lock.withLock {
                if let e = scratch[key], e.source === src, e.texture.width == src.width, e.texture.height == src.height,
                   e.texture.pixelFormat == src.pixelFormat { return e.texture }
                scratch = scratch.filter { $0.value.source != nil && $0.key != key }
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                let t = device.makeTexture(descriptor: d)!
                scratch[key] = Scratch(source: src, texture: t)
                return t
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = src
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
        pass.colorAttachments[0].resolveTexture = target
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        if !direct {
            if dst.mipmapLevelCount > 1, dst.width == target.width, dst.height == target.height, dst.pixelFormat == target.pixelFormat {
                let blit = commandBuffer.makeBlitCommandEncoder()!
                blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, to: dst, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
                blit.endEncoding()
            } else {
                Blitter.shared(device).draw(target, into: dst, commandBuffer: commandBuffer)
            }
        }
    }
}
