import CoreText
import Foundation

/// `photon-tool text-shape <font name|file> <size> <text>`: how CoreText lays out one line (CTLine runs: font, glyph
/// ids, advances, positions, string indices). `photon-linux text-shape` prints the same format from the Linux CoreText
/// stand-in (FreeType + HarfBuzz), and scripts/linux/ci.sh compares the two (docs/linux-port.md §3.3).
func textShape(_ args: [String]) {
    guard args.count >= 3, let size = Double(args[1]) else { print("usage: text-shape <font name|file> <size> <text>"); return }
    let font: CTFont
    if args[0].contains("/"), let data = FileManager.default.contents(atPath: args[0]),
       let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) {
        font = CTFontCreateWithGraphicsFont(cg, CGFloat(size), nil, nil)
    } else {
        font = CTFontCreateWithName(args[0] as CFString, CGFloat(size), nil)
    }
    let text = args[2...].joined(separator: " ")
    print(String(format: "font %@ ascent %.4f descent %.4f leading %.4f", CTFontCopyPostScriptName(font) as String,
                 Double(CTFontGetAscent(font)), Double(CTFontGetDescent(font)), Double(CTFontGetLeading(font))))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n), adv = [CGSize](repeating: .zero, count: n)
        var pos = [CGPoint](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
        print("run \(CTFontCopyPostScriptName(runFont) as String) \(n)")
        for k in 0..<n {
            print(String(format: "  %d g%d adv %.4f x %.4f y %.4f", idx[k], Int(glyphs[k]), Double(adv[k].width), Double(pos[k].x), Double(pos[k].y)))
        }
    }
}
