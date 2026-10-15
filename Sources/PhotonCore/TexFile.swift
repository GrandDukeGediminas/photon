#if canImport(Compression)
import Compression
#endif
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// A parsed `.tex` file (docs/re/01 §3, `sub_14015e580`).
public struct TexFile {
    public enum Format: Int32 {
        case rgba8888 = 0, dxt5 = 4, dxt3 = 6, dxt1 = 7, rg88 = 8, r8 = 9
        case rg16f = 10, r16f = 11, bc7 = 12, rgb10a2 = 13, rgba16f = 14, r32f = 16
        case rgba16 = 17, rgba16s = 19

        /// `sub_1400d2a20`: 15 → R16G16B16A16_FLOAT, 17/18 → R16G16B16A16_UNORM, 19/20 → R16G16B16A16_SNORM; 1, 2, 3, 5, 21
        /// and unknown values map to RGBA8 (docs/re/01 §3.3).
        init(raw: Int32) {
            switch raw {
            case 15: self = .rgba16f
            case 18: self = .rgba16
            case 20: self = .rgba16s
            default: self = Format(rawValue: raw) ?? .rgba8888
            }
        }
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }
        public static let noInterpolation = Flags(rawValue: 0x1)
        public static let clampUVs = Flags(rawValue: 0x2)
        public static let spriteSheet = Flags(rawValue: 0x4)
        public static let singleMip = Flags(rawValue: 0x8)
        public static let video = Flags(rawValue: 0x20)
        public static let volume = Flags(rawValue: 0x40)
    }

    public struct Mip {
        public let width: Int
        public let height: Int
        public let depth: Int
        /// Raw pixels in `format`, RGBA8 after image decoding, or an MP4 file for video textures.
        public let data: Data
    }

    /// A sprite-sheet frame: a parallelogram in padded-texture UV space (§3.6).
    public struct Frame {
        public let imageIndex: Int
        public let frameTime: Float
        public let u: Float, v: Float
        public let xAxis: SIMD2<Float>
        public let yAxis: SIMD2<Float>
    }

    public enum Error: Swift.Error {
        case badMagic(String)
        case lz4
        case image
        case truncated
    }

    public var format: Format = .rgba8888
    /// The TEXI format code as stored (texture object +0x18). `TEXnFORMAT` combos take this value (`sub_1401a5c40`),
    /// including codes that load as RGBA8 (1 RGB888, 2 RGB565, 3 ETC1, 5 ETC2, 21 …).
    public var rawFormat: Int32 = 0
    public var flags: Flags = []
    public var textureWidth = 0, textureHeight = 0
    public var imageWidth = 0, imageHeight = 0
    public var depth = 1
    /// Free-image format of each mip blob; -1 means raw pixels.
    public var imageFormat: Int32 = -1
    public var images: [[Mip]] = []
    public var frames: [Frame] = []
    public var sheetWidth = 0, sheetHeight = 0

    /// The pixel format of `images` after decoding. Encoded images always decode to RGBA8.
    public var pixelFormat: Format { imageFormat == -1 ? format : .rgba8888 }

    /// Texture reduction of the scene being loaded (`C+0x1218`, docs/re/07 §3.6): 1, or 2 for the `resolution` setting
    /// "half" (or "auto" on a small screen). With 2, `Texture_load` passes load flags 6 instead of 4 (0x1400ec43a–
    /// 0x1400ec453): TEXB drops mip 0 of every image that has more than one mip, and the TEXV reader halves the sprite
    /// frame rects (0x14015e937–0x14015e9a3).
    nonisolated(unsafe) public static var loadReduction = 1
    /// TEXB returned 1: some image lost its top mip.
    public private(set) var droppedTopMip = false

    public init(data: Data) throws {
        try self.init(data: data, reduction: Self.loadReduction)
    }

    public init(data: Data, reduction: Int) throws {
        reductionLoad = reduction > 1
        var r = BinaryReader(data)
        let magic = r.cString()
        switch magic {
        case "TEXV0005":
            while r.remaining > 0 {
                let tag = r.cString()
                let ver = tag.count > 4 ? Int(tag.dropFirst(4)) ?? 0 : 0
                switch tag.prefix(4) {
                case "TEXI": readTEXI(&r, version: ver)
                case "TEXB": try readTEXB(&r, version: ver)
                case "TEXS": readTEXS(&r, version: ver)
                default: r = BinaryReader(data, offset: data.count)
                }
            }
        case "TEXV0004":
            readTEXI(&r, version: 0)
            try readTEXB(&r, version: 0)
        default:
            throw Error.badMagic(magic)
        }
        if let first = images.first, first.count < 2 { flags.insert(.singleMip) }
        if droppedTopMip {
            frames = frames.map { f in
                Frame(imageIndex: f.imageIndex, frameTime: f.frameTime, u: f.u * 0.5, v: f.v * 0.5,
                      xAxis: f.xAxis * 0.5, yAxis: f.yAxis * 0.5)
            }
        }
    }
    private var reductionLoad = false

    private mutating func readTEXI(_ r: inout BinaryReader, version: Int) {
        rawFormat = r.i32()
        format = Format(raw: rawFormat)
        flags.formUnion(Flags(rawValue: r.i32()))
        textureWidth = Int(r.i32()); textureHeight = Int(r.i32())
        imageWidth = Int(r.i32()); imageHeight = Int(r.i32())
        if flags.contains(.volume) { depth = Int(r.i32()) }
        if version >= 1 { _ = r.i32() } // unknown, looks like an ARGB colour; unused by the loader
    }

    /// TEXB0004 variant selection (`info+0x20`): property name → the chosen value ("1"/"0" for bool conditions, the matched
    /// string, or "$__default"). `Texture_load` binds one user listener per entry and reloads the texture when a value
    /// changes (0x14015ea10 / 0x140161a60); photon2 reloads the whole scene on a property change instead.
    public var variantSelection: [String: String] = [:]

    /// The condition evaluator TEXB uses (vt[0] of the scene binding manager, 0x140174a60), against the project
    /// properties: no `cond` → the property's `value` is a JSON bool that is true; with `cond` → the `value` is a JSON
    /// string equal to it (case-sensitive). Numbers never match (unlike `UserProps_Apply`).
    public static func variantCondition(_ name: String, _ cond: String?, _ props: [String: Any]) -> Bool {
        guard let v = props[name] else { return false }
        if let cond { return (v as? String) == cond }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return false
    }

    private struct Patch {
        let mode: Int32, fif: Int32
        let x: Int, y: Int, w: Int, h: Int
        let data: Data?
    }

    /// TEXB 0x14015c8d0 (docs/re/01 §3.5). Variants (v4): `{i32 groupId, i32 patchKey, i32 patchMode, cstring json}`; the
    /// first matching variant per group sets keyMode[patchKey] = patchMode (bit 0 alpha-over, bit 1 replace). With
    /// variants, each mip is followed by `u32 groups; per group u32 n; n × {i32 ignored, i32 key, u32 x, y, w, h, i32 fif,
    /// i32 size, bytes}`; patches whose key is selected apply in file order to that mip.
    private mutating func readTEXB(_ r: inout BinaryReader, version: Int) throws {
        let imageCount = version >= 1 ? Int(r.i32()) : 1
        imageFormat = version >= 3 ? r.i32() : -1
        let variants = version >= 4 ? Int(r.i32()) : 0
        if imageFormat != -1 { textureWidth = imageWidth; textureHeight = imageHeight }
        var keyMode: [Int32: Int32] = [:]
        var taken = Set<Int32>()
        let props = UserProperties.current
        for _ in 0..<max(variants, 0) {
            let group = r.i32(), key = r.i32(), mode = r.i32()
            let text = r.cString()
            // A JSON parse error skips the variant (a non-object root asserts in the engine).
            guard let doc = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let c = doc["condition"] else { continue }
            var eq = false
            if let name = c as? String {
                eq = Self.variantCondition(name, nil, props)
                variantSelection[name] = eq ? "1" : "0"
            } else if let o = c as? [String: Any], let name = o["name"] as? String, let cc = o["condition"] as? String {
                eq = Self.variantCondition(name, cc, props)
                if eq || variantSelection[name] == nil { variantSelection[name] = eq ? cc : "$__default" }
            } else {
                continue
            }
            if eq, taken.insert(group).inserted { keyMode[key] = mode }
        }
        for _ in 0..<max(imageCount, 0) {
            let mipCount = Int(r.i32())
            var mips: [Mip] = []
            for mipIndex in 0..<max(mipCount, 0) {
                let w = Int(r.i32()), h = Int(r.i32())
                let d = flags.contains(.volume) ? Int(r.i32()) : 1
                // "Invalid texture resolution" (> 8192, depth > 128 or a 32-bit size overflow) is only logged.
                if w > 0x2000 || h > 0x2000 || d > 0x80 { NSLog("photon: Invalid texture resolution: w=%d h=%d d=%d", w, h, d) }
                var compression: Int32 = 0, decompressedSize = 0
                if version >= 2 { compression = r.i32(); decompressedSize = Int(r.i32()) }
                guard let blob = r.bytes(Int(r.i32())) else { throw Error.truncated }
                // Load flag 2 (texture reduction): mip 0 of a multi-mip image is read and discarded before its patch
                // list, so with variants the next mip header is read from those bytes (engine quirk, docs/re/01 §3.5).
                if reductionLoad && mipCount > 1 && mipIndex == 0 {
                    droppedTopMip = true
                    continue
                }

                var patches: [Patch] = []
                if variants > 0 && r.remaining >= 4 {
                    for _ in 0..<r.u32() {
                        for _ in 0..<r.u32() {
                            _ = r.i32()
                            let key = r.i32()
                            let x = Int(r.u32()), y = Int(r.u32()), pw = Int(r.u32()), ph = Int(r.u32())
                            let pf = r.i32(), size = Int(r.i32())
                            let pdata = r.bytes(size)
                            if let mode = keyMode[key] { patches.append(Patch(mode: mode, fif: pf, x: x, y: y, w: pw, h: ph, data: pdata)) }
                        }
                    }
                }
                // erase(begin, begin + i − 1) for the last replace patch i ≥ 2 (with two replace patches the earlier wins).
                if let i = patches.lastIndex(where: { $0.mode & 2 != 0 }), i >= 2 { patches.removeFirst(i - 1) }

                var payload = blob
                let lz4 = compression & 1 != 0
                if flags.contains(.video) {
                    // MP4 handed to the video player as-is.
                } else if lz4 {
                    guard let out = Self.lz4Block(blob, size: decompressedSize) else { throw Error.lz4 }
                    payload = out
                } else if imageFormat != -1 {
                    guard let out = Self.decodeImage(blob, width: w, height: h * d) else { throw Error.image }
                    payload = out
                }
                if !patches.isEmpty && !flags.contains(.video) {
                    payload = applyPatches(patches, to: payload, width: w, height: h, lz4: lz4)
                }
                mips.append(Mip(width: w, height: h, depth: d, data: payload))
            }
            images.append(mips)
        }
    }

    /// Patch application (TEXB, blit 0x14015c480): a replace patch swaps in its bytes as-is and stops; others are
    /// bounds-checked rectangles, LZ4- or image-decoded like their mip, then copied (formats 0/4/6/7/8/9) or, with mode
    /// bit 0 on RGBA8 only, alpha-blended in 32-bit integer arithmetic.
    private func applyPatches(_ patches: [Patch], to pixels: Data, width w: Int, height h: Int, lz4: Bool) -> Data {
        var buf = [UInt8](pixels)
        let fmt = pixelFormat.rawValue
        for p in patches {
            if p.mode & 2 != 0 { return p.data ?? Data() }
            guard p.w > 0, p.h > 0, p.x <= w, p.w <= w - p.x, p.y <= h, p.h <= h - p.y, let pd = p.data, !pd.isEmpty else { continue }
            var src: Data
            if lz4 {
                // LZ4_decompress_safe with capacity w·h·4 whatever the format (an R8 patch decodes to fewer bytes).
                guard let o = Self.lz4Block(pd, capacity: p.w * p.h * 4) else { continue }
                src = o
            } else if imageFormat != -1 {
                guard let o = Self.decodeImage(pd, width: p.w, height: p.h) else { continue }
                src = o
            } else {
                src = pd
            }
            let s = [UInt8](src)
            func copy(_ dst: Int, _ so: Int, _ n: Int) {
                guard dst >= 0, so >= 0, n > 0, dst + n <= buf.count, so + n <= s.count else { return }
                buf.replaceSubrange(dst..<(dst + n), with: s[so..<(so + n)])
            }
            if p.mode & 1 != 0 {
                guard fmt == 0 else { continue }
                for row in 0..<p.h {
                    for col in 0..<p.w {
                        let so = (p.w * row + col) * 4, o = ((p.y + row) * w + p.x + col) * 4
                        guard so + 4 <= s.count, o + 4 <= buf.count else { continue }
                        let sv = UInt32(s[so]) | UInt32(s[so + 1]) << 8 | UInt32(s[so + 2]) << 16 | UInt32(s[so + 3]) << 24
                        let dv = UInt32(buf[o]) | UInt32(buf[o + 1]) << 8 | UInt32(buf[o + 2]) << 16 | UInt32(buf[o + 3]) << 24
                        let a = sv >> 24
                        let rb = ((((sv & 0xff00ff) &- (dv & 0xff00ff)) &* a) >> 8 &+ (dv & 0xff00ff)) & 0xff00ff
                        let g = ((((sv & 0xff00) &- (dv & 0xff00)) &* a) >> 8 &+ (dv & 0xff00)) & 0xff00
                        let out = rb | g | (max(dv >> 24, a) << 24)
                        buf[o] = UInt8(out & 0xff); buf[o + 1] = UInt8(out >> 8 & 0xff)
                        buf[o + 2] = UInt8(out >> 16 & 0xff); buf[o + 3] = UInt8(out >> 24)
                    }
                }
                continue
            }
            switch fmt {
            case 0: for row in 0..<p.h { copy(((p.y + row) * w + p.x) * 4, row * p.w * 4, p.w * 4) }
            case 4, 6: for row in stride(from: 0, to: p.h, by: 4) { copy((p.y + row) * w + p.x * 4, p.w * row, p.w * 4) }
            case 7: for row in stride(from: 0, to: p.h, by: 4) { copy(((p.y + row) * w + p.x * 4) >> 1, (p.w * row) >> 1, p.w * 2) }
            case 8: for row in 0..<p.h { copy(((p.y + row) * w + p.x) * 2, row * p.w * 2, p.w * 2) }
            case 9: for row in 0..<p.h { copy((p.y + row) * w + p.x, row * p.w, p.w) }
            default: break
            }
        }
        return Data(buf)
    }

    private mutating func readTEXS(_ r: inout BinaryReader, version: Int) {
        let count = Int(r.i32())
        if version >= 3 {
            sheetWidth = Int(r.i32()); sheetHeight = Int(r.i32())
        } else {
            sheetWidth = imageWidth; sheetHeight = imageHeight
        }
        for _ in 0..<max(count, 0) {
            let index = Int(r.i32())
            let time = r.f32()
            var v = [Float](repeating: 0, count: 6)
            for i in 0..<6 { v[i] = version == 1 ? Float(r.i32()) : r.f32() }
            // Normalise by the referenced image's mip 0 size.
            if index >= 0, index < images.count, let mip0 = images[index].first {
                let w = Float(mip0.width), h = Float(mip0.height)
                v[0] /= w; v[2] /= w; v[4] /= w
                v[1] /= h; v[3] /= h; v[5] /= h
            }
            frames.append(Frame(imageIndex: index, frameTime: time, u: v[0], v: v[1],
                                xAxis: [v[2], v[3]], yAxis: [v[4], v[5]]))
        }
    }

    /// LZ4_decompress_safe semantics with an output capacity: the decoded bytes, whatever their count.
    static func lz4Block(_ src: Data, capacity: Int) -> Data? {
        guard capacity > 0, !src.isEmpty else { return nil }
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written > 0 ? out.prefix(written) : nil
    }

    /// LZ4 raw block decompression (`sub_14014c160` is LZ4_decompress_safe).
    static func lz4Block(_ src: Data, size: Int) -> Data? {
        guard size > 0 else { return src == Data([0]) ? Data() : nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? out : nil
    }

#if canImport(ImageIO)
    /// The engine decodes embedded images (PNG = 13, JPEG = 2 in practice) to RGBA8 with wuffs.
    static func decodeImage(_ blob: Data, width: Int, height: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(blob as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let w = width > 0 ? width : image.width, h = height > 0 ? height : image.height
        var out = Data(count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            // Straight (un-premultiplied) RGBA, matching wuffs' RGBA_NONPREMUL output.
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        unpremultiply(&out)
        return out
    }
#endif

    /// CGContext cannot draw into a non-premultiplied RGBA8 buffer, so undo it after drawing.
    static func unpremultiply(_ data: inout Data) {
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a != 0 && a != 255 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
    }
}
