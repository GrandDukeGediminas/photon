import CoreGraphics
import CoreText
import Foundation
import Metal

/// Layout request: the struct `Text_Rebuild` 0x140256f20 fills for `TextLayout_Build` 0x1401b0410 (§4.3.1).
struct TextLayoutRequest {
    var font = "systemfont_arial"
    var pointSize: Float = 32
    var spacing = SIMD2<Float>(0, 0)
    /// 0 left, 1 center, 2 right.
    var horizontalAlign = 1
    /// 0 = unlimited (limitwidth off).
    var maxWidth: Float = 0
    /// 0 = unlimited (limitrows off).
    var maxRows = 0
    var ellipsis = false
    var blockAlign = false
    /// req+0x1a (any of msdf/outline/blur/dropshadow) → the `_msdf` font entry (`TextLayout_Build` 0x1401b0600–0x1401b06b3).
    var msdf = false
}

/// The laid-out block (engine object at text+0x5a8): glyph quads for the R8 and colour atlases plus the
/// bounds fields at block+0x90..0xa8.
final class TextBlock {
    var minX: Float = 0, minY: Float = 0, maxX: Float = 0, maxY: Float = 0
    var lineHeight: Float = 0
    var lineCount = 0
    var pixelSize: Float = 0
    var ascender: Float = 0
    var descender: Float = 0
    /// x, y, 0, u, v per vertex; quads indexed 0,2,1, 1,2,3.
    var grayVertices: [Float] = [], colorVertices: [Float] = []
    var grayIndices: [UInt32] = [], colorIndices: [UInt32] = []
    var grayGeneration = -1, colorGeneration = -1
    /// The outline-glyph mesh addresses the MSDF page.
    var msdf = false

    var width: Float { maxX - minX }
    var height: Float { maxY - minY }
}

enum TextLayout {
    private struct Glyph {
        var atlas: AtlasGlyph
        var advance: Float
        var whitespace: Bool
        /// Unicode scalar index of the glyph's cluster in the shaped string (HarfBuzz `cluster`).
        var cluster = 0
    }

    private struct Line {
        var glyphs: [Glyph] = []
        /// Ended by word wrap rather than by a newline or the end of the text (blockalign only justifies these).
        var wrapped = false
    }

    /// HarfBuzz whitespace test used for wrapping and justification: tab, CR and space (mask 0x100002200).
    private static func isBreakSpace(_ c: UInt32) -> Bool { c == 0x20 || c == 0x09 || c == 0x0d }

    static func build(_ text: String, _ req: TextLayoutRequest, library: FontLibrary) -> TextBlock {
        let block = TextBlock()
        // FT_Set_Char_Size(face, 0, pt*64, 300, 300) (0x1401ad1f2): pixels = pt * 300/72.
        let size = CGFloat(min(max(req.pointSize, 1), 256)) * 300 / 72
        let font = library.font(req.font, pixelSize: size)
        let atlas = library.atlas
        // FT size metrics (26.6, grid-fitted): ascender ceil, descender floor, height round.
        let asc = Float(ceil(CTFontGetAscent(font)))
        let desc = Float(floor(-CTFontGetDescent(font)))
        let height = Float((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded())
        let lineHeight = height + req.spacing.y
        block.pixelSize = Float(size)
        block.ascender = asc
        block.descender = desc
        block.lineHeight = lineHeight

        // Line building as TextLayout_Build 0x1401b0410 does it (docs/re/04 §4.3.1, session 5), on strings of Unicode
        // scalars: paragraphs at "\n"; each is shaped and walked; an overflowing glyph either splits the string at the
        // last tab/CR/space (the rest becomes the next line) or, on the last allowed row, cuts or ellipsises it.
        func scalars(_ t: String) -> [Unicode.Scalar] { Array(t.unicodeScalars) }
        func string(_ u: ArraySlice<Unicode.Scalar>) -> String { var r = ""; r.unicodeScalars.append(contentsOf: u); return r }
        func isWS(_ u: Unicode.Scalar) -> Bool { isBreakSpace(u.value) }
        let ellipsisChar = Unicode.Scalar(0x2026)!
        /// 0x1401b0360: strip trailing tab/CR/space; with `ellipsis`, append U+2026 unless the text already ends with it.
        func finishLast(_ u: [Unicode.Scalar], ellipsis: Bool) -> [Unicode.Scalar] {
            var u = u
            while let l = u.last, isWS(l) { u.removeLast() }
            if ellipsis && u.last != ellipsisChar { u.append(ellipsisChar) }
            return u
        }
        // Paragraph split (0x1401b0a1c–0x1401b0b82): with maxrows, a paragraph beyond the limit is not added and the last
        // kept one goes through 0x1401b0360.
        var queue: [(text: [Unicode.Scalar], wrapped: Bool)] = []
        for para in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if req.maxRows > 0 && queue.count >= req.maxRows {
                queue[queue.count - 1].text = finishLast(queue[queue.count - 1].text, ellipsis: req.ellipsis)
                break
            }
            queue.append((scalars(para), false))
        }
        var lines: [Line] = []
        var qi = 0
        lineLoop: while qi < queue.count {
            let u = queue[qi].text
            let glyphs = shape(string(u[...]), font: font, spacing: req.spacing.x, atlas: atlas, msdf: req.msdf)
            // Wrap test (0x1401b1240–0x1401b1272): maxwidth set, not the line's first glyph, not tab/CR/space, a new
            // cluster, and the glyph's ink right edge `pen + x1` past maxwidth.
            var pen: Float = 0, overflow: Int? = nil, lastCluster = -1
            for (k, g) in glyphs.enumerated() {
                if req.maxWidth > 0, k > 0, !g.whitespace, g.cluster != lastCluster, pen + g.atlas.x1 > req.maxWidth {
                    overflow = k; break
                }
                lastCluster = g.cluster
                pen += g.advance
            }
            guard let k = overflow else {
                lines.append(Line(glyphs: glyphs, wrapped: queue[qi].wrapped))
                qi += 1
                continue
            }
            let n = glyphs[k].cluster
            if req.maxRows > 0 && lines.count + 1 >= req.maxRows {
                if req.ellipsis {
                    // 0x1401b14a0–0x1401b1828: shorten the prefix one scalar at a time until prefix + "…" fits, measured
                    // as the last glyph's ink right edge; then 0x1401b0360's rule on the prefix (0x1401b184f–0x1401b199e).
                    var m = n
                    while true {
                        let t = shape(string(u[..<m]) + "\u{2026}", font: font, spacing: 0, atlas: atlas, msdf: req.msdf)
                        var p: Float = 0, w: Float = 0
                        for g in t { w = p + g.atlas.x1; p += g.advance }
                        if w > req.maxWidth && m > 0 { m -= 1 } else { break }
                    }
                    let t2 = finishLast(Array(u[..<m]), ellipsis: true)
                    lines.append(Line(glyphs: shape(string(t2[...]), font: font, spacing: req.spacing.x, atlas: atlas, msdf: req.msdf)))
                } else {
                    // 0x1401b19f6: no ellipsis, the row ends before the overflowing glyph.
                    lines.append(Line(glyphs: Array(glyphs[..<k]), wrapped: queue[qi].wrapped))
                }
                break lineLoop
            }
            // Word wrap (0x1401b1a30–0x1401b1c7a): split at the last space/tab/CR before the overflowing cluster, or at
            // that cluster when there is none; the rest (leading tab/CR/space removed) becomes the next line.
            var e = n
            var j = e - 1
            while j >= 0 { if u[j] == " " || u[j] == "\t" || u[j] == "\r" { e = j; break }; j -= 1 }
            var tail = Array(u[e...])
            while let f = tail.first, isWS(f) { tail.removeFirst() }
            queue[qi] = (Array(u[..<e]), true)
            queue.insert((tail, queue[qi].wrapped), at: qi + 1)
            queue[qi + 1].wrapped = false
        }

        // Per-line ink bounds (0x1401b215d): start at 0, grow by each glyph box at the pen position.
        struct Bounds { var minX: Float = 0, maxX: Float = 0, minY: Float = 0, maxY: Float = 0 }
        var lineBounds: [Bounds] = []
        var blockMinX: Float = 0, blockMaxX: Float = 0, maxLineWidth: Float = 0
        var inkMinY: Float = 0, inkMaxY: Float = -Float.greatestFiniteMagnitude
        for (i, var line) in lines.enumerated() {
            var b = Bounds()
            var pen: Float = 0
            for g in line.glyphs {
                if !g.atlas.empty {
                    b.minX = min(b.minX, pen + g.atlas.x0); b.maxX = max(b.maxX, pen + g.atlas.x1)
                    b.minY = min(b.minY, g.atlas.y0); b.maxY = max(b.maxY, g.atlas.y1)
                }
                pen += g.advance
            }
            // blockalign: spread the free width over the whitespace of wrapped lines.
            if req.blockAlign && line.wrapped && req.maxWidth > 0 {
                let spaces = line.glyphs.filter(\.whitespace).count
                if spaces > 0 {
                    let extra = (req.maxWidth - (b.maxX - b.minX)) / Float(spaces)
                    for k in line.glyphs.indices where line.glyphs[k].whitespace { line.glyphs[k].advance += extra }
                    lines[i] = line
                    b.maxX = b.minX + req.maxWidth
                }
            }
            let y = -Float(i) * lineHeight
            inkMinY = min(inkMinY, y + b.minY)
            inkMaxY = max(inkMaxY, y + b.maxY)
            blockMinX = min(blockMinX, b.minX)
            blockMaxX = max(blockMaxX, b.maxX)
            maxLineWidth = max(maxLineWidth, b.maxX - b.minX)
            lineBounds.append(b)
        }
        block.lineCount = lines.count
        block.minX = blockMinX
        block.maxX = blockMaxX
        block.maxY = max(asc, inkMaxY)
        block.minY = min(asc - Float(lines.count) * lineHeight, inkMinY)

        // Quads (0x1401b2952): line y steps down by lineHeight; lines align inside the widest line.
        let grayPage = req.msdf ? atlas.msdfPage : atlas.gray, colorPage = atlas.color
        block.msdf = req.msdf
        for (i, line) in lines.enumerated() {
            let w = lineBounds[i].maxX - lineBounds[i].minX
            let alignX: Float = req.horizontalAlign == 1 ? (maxLineWidth - w) * 0.5 : req.horizontalAlign == 2 ? maxLineWidth - w : 0
            let y = -Float(i) * lineHeight
            var pen: Float = 0
            for g in line.glyphs {
                defer { pen += g.advance }
                guard !g.atlas.empty else { continue }
                let a = g.atlas
                let page = a.color ? colorPage : grayPage
                let pw = Float(page.width), ph = Float(page.height)
                let u0 = Float(a.rect.x) / pw, u1 = Float(a.rect.x + a.rect.w) / pw
                let v0 = Float(a.rect.y) / ph, v1 = Float(a.rect.y + a.rect.h) / ph
                let x0 = pen + a.x0 - a.pad + alignX, x1 = pen + a.x1 + a.pad + alignX
                let yb = y + a.y0 - a.pad, yt = y + a.y1 + a.pad
                let quad: [Float] = [x0, yt, 0, u0, v0, x1, yt, 0, u1, v0, x0, yb, 0, u0, v1, x1, yb, 0, u1, v1]
                if a.color {
                    let base = UInt32(block.colorVertices.count / 5)
                    block.colorVertices += quad
                    block.colorIndices += [0, 2, 1, 1, 2, 3].map { base + $0 }
                } else {
                    let base = UInt32(block.grayVertices.count / 5)
                    block.grayVertices += quad
                    block.grayIndices += [0, 2, 1, 1, 2, 3].map { base + $0 }
                }
            }
        }
        block.grayGeneration = grayPage.generation
        block.colorGeneration = colorPage.generation
        return block
    }

    /// Shapes one paragraph. CoreText stands in for HarfBuzz + the engine fallback chain; advances are whole
    /// pixels (`x_advance >> 6`) plus `spacing.x`.
    private static func shape(_ s: String, font: CTFont, spacing: Float, atlas: GlyphAtlas, msdf: Bool = false) -> [Glyph] {
        guard !s.isEmpty else { return [] }
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        let utf16 = Array(s.utf16)
        // UTF-16 index → Unicode scalar index, for HarfBuzz-style clusters.
        var scalarIndex = [Int](repeating: 0, count: utf16.count + 1)
        do {
            var si = 0, ui = 0
            for sc in s.unicodeScalars {
                let w = sc.utf16.count
                for k in 0..<w where ui + k < scalarIndex.count { scalarIndex[ui + k] = si }
                ui += w; si += 1
            }
            if ui < scalarIndex.count { scalarIndex[ui] = si }
        }
        var out: [Glyph] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            let key = GlyphAtlas.fontKey(runFont)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for k in 0..<n {
                let ch = indices[k] < utf16.count ? UInt32(utf16[indices[k]]) : 0
                let g = atlas.glyph(glyphs[k], font: runFont, fontKey: key, msdf: msdf)
                out.append(Glyph(atlas: g, advance: Float(advances[k].width.rounded()) + spacing, whitespace: isBreakSpace(ch),
                                 cluster: indices[k] < scalarIndex.count ? scalarIndex[indices[k]] : 0))
            }
        }
        return out
    }
}
