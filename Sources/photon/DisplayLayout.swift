import AppKit
import Metal
import MetalKit
import PhotonApp
import PhotonHost

/// Multi-display layouts (docs/re/09 §8.2, §8.3). The engine's wallpaperconfig `layout` (0x14006a574 → 0x1404e52e0) is
/// 0 = a wallpaper per display, 1 = "Stretch single wallpaper", 2 = "Clone single wallpaper" (UI `W.layouts`); with 0 the
/// profile's `groups` make stretch and clone groups of some displays and `splits` cut a display in regions. Which record
/// shows what is `LayoutPlan` (PhotonApp/MonitorLayout.swift, `Layout_Compute` 0x1400740d0).
///
/// - Stretch (layout 1, a stretch group): one wallpaper instance covers the bounding rectangle of its displays (the
///   union, 0x140074257 / 0x1400624d0); each display shows its own part of it, so the scene's alignment/fit applies to the
///   whole box.
/// - Clone (layout 2, a clone group): the wallpaper renders on the source display (the profile's `source`, or the size /
///   orientation rule); the other displays get no wallpaper of their own (`App_LoadDesktopWallpaper` 0x14007344a skips
///   them) and show a `CreateClone` of the source window (cloneextensions64 0x180007090): the source scaled to cover the
///   target (aspect kept, centred, cropped), mirrored when the display's `flip` is set.
/// - Pause rules with layout 1 or 2 pause only when every display is covered (0x14006d103, PlaybackEvaluator).
///
/// photon2 renders each shared instance once per frame on its host display into a texture (`frames`, keyed by the
/// instance's wallpaper key) and every member display samples its tile from it. Web wallpapers stay per display.
/// - Splits (`splits`, `Layout_ApplySplit` 0x140061280): every region is a wallpaper instance of its own (keyed
///   `<display>/L`, `<display>/R`, …) with a window over its rectangle in the engine. photon2 renders each region's scene
///   into a frame of the region's size and the display composes its regions (`compose`); a region that is a member of
///   a stretch / clone group samples the group's frame. Web pages in regions are web views over the region.
final class LayoutCompositor {
    let device: MTLDevice
    private var frames: [String: MTLTexture] = [:]
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var composePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let library: MTLLibrary
    private let sampler: MTLSamplerState

    init(device: MTLDevice) {
        self.device = device
        library = try! device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V layoutV(uint i [[vertex_id]], constant float4 &r [[buffer(0)]]) {
            float2 uv = float2((i << 1) & 2, i & 2);
            V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = r.xy + uv * r.zw; return o;
        }
        fragment float4 layoutF(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
            return t.sample(s, in.uv);
        }
        // mode 1: extended-linear fp16 → sRGB-encoded 8-bit; 2: sRGB-encoded 8-bit → linear fp16.
        fragment float4 composeF(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                                 constant int &mode [[buffer(0)]]) {
            float4 c = t.sample(s, in.uv);
            if (mode == 1) {
                float3 x = saturate(c.rgb);
                c.rgb = select(1.055 * pow(x, 1.0 / 2.4) - 0.055, 12.92 * x, x <= 0.0031308);
            } else if (mode == 2) {
                float3 x = c.rgb;
                c.rgb = select(pow((x + 0.055) / 1.055, 2.4), x / 12.92, x <= 0.04045);
            }
            return float4(c.rgb, 1);
        }
        """, options: nil)
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: d)!
    }

    /// Display rectangles in global top-left points (CGDisplayBounds), `NSScreen.screens` order.
    static func displayRects() -> [(id: CGDirectDisplayID, rect: CGRect, scale: CGFloat)] {
        NSScreen.screens.map { ($0.displayID, CGDisplayBounds($0.displayID), $0.backingScaleFactor) }
    }

    /// The displays as `LayoutPlan` monitors: display key, global rectangle in points, backing scale.
    static func monitors() -> [LayoutPlan.Monitor] {
        displayRects().map { LayoutPlan.Monitor(key: DisplayInfo.key(for: $0.id), rect: $0.rect, scale: $0.scale) }
    }

    /// Bounding box of every display and each display's part of it as a UV rectangle (origin, size; y down).
    static func spanRegions(_ rects: [(id: CGDirectDisplayID, rect: CGRect, scale: CGFloat)]) -> (box: CGRect, uv: [CGDirectDisplayID: CGRect]) {
        LayoutGeometry.spanRegions(rects)
    }

    /// Cover fit of a source with aspect `src` (w/h) onto a target with aspect `dst` (LayoutGeometry, PhotonApp).
    static func coverUV(source src: CGFloat, target dst: CGFloat) -> CGRect {
        LayoutGeometry.coverUV(source: src, target: dst)
    }

    /// Pixel size of an instance's frame: stretch = its box at the smallest backing scale of its displays (clamped to
    /// 16384), clone = the source display's drawable.
    func targetSize(_ instance: LayoutPlan.Instance, sourceDrawable: CGSize) -> CGSize {
        instance.kind == .span ? instance.pixelSize : sourceDrawable
    }

    /// The frame the host display renders `key` into.
    func target(_ key: String, size: CGSize, format: MTLPixelFormat) -> MTLTexture? {
        let w = Int(size.width), h = Int(size.height)
        if let f = frames[key], f.width == w, f.height == h, f.pixelFormat == format { return f }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        frames[key] = device.makeTexture(descriptor: d)
        return frames[key]
    }

    func hasFrame(_ key: String) -> Bool { frames[key] != nil }
    func frameFormat(_ key: String) -> MTLPixelFormat? { frames[key]?.pixelFormat }
    var frameKeys: Set<String> { Set(frames.keys) }

    /// Frees frames no instance uses any more (up to 16384² fp16 each).
    func release(keeping keys: Set<String>) { frames = frames.filter { keys.contains($0.key) } }
    func releaseAll() { frames.removeAll() }

    /// Cursor in the instance frame's UV space (y down): global position relative to the instance's rectangle.
    func pointer(_ instance: LayoutPlan.Instance) -> CGPoint? {
        let p = NSEvent.mouseLocation
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        let box = instance.rect
        guard box.width > 0, box.height > 0 else { return nil }
        return CGPoint(x: (p.x - box.minX) / box.width, y: ((mainH - p.y) - box.minY) / box.height)
    }

    /// Draws a display's tile of an instance frame into its drawable: the tile's source rectangle over the whole display.
    /// A flipped clone target (profile `monitorconfig.<monitor>.flip`, monitor record +0x53 bit 2) is mirrored: `CreateClone`
    /// negates the composition transform's x scale (0x1800072fb) and offsets x by the target width (0x180007311–0x180007328).
    func present(_ view: MTKView, tile: LayoutPlan.Tile, commandBuffer: MTLCommandBuffer) {
        guard let src = frames[tile.instance], let drawable = view.currentDrawable else { return }
        let r = tile.source
        var rect = SIMD4<Float>(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        if tile.flip { rect = SIMD4(Float(r.maxX), Float(r.minY), -Float(r.width), Float(r.height)) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass), let p = pipeline(drawable.texture.pixelFormat) else { return }
        e.setRenderPipelineState(p)
        e.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        e.setFragmentTexture(src, index: 0)
        e.setFragmentSamplerState(sampler, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        commandBuffer.present(drawable)
    }

    /// A display with split regions: each tile's frame (its source rectangle, mirrored when flipped) into the tile's
    /// target rectangle of the drawable; black where a region has no frame yet (loading, or a web page drawn by a view
    /// over it). A frame in another format than the drawable (an 8-bit sRGB region on an EDR display, or the reverse) is
    /// converted.
    func compose(_ view: MTKView, tiles: [LayoutPlan.Tile], commandBuffer: MTLCommandBuffer) {
        guard let drawable = view.currentDrawable else { return }
        let dst = drawable.texture
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: pass), let p = composePipeline(dst.pixelFormat) else { return }
        e.setRenderPipelineState(p)
        e.setFragmentSamplerState(sampler, index: 0)
        let W = Double(dst.width), H = Double(dst.height)
        for t in tiles {
            guard let src = frames[t.instance] else { continue }
            let x0 = (t.target.minX * W).rounded(), y0 = (t.target.minY * H).rounded()
            let x1 = (t.target.maxX * W).rounded(), y1 = (t.target.maxY * H).rounded()
            guard x1 > x0, y1 > y0 else { continue }
            e.setViewport(MTLViewport(originX: x0, originY: y0, width: x1 - x0, height: y1 - y0, znear: 0, zfar: 1))
            let r = t.source
            var rect = SIMD4<Float>(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
            if t.flip { rect = SIMD4(Float(r.maxX), Float(r.minY), -Float(r.width), Float(r.height)) }
            var mode: Int32 = src.pixelFormat == dst.pixelFormat ? 0 : (src.pixelFormat == .rgba16Float ? 1 : 2)
            e.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 0)
            e.setFragmentTexture(src, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        e.endEncoding()
        commandBuffer.present(drawable)
    }

    private func composePipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = composePipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "layoutV")
        d.fragmentFunction = library.makeFunction(name: "composeF")
        d.colorAttachments[0].pixelFormat = format
        let p = try? device.makeRenderPipelineState(descriptor: d)
        composePipelines[format] = p
        return p
    }

    private func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "layoutV")
        d.fragmentFunction = library.makeFunction(name: "layoutF")
        d.colorAttachments[0].pixelFormat = format
        let p = try? device.makeRenderPipelineState(descriptor: d)
        pipelines[format] = p
        return p
    }
}
