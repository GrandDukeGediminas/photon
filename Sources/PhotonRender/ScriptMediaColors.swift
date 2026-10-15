import AppKit
import Foundation

/// Thumbnail colours of the media integration, ported from `winrtutil64.exe` (sha256 of the installed build in
/// docs/re/08 §7). All arithmetic is single precision except where the binary converts to double.
///
/// - `dominant` = 0x140065590: an HSV hue histogram over pixels with alpha >= 16 (`c >= 0x10000000`), 360 bins of
///   {Σs, Σv, Σ(int)(v·s·100), count}; primary = the bin with the highest score (first wins), secondary = highest
///   `score·d1/180` (d1 = circular hue distance to the primary, in bins), tertiary = highest
///   `score·((d1/180)·(d2/180))²` (d2 to the secondary). Each colour is (bin/360, Σs/n, Σv/n) converted by
///   `hsvToRGB` (0x140063cc0) and packed as 0xFFBBGGRR with each channel `clamp((int)(c·255), 0, 255)`.
/// - `palette` = the thumbnail handler 0x140046c20: the three colours plus highContrastColor (black 0x00000000 when
///   the primary's WCAG contrast against black is >= 2.5, else white 0xFFFFFFFF) and textColor.
enum MediaColors {
    /// [primary, secondary, tertiary, textColor, highContrastColor] as sent in the thumbnail event.
    static func palette(_ px: [UInt32], width: Int, height: Int) -> [UInt32] {
        let (p, s, t) = dominant(px, width: width, height: height)
        let black: SIMD3<Float> = .zero
        let high: UInt32 = contrast(rgb(p), black) >= 2.5 ? 0 : 0xFFFF_FFFF
        let cs = contrast(rgb(p), rgb(s)), ct = contrast(rgb(p), rgb(t))
        let text: UInt32 = (cs >= 2.5 && cs > ct) ? s : (ct >= 2.5 ? t : high)
        return [p, s, t, text, high]
    }

    static func rgb(_ c: UInt32) -> SIMD3<Float> {
        SIMD3(Float(c & 0xff) / 255, Float((c >> 8) & 0xff) / 255, Float((c >> 16) & 0xff) / 255)
    }

    /// 0x14002db80: (max(L1, L2) + 0.05) / (min(L1, L2) + 0.05), L = 0.2126 R + 0.7152 G + 0.0722 B of the
    /// linearised channels (c <= 0.03928 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)).
    static func contrast(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        func lin(_ c: Float) -> Float { c <= 0.03928 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        let la = lin(a.x) * 0.2126 + lin(a.y) * 0.7152 + lin(a.z) * 0.0722
        let lb = lin(b.x) * 0.2126 + lin(b.y) * 0.7152 + lin(b.z) * 0.0722
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func dominant(_ px: [UInt32], width: Int, height: Int) -> (UInt32, UInt32, UInt32) {
        var satSum = [Float](repeating: 0, count: 360), valSum = [Float](repeating: 0, count: 360)
        var score = [Int64](repeating: 0, count: 360), count = [UInt64](repeating: 0, count: 360)
        for x in 0..<width {
            for y in 0..<height {
                let c = px[y * width + x]
                guard c >= 0x1000_0000 else { continue }
                let r = Float(c & 0xff) / 255, g = Float((c >> 8) & 0xff) / 255, b = Float((c >> 16) & 0xff) / 255
                let mx = max(max(r, g), b), mn = min(min(r, g), b)
                let delta = mx - mn
                var s: Float = 0
                var bin = 0
                if delta >= 1e-5, mx > 0 {
                    s = delta / mx
                    var h: Float
                    if r >= mx { h = (g - b) / delta }
                    else if g >= mx { h = Float(Double((b - r) / delta) + 2.0) }
                    else { h = Float(Double((r - g) / delta) + 4.0) }
                    h /= 6
                    if h < 0 { h += 1 }
                    bin = min(max(Int(h * 360), 0), 359)
                }
                satSum[bin] += s
                valSum[bin] += mx
                score[bin] += Int64(Int32(truncatingIfNeeded: Int(mx * s * 100)))
                count[bin] += 1
            }
        }
        func hsv(_ bin: Int) -> SIMD3<Float> {
            let n = Float(count[bin])
            return SIMD3(Float(bin) / 360, satSum[bin] / n, valSum[bin] / n)
        }
        func dist(_ a: Int, _ b: Int) -> Float {
            let d = Float(abs(a - b))
            return d > 180 ? 360 - d : d
        }
        var best: Int64 = 0, pBin = 0
        var p = SIMD3<Float>(repeating: 0)
        for i in 0..<360 where score[i] > best { best = score[i]; pBin = i; p = hsv(i) }
        var best2: Int32 = 0, sBin = 0
        var s = SIMD3<Float>(repeating: 0)
        for i in 0..<360 {
            let w = Float(score[i]) * dist(pBin, i) / 180
            if w > Float(best2) { best2 = Int32(truncatingIfNeeded: Int(w)); sBin = i; s = hsv(i) }
        }
        var best3: Int32 = 0
        var t = SIMD3<Float>(repeating: 0)
        for i in 0..<360 {
            let f = dist(pBin, i) / 180 * dist(sBin, i) / 180
            let w = Float(score[i]) * (f * f)
            if w > Float(best3) { best3 = Int32(truncatingIfNeeded: Int(w)); t = hsv(i) }
        }
        return (pack(hsvToRGB(p)), pack(hsvToRGB(s)), pack(hsvToRGB(t)))
    }

    static func pack(_ c: SIMD3<Float>) -> UInt32 {
        func ch(_ v: Float) -> UInt32 { UInt32(min(max(Int(Int32(truncatingIfNeeded: Int(v * 255))), 0), 255)) }
        return 0xFF00_0000 | (ch(c.z) << 16) | (ch(c.y) << 8) | ch(c.x)
    }

    /// 0x140063cc0: C = v·s, h' = fmod(h·6, 6) (double, stored as float), X = C·(1 − |fmod(h', 2) − 1|),
    /// m = v − C; sextant 0…5 picks (C,X,0) (X,C,0) (0,C,X) (0,X,C) (X,0,C) (C,0,X), anything else (0,0,0).
    static func hsvToRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let v = hsv.z, c = v * hsv.y
        let hp = Float(fmod(Double(hsv.x * 6), 6.0))
        let x = Float((1.0 - abs(fmod(Double(hp), 2.0) - 1.0)) * Double(c))
        let m = v - c
        var rgb: SIMD3<Float>
        if hp >= 0 && hp < 1 { rgb = SIMD3(c, x, 0) }
        else if hp >= 1 && hp < 2 { rgb = SIMD3(x, c, 0) }
        else if hp >= 2 && hp < 3 { rgb = SIMD3(0, c, x) }
        else if hp >= 3 && hp < 4 { rgb = SIMD3(0, x, c) }
        else if hp >= 4 && hp < 5 { rgb = SIMD3(x, 0, c) }
        else if hp >= 5 && hp < 6 { rgb = SIMD3(c, 0, x) }
        else { rgb = .zero }
        return rgb + SIMD3(repeating: m)
    }

    #if os(Linux)
    /// Straight RGBA8 → premultiplied 0xAABBGGRR words (CoreGraphics' premultiplication: c·a/255 rounded).
    static func premultipliedWords(_ straight: Data, width w: Int, height h: Int) -> (data: [UInt32], width: Int, height: Int) {
        var px = [UInt32](repeating: 0, count: w * h)
        straight.withUnsafeBytes { s in
            for i in 0..<min(w * h, s.count / 4) {
                let a = UInt32(s[i * 4 + 3])
                func pm(_ c: UInt8) -> UInt32 { (UInt32(c) * a + 127) / 255 }
                px[i] = a << 24 | pm(s[i * 4 + 2]) << 16 | pm(s[i * 4 + 1]) << 8 | pm(s[i * 4])
            }
        }
        return (px, w, h)
    }
    #endif

    /// Decodes an image into 0xAABBGGRR pixels (R in the low byte, as the thumbnail handler reads them).
    static func rgba(_ img: NSImage) -> (data: [UInt32], width: Int, height: Int)? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt32](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // byteOrder32Little + premultipliedLast stores A,B,G,R in memory → as UInt32 that is 0xRRGGBBAA; swap to
        // 0xAABBGGRR.
        return (px.map { $0.byteSwapped }, w, h)
    }
}
