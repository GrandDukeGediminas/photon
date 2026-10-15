// Linux stand-in for Apple's CoreText (docs/linux-port.md §4), over FreeType + fontconfig + HarfBuzz: the subset
// FontAtlas.swift and TextLayout.swift call. Conventions follow CoreText, not FreeType:
// - every metric is in points = font units × size / unitsPerEm, unhinted and fractional;
// - ascent/descent/leading come from `hhea` (OS/2 typo metrics when the font sets USE_TYPO_METRICS);
// - glyph paths are y-up in points, TrueType quadratics stay quadratic, every contour ends with closeSubpath;
// - CTFontDrawGlyphs renders the unhinted outline with FreeType's anti-aliasing rasteriser at the exact position.
// Shaping (CTLine) is HarfBuzz with its default features (GSUB ligatures and contextual forms, GPOS/`kern` kerning,
// mark positioning), as CoreText applies by default; characters the font lacks go to a fontconfig fallback font, one
// CTRun per font and script change, combining marks and joiners staying with their base; runs are put in visual order
// by a run-level bidi reorder. Not done: the full bidi algorithm's weak types (numbers inside right-to-left text).

@_exported import CoreGraphics
import CFreeType
import CHarfBuzz
import Foundation

public let kCTFontAttributeName: CFString = "NSFont"
public let kCTForegroundColorAttributeName: CFString = "CTForegroundColor"

public enum CTFontOrientation: UInt32 { case `default` = 0, horizontal = 1, vertical = 2 }

public struct CTFontSymbolicTraits: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let traitItalic = CTFontSymbolicTraits(rawValue: 1 << 0)
    public static let traitBold = CTFontSymbolicTraits(rawValue: 1 << 1)
    public static let traitMonoSpace = CTFontSymbolicTraits(rawValue: 1 << 10)
    public static let traitColorGlyphs = CTFontSymbolicTraits(rawValue: 1 << 13)
}

public final class CTFontDescriptor {}

// FreeType load flags (freetype.h; the macros are shifts Swift does not import).
private let FT_LOAD_NO_SCALE_: Int32 = 1 << 0
private let FT_LOAD_NO_HINTING_: Int32 = 1 << 1
private let FT_LOAD_NO_BITMAP_: Int32 = 1 << 3
private let FT_LOAD_COLOR_: Int32 = 1 << 20
private let FT_FACE_FLAG_COLOR_: FT_Long = 1 << 14
private let FT_FACE_FLAG_FIXED_WIDTH_: FT_Long = 1 << 2
private let FT_STYLE_FLAG_ITALIC_: FT_Long = 1 << 0
private let FT_STYLE_FLAG_BOLD_: FT_Long = 1 << 1

/// A font at a size. Each instance owns its FreeType face (faces are not thread-safe; `lock` serialises use).
public final class CTFont {
    public let graphicsFont: CGFont
    public let size: CGFloat
    let holder: CGFont.FaceHolder
    var face: FT_Face { holder.face }
    let lock = NSLock()
    public let unitsPerEm: Int
    let scale: CGFloat
    let postScriptName: String
    private var fallbacks: [UInt32: CTFont?] = [:]
    /// One fallback CTFont per font file, so consecutive characters from the same fallback face share a run (and
    /// HarfBuzz sees them together: Arabic joining, CJK runs, emoji sequences).
    private var fallbackFonts: [String: CTFont] = [:]

    init?(graphicsFont: CGFont, size: CGFloat, reportedName: String? = nil) {
        guard let h = CGFont.openFace(graphicsFont.storage, graphicsFont.faceIndex) else { return nil }
        self.graphicsFont = graphicsFont
        self.size = size
        holder = h
        // Select a Unicode charmap (FreeType picks one by default; prefer full-repertoire UCS-4 tables).
        _ = FT_Select_Charmap(h.face, FT_ENCODING_UNICODE)
        let upem = Int(h.face.pointee.units_per_EM)
        unitsPerEm = upem > 0 ? upem : 1000
        scale = size / CGFloat(unitsPerEm)
        postScriptName = reportedName ?? graphicsFont.postScriptName ?? ""
    }

    deinit {
        if let hb = hbFontStorage { hb_font_destroy(hb) }
        FreeTypeLibrary.lock.withLock { _ = FT_Done_Face(holder.face) }
    }

    /// HarfBuzz font over the same shared bytes as the FreeType face, scaled to font units (positions are exact
    /// integers, multiplied by `scale` like every other metric). Created on first use.
    private var hbFontStorage: OpaquePointer?
    var hbFont: OpaquePointer {
        if let f = hbFontStorage { return f }
        let storage = graphicsFont.storage
        let blob = storage.bytes.withMemoryRebound(to: CChar.self, capacity: storage.count) {
            hb_blob_create($0, UInt32(storage.count), HB_MEMORY_MODE_READONLY, nil, nil)
        }
        let face = hb_face_create(blob, UInt32(graphicsFont.faceIndex))
        let font = hb_font_create(face)!
        hb_face_destroy(face)
        hb_blob_destroy(blob)
        hb_font_set_scale(font, Int32(unitsPerEm), Int32(unitsPerEm))
        hbFontStorage = font
        return font
    }

    // Metrics (font units)

    struct VMetrics { var ascent: CGFloat, descent: CGFloat, lineGap: CGFloat }
    /// `hhea` ascender/descender/line gap, whatever OS/2 fsSelection's USE_TYPO_METRICS says (measured on macOS 26
    /// over 82 workshop fonts: CoreText reports hhea even for fonts that set the bit and whose typo metrics differ);
    /// OS/2 typo metrics only when hhea has neither ascender nor descender.
    lazy var vmetrics: VMetrics = {
        let f = face.pointee
        var asc = CGFloat(f.ascender), desc = CGFloat(-f.descender), gap: CGFloat = 0
        if let hhea = FT_Get_Sfnt_Table(face, FT_SFNT_HHEA)?.assumingMemoryBound(to: TT_HoriHeader.self) {
            asc = CGFloat(hhea.pointee.Ascender)
            desc = CGFloat(-hhea.pointee.Descender)
            gap = CGFloat(hhea.pointee.Line_Gap)
        }
        if asc == 0 && desc == 0, let os2 = FT_Get_Sfnt_Table(face, FT_SFNT_OS2)?.assumingMemoryBound(to: TT_OS2.self),
           os2.pointee.version != 0xFFFF {
            asc = CGFloat(os2.pointee.sTypoAscender)
            desc = CGFloat(-os2.pointee.sTypoDescender)
            gap = CGFloat(os2.pointee.sTypoLineGap)
        }
        return VMetrics(ascent: asc, descent: desc, lineGap: gap)
    }()

    /// Font-wide line metrics as CoreText reports them (measured against macOS 26 CoreText, docs/linux-port.md §3.3):
    /// a TrueType font's units/em ratio is held in 16.16 fixed point before scaling by the size; a CFF font's goes
    /// through its FontMatrix: the default (no FontMatrix operator) carries a constant factor of 1 + 17·2⁻²³, an explicit
    /// one the factor FontMatrix[0] × unitsPerEm (LEMONMILK's 0.000488281 for 1/2048). Matters where layout ceils/floors
    /// them.
    func lineMetric(_ units: CGFloat) -> CGFloat {
        let perEm = units / CGFloat(unitsPerEm)
        if let factor = cffFactor { return perEm * factor * size }
        return (perEm * 65536).rounded() / 65536 * size
    }

    /// nil for TrueType outlines.
    lazy var cffFactor: CGFloat? = {
        var length: FT_ULong = 0
        guard FT_Load_Sfnt_Table(face, FT_ULong(0x4346_4620), 0, nil, &length) == 0, length > 0 else { return nil } // 'CFF '
        var table = [UInt8](repeating: 0, count: Int(length))
        guard FT_Load_Sfnt_Table(face, FT_ULong(0x4346_4620), 0, &table, &length) == 0 else { return 1.000002026557922 }
        if let m = CFFTopDict.fontMatrixA(table), m > 0 { return CGFloat(m) * CGFloat(unitsPerEm) }
        return 1.000002026557922
    }()

    /// Loads `glyph` unscaled (font units); `body` sees the slot. Nil if the glyph has no outline/failed.
    func withUnscaledGlyph<T>(_ glyph: CGGlyph, _ body: (FT_GlyphSlot) -> T) -> T? {
        lock.withLock {
            guard FT_Load_Glyph(face, FT_UInt(glyph), FT_LOAD_NO_SCALE_ | FT_LOAD_NO_HINTING_ | FT_LOAD_NO_BITMAP_) == 0,
                  let slot = face.pointee.glyph else { return nil }
            return body(slot)
        }
    }

    func advance(_ glyph: CGGlyph) -> CGFloat {
        withUnscaledGlyph(glyph) { CGFloat($0.pointee.advance.x) * scale } ?? 0
    }

    func boundingRect(_ glyph: CGGlyph) -> CGRect {
        withUnscaledGlyph(glyph) { slot -> CGRect in
            guard slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE, slot.pointee.outline.n_points > 0 else { return .zero }
            var box = FT_BBox()
            FT_Outline_Get_CBox(&slot.pointee.outline, &box)
            return CGRect(x: CGFloat(box.xMin) * scale, y: CGFloat(box.yMin) * scale,
                          width: CGFloat(box.xMax - box.xMin) * scale, height: CGFloat(box.yMax - box.yMin) * scale)
        } ?? .zero
    }

    func glyph(for scalar: UInt32) -> CGGlyph {
        lock.withLock { CGGlyph(truncatingIfNeeded: FT_Get_Char_Index(face, FT_ULong(scalar))) }
    }

    var isColor: Bool { face.pointee.face_flags & FT_FACE_FLAG_COLOR_ != 0 }

    /// A same-size font for a character this font lacks (CoreText's cascade list stand-in): Helvetica's stand-in
    /// (Arimo, Helvetica's advance widths) first, as CoreText's cascade starts with Helvetica (measured: a font without
    /// a space or an en dash gets them from Helvetica, a bold one from Helvetica-Bold), then fontconfig's best font
    /// covering it; emoji with default emoji presentation prefer a colour font.
    func fallback(for scalar: UInt32) -> CTFont? {
        if let f = fallbacks[scalar] { return f }
        var f: CTFont?
        let emoji = Unicode.Scalar(scalar)?.properties.isEmojiPresentation ?? false
        var file: (String, Int)?
        if !emoji {
            // Helvetica-Bold for a bold font, as CoreText's cascade matches the weight.
            let bold = face.pointee.style_flags & FT_STYLE_FLAG_BOLD_ != 0
            let candidates = bold ? ["Arimo-Bold", "LiberationSans-Bold"].compactMap { FontConfig.match(name: $0) }
                                  : ["Arimo", "Liberation Sans"].compactMap { FontConfig.installed(family: $0) }
            if let first = candidates.first, FontConfig.file(first.path, index: first.index, covers: scalar) { file = first }
        }
        if file == nil { file = FontConfig.fileCovering(scalar, color: emoji) }
        if let (path, index) = file {
            let key = "\(path)#\(index)"
            if let hit = fallbackFonts[key] {
                f = hit
            } else if let cg = CGFont.fromFile(path, index: index), let font = CTFont(graphicsFont: cg, size: size) {
                fallbackFonts[key] = font
                f = font
            }
        }
        fallbacks[scalar] = f
        return f
    }
}

// MARK: - Creation and metrics

public func CTFontCreateWithGraphicsFont(_ graphicsFont: CGFont, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?,
                                         _ attributes: CTFontDescriptor?) -> CTFont {
    CTFont(graphicsFont: graphicsFont, size: size == 0 ? 12 : size) ?? defaultFont(size)
}

/// By PostScript or family name through fontconfig. An unknown name gets the closest match (fontconfig's default sans),
/// as CoreText returns a default face; `CTFontCopyPostScriptName` then reports what was actually loaded.
///
/// Windows and macOS fonts that are not installed but have a metric-compatible substitute (same advance widths, kerning
/// and vertical metrics, so line breaks and layout match) load that substitute and report the requested PostScript
/// name, as if the font were installed: FontAtlas's `systemfont_*` chains test the name to decide whether a font
/// exists, and would otherwise skip to their last resort.
public func CTFontCreateWithName(_ name: CFString, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont {
    let s = size == 0 ? 12 : size
    let requested = name as String
    if let sub = metricCompatibleFont(requested), let f = CTFont(graphicsFont: sub, size: s, reportedName: requested) { return f }
    if let cg = namedFont(name), let f = CTFont(graphicsFont: cg, size: s) { return f }
    return defaultFont(s)
}

/// PostScript name → families with the same metrics, in preference order (checked with `text-shape` against macOS:
/// ArialMT and Arimo agree in glyph ids, advances, kerning and line metrics). Only faces with matching metrics are
/// listed; fonts without one (Verdana, Georgia, Comic Sans, Helvetica, Helvetica Neue, Segoe UI, Consolas) keep
/// fontconfig's ordinary best match. Helvetica is not listed: Arimo has its advance widths but not its line metrics.
let metricCompatibleFamilies: [String: [String]] = [
    "ArialMT": ["Arimo", "Liberation Sans"],
    "Arial-BoldMT": ["Arimo", "Liberation Sans"],
    "TimesNewRomanPSMT": ["Tinos", "Liberation Serif"],
    "CourierNewPSMT": ["Cousine", "Liberation Mono"],
    "Calibri": ["Carlito"],
    "Cambria": ["Caladea"],
    "Menlo-Regular": ["DejaVu Sans Mono"], // Menlo is Apple's revision of DejaVu Sans Mono
]

private func metricCompatibleFont(_ postScriptName: String) -> CGFont? {
    guard let families = metricCompatibleFamilies[postScriptName] else { return nil }
    // The real font wins when it is installed.
    if let (path, _) = FontConfig.match(name: postScriptName), let cg = namedFont(postScriptName as CFString),
       cg.postScriptName == postScriptName, !path.isEmpty { return cg }
    let bold = postScriptName.contains("Bold")
    for family in families {
        guard let (path, index) = FontConfig.installed(family: family) else { continue }
        if bold, let (bp, bi) = FontConfig.match(name: family.replacingOccurrences(of: " ", with: "") + "-Bold"),
           let cg = CGFont.fromFile(bp, index: bi), cg.postScriptName?.contains("Bold") == true { return cg }
        if let cg = CGFont.fromFile(path, index: index) { return cg }
    }
    return nil
}

/// fontconfig lookups and font-file reads, once per name (CoreText caches named fonts the same way).
private var namedFonts: [String: CGFont?] = [:]
private let namedFontsLock = NSLock()
private func namedFont(_ name: CFString) -> CGFont? {
    let key = name as String
    namedFontsLock.lock()
    defer { namedFontsLock.unlock() }
    if let hit = namedFonts[key] { return hit }
    let f = CGFont(name: name)
    namedFonts[key] = f
    return f
}

private func defaultFont(_ size: CGFloat) -> CTFont {
    for name in ["Helvetica", "Arial", "DejaVu Sans", "sans-serif"] {
        if let cg = CGFont(name: name), let f = CTFont(graphicsFont: cg, size: size) { return f }
    }
    fatalError("CoreText: no usable font found through fontconfig")
}

public func CTFontCreateCopyWithAttributes(_ font: CTFont, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?,
                                           _ attributes: CTFontDescriptor?) -> CTFont {
    CTFont(graphicsFont: font.graphicsFont, size: size == 0 ? font.size : size) ?? font
}

public func CTFontCopyGraphicsFont(_ font: CTFont, _ attributes: UnsafeMutablePointer<CTFontDescriptor?>?) -> CGFont { font.graphicsFont }
public func CTFontCopyPostScriptName(_ font: CTFont) -> CFString { font.postScriptName }
public func CTFontCopyFullName(_ font: CTFont) -> CFString { font.graphicsFont.fullName ?? font.postScriptName }
public func CTFontCopyFamilyName(_ font: CTFont) -> CFString {
    font.lock.withLock { font.face.pointee.family_name.map { String(cString: $0) } ?? "" }
}
public func CTFontGetSize(_ font: CTFont) -> CGFloat { font.size }
public func CTFontGetUnitsPerEm(_ font: CTFont) -> UInt32 { UInt32(font.unitsPerEm) }
public func CTFontGetAscent(_ font: CTFont) -> CGFloat { font.lineMetric(font.vmetrics.ascent) }
public func CTFontGetDescent(_ font: CTFont) -> CGFloat { font.lineMetric(font.vmetrics.descent) }
public func CTFontGetLeading(_ font: CTFont) -> CGFloat { font.lineMetric(font.vmetrics.lineGap) }
public func CTFontGetGlyphCount(_ font: CTFont) -> CFIndex { Int(font.face.pointee.num_glyphs) }
public func CTFontGetUnderlinePosition(_ font: CTFont) -> CGFloat { CGFloat(font.face.pointee.underline_position) * font.scale }
public func CTFontGetUnderlineThickness(_ font: CTFont) -> CGFloat { CGFloat(font.face.pointee.underline_thickness) * font.scale }
public func CTFontGetCapHeight(_ font: CTFont) -> CGFloat {
    guard let os2 = FT_Get_Sfnt_Table(font.face, FT_SFNT_OS2)?.assumingMemoryBound(to: TT_OS2.self), os2.pointee.version >= 2 else {
        return CTFontGetAscent(font)
    }
    return CGFloat(os2.pointee.sCapHeight) * font.scale
}
public func CTFontGetXHeight(_ font: CTFont) -> CGFloat {
    guard let os2 = FT_Get_Sfnt_Table(font.face, FT_SFNT_OS2)?.assumingMemoryBound(to: TT_OS2.self), os2.pointee.version >= 2 else {
        return CTFontGetAscent(font) / 2
    }
    return CGFloat(os2.pointee.sxHeight) * font.scale
}

public func CTFontGetSymbolicTraits(_ font: CTFont) -> CTFontSymbolicTraits {
    let f = font.face.pointee
    var t = CTFontSymbolicTraits()
    if f.style_flags & FT_STYLE_FLAG_ITALIC_ != 0 { t.insert(.traitItalic) }
    if f.style_flags & FT_STYLE_FLAG_BOLD_ != 0 { t.insert(.traitBold) }
    if f.face_flags & FT_FACE_FLAG_FIXED_WIDTH_ != 0 { t.insert(.traitMonoSpace) }
    if font.isColor { t.insert(.traitColorGlyphs) }
    return t
}

/// Glyphs for UTF-16 `characters` (a surrogate pair maps to one glyph followed by glyph 0, as in CoreText). Returns
/// false if any character has no glyph.
@discardableResult
public func CTFontGetGlyphsForCharacters(_ font: CTFont, _ characters: UnsafePointer<UniChar>, _ glyphs: UnsafeMutablePointer<CGGlyph>,
                                         _ count: CFIndex) -> Bool {
    var all = true
    var i = 0
    while i < count {
        let c = characters[i]
        if UTF16.isLeadSurrogate(c), i + 1 < count, UTF16.isTrailSurrogate(characters[i + 1]) {
            let scalar = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(characters[i + 1]) - 0xDC00)
            glyphs[i] = font.glyph(for: scalar)
            glyphs[i + 1] = 0
            if glyphs[i] == 0 { all = false }
            i += 2
        } else {
            glyphs[i] = font.glyph(for: UInt32(c))
            if glyphs[i] == 0 { all = false }
            i += 1
        }
    }
    return all
}

/// Per-glyph advances in points (unhinted); returns their sum.
@discardableResult
public func CTFontGetAdvancesForGlyphs(_ font: CTFont, _ orientation: CTFontOrientation, _ glyphs: UnsafePointer<CGGlyph>,
                                       _ advances: UnsafeMutablePointer<CGSize>?, _ count: CFIndex) -> Double {
    var total = 0.0
    for i in 0..<count {
        let a = font.advance(glyphs[i])
        advances?[i] = CGSize(width: a, height: 0)
        total += Double(a)
    }
    return total
}

/// Outline bounds per glyph in points (control box of the glyph outline, as `glyf` stores it); `.zero` for glyphs
/// without contours. Returns the union.
@discardableResult
public func CTFontGetBoundingRectsForGlyphs(_ font: CTFont, _ orientation: CTFontOrientation, _ glyphs: UnsafePointer<CGGlyph>,
                                            _ boundingRects: UnsafeMutablePointer<CGRect>?, _ count: CFIndex) -> CGRect {
    var all = CGRect.null
    for i in 0..<count {
        let r = font.boundingRect(glyphs[i])
        boundingRects?[i] = r
        if r != .zero { all = all.union(r) }
    }
    return all.isNull ? .zero : all
}

// MARK: - Glyph paths

/// The glyph outline in points, y-up, origin at the glyph origin, walked like FT_Outline_Decompose (start at the first
/// on-curve point, or the last, or their implied midpoint; consecutive TrueType off-curve points get an implied on-curve
/// midpoint; quadratics stay quadratic) but in floating point, as CoreText does: implied midpoints are exact, not
/// rounded to font units. Each contour ends with closeSubpath and no explicit closing line. Nil for glyphs without an
/// outline (CoreText returns nil for those too).
public func CTFontCreatePathForGlyph(_ font: CTFont, _ glyph: CGGlyph, _ matrix: UnsafePointer<CGAffineTransform>?) -> CGPath? {
    let t = matrix?.pointee ?? .identity
    let k = font.scale
    let path = CGMutablePath()
    let ok: Bool = font.withUnscaledGlyph(glyph) { slot -> Bool in
        guard slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE else { return false }
        let o = slot.pointee.outline
        guard o.n_contours > 0, let pts = o.points, let tags = o.tags, let ends = o.contours else { return false }
        func p(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(pts[i].x) * k, y: CGFloat(pts[i].y) * k) }
        func tag(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: tags[i]) & 3 } // 1 on, 0 conic, 2 cubic (char before FreeType 2.13.3, unsigned char after)
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var first = 0
        for c in 0..<Int(o.n_contours) {
            var last = Int(ends[c])
            guard last >= first else { continue }
            var start = p(first)
            var i = first
            if tag(first) == 0 {
                if tag(last) == 1 { start = p(last); last -= 1 } else { start = mid(p(first), p(last)) }
                i = first - 1
            }
            path.move(to: start, transform: t)
            var closedByCurve = false
            while i < last {
                i += 1
                switch tag(i) {
                case 1:
                    path.addLine(to: p(i), transform: t)
                case 0:
                    var control = p(i)
                    while true {
                        if i < last {
                            i += 1
                            if tag(i) == 1 { path.addQuadCurve(to: p(i), control: control, transform: t); break }
                            let m = mid(control, p(i))
                            path.addQuadCurve(to: m, control: control, transform: t)
                            control = p(i)
                        } else {
                            path.addQuadCurve(to: start, control: control, transform: t)
                            closedByCurve = true
                            break
                        }
                    }
                default:
                    if i + 2 <= last {
                        path.addCurve(to: p(i + 2), control1: p(i), control2: p(i + 1), transform: t)
                        i += 2
                    } else {
                        path.addCurve(to: start, control1: p(i), control2: p(min(i + 1, last)), transform: t)
                        closedByCurve = true
                        i = last
                    }
                }
                if closedByCurve { break }
            }
            path.closeSubpath()
            first = Int(ends[c]) + 1
        }
        return true
    } ?? false
    guard ok, !path.isEmpty else { return nil }
    return path
}

// MARK: - Drawing

/// Draws `glyphs` at user-space `positions` with the context's fill colour. Outline glyphs are scaled to the font size
/// (and the CTM's scale), placed at the exact fractional device position and rasterised unhinted with FreeType's
/// anti-aliasing rasteriser; colour bitmap glyphs (CBDT/sbix) take the nearest strike, scaled bilinearly.
public func CTFontDrawGlyphs(_ font: CTFont, _ glyphs: UnsafePointer<CGGlyph>, _ positions: UnsafePointer<CGPoint>, _ count: Int,
                             _ context: CGContext) {
    guard let lib = FreeTypeLibrary.shared else { return }
    let ctm = context.ctm
    let sx = (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot()
    for i in 0..<count {
        // Bitmap contexts do not subpixel-position glyphs by default: CoreText snaps each glyph origin down to the pixel
        // grid (measured against macOS: centroids match only with floor, not round).
        let exact = positions[i].applying(ctm)
        let origin = CGPoint(x: exact.x.rounded(.down), y: exact.y.rounded(.down))
        if font.isColor, drawColorGlyph(font, glyphs[i], origin: origin, scale: sx, context: context) { continue }
        font.lock.withLock {
            guard FT_Load_Glyph(font.face, FT_UInt(glyphs[i]), FT_LOAD_NO_SCALE_ | FT_LOAD_NO_HINTING_ | FT_LOAD_NO_BITMAP_) == 0,
                  let slot = font.face.pointee.glyph, slot.pointee.format == FT_GLYPH_FORMAT_OUTLINE,
                  slot.pointee.outline.n_points > 0 else { return }
            let outline = withUnsafeMutablePointer(to: &slot.pointee.outline) { $0 }
            // Font units → 26.6 device pixels: 16.16 matrix of scale·64 (with the CTM's linear part).
            let k = font.scale * 64
            var m = FT_Matrix(xx: FT_Fixed((ctm.a * k * 65536).rounded()), xy: FT_Fixed((ctm.c * k * 65536).rounded()),
                              yx: FT_Fixed((ctm.b * k * 65536).rounded()), yy: FT_Fixed((ctm.d * k * 65536).rounded()))
            FT_Outline_Transform(outline, &m)
            FT_Outline_Translate(outline, FT_Pos((origin.x * 64).rounded()), FT_Pos((origin.y * 64).rounded()))
            var box = FT_BBox()
            FT_Outline_Get_CBox(outline, &box)
            let x0 = Int((Double(box.xMin) / 64).rounded(.down)), y0 = Int((Double(box.yMin) / 64).rounded(.down))
            let x1 = Int((Double(box.xMax) / 64).rounded(.up)), y1 = Int((Double(box.yMax) / 64).rounded(.up))
            let w = x1 - x0, h = y1 - y0
            guard w > 0, h > 0, w < 16384, h < 16384 else { return }
            FT_Outline_Translate(outline, FT_Pos(-x0 * 64), FT_Pos(-y0 * 64))
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
            defer { buf.deallocate() }
            buf.initialize(repeating: 0, count: w * h)
            var bmp = FT_Bitmap()
            bmp.rows = UInt32(h)
            bmp.width = UInt32(w)
            bmp.pitch = Int32(w)
            bmp.buffer = buf
            bmp.num_grays = 256
            bmp.pixel_mode = UInt8(FT_PIXEL_MODE_GRAY.rawValue)
            guard FT_Outline_Get_Bitmap(lib, outline, &bmp) == 0 else { return }
            // Bitmap row 0 is the top (device y = y1 − 1).
            context.drawCoverage(buf, width: w, height: h, pitch: w, deviceX: x0, deviceTopY: y1 - 1)
        }
    }
}

/// COLR/CPAL glyph (scalable colour layers): FreeType composites the layers into a premultiplied BGRA bitmap at the
/// exact size. Caller holds `font.lock`.
private func drawLayeredColorGlyph(_ font: CTFont, _ glyph: CGGlyph, origin: CGPoint, scale: CGFloat, context: CGContext) -> Bool {
    let face = font.face
    guard FT_Set_Char_Size(face, 0, FT_F26Dot6((font.size * scale * 64).rounded()), 72, 72) == 0,
          FT_Load_Glyph(face, FT_UInt(glyph), FT_LOAD_COLOR_ | FT_LOAD_NO_HINTING_) == 0, let slot = face.pointee.glyph,
          FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) == 0 else { return false }
    let bmp = slot.pointee.bitmap
    guard bmp.pixel_mode == UInt8(FT_PIXEL_MODE_BGRA.rawValue), let src = bmp.buffer else { return false }
    let w = Int(bmp.width), h = Int(bmp.rows), pitch = Int(bmp.pitch)
    guard w > 0, h > 0 else { return true }
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let p = src + y * pitch + x * 4, o = (y * w + x) * 4
            out[o] = p[2]; out[o + 1] = p[1]; out[o + 2] = p[0]; out[o + 3] = p[3]
        }
    }
    out.withUnsafeBufferPointer { p in
        context.drawPremultipliedRGBA(p.baseAddress!, width: w, height: h, deviceX: Int(origin.x) + Int(slot.pointee.bitmap_left),
                                      deviceTopY: Int(origin.y) + Int(slot.pointee.bitmap_top) - 1)
    }
    return true
}

/// Colour bitmap glyph: nearest strike, BGRA premultiplied, scaled to the font size. False if the font has none.
private func drawColorGlyph(_ font: CTFont, _ glyph: CGGlyph, origin: CGPoint, scale: CGFloat, context: CGContext) -> Bool {
    font.lock.withLock { () -> Bool in
        let face = font.face
        let n = Int(face.pointee.num_fixed_sizes)
        guard n > 0, let sizes = face.pointee.available_sizes else {
            return drawLayeredColorGlyph(font, glyph, origin: origin, scale: scale, context: context)
        }
        let want = font.size * scale
        var best = 0
        for s in 0..<n where abs(CGFloat(sizes[s].y_ppem) / 64 - want) < abs(CGFloat(sizes[best].y_ppem) / 64 - want) { best = s }
        guard FT_Select_Size(face, FT_Int(best)) == 0, FT_Load_Glyph(face, FT_UInt(glyph), FT_LOAD_COLOR_) == 0,
              let slot = face.pointee.glyph else { return false }
        if slot.pointee.format != FT_GLYPH_FORMAT_BITMAP { _ = FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) }
        let bmp = slot.pointee.bitmap
        guard bmp.pixel_mode == UInt8(FT_PIXEL_MODE_BGRA.rawValue), bmp.width > 0, bmp.rows > 0, let src = bmp.buffer else { return false }
        let strike = CGFloat(sizes[best].y_ppem) / 64
        let k = want / max(strike, 1)
        let sw = Int(bmp.width), sh = Int(bmp.rows), pitch = Int(bmp.pitch)
        let left = CGFloat(slot.pointee.bitmap_left) * k, top = CGFloat(slot.pointee.bitmap_top) * k
        let dx0 = origin.x + left, dyTop = origin.y + top
        let dw = Int((CGFloat(sw) * k).rounded(.up)), dh = Int((CGFloat(sh) * k).rounded(.up))
        guard dw > 0, dh > 0 else { return true }
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let cx = min(max(x, 0), sw - 1), cy = min(max(y, 0), sh - 1)
            let p = src + cy * pitch + cx * 4
            return SIMD4(Float(p[2]), Float(p[1]), Float(p[0]), Float(p[3])) // BGRA → RGBA, premultiplied
        }
        for y in 0..<dh {
            for x in 0..<dw {
                let u = (CGFloat(x) + 0.5) / k - 0.5, v = (CGFloat(y) + 0.5) / k - 0.5
                let fu = floor(u), fv = floor(v), tu = Float(u - fu), tv = Float(v - fv)
                let a = texel(Int(fu), Int(fv)) * (1 - tu) + texel(Int(fu) + 1, Int(fv)) * tu
                let b = texel(Int(fu), Int(fv) + 1) * (1 - tu) + texel(Int(fu) + 1, Int(fv) + 1) * tu
                let s = a * (1 - tv) + b * tv
                for c in 0..<4 { out[(y * dw + x) * 4 + c] = UInt8(min(255, max(0, s[c].rounded()))) }
            }
        }
        out.withUnsafeBufferPointer { p in
            context.drawPremultipliedRGBA(p.baseAddress!, width: dw, height: dh, deviceX: Int(dx0.rounded()),
                                          deviceTopY: Int(dyTop.rounded()) - 1)
        }
        return true
    }
}

// MARK: - Lines and runs

public final class CTRun {
    public let font: CTFont
    let glyphs: [CGGlyph]
    let advances: [CGSize]
    let positions: [CGPoint]
    let indices: [CFIndex]
    let attributes: NSDictionary
    init(font: CTFont, glyphs: [CGGlyph], advances: [CGSize], positions: [CGPoint], indices: [CFIndex], attributes: [String: Any]) {
        self.font = font
        self.glyphs = glyphs
        self.advances = advances
        self.positions = positions
        self.indices = indices
        var a = attributes
        a[kCTFontAttributeName] = font
        self.attributes = NSDictionary(dictionary: a)
    }
}

public final class CTLine {
    public let runs: [CTRun]
    let width: CGFloat
    init(runs: [CTRun], width: CGFloat) {
        self.runs = runs
        self.width = width
    }
}

private func slice<T>(_ a: [T], _ r: CFRange) -> ArraySlice<T> {
    let start = max(0, min(r.location, a.count))
    let end = r.length == 0 ? a.count : max(start, min(a.count, start + r.length))
    return a[start..<end]
}

public func CTRunGetGlyphCount(_ run: CTRun) -> CFIndex { run.glyphs.count }
public func CTRunGetAttributes(_ run: CTRun) -> NSDictionary { run.attributes }
public func CTRunGetGlyphs(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGGlyph>) {
    for (i, g) in slice(run.glyphs, range).enumerated() { buffer[i] = g }
}
public func CTRunGetAdvances(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGSize>) {
    for (i, a) in slice(run.advances, range).enumerated() { buffer[i] = a }
}
public func CTRunGetPositions(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGPoint>) {
    for (i, p) in slice(run.positions, range).enumerated() { buffer[i] = p }
}
public func CTRunGetStringIndices(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CFIndex>) {
    for (i, x) in slice(run.indices, range).enumerated() { buffer[i] = x }
}
public func CTRunGetStringRange(_ run: CTRun) -> CFRange {
    guard let f = run.indices.min(), let l = run.indices.max() else { return CFRange(location: 0, length: 0) }
    return CFRange(location: f, length: l - f + 1)
}

public func CTLineGetGlyphRuns(_ line: CTLine) -> [CTRun] { line.runs }
public func CTLineGetGlyphCount(_ line: CTLine) -> CFIndex { line.runs.reduce(0) { $0 + $1.glyphs.count } }
public func CTLineGetTypographicBounds(_ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?,
                                       _ leading: UnsafeMutablePointer<CGFloat>?) -> Double {
    ascent?.pointee = line.runs.map { CTFontGetAscent($0.font) }.max() ?? 0
    descent?.pointee = line.runs.map { CTFontGetDescent($0.font) }.max() ?? 0
    leading?.pointee = line.runs.map { CTFontGetLeading($0.font) }.max() ?? 0
    return Double(line.width)
}

/// Lays out one line. Per attribute run, each Unicode scalar picks a font (the run's font when its cmap has the
/// character, else fontconfig's fallback for it; combining marks, variation selectors and joiners stay with the font
/// before them, as CoreText keeps a cluster in one font), and every same-font segment is shaped by HarfBuzz with the
/// whole paragraph as context. Advances include kerning; positions add the mark offsets. String indices are UTF-16
/// offsets of each glyph's cluster (a ligature reports its first character), as CoreText reports them.
public func CTLineCreateWithAttributedString(_ string: NSAttributedString) -> CTLine {
    let units = Array(string.string.utf16)
    var runs: [CTRun] = []
    var pieces: [Piece] = []
    var penX: CGFloat = 0
    var location = 0
    while location < units.count {
        var range = NSRange(location: 0, length: 0)
        let attrs = string.attributes(at: location, effectiveRange: &range)
        let end = min(units.count, max(range.location + range.length, location + 1))
        let base = (attrs[NSAttributedString.Key(kCTFontAttributeName)] as? CTFont) ?? CTFontCreateWithName("Helvetica", 12, nil)
        var plain: [String: Any] = [:]
        for (k, v) in attrs where k.rawValue != kCTFontAttributeName { plain[k.rawValue] = v }

        // Scalars of [location, end) with their font: the run's font when its cmap has the character, else fontconfig's
        // fallback; marks, variation selectors and joiners stay with the font before them.
        var scalars: [(value: UInt32, start: Int, width: Int, font: CTFont, script: hb_script_t)] = []
        var i = location
        let unicode = hb_unicode_funcs_get_default()
        while i < end {
            var scalar = UInt32(units[i])
            var width = 1
            if UTF16.isLeadSurrogate(units[i]), i + 1 < end, UTF16.isTrailSurrogate(units[i + 1]) {
                scalar = 0x10000 + ((UInt32(units[i]) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                width = 2
            }
            var font = base
            if let last = scalars.last, staysWithPrevious(scalar) {
                font = last.font
            } else if base.glyph(for: scalar) == 0, scalar >= 0x20, let fb = base.fallback(for: scalar), fb.glyph(for: scalar) != 0 {
                font = fb
            }
            scalars.append((scalar, i, width, font, hb_unicode_script(unicode, scalar)))
            i += width
        }
        // Scripts within each same-font stretch: Common and Inherited characters (spaces, punctuation, marks) take the
        // script before them, leading ones the stretch's first real script (measured: CoreText puts "мир " and
        // "Ελληνικά" in two runs of one font, and a space between a Hangul fallback run and Latin text in the Latin
        // run). A stretch without a real script stays neutral.
        func isWeak(_ s: hb_script_t) -> Bool { s == HB_SCRIPT_COMMON || s == HB_SCRIPT_INHERITED || s == HB_SCRIPT_UNKNOWN }
        var k0 = 0
        while k0 < scalars.count {
            var k1 = k0
            while k1 + 1 < scalars.count, scalars[k1 + 1].font === scalars[k0].font { k1 += 1 }
            var current = scalars[k0...k1].first(where: { !isWeak($0.script) })?.script ?? HB_SCRIPT_COMMON
            for k in k0...k1 {
                if isWeak(scalars[k].script) { scalars[k].script = current } else { current = scalars[k].script }
            }
            k0 = k1 + 1
        }

        // Segments of one font and one script.
        var segments: [(font: CTFont, script: hb_script_t, start: Int, end: Int)] = []
        for sc in scalars {
            if let last = segments.last, last.font === sc.font, last.script == sc.script {
                segments[segments.count - 1].end = sc.start + sc.width
            } else {
                segments.append((sc.font, sc.script, sc.start, sc.start + sc.width))
            }
        }
        for seg in segments {
            pieces.append(Piece(font: seg.font, rtl: hb_script_get_horizontal_direction(seg.script) == HB_DIRECTION_RTL,
                                strong: !isWeak(seg.script), start: seg.start, length: seg.end - seg.start, attributes: plain))
        }
        location = end
    }
    // Visual order (a run-level Unicode bidi reorder): the paragraph direction is the first run's; left-to-right runs
    // get level 0 in a left-to-right paragraph and 2 in a right-to-left one, right-to-left runs level 1; then, from
    // the highest level down to 1, every maximal sequence at or above it is reversed. HarfBuzz already returns a
    // right-to-left run's glyphs in visual order, as CoreText's CTRun holds them.
    let paragraphRTL = pieces.first(where: { $0.strong })?.rtl ?? false
    // Neutral pieces (no script of their own, e.g. a space in the base font between two fallback runs) take the
    // direction of the strong pieces around them when both agree, else the paragraph's (UBA rules N1/N2).
    for k in pieces.indices where !pieces[k].strong {
        let before = pieces[..<k].last(where: { $0.strong })?.rtl ?? paragraphRTL
        let after = pieces[(k + 1)...].first(where: { $0.strong })?.rtl ?? paragraphRTL
        pieces[k].rtl = before == after ? before : paragraphRTL
    }
    let levels = pieces.map { $0.rtl ? 1 : (paragraphRTL ? 2 : 0) }
    var order = Array(pieces.indices)
    if let top = levels.max(), top > 0 {
        for level in stride(from: top, through: 1, by: -1) {
            var k = 0
            while k < order.count {
                guard levels[order[k]] >= level else { k += 1; continue }
                var e = k
                while e + 1 < order.count, levels[order[e + 1]] >= level { e += 1 }
                order[k...e].reverse()
                k = e + 1
            }
        }
    }
    for p in order.map({ pieces[$0] }) {
        let shaped = shape(units, p.start, p.length, font: p.font, penX: &penX)
        runs.append(CTRun(font: p.font, glyphs: shaped.glyphs, advances: shaped.advances, positions: shaped.positions,
                          indices: shaped.indices, attributes: p.attributes))
    }
    return CTLine(runs: runs, width: penX)
}

/// A same-font, same-script piece of a line, shaped once its visual position is known.
private struct Piece {
    let font: CTFont
    var rtl: Bool
    let strong: Bool
    let start: Int, length: Int
    let attributes: [String: Any]
}

/// Characters that belong to the cluster before them: nonspacing/enclosing/spacing marks, format characters (ZWJ,
/// ZWNJ), variation selectors and emoji modifiers.
private func staysWithPrevious(_ scalar: UInt32) -> Bool {
    if (0xFE00...0xFE0F).contains(scalar) || (0xE0100...0xE01EF).contains(scalar) || (0x1F3FB...0x1F3FF).contains(scalar) { return true }
    guard let u = Unicode.Scalar(scalar) else { return false }
    switch u.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .spacingMark, .format: return true
    default: return false
    }
}

/// HarfBuzz-shapes `units[start ..< start + length]` (the whole array is the context) with `font`.
private func shape(_ units: [UInt16], _ start: Int, _ length: Int, font: CTFont, penX: inout CGFloat)
    -> (glyphs: [CGGlyph], advances: [CGSize], positions: [CGPoint], indices: [CFIndex]) {
    guard let buf = hb_buffer_create() else { return ([], [], [], []) }
    defer { hb_buffer_destroy(buf) }
    // Each mark keeps its own string index (CoreText reports a mark at its own character; HarfBuzz's default level
    // would merge it into the base's cluster). Ligatures still report their first character.
    hb_buffer_set_cluster_level(buf, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS)
    units.withUnsafeBufferPointer { hb_buffer_add_utf16(buf, $0.baseAddress, Int32($0.count), UInt32(start), Int32(length)) }
    hb_buffer_guess_segment_properties(buf)
    font.lock.withLock { hb_shape(font.hbFont, buf, nil, 0) }
    var n: UInt32 = 0
    guard let info = hb_buffer_get_glyph_infos(buf, &n), let pos = hb_buffer_get_glyph_positions(buf, &n) else { return ([], [], [], []) }
    var glyphs: [CGGlyph] = [], advances: [CGSize] = [], positions: [CGPoint] = [], indices: [CFIndex] = []
    glyphs.reserveCapacity(Int(n))
    let k = font.scale
    for g in 0..<Int(n) {
        glyphs.append(CGGlyph(truncatingIfNeeded: info[g].codepoint))
        positions.append(CGPoint(x: penX + CGFloat(pos[g].x_offset) * k, y: CGFloat(pos[g].y_offset) * k))
        indices.append(CFIndex(info[g].cluster))
        penX += CGFloat(pos[g].x_advance) * k
    }
    // CoreText's advance of a glyph is the distance from its position to the next glyph's (the pen end for the last
    // one), so an offset mark carries a negative advance and its base the rest (measured on macOS 26).
    for g in 0..<Int(n) {
        let next = g + 1 < Int(n) ? positions[g + 1].x : penX
        advances.append(CGSize(width: next - positions[g].x, height: 0))
    }
    return (glyphs, advances, positions, indices)
}

/// CoreText fonts hash by value (CTFontRef equality is descriptor + size + matrix), so two `CTFontCreateWithName`
/// calls for one face and size hash alike. FontAtlas keys its glyph cache on this: an identity hash made every text
/// rebuild rasterise its glyphs again until the atlas pages were full and later glyphs came back empty.
public func CFHash(_ font: CTFont) -> Int {
    var h = Hasher()
    h.combine(font.postScriptName)
    h.combine(font.graphicsFont.faceIndex)
    h.combine(font.graphicsFont.fontData.count)
    h.combine(font.size)
    return h.finalize()
}

/// The CFF Top DICT's FontMatrix (operator 12 7), first element; nil when the font does not set it.
enum CFFTopDict {
    static func fontMatrixA(_ b: [UInt8]) -> Double? {
        guard b.count > 4 else { return nil }
        var o = Int(b[2]) // header size
        // Name INDEX, then the Top DICT INDEX.
        guard let afterNames = skipIndex(b, o) else { return nil }
        o = afterNames
        guard o + 3 <= b.count else { return nil }
        let count = Int(b[o]) << 8 | Int(b[o + 1])
        guard count > 0 else { return nil }
        let offSize = Int(b[o + 2])
        func offset(_ i: Int) -> Int? {
            let p = o + 3 + i * offSize
            guard offSize >= 1, offSize <= 4, p + offSize <= b.count else { return nil }
            var v = 0
            for k in 0..<offSize { v = v << 8 | Int(b[p + k]) }
            return v
        }
        let dataStart = o + 3 + (count + 1) * offSize - 1
        guard let s0 = offset(0), let s1 = offset(1), dataStart + s1 <= b.count, s0 <= s1 else { return nil }
        var p = dataStart + s0
        let end = dataStart + s1
        var operands: [Double] = []
        while p < end {
            let v = Int(b[p])
            switch v {
            case 0...21:
                if v == 12, p + 1 < end {
                    if b[p + 1] == 7 { return operands.first }
                    p += 2
                } else {
                    p += 1
                }
                operands.removeAll()
            case 28:
                guard p + 2 < end else { return nil }
                operands.append(Double(Int16(bitPattern: UInt16(b[p + 1]) << 8 | UInt16(b[p + 2])))); p += 3
            case 29:
                guard p + 4 < end else { return nil }
                let x = UInt32(b[p + 1]) << 24 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 8 | UInt32(b[p + 4])
                operands.append(Double(Int32(bitPattern: x))); p += 5
            case 30:
                // Real number: nibbles 0-9, a '.', b 'E', c 'E-', e '-', f end.
                var text = ""
                p += 1
                scan: while p < end {
                    for nib in [Int(b[p]) >> 4, Int(b[p]) & 15] {
                        switch nib {
                        case 0...9: text += String(nib)
                        case 0xa: text += "."
                        case 0xb: text += "E"
                        case 0xc: text += "E-"
                        case 0xe: text += "-"
                        case 0xf: p += 1; break scan
                        default: break
                        }
                    }
                    p += 1
                }
                operands.append(Double(text) ?? 0)
            case 32...246: operands.append(Double(v - 139)); p += 1
            case 247...250:
                guard p + 1 < end else { return nil }
                operands.append(Double((v - 247) * 256 + Int(b[p + 1]) + 108)); p += 2
            case 251...254:
                guard p + 1 < end else { return nil }
                operands.append(Double(-(v - 251) * 256 - Int(b[p + 1]) - 108)); p += 2
            default: p += 1
            }
        }
        return nil
    }

    private static func skipIndex(_ b: [UInt8], _ o: Int) -> Int? {
        guard o + 2 <= b.count else { return nil }
        let count = Int(b[o]) << 8 | Int(b[o + 1])
        if count == 0 { return o + 2 }
        guard o + 3 <= b.count else { return nil }
        let offSize = Int(b[o + 2])
        let last = o + 3 + count * offSize
        guard offSize >= 1, offSize <= 4, last + offSize <= b.count else { return nil }
        var v = 0
        for k in 0..<offSize { v = v << 8 | Int(b[last + k]) }
        return o + 3 + (count + 1) * offSize - 1 + v
    }
}
