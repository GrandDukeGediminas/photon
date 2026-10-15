// Linux stand-in for AppKit (docs/linux-port.md §4): only what PhotonRender touches outside the app target.
// - NSScreen: the output size, from PHOTON_SCREEN=WxH (set by the X11 host from XRandR) or 1920×1080, scale 1.
// - NSWorkspace: open(URL) through xdg-open; icon(forFile:) a generic document icon.
// - NSImage: a CGImage holder. `NSImage(data:)` does not decode (AppKit cannot see PhotonCore's libpng/libjpeg-turbo
//   decoder); callers that need pixels decode with `TexFile.decodeStraightRGBA` and use `NSImage(cgImage:size:)`.

@_exported import CoreGraphics
import Foundation

public typealias NSSize = CGSize
public typealias NSPoint = CGPoint

public final class NSScreen {
    public let frame: CGRect
    public let backingScaleFactor: CGFloat
    public var visibleFrame: CGRect { frame }

    init(frame: CGRect, backingScaleFactor: CGFloat = 1) {
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
    }

    /// PHOTON_SCREENS="WxH+X+Y,…" (every monitor, set by the X11 host) or PHOTON_SCREEN="WxH".
    public static var screens: [NSScreen] {
        let env = ProcessInfo.processInfo.environment
        if let list = env["PHOTON_SCREENS"] {
            let parsed = list.split(separator: ",").compactMap { spec -> NSScreen? in
                let p = spec.split(whereSeparator: { $0 == "x" || $0 == "+" }).compactMap { Double($0) }
                guard p.count >= 2 else { return nil }
                return NSScreen(frame: CGRect(x: p.count > 2 ? p[2] : 0, y: p.count > 3 ? p[3] : 0, width: p[0], height: p[1]))
            }
            if !parsed.isEmpty { return parsed }
        }
        if let s = env["PHOTON_SCREEN"] {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { return [NSScreen(frame: CGRect(x: 0, y: 0, width: p[0], height: p[1]))] }
        }
        return [NSScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
    }

    public static var main: NSScreen? { screens.first }
}

public final class NSImage {
    public var size: NSSize
    let cg: CGImage?

    public init(cgImage: CGImage, size: NSSize) {
        cg = cgImage
        self.size = size == .zero ? CGSize(width: cgImage.width, height: cgImage.height) : size
    }

    public init(size: NSSize) {
        cg = nil
        self.size = size
    }

    /// Not decoded on Linux (see the file comment).
    public init?(data: Data) { return nil }
    public init?(contentsOf url: URL) { return nil }
    public init?(contentsOfFile path: String) { return nil }

    public func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?, context: AnyObject?,
                        hints: [AnyHashable: Any]?) -> CGImage? {
        if let cg { return cg }
        // A generic icon: a light rounded page with a folded corner, at the proposed size (default 256).
        let w = Int(proposedDestRect?.pointee.width ?? size.width), h = Int(proposedDestRect?.pointee.height ?? size.height)
        return NSImage.genericIcon(width: max(w, 1), height: max(h, 1))
    }

    static func genericIcon(width w: Int, height h: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let mx = w / 6, my = h / 12, fold = w / 4
        for y in my..<(h - my) {
            for x in mx..<(w - mx) {
                let fx = x - (w - mx - fold), fy = y - my
                if fx > 0 && fy < fold && fx > fy { continue } // cut corner
                let o = (y * w + x) * 4
                let edge = x == mx || x == w - mx - 1 || y == my || y == h - my - 1
                let v: UInt8 = edge ? 160 : 245
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }
        return CGImage(width: w, height: h, premultipliedRGBA: px)
    }
}

public final class NSWorkspace {
    public static let shared = NSWorkspace()

    /// `xdg-open <url>`; true if the launcher started.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["xdg-open", url.isFileURL ? url.path : url.absoluteString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    public func icon(forFile fullPath: String) -> NSImage { NSImage(size: CGSize(width: 256, height: 256)) }
}
