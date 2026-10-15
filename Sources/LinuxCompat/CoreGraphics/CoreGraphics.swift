// Linux stand-in for Apple's CoreGraphics (docs/linux-port.md §4): the subset PhotonRender calls.
//
// - Bitmap CGContext over caller memory (8-bit gray, 8-bit RGBA/BGRA with the alpha/byte-order combinations the
//   renderer uses), solid fills, image draws (bilinear, CG's bottom-left user space), makeImage.
// - CGImage / CGColorSpace / CGDataProvider value holders, CGFont over a FreeType face, CGPath with element iteration.
// - The CoreFoundation names the font code spells (CFString, CFData, CFRange, CFIndex, CFHash), which
//   swift-corelibs-foundation does not export, and NSMapTable (also missing there).
// CGFloat, CGPoint, CGSize and CGRect come from Foundation on Linux and are re-exported.

@_exported import Foundation
import CFreeType

// MARK: - CoreFoundation names

public typealias CFString = String
public typealias CFData = Data
public typealias CFIndex = Int
public typealias CFTypeRef = AnyObject
public typealias CGGlyph = UInt16
public typealias UniChar = UInt16

public struct CFRange: Hashable {
    public var location: CFIndex
    public var length: CFIndex
    public init(location: CFIndex, length: CFIndex) {
        self.location = location
        self.length = length
    }
}

public func CFRangeMake(_ location: CFIndex, _ length: CFIndex) -> CFRange { CFRange(location: location, length: length) }

/// Identity hash, as CFHash gives for CTFont/CGFont (pointer-based on Apple platforms).
public func CFHash(_ object: AnyObject) -> Int { ObjectIdentifier(object).hashValue }

// MARK: - NSMapTable (missing from swift-corelibs-foundation)

public struct NSPointerFunctions {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let strongMemory = Options([])
        public static let weakMemory = Options(rawValue: 5)
        public static let copyIn = Options(rawValue: 1 << 16)
        public static let objectPointerPersonality = Options(rawValue: 512)
    }
}

/// Object-keyed map with weak or strong keys and values (identity semantics, as NSMapTable with object keys).
/// Entries whose weak key or value has gone are dropped on access.
public final class NSMapTable<KeyType: AnyObject, ObjectType: AnyObject> {
    private final class Box {
        weak var weakObject: AnyObject?
        var strongObject: AnyObject?
        init(_ o: AnyObject, weak: Bool) { if weak { weakObject = o } else { strongObject = o } }
        var object: AnyObject? { strongObject ?? weakObject }
    }
    private let weakKeys: Bool
    private let weakValues: Bool
    private var entries: [ObjectIdentifier: (key: Box, value: Box)] = [:]
    private let lock = NSLock()

    public init(keyOptions: NSPointerFunctions.Options = .strongMemory, valueOptions: NSPointerFunctions.Options = .strongMemory,
                capacity: Int = 0) {
        weakKeys = keyOptions.contains(.weakMemory)
        weakValues = valueOptions.contains(.weakMemory)
    }

    public static func strongToStrongObjects() -> NSMapTable { NSMapTable() }
    public static func weakToStrongObjects() -> NSMapTable { NSMapTable(keyOptions: .weakMemory) }
    public static func strongToWeakObjects() -> NSMapTable { NSMapTable(valueOptions: .weakMemory) }
    public static func weakToWeakObjects() -> NSMapTable { NSMapTable(keyOptions: .weakMemory, valueOptions: .weakMemory) }

    private func purge() { entries = entries.filter { $0.value.key.object != nil && $0.value.value.object != nil } }

    public func object(forKey key: KeyType?) -> ObjectType? {
        guard let key else { return nil }
        return lock.withLock {
            purge()
            guard let e = entries[ObjectIdentifier(key)], e.key.object === key else { return nil }
            return e.value.object as? ObjectType
        }
    }

    public func setObject(_ object: ObjectType?, forKey key: KeyType?) {
        guard let key else { return }
        lock.withLock {
            purge()
            if let object {
                entries[ObjectIdentifier(key)] = (Box(key, weak: weakKeys), Box(object, weak: weakValues))
            } else {
                entries[ObjectIdentifier(key)] = nil
            }
        }
    }

    public func removeObject(forKey key: KeyType?) { setObject(nil, forKey: key) }
    public func removeAllObjects() { lock.withLock { entries.removeAll() } }
    public var count: Int { lock.withLock { purge(); return entries.count } }
}

// MARK: - Affine transform

public struct CGAffineTransform: Equatable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }
    public static let identity = CGAffineTransform()
    public init(translationX x: CGFloat, y: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public init(scaleX x: CGFloat, y: CGFloat) { self.init(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    public var isIdentity: Bool { self == .identity }
    /// `self` then `t` (CG order: t2 ∘ t1 applied to row vectors).
    public func concatenating(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: a * t.a + b * t.c, b: a * t.b + b * t.d, c: c * t.a + d * t.c, d: c * t.b + d * t.d,
                          tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }
    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: x, y: y).concatenating(self) }
    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(scaleX: x, y: y).concatenating(self) }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

// MARK: - Colour spaces, bitmap info

public final class CGColorSpace {
    public enum Model { case monochrome, rgb }
    public let model: Model
    public let name: CFString?
    public static let sRGB: CFString = "kCGColorSpaceSRGB"
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear"
    public static let linearSRGB: CFString = "kCGColorSpaceLinearSRGB"
    public static let genericGrayGamma2_2: CFString = "kCGColorSpaceGenericGrayGamma2_2"
    public static let linearGray: CFString = "kCGColorSpaceLinearGray"
    init(model: Model, name: CFString?) {
        self.model = model
        self.name = name
    }
    /// Named spaces: no colour management on Linux, so only the channel model matters.
    public convenience init?(name: CFString) {
        self.init(model: name.lowercased().contains("gray") ? .monochrome : .rgb, name: name)
    }
    public var numberOfComponents: Int { model == .rgb ? 3 : 1 }
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(model: .rgb, name: nil) }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(model: .monochrome, name: nil) }

public enum CGImageAlphaInfo: UInt32 {
    case none = 0, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

public struct CGBitmapInfo: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo([])
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
    public init(alpha: CGImageAlphaInfo) { self.init(rawValue: alpha.rawValue) }
}

/// Where R, G, B, A sit inside one 4-byte pixel for a bitmapInfo (nil alpha = skipped/none).
struct PixelLayout {
    var r = 0, g = 1, b = 2, a: Int? = 3
    var premultiplied = true
    var gray = false

    init?(space: CGColorSpace?, bitsPerComponent: Int, bitmapInfo: UInt32) {
        guard bitsPerComponent == 8 else { return nil }
        let alpha = CGImageAlphaInfo(rawValue: bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
        if space?.model == .monochrome || alpha == .alphaOnly {
            // 8-bit gray (alpha none) or alpha-only: one byte per pixel.
            guard alpha == .none || alpha == .alphaOnly else { return nil }
            gray = true
            a = alpha == .alphaOnly ? 0 : nil
            return
        }
        // Order in a big-endian 32-bit word: Last = RGBA, First = ARGB.
        var order: [Character]
        switch alpha {
        case .premultipliedLast, .last, .noneSkipLast: order = ["r", "g", "b", "a"]
        case .premultipliedFirst, .first, .noneSkipFirst: order = ["a", "r", "g", "b"]
        default: return nil // 24-bit RGB without alpha is not supported by CG bitmap contexts either
        }
        if bitmapInfo & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue { order.reverse() }
        r = order.firstIndex(of: "r")!
        g = order.firstIndex(of: "g")!
        b = order.firstIndex(of: "b")!
        a = (alpha == .noneSkipLast || alpha == .noneSkipFirst) ? nil : order.firstIndex(of: "a")!
        premultiplied = alpha != .last && alpha != .first
    }

    var bytesPerPixel: Int { gray ? 1 : 4 }
}

// MARK: - Data provider, image

public final class CGDataProvider {
    public let data: CFData?
    public init?(data: CFData) { self.data = data }
}

/// An 8-bit image. Pixels are kept as premultiplied RGBA, rows top-down.
public final class CGImage {
    public let width: Int
    public let height: Int
    public let bitsPerComponent = 8
    public let bitsPerPixel = 32
    public var bytesPerRow: Int { width * 4 }
    public let colorSpace: CGColorSpace? = CGColorSpaceCreateDeviceRGB()
    public var alphaInfo: CGImageAlphaInfo { .premultipliedLast }
    public var bitmapInfo: CGBitmapInfo { CGBitmapInfo(alpha: .premultipliedLast) }
    /// Premultiplied RGBA, row 0 = top.
    public let premultipliedRGBA: [UInt8]

    public init(width: Int, height: Int, premultipliedRGBA: [UInt8]) {
        self.width = width
        self.height = height
        self.premultipliedRGBA = premultipliedRGBA
    }

    /// Straight-alpha RGBA rows (top-down), premultiplied here.
    public convenience init(width: Int, height: Int, straightRGBA: [UInt8]) {
        var p = straightRGBA
        for i in stride(from: 0, to: p.count - 3, by: 4) where p[i + 3] != 255 {
            let a = Int(p[i + 3])
            for c in 0..<3 { p[i + c] = UInt8((Int(p[i + c]) * a + 127) / 255) }
        }
        self.init(width: width, height: height, premultipliedRGBA: p)
    }

    public var dataProvider: CGDataProvider? { CGDataProvider(data: Data(premultipliedRGBA)) }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let s = ((y0 + y) * width + x0) * 4
            out.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: premultipliedRGBA[s..<(s + w * 4)])
        }
        return CGImage(width: w, height: h, premultipliedRGBA: out)
    }
}

// MARK: - Bitmap context

public enum CGInterpolationQuality: Int32 { case `default` = 0, none = 1, low = 2, medium = 4, high = 3 }
public enum CGBlendMode: Int32 { case normal = 0, copy = 17, clear = 16 }
public enum CGTextDrawingMode: Int32 { case fill = 0 }
public enum CGPathFillRule: Int { case winding = 0, evenOdd = 1 }

/// A bitmap context drawing into `data` (row 0 = top of the image; user space is y-up from the bottom-left corner,
/// as on macOS). Supports solid rects, images and (through CoreText) glyph coverage, all source-over in
/// premultiplied space.
public final class CGContext {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bitsPerComponent: Int
    public let bitmapInfo: CGBitmapInfo
    public let colorSpace: CGColorSpace?
    public let data: UnsafeMutableRawPointer?
    let layout: PixelLayout
    private var owned: UnsafeMutableRawPointer?

    /// Current transformation matrix (user → device, device y-up from the bottom-left).
    public private(set) var ctm = CGAffineTransform.identity
    public var textMatrix = CGAffineTransform.identity
    public var textPosition = CGPoint.zero
    public var interpolationQuality = CGInterpolationQuality.default
    /// Fill colour, straight RGBA 0…1.
    public private(set) var fillColor: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 1)
    public private(set) var shouldAntialias = true
    public private(set) var shouldSmoothFonts = true
    public private(set) var allowsFontSmoothing = true
    public private(set) var blendMode = CGBlendMode.normal
    private var stateStack: [(CGAffineTransform, (CGFloat, CGFloat, CGFloat, CGFloat), CGBlendMode)] = []

    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
                 space: CGColorSpace, bitmapInfo: UInt32) {
        guard width > 0, height > 0, let layout = PixelLayout(space: space, bitsPerComponent: bitsPerComponent, bitmapInfo: bitmapInfo)
        else { return nil }
        let bpr = bytesPerRow > 0 ? bytesPerRow : width * layout.bytesPerPixel
        guard bpr >= width * layout.bytesPerPixel else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bpr
        self.bitsPerComponent = bitsPerComponent
        self.bitmapInfo = CGBitmapInfo(rawValue: bitmapInfo)
        self.colorSpace = space
        self.layout = layout
        if let data {
            self.data = data
        } else {
            let p = UnsafeMutableRawPointer.allocate(byteCount: bpr * height, alignment: 16)
            memset(p, 0, bpr * height)
            owned = p
            self.data = p
        }
    }

    deinit { owned?.deallocate() }

    // State

    public func saveGState() { stateStack.append((ctm, fillColor, blendMode)) }
    public func restoreGState() {
        guard let s = stateStack.popLast() else { return }
        ctm = s.0; fillColor = s.1; blendMode = s.2
    }
    public func translateBy(x: CGFloat, y: CGFloat) { ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctm) }
    public func scaleBy(x: CGFloat, y: CGFloat) { ctm = CGAffineTransform(scaleX: x, y: y).concatenating(ctm) }
    public func concatenate(_ t: CGAffineTransform) { ctm = t.concatenating(ctm) }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { ctm }

    public func setFillColor(gray: CGFloat, alpha: CGFloat) { fillColor = (gray, gray, gray, alpha) }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { fillColor = (red, green, blue, alpha) }
    public func setShouldAntialias(_ v: Bool) { shouldAntialias = v }
    public func setAllowsAntialiasing(_ v: Bool) { shouldAntialias = v }
    public func setShouldSmoothFonts(_ v: Bool) { shouldSmoothFonts = v }
    public func setAllowsFontSmoothing(_ v: Bool) { allowsFontSmoothing = v }
    public func setShouldSubpixelPositionFonts(_ v: Bool) {}
    public func setShouldSubpixelQuantizeFonts(_ v: Bool) {}
    public func setAllowsFontSubpixelPositioning(_ v: Bool) {}
    public func setAllowsFontSubpixelQuantization(_ v: Bool) {}
    public func setTextDrawingMode(_ m: CGTextDrawingMode) {}
    public func setBlendMode(_ m: CGBlendMode) { blendMode = m }

    // Pixel access (premultiplied 0…255 floats)

    @inline(__always) func offset(_ x: Int, _ memRow: Int) -> Int { memRow * bytesPerRow + x * layout.bytesPerPixel }

    @inline(__always) func read(_ x: Int, _ memRow: Int) -> SIMD4<Float> {
        let p = data!.assumingMemoryBound(to: UInt8.self) + offset(x, memRow)
        if layout.gray {
            if layout.a != nil { return SIMD4(0, 0, 0, Float(p[0])) }
            return SIMD4(Float(p[0]), Float(p[0]), Float(p[0]), 255)
        }
        var v = SIMD4<Float>(Float(p[layout.r]), Float(p[layout.g]), Float(p[layout.b]), layout.a.map { Float(p[$0]) } ?? 255)
        if !layout.premultiplied, let _ = layout.a { v = SIMD4(v.x * v.w / 255, v.y * v.w / 255, v.z * v.w / 255, v.w) }
        return v
    }

    @inline(__always) func write(_ x: Int, _ memRow: Int, _ v: SIMD4<Float>) {
        let p = data!.assumingMemoryBound(to: UInt8.self) + offset(x, memRow)
        @inline(__always) func q(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f + 0.5).rounded(.down)))) }
        if layout.gray {
            if layout.a != nil { p[0] = q(v.w); return }
            // Gray without alpha: the luminance of the colour over an opaque result.
            p[0] = q(v.x * 0.299 + v.y * 0.587 + v.z * 0.114)
            return
        }
        var c = v
        if !layout.premultiplied, layout.a != nil {
            c = v.w > 0 ? SIMD4(v.x * 255 / v.w, v.y * 255 / v.w, v.z * 255 / v.w, v.w) : .zero
        }
        p[layout.r] = q(c.x); p[layout.g] = q(c.y); p[layout.b] = q(c.z)
        if let a = layout.a { p[a] = q(c.w) }
    }

    /// Source-over of premultiplied `src` onto device pixel (x, yUp) (y counted up from the bottom row).
    @inline(__always) func blend(_ x: Int, _ yUp: Int, _ src: SIMD4<Float>) {
        guard x >= 0, x < width, yUp >= 0, yUp < height else { return }
        let row = height - 1 - yUp
        if blendMode == .copy { write(x, row, src); return }
        if layout.gray && layout.a == nil {
            // Opaque destination: dst = src + dst·(1 − αs), on the gray value.
            let d = read(x, row)
            let g = (src.x * 0.299 + src.y * 0.587 + src.z * 0.114) + d.x * (1 - src.w / 255)
            write(x, row, SIMD4(g, g, g, 255))
            return
        }
        let d = read(x, row)
        write(x, row, src + d * (1 - src.w / 255))
    }

    /// Fill colour as premultiplied 0…255 scaled by `coverage` (0…1).
    @inline(__always) func fillSample(coverage: Float) -> SIMD4<Float> {
        let a = Float(fillColor.a) * coverage
        return SIMD4(Float(fillColor.r) * a * 255, Float(fillColor.g) * a * 255, Float(fillColor.b) * a * 255, a * 255)
    }

    /// Device-space bounds of a user rect under the CTM.
    func deviceRect(_ r: CGRect) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            .map { $0.applying(ctm) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // Drawing

    /// Fills `rect` with the fill colour; partial pixel coverage at the edges when antialiasing.
    public func fill(_ rect: CGRect) {
        let r = deviceRect(rect)
        let x0 = max(0, Int(floor(r.minX))), x1 = min(width, Int(ceil(r.maxX)))
        let y0 = max(0, Int(floor(r.minY))), y1 = min(height, Int(ceil(r.maxY)))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let cy = Float(min(CGFloat(y + 1), r.maxY) - max(CGFloat(y), r.minY))
            for x in x0..<x1 {
                let cx = Float(min(CGFloat(x + 1), r.maxX) - max(CGFloat(x), r.minX))
                var cov = max(0, min(1, cx)) * max(0, min(1, cy))
                if !shouldAntialias { cov = cov >= 0.5 ? 1 : 0 }
                if cov > 0 { blend(x, y, fillSample(coverage: cov)) }
            }
        }
    }

    public func fill(_ rects: [CGRect]) { for r in rects { fill(r) } }

    /// Sets `rect` to transparent black (opaque black for gray without alpha).
    public func clear(_ rect: CGRect) {
        let r = deviceRect(rect).integral
        let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 { write(x, height - 1 - y, .zero) } }
    }

    /// Composites coverage (row 0 = top) at device position (x0, yTop) with the fill colour.
    public func drawCoverage(_ coverage: UnsafePointer<UInt8>, width w: Int, height h: Int, pitch: Int, deviceX x0: Int, deviceTopY yTop: Int) {
        for r in 0..<h {
            let yUp = yTop - r
            guard yUp >= 0, yUp < height else { continue }
            for c in 0..<w {
                let v = coverage[r * pitch + c]
                guard v != 0 else { continue }
                var cov = Float(v) / 255
                if !shouldAntialias { cov = cov >= 0.5 ? 1 : 0 }
                blend(x0 + c, yUp, fillSample(coverage: cov))
            }
        }
    }

    /// Composites premultiplied RGBA pixels (row 0 = top) at device position (x0, yTop).
    public func drawPremultipliedRGBA(_ px: UnsafePointer<UInt8>, width w: Int, height h: Int, deviceX x0: Int, deviceTopY yTop: Int) {
        for r in 0..<h {
            for c in 0..<w {
                let p = px + (r * w + c) * 4
                guard p[3] != 0 else { continue }
                blend(x0 + c, yTop - r, SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])))
            }
        }
    }

    /// Draws `image` scaled into `rect` (the image's top row at the rect's top), bilinear unless interpolation is off.
    public func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false) {
        let r = deviceRect(rect)
        guard r.width > 0, r.height > 0, image.width > 0, image.height > 0 else { return }
        let x0 = max(0, Int(floor(r.minX))), x1 = min(width, Int(ceil(r.maxX)))
        let y0 = max(0, Int(floor(r.minY))), y1 = min(height, Int(ceil(r.maxY)))
        guard x0 < x1, y0 < y1 else { return }
        let iw = image.width, ih = image.height
        let sx = CGFloat(iw) / r.width, sy = CGFloat(ih) / r.height
        let exact = sx == 1 && sy == 1 && r.minX == r.minX.rounded() && r.minY == r.minY.rounded()
        image.premultipliedRGBA.withUnsafeBufferPointer { src in
            @inline(__always) func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
                let cx = min(max(x, 0), iw - 1), cy = min(max(y, 0), ih - 1)
                let o = (cy * iw + cx) * 4
                return SIMD4(Float(src[o]), Float(src[o + 1]), Float(src[o + 2]), Float(src[o + 3]))
            }
            for y in y0..<y1 {
                // Image row 0 is at the top of the rect (max device y).
                let v = (r.maxY - (CGFloat(y) + 0.5)) * sy - 0.5
                for x in x0..<x1 {
                    let u = (CGFloat(x) + 0.5 - r.minX) * sx - 0.5
                    let s: SIMD4<Float>
                    if exact || interpolationQuality == .none {
                        s = texel(Int((u + 0.5).rounded(.down)), Int((v + 0.5).rounded(.down)))
                    } else {
                        let fu = floor(u), fv = floor(v)
                        let tu = Float(u - fu), tv = Float(v - fv)
                        let iu = Int(fu), iv = Int(fv)
                        let a = texel(iu, iv) * (1 - tu) + texel(iu + 1, iv) * tu
                        let b = texel(iu, iv + 1) * (1 - tu) + texel(iu + 1, iv + 1) * tu
                        s = a * (1 - tv) + b * tv
                    }
                    if s.w > 0 || blendMode == .copy { blend(x, y, s) }
                }
            }
        }
    }

    /// A copy of the bitmap as an image.
    public func makeImage() -> CGImage? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = read(x, y)
                let o = (y * width + x) * 4
                out[o] = UInt8(min(255, max(0, v.x.rounded()))); out[o + 1] = UInt8(min(255, max(0, v.y.rounded())))
                out[o + 2] = UInt8(min(255, max(0, v.z.rounded()))); out[o + 3] = UInt8(min(255, max(0, v.w.rounded())))
            }
        }
        return CGImage(width: width, height: height, premultipliedRGBA: out)
    }
}

// MARK: - Fonts

/// Process-wide FreeType library. FT_Library calls that create or free faces are serialised by `lock`.
public enum FreeTypeLibrary {
    public static let lock = NSLock()
    nonisolated(unsafe) public static let shared: FT_Library? = {
        var lib: FT_Library?
        return FT_Init_FreeType(&lib) == 0 ? lib : nil
    }()
}

/// A font program in memory (CGFont): the file bytes and face index. CTFont instances open their own FreeType faces
/// from it, so sizes never share mutable face state; they share the bytes (`storage`), which FreeType reads in place.
public final class CGFont {
    public let fontData: Data
    public let faceIndex: Int
    public let postScriptName: CFString?
    public let fullName: CFString?
    /// The bytes every face of this font reads (one copy per font file, not per face).
    public let storage: FontStorage

    public convenience init?(_ provider: CGDataProvider) {
        guard let d = provider.data, !d.isEmpty else { return nil }
        self.init(data: d, faceIndex: 0)
    }

    public convenience init?(data: Data, faceIndex: Int) {
        self.init(data: data, storage: FontStorage(data), faceIndex: faceIndex)
    }

    init?(data: Data, storage: FontStorage, faceIndex: Int) {
        fontData = data
        self.storage = storage
        self.faceIndex = faceIndex
        guard let face = CGFont.openFace(storage, faceIndex) else { return nil }
        defer { FreeTypeLibrary.lock.withLock { _ = FT_Done_Face(face.face) } }
        postScriptName = FT_Get_Postscript_Name(face.face).map { String(cString: $0) }
        let fam = face.face.pointee.family_name.map { String(cString: $0) }
        let style = face.face.pointee.style_name.map { String(cString: $0) }
        fullName = fam.map { f in style.map { "\(f) \($0)" } ?? f }
    }

    public convenience init?(name: CFString) {
        guard let (path, index) = FontConfig.match(name: name), let file = CGFont.file(path) else { return nil }
        self.init(data: file.data, storage: file.storage, faceIndex: index)
    }

    /// A font file's bytes, read once per process: fontconfig hands out the same few files (and the CJK fallback is
    /// tens of megabytes), while photon2 creates fonts per text layer and size.
    nonisolated(unsafe) private static var files: [String: (data: Data, storage: FontStorage)] = [:]
    private static let filesLock = NSLock()
    static func file(_ path: String) -> (data: Data, storage: FontStorage)? {
        filesLock.withLock {
            if let hit = files[path] { return hit }
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            let f = (d, FontStorage(d))
            files[path] = f
            return f
        }
    }

    /// The font at face `index` of the file at `path`, sharing the cached bytes.
    public static func fromFile(_ path: String, index: Int) -> CGFont? {
        guard let file = file(path) else { return nil }
        return CGFont(data: file.data, storage: file.storage, faceIndex: index)
    }

    /// An FT_Face over `data`. The returned holder keeps the bytes alive (FreeType does not copy memory faces).
    public static func openFace(_ data: Data, _ index: Int) -> FaceHolder? { openFace(FontStorage(data), index) }

    /// An FT_Face over shared bytes; the holder keeps them alive.
    public static func openFace(_ storage: FontStorage, _ index: Int) -> FaceHolder? {
        guard let lib = FreeTypeLibrary.shared else { return nil }
        let holder = FaceHolder(storage: storage)
        var face: FT_Face?
        let err = FreeTypeLibrary.lock.withLock {
            FT_New_Memory_Face(lib, storage.bytes, FT_Long(storage.count), FT_Long(index), &face)
        }
        guard err == 0, let face else { return nil }
        holder.face = face
        return holder
    }

    /// Immutable font bytes in stable memory (FT_New_Memory_Face keeps a pointer to them).
    public final class FontStorage {
        public let bytes: UnsafeMutablePointer<FT_Byte>
        public let count: Int
        init(_ data: Data) {
            count = data.count
            bytes = UnsafeMutablePointer<FT_Byte>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: bytes, count: data.count)
        }
        deinit { bytes.deallocate() }
    }

    public final class FaceHolder {
        public let storage: FontStorage
        public var bytes: UnsafeMutablePointer<FT_Byte> { storage.bytes }
        public var face: FT_Face!
        init(storage: FontStorage) { self.storage = storage }
    }
}

/// fontconfig lookups: a PostScript or family name → font file and face index.
public enum FontConfig {
    nonisolated(unsafe) private static var cache: [String: (String, Int)?] = [:]
    private static let lock = NSLock()
    private static let initialised: Bool = FcInit() != 0

    public static func match(name: String) -> (path: String, index: Int)? {
        lock.withLock {
            if let hit = cache[name] { return hit }
            let r = lookup(name)
            cache[name] = r
            return r
        }
    }

    private static func fileOf(_ pat: OpaquePointer) -> (String, Int)? {
        var file: UnsafeMutablePointer<FcChar8>?
        guard FcPatternGetString(pat, "file", 0, &file) == FcResultMatch, let file else { return nil }
        var index: Int32 = 0
        _ = FcPatternGetInteger(pat, "index", 0, &index)
        return (String(cString: file), Int(index))
    }

    private static func lookup(_ name: String) -> (String, Int)? {
        guard initialised else { return nil }
        // 1. Exact PostScript name among installed fonts.
        if let pat = FcPatternCreate() {
            defer { FcPatternDestroy(pat) }
            _ = name.withCString { s in s.withMemoryRebound(to: FcChar8.self, capacity: 1) { FcPatternAddString(pat, "postscriptname", $0) } }
            let os = FcObjectSetCreate()!
            defer { FcObjectSetDestroy(os) }
            _ = FcObjectSetAdd(os, "file"); _ = FcObjectSetAdd(os, "index")
            if let list = FcFontList(nil, pat, os) {
                defer { FcFontSetDestroy(list) }
                if list.pointee.nfont > 0, let first = list.pointee.fonts[0], let r = fileOf(first) { return r }
            }
        }
        // 2. Best match for the family part ("ArialMT" → "Arial", "Menlo-Regular" → "Menlo"), as CoreText falls back
        //    to a default face for unknown names.
        var family = name.split(separator: "-").first.map(String.init) ?? name
        if family.hasSuffix("MT") { family.removeLast(2) }
        guard let pat = FcPatternCreate() else { return nil }
        defer { FcPatternDestroy(pat) }
        _ = family.withCString { s in s.withMemoryRebound(to: FcChar8.self, capacity: 1) { FcPatternAddString(pat, "family", $0) } }
        _ = FcConfigSubstitute(nil, pat, FcMatchPattern)
        FcDefaultSubstitute(pat)
        var result = FcResultNoMatch
        guard let m = FcFontMatch(nil, pat, &result) else { return nil }
        defer { FcPatternDestroy(m) }
        return fileOf(m)
    }

    /// The regular face of an installed family, only when fontconfig's best match really is that family (no
    /// substitution): the metric-compatible font table in CoreText needs to know what is actually there.
    public static func installed(family: String) -> (path: String, index: Int)? {
        lock.withLock {
            let key = "family:" + family
            if let hit = cache[key] { return hit }
            var r: (String, Int)?
            if initialised, let pat = FcPatternCreate() {
                _ = family.withCString { s in s.withMemoryRebound(to: FcChar8.self, capacity: 1) { FcPatternAddString(pat, "family", $0) } }
                _ = FcConfigSubstitute(nil, pat, FcMatchPattern)
                FcDefaultSubstitute(pat)
                var result = FcResultNoMatch
                if let m = FcFontMatch(nil, pat, &result) {
                    var fam: UnsafeMutablePointer<FcChar8>?
                    if FcPatternGetString(m, "family", 0, &fam) == FcResultMatch, let fam,
                       String(cString: fam).lowercased() == family.lowercased() {
                        r = fileOf(m)
                    }
                    FcPatternDestroy(m)
                }
                FcPatternDestroy(pat)
            }
            cache[key] = r
            return r
        }
    }

    /// Whether face `index` of the file at `path` has `scalar` in its charset (read once per face).
    public static func file(_ path: String, index: Int, covers scalar: UInt32) -> Bool {
        lock.withLock {
            let key = "\(path)#\(index)"
            if charsets[key] == nil {
                var set: OpaquePointer?
                var count: Int32 = 0
                if initialised, let pat = path.withCString({ s in
                    s.withMemoryRebound(to: FcChar8.self, capacity: 1) { FcFreeTypeQuery($0, UInt32(index), nil, &count) }
                }) {
                    var cs: OpaquePointer?
                    if FcPatternGetCharSet(pat, "charset", 0, &cs) == FcResultMatch, let cs { set = FcCharSetCopy(cs) }
                    FcPatternDestroy(pat)
                }
                charsets[key] = .some(set)
            }
            guard let set = charsets[key] ?? nil else { return false }
            return FcCharSetHasChar(set, scalar) != 0
        }
    }
    nonisolated(unsafe) private static var charsets: [String: OpaquePointer?] = [:]

    /// A font file that covers `scalar` (fallback for characters the requested font lacks). `color` asks for a colour
    /// font first (emoji presentation, as CoreText's cascade puts Apple Color Emoji first for those), then any font.
    public static func fileCovering(_ scalar: UInt32, color: Bool = false) -> (path: String, index: Int)? {
        if color, let r = fileCovering(scalar, requireColor: true) { return r }
        return fileCovering(scalar, requireColor: false)
    }

    private static func fileCovering(_ scalar: UInt32, requireColor: Bool) -> (path: String, index: Int)? {
        lock.withLock {
            let key = "U+\(scalar)" + (requireColor ? "c" : "")
            if let hit = cache[key] { return hit }
            var r: (String, Int)?
            if initialised, let pat = FcPatternCreate(), let cs = FcCharSetCreate() {
                _ = FcCharSetAddChar(cs, scalar)
                _ = FcPatternAddCharSet(pat, "charset", cs)
                if requireColor { _ = FcPatternAddBool(pat, "color", 1) }
                _ = FcConfigSubstitute(nil, pat, FcMatchPattern)
                FcDefaultSubstitute(pat)
                var result = FcResultNoMatch
                if let m = FcFontMatch(nil, pat, &result) {
                    var mcs: OpaquePointer?
                    var isColor: FcBool = 0
                    _ = FcPatternGetBool(m, "color", 0, &isColor)
                    if FcPatternGetCharSet(m, "charset", 0, &mcs) == FcResultMatch, let mcs, FcCharSetHasChar(mcs, scalar) != 0,
                       !requireColor || isColor != 0 {
                        r = fileOf(m)
                    }
                    FcPatternDestroy(m)
                }
                FcCharSetDestroy(cs)
                FcPatternDestroy(pat)
            }
            cache[key] = r
            return r
        }
    }
}

// MARK: - Paths

public enum CGPathElementType: Int32 {
    case moveToPoint = 0, addLineToPoint, addQuadCurveToPoint, addCurveToPoint, closeSubpath
}

public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>
}

public typealias CGPathApplierFunction = (UnsafeMutableRawPointer?, UnsafePointer<CGPathElement>) -> Void

public class CGPath {
    struct Element {
        var type: CGPathElementType
        var points: [CGPoint]
    }
    var elements: [Element] = []
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero

    init() {}

    public var isEmpty: Bool { elements.isEmpty }
    public var currentPoint: CGPoint { current }

    /// Calls `body` with each element (points valid only during the call).
    public func applyWithBlock(_ body: (UnsafePointer<CGPathElement>) -> Void) {
        for e in elements {
            var pts = e.points.isEmpty ? [CGPoint.zero] : e.points
            pts.withUnsafeMutableBufferPointer { p in
                var el = CGPathElement(type: e.type, points: p.baseAddress!)
                withUnsafePointer(to: &el) { body($0) }
            }
        }
    }

    public func apply(info: UnsafeMutableRawPointer?, function: CGPathApplierFunction) {
        applyWithBlock { function(info, $0) }
    }

    /// Control-point bounds.
    public var boundingBox: CGRect {
        let pts = elements.flatMap(\.points)
        guard let f = pts.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    public func copy() -> CGPath? {
        let c = CGPath()
        c.elements = elements; c.current = current; c.subpathStart = subpathStart
        return c
    }

    public func mutableCopy() -> CGMutablePath? {
        let c = CGMutablePath()
        c.elements = elements; c.current = current; c.subpathStart = subpathStart
        return c
    }
}

public final class CGMutablePath: CGPath {
    public override init() { super.init() }

    public func move(to p: CGPoint, transform: CGAffineTransform = .identity) {
        let q = p.applying(transform)
        elements.append(Element(type: .moveToPoint, points: [q]))
        current = q; subpathStart = q
    }
    public func addLine(to p: CGPoint, transform: CGAffineTransform = .identity) {
        let q = p.applying(transform)
        elements.append(Element(type: .addLineToPoint, points: [q]))
        current = q
    }
    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        let e = end.applying(transform)
        elements.append(Element(type: .addQuadCurveToPoint, points: [control.applying(transform), e]))
        current = e
    }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint, transform: CGAffineTransform = .identity) {
        let e = end.applying(transform)
        elements.append(Element(type: .addCurveToPoint, points: [control1.applying(transform), control2.applying(transform), e]))
        current = e
    }
    public func closeSubpath() {
        elements.append(Element(type: .closeSubpath, points: []))
        current = subpathStart
    }
    public func addRect(_ r: CGRect, transform: CGAffineTransform = .identity) {
        move(to: CGPoint(x: r.minX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY), transform: transform)
        addLine(to: CGPoint(x: r.minX, y: r.maxY), transform: transform)
        closeSubpath()
    }
    public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        for e in path.elements {
            elements.append(Element(type: e.type, points: e.points.map { $0.applying(transform) }))
        }
        current = path.current.applying(transform)
    }
}
