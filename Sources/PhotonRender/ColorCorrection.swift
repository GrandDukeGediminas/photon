import Foundation
import Metal
import PhotonCore

/// The wallpaper's colour options (docs/re/09 §5.1): the general properties `wec_e` (show colour options),
/// `wec_brs` (brightness), `wec_con` (contrast), `wec_sa` (saturation), `wec_hue` (hue shift) and the LUT filter
/// `wcc_v` (file name under `materials/lut/`) with `wcc_amt` (strength).
///
/// `Renderer_ApplyGeneral` 0x140181f30 reads them into the renderer (0x140182311–0x14018262f): `wec_e` → R+0x3110,
/// `wec_con`/50 → R+0x3114, `wec_brs`/50 → R+0x3118, `wec_sa`/50 → R+0x311c, `wec_hue`/100 − 0.5 → R+0x3120,
/// `wcc_v` → R+0x3128, `wcc_amt`/50 → R+0x3148. A missing key keeps the previous value; the renderer ctor sets
/// (false, 1, 1, 1, 0, "", 1) (0x14012b911–0x14012b96a).
///
/// Then (0x140182638–0x140182ea3): COL = `wec_e` and any of con/brs/sa ≠ 1 or hue ≠ 0; LUT = a LUT name is set and
/// amount > 0. Neither: no pass (R+0x3188 = null). Otherwise R+0x3188 = `materials/util/ccsimple.json` with combos
/// `{COL: 1, LUT: LUT}` or `{LUT: 1}`. With COL, `params` = (brs², √con, √sa, hue) (crt_powf 0x14041e350 with 2 and
/// 0.5). With LUT, texture slot 1 (material +0xd8) = TextureMgr_Load("lut/" + name) and `lutparams` = amount.
///
/// `Renderer_Frame` draws it last, after the bloom combine (and combine_srgb on the HDR path) and before the fade-in
/// pass R+0x3180 (0x140180bd2–0x140180c06): `_rt_FullFrameBuffer` ← current target (R+0x3098 vt+8), then ccsimple
/// with the fullscreen quad (R+0x58) into the current target.
public final class ColorCorrection {
    var enabled = false
    var contrast: Float = 1, brightness: Float = 1, saturation: Float = 1, hue: Float = 0
    var lut = ""
    var lutAmount: Float = 1

    private var material: Material?
    private var materialKey = ""
    private var intermediate: MTLTexture?
    private var srgbOut: MTLTexture?
    private var srgbOutView: MTLTexture?
    private(set) var inPass = false

    public init() {}

    /// 0x140182311–0x14018262f. Values are the UI slider units (0–100).
    public func apply(_ p: [String: Any]) {
        func value(_ k: String) -> Any? {
            let v = p[k]
            if let o = v as? [String: Any] { return o["value"] }
            return v
        }
        func num(_ k: String) -> Float? {
            let v = value(k)
            if let n = v as? NSNumber { return n.floatValue }
            return (v as? String).flatMap(Float.init)
        }
        if let b = value("wec_e") { enabled = (b as? Bool) ?? ((b as? NSNumber)?.boolValue ?? enabled) }
        if let v = num("wec_con") { contrast = v / 50 }
        if let v = num("wec_brs") { brightness = v / 50 }
        if let v = num("wec_sa") { saturation = v / 50 }
        if let v = num("wec_hue") { hue = v / 100 - 0.5 }
        if let s = value("wcc_v") as? String { lut = s }
        if let v = num("wcc_amt") { lutAmount = v / 50 }
    }

    var colorActive: Bool { enabled && (contrast != 1 || brightness != 1 || saturation != 1 || hue != 0) }
    var lutActive: Bool { !lut.isEmpty && lutAmount > 0 }
    public var isActive: Bool { colorActive || lutActive }

    func currentMaterial(_ scene: SceneRenderer) -> Material? {
        let col = colorActive, useLUT = lutActive
        guard col || useLUT else { material = nil; return nil }
        let params = "\(powf(brightness, 2)) \(powf(contrast, 0.5)) \(powf(saturation, 0.5)) \(hue)"
        let key = "\(col) \(useLUT) \(params) \(lut) \(lutAmount)"
        if key == materialKey, let material { return material }
        var override: [String: Any] = ["combos": col ? ["COL": 1, "LUT": useLUT ? 1 : 0] : ["LUT": 1]]
        var consts: [String: Any] = [:]
        if col { consts["params"] = params }
        if useLUT {
            consts["lutparams"] = lutAmount
            override["textures"] = ["_rt_FullFrameBuffer", "lut/" + lut]
        }
        override["constantshadervalues"] = consts
        material = scene.resources.material("materials/util/ccsimple.json", override: override)
        materialKey = key
        return material
    }

    /// Renders the frame into an intermediate texture (the engine's back buffer before the pass, copied to
    /// `_rt_FullFrameBuffer`), then draws ccsimple from it into `output`. Returns nil when the pass is off, so the
    /// caller renders normally.
    func render(_ scene: SceneRenderer, into output: MTLTexture, time: Double, outputSize: CGSize, pointer: CGPoint?) -> MTLCommandBuffer? {
        guard !inPass, ProcessInfo.processInfo.environment["PHOTON_SHOW"] == nil, let m = currentMaterial(scene) else { return nil }
        let device = scene.resources.device
        // The HDR path's back buffer is linear fp16 (docs/re/04 §6.2), and ccsimple's HDR combo expects linear input.
        let format: MTLPixelFormat = scene.hdr ? .rgba16Float : output.pixelFormat
        if intermediate == nil || intermediate!.width != output.width || intermediate!.height != output.height
            || intermediate!.pixelFormat != format {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: output.width, height: output.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            intermediate = device.makeTexture(descriptor: d)
        }
        guard let src = intermediate else { return nil }
        inPass = true
        let cb = scene.render(into: src, time: time, outputSize: outputSize, pointer: pointer)
        inPass = false
        guard let cb else { return nil }

        // A linear result has to be encoded for an 8-bit output, as the HDR post does (sRGB view, then blit).
        let encode = format == .rgba16Float && output.pixelFormat != .rgba16Float
        var dst = output
        if encode {
            if srgbOut == nil || srgbOut!.width != output.width || srgbOut!.height != output.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: output.width, height: output.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead, .pixelFormatView]
                d.storageMode = .private
                srgbOut = device.makeTexture(descriptor: d)
                srgbOutView = srgbOut!.makeTextureView(pixelFormat: .bgra8Unorm_srgb)
            }
            dst = srgbOutView!
        }
        let ctx = RenderContext(device: device, commandBuffer: cb, backBuffer: dst)
        ctx.errorTexture = BoundTexture(gpu: scene.resources.textures.errorTexture)
        let ident = FrameState()
        ident.screen = scene.frame.screen
        ident.proj = Mat.orthoLH(l: -1, r: 1, b: -1, t: 1, zn: -1000, zf: 1000)
        scene.drawFullscreen(m, ctx, ident, renderVar0: SIMD4(1, 1, 1, 1),
                             textures: [0: BoundTexture(texture: src, sampler: scene.fullFrameBuffer.sampler)])
        // The camera-path fade R+0x3180 comes after the colour pass (0x140180c0b follows 0x140180c06).
        scene.drawCameraFade(ctx, ident, output: dst, afterColorPass: true)
        ctx.endEncoder()
        if encode, let s = srgbOut { Blitter.shared(device).draw(s, into: output, commandBuffer: cb) }
        return cb
    }
}
