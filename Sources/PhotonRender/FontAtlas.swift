import CoreGraphics
import CoreText
import Foundation
import Metal
import PhotonCore

/// Font resolution and glyph atlases for text objects (docs/re/04 §4.3, §4.3.1).
///
/// The engine rasterises with FreeType, shapes with HarfBuzz and packs glyphs into shared atlas textures
/// (`__font_atlas_<font>_<size*64>`, R8, and `__font_atlas_color_…` for colour glyphs). Here CoreText does the
/// shaping, fallback and rasterisation; the atlas layout and the vertex data follow the engine.
final class FontLibrary {
    /// `systemfont_*` aliases (string table 0x14048ef08, index order of `Text_Rebuild` 0x140256f20) mapped to the
    /// Windows file and the macOS face used in its place.
    static let systemFonts: [String: (file: String, mac: [String])] = [
        "systemfont_arial": ("arial.ttf", ["ArialMT"]),
        "systemfont_calibri": ("calibri.ttf", ["Calibri", "HelveticaNeue"]),
        "systemfont_cambria": ("cambria.ttc", ["Cambria", "Georgia"]),
        "systemfont_comicsans": ("comic.ttf", ["ComicSansMS"]),
        "systemfont_consolas": ("consola.ttf", ["Consolas", "Menlo-Regular"]),
        "systemfont_sansserif": ("micross.ttf", ["MicrosoftSansSerif", "ArialMT"]),
        "systemfont_segoe": ("segoeui.ttf", ["SegoeUI", "HelveticaNeue"]),
        "systemfont_verdana": ("verdana.ttf", ["Verdana"]),
    ]

    private let fs: AssetFileSystem
    private var graphicsFonts: [String: CGFont] = [:]
    private var missing = Set<String>()
    let atlas: GlyphAtlas

    init(device: MTLDevice, fs: AssetFileSystem) {
        self.fs = fs
        atlas = GlyphAtlas(device: device)
    }

    /// One library per scene. Keyed weakly by the scene's resources.
    private static let libraries = NSMapTable<SceneResources, FontLibrary>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func shared(_ resources: SceneResources) -> FontLibrary {
        if let lib = libraries.object(forKey: resources) { return lib }
        let lib = FontLibrary(device: resources.device, fs: resources.fs)
        libraries.setObject(lib, forKey: resources)
        return lib
    }

    /// The CTFont for a `font` value at `pixelSize` (the engine's 26.6 char size `pt*64` at 300 dpi). A font that fails to load falls back to arial (0x1401ad549).
    func font(_ name: String, pixelSize: CGFloat) -> CTFont {
        if let sys = Self.systemFonts[name.lowercased()] {
            for mac in sys.mac {
                let f = CTFontCreateWithName(mac as CFString, pixelSize, nil)
                if (CTFontCopyPostScriptName(f) as String) == mac { return f }
            }
            return CTFontCreateWithName("ArialMT" as CFString, pixelSize, nil)
        }
        if let cg = graphicsFont(name) { return CTFontCreateWithGraphicsFont(cg, pixelSize, nil, nil) }
        return CTFontCreateWithName("ArialMT" as CFString, pixelSize, nil)
    }

    private func graphicsFont(_ path: String) -> CGFont? {
        if let f = graphicsFonts[path] { return f }
        guard !missing.contains(path) else { return nil }
        var font: CGFont?
        if let data = fs.read(path), let provider = CGDataProvider(data: data as CFData) {
            font = CGFont(provider)
        }
        guard let font else {
            missing.insert(path)
            NSLog("photon: font %@ not found, using arial", path)
            return nil
        }
        graphicsFonts[path] = font
        return font
    }
}

/// A glyph placed in an atlas. The box is in pixels relative to the pen position on the baseline (y up), as
/// FreeType's `bitmap_left`, `bitmap_top - rows`, … The quad is the box grown by `pad` on every side.
struct AtlasGlyph {
    var x0: Float, y0: Float, x1: Float, y1: Float
    var pad: Float
    var color: Bool
    /// Placed in the MSDF page (msdfgen field, `Font_AddGlyph` 0x1401aefe2–0x1401af853).
    var msdf = false
    /// Pixel rect in the atlas including padding.
    var rect: (x: Int, y: Int, w: Int, h: Int)
    var empty: Bool { x1 <= x0 || y1 <= y0 }
}

/// Shelf-packed glyph atlases: one R8 page for outline glyphs and one RGBA page for colour glyphs (emoji).
final class GlyphAtlas {
    final class Page {
        let bytesPerPixel: Int
        var width: Int, height: Int
        var pixels: [UInt8]
        var shelfY = 0, shelfH = 0, cursorX = 0
        var texture: MTLTexture?
        var dirty = true
        /// Bumped when the page grows; UVs built against an older size must be rebuilt.
        var generation = 0

        init(bytesPerPixel: Int, size: Int) {
            self.bytesPerPixel = bytesPerPixel
            width = size; height = size / 4
            pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        }

        func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
            guard w <= width, h <= 4096 else { return nil }
            if cursorX + w > width { shelfY += shelfH; shelfH = 0; cursorX = 0 }
            if shelfY + h > height {
                guard height < 4096 else { return nil }
                grow()
                return allocate(w, h)
            }
            let p = (cursorX, shelfY)
            cursorX += w + 1
            shelfH = max(shelfH, h + 1)
            return p
        }

        /// Doubles the height, keeping existing rows (UVs scale in v only, so callers rebuild meshes).
        private func grow() {
            let newH = height * 2
            pixels += [UInt8](repeating: 0, count: width * (newH - height) * bytesPerPixel)
            height = newH
            texture = nil
            generation += 1
            dirty = true
        }

        func gpuTexture(_ device: MTLDevice) -> MTLTexture? {
            if texture == nil {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bytesPerPixel == 1 ? .r8Unorm : .rgba8Unorm,
                                                                 width: width, height: height, mipmapped: false)
                d.usage = .shaderRead
                d.storageMode = .shared
                texture = device.makeTexture(descriptor: d)
                texture?.label = bytesPerPixel == 1 ? "__font_atlas_" : "__font_atlas_color_"
                dirty = true
            }
            if dirty, let t = texture {
                pixels.withUnsafeBytes { raw in
                    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                              withBytes: raw.baseAddress!, bytesPerRow: width * bytesPerPixel)
                }
                dirty = false
            }
            return texture
        }
    }

    let device: MTLDevice
    let gray = Page(bytesPerPixel: 1, size: 2048)
    let color = Page(bytesPerPixel: 4, size: 1024)
    /// `__font_atlas_<font>_msdf`: RGBA pages (`FontAtlas_Create` 0x1401ac8d0 uses 4 bytes per pixel when msdf).
    let msdfPage = Page(bytesPerPixel: 4, size: 2048)
    private var glyphs: [GlyphKey: AtlasGlyph] = [:]
    private var sampler: MTLSamplerState

    struct GlyphKey: Hashable {
        let font: String
        let glyph: CGGlyph
    }

    init(device: MTLDevice) {
        self.device = device
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: d)!
    }

    static func fontKey(_ font: CTFont) -> String {
        "\(CTFontCopyPostScriptName(font) as String)|\(CTFontGetSize(font))|\(CFHash(font))"
    }

    func glyph(_ g: CGGlyph, font: CTFont, fontKey: String, msdf: Bool = false) -> AtlasGlyph {
        let key = GlyphKey(font: msdf ? fontKey + "_msdf" : fontKey, glyph: g)
        if let hit = glyphs[key] { return hit }
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        if msdf {
            let e = isColor ? colorMsdfGlyph(g, font: font) : msdfGlyph(g, font: font)
            glyphs[key] = e
            return e
        }
        var glyph = g
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        let pad = 1
        var entry = AtlasGlyph(x0: 0, y0: 0, x1: 0, y1: 0, pad: Float(pad), color: isColor, rect: (0, 0, 0, 0))
        if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
            let x0 = floor(bounds.minX), x1 = ceil(bounds.maxX), y0 = floor(bounds.minY), y1 = ceil(bounds.maxY)
            let w = Int(x1 - x0) + 2 * pad, h = Int(y1 - y0) + 2 * pad
            let page = isColor ? color : gray
            if let (px, py) = page.allocate(w, h) {
                rasterize(glyph, font: font, origin: CGPoint(x: -x0 + CGFloat(pad), y: -y0 + CGFloat(pad)),
                          w: w, h: h, into: page, at: (px, py))
                entry = AtlasGlyph(x0: Float(x0), y0: Float(y0), x1: Float(x1), y1: Float(y1), pad: Float(pad), color: isColor,
                                   rect: (px, py, w, h))
            }
        }
        glyphs[key] = entry
        return entry
    }

    /// MSDF glyph (`Font_AddGlyph` 0x1401ae4b6–0x1401ae546, 0x1401af405–0x1401af82c): the box is the pixel bounds at
    /// the layout size; the field is drawn at 32 px per em: Wa = max(1, (int)(bw·32/ppem)), Ha likewise, bitmap
    /// (Wa + 24) × (Ha + 24), scale = max(Wa, Ha) / max(bw, bh), translate = 12/scale − (x0, y0), range = 24/scale
    /// (msdfgen units), bytes = clamp((int)(v·256), 0, 255), alpha 255, rows top-down. The layout pads the quad by
    /// ppem·12/32 (`TextLayout_Build` 0x1401b120c–0x1401b1238).
    private func msdfGlyph(_ g: CGGlyph, font: CTFont) -> AtlasGlyph {
        var glyph = g
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        let ppem = max(1, Int(CTFontGetSize(font).rounded()))
        let pad = Float(ppem) * 12 * 0.03125
        var entry = AtlasGlyph(x0: 0, y0: 0, x1: 0, y1: 0, pad: pad, color: false, msdf: true, rect: (0, 0, 0, 0))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, let path = CTFontCreatePathForGlyph(font, g, nil) else { return entry }
        let x0 = Int(floor(bounds.minX)), x1 = Int(ceil(bounds.maxX)), y0 = Int(floor(bounds.minY)), y1 = Int(ceil(bounds.maxY))
        let bw = x1 - x0, bh = y1 - y0
        let k = Float(32) / Float(ppem)
        let wa = max(1, Int(Float(bw) * k)), ha = max(1, Int(Float(bh) * k))
        let W = wa + 24, H = ha + 24
        let scale = Float(max(wa, ha)) / Float(max(bw, bh))
        let tr = SIMD2<Double>(Double(12 / scale - Float(x0)), Double(12 / scale - Float(y0)))
        let field = MsdfGen.generate(path: path, width: W, height: H, scale: Double(scale), translate: tr, range: Double(24 / scale))
        guard field.count == W * H * 3, let (px, py) = msdfPage.allocate(W, H) else { return entry }
        for y in 0..<H {
            let src = (H - 1 - y) * W * 3
            var dst = ((py + y) * msdfPage.width + px) * 4
            for x in 0..<W {
                for c in 0..<3 {
                    let v = Int(field[src + x * 3 + c] * 256)
                    msdfPage.pixels[dst + c] = UInt8(min(max(v, 0), 255))
                }
                msdfPage.pixels[dst + 3] = 255
                dst += 4
            }
        }
        msdfPage.dirty = true
        entry = AtlasGlyph(x0: Float(x0), y0: Float(y0), x1: Float(x1), y1: Float(y1), pad: pad, color: false, msdf: true, rect: (px, py, W, H))
        return entry
    }

    /// A colour (bitmap) glyph in an MSDF text: same box, scale, translate and range as `msdfGlyph`, but the field is
    /// `MsdfGen.bitmapField` of the glyph bitmap's alpha (`Glyph_BitmapSDF` 0x1401ab9c0, caller 0x1401af6ae–0x1401af82c:
    /// four float channels, bytes clamp((int)(v·256)) in all of R, G, B **and A**, rows flipped). The glyph lands in the
    /// MSDF page and draws in the text colour. The bitmap is CoreText's colour rendering at the layout size over the
    /// glyph's pixel bounds (FreeType's `FT_BitmapGlyph` at the same size: left = x0, top = y1).
    private func colorMsdfGlyph(_ g: CGGlyph, font: CTFont) -> AtlasGlyph {
        var glyph = g
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        let ppem = max(1, Int(CTFontGetSize(font).rounded()))
        let pad = Float(ppem) * 12 * 0.03125
        var entry = AtlasGlyph(x0: 0, y0: 0, x1: 0, y1: 0, pad: pad, color: false, msdf: true, rect: (0, 0, 0, 0))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return entry }
        let x0 = Int(floor(bounds.minX)), x1 = Int(ceil(bounds.maxX)), y0 = Int(floor(bounds.minY)), y1 = Int(ceil(bounds.maxY))
        let bw = x1 - x0, bh = y1 - y0
        let k = Float(32) / Float(ppem)
        let wa = max(1, Int(Float(bw) * k)), ha = max(1, Int(Float(bh) * k))
        let W = wa + 24, H = ha + 24
        let scale = Float(max(wa, ha)) / Float(max(bw, bh))
        let tr = SIMD2<Double>(Double(12 / scale - Float(x0)), Double(12 / scale - Float(y0)))
        var rgba = [UInt8](repeating: 0, count: bw * bh * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            var pos = CGPoint(x: -x0, y: -y0)
            CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx)
        }
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } // CG row 0 = top row, like FreeType
        let field = MsdfGen.bitmapField(alpha: alpha, bitmapWidth: bw, bitmapHeight: bh, left: x0, top: y1, width: W, height: H,
                                        scale: Double(scale), translate: tr, range: 24 / scale)
        guard field.count == W * H, let (px, py) = msdfPage.allocate(W, H) else { return entry }
        for y in 0..<H {
            let src = (H - 1 - y) * W
            var dst = ((py + y) * msdfPage.width + px) * 4
            for x in 0..<W {
                let b = UInt8(min(max(Int(field[src + x] * 256), 0), 255))
                for c in 0..<4 { msdfPage.pixels[dst + c] = b }
                dst += 4
            }
        }
        msdfPage.dirty = true
        entry = AtlasGlyph(x0: Float(x0), y0: Float(y0), x1: Float(x1), y1: Float(y1), pad: pad, color: false, msdf: true, rect: (px, py, W, H))
        return entry
    }

    private func rasterize(_ g: CGGlyph, font: CTFont, origin: CGPoint, w: Int, h: Int, into page: Page, at p: (Int, Int)) {
        var glyph = g
        var pos = origin
        if page.bytesPerPixel == 1 {
            var buf = [UInt8](repeating: 0, count: w * h)
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.setAllowsFontSmoothing(false)
                ctx.setShouldSmoothFonts(false)
                ctx.setShouldAntialias(true)
                ctx.setFillColor(gray: 1, alpha: 1)
                CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx)
            }
            // CG bitmap row 0 is the top row, as in the atlas texture.
            for row in 0..<h {
                let dst = (p.1 + row) * page.width + p.0
                page.pixels.replaceSubrange(dst..<(dst + w), with: buf[(row * w)..<(row * w + w)])
            }
        } else {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx)
            }
            // The COLORFONT shader blends straight alpha.
            for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] > 0 && buf[i + 3] < 255 {
                let a = Float(buf[i + 3]) / 255
                for c in 0..<3 { buf[i + c] = UInt8(min(255, Float(buf[i + c]) / a + 0.5)) }
            }
            for row in 0..<h {
                let dst = ((p.1 + row) * page.width + p.0) * 4
                page.pixels.replaceSubrange(dst..<(dst + w * 4), with: buf[(row * w * 4)..<((row + 1) * w * 4)])
            }
        }
        page.dirty = true
    }

    func bound(_ page: Page) -> BoundTexture? {
        guard let t = page.gpuTexture(device) else { return nil }
        let w = Float(t.width), h = Float(t.height)
        return BoundTexture(texture: t, sampler: sampler, resolution: SIMD4(w, h, w, h))
    }
}

extension BoundTexture {
    /// A texture that is not a `.tex` file or render target (glyph atlases).
    init(texture: MTLTexture, sampler: MTLSamplerState, resolution: SIMD4<Float>) {
        self.texture = texture
        self.sampler = sampler
        self.resolution = resolution
        gpu = nil
    }
}
