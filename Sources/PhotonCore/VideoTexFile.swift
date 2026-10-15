import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension TexFile {
    /// Header-only texture info for a video bound without a `.tex` wrapper (the `videotex` user texture of
    /// video wallpapers). Matches what a flag-0x20 `.tex` reports: format 0, texture size = image size = video size.
    public init(videoWidth: Int, height: Int, flags: Flags = [.clampUVs]) {
        format = .rgba8888
        self.flags = flags.union([.video, .singleMip])
        textureWidth = videoWidth; textureHeight = height
        imageWidth = videoWidth; imageHeight = height
    }
}

extension TexFile {
    /// The engine's built-in error texture (`Texture_load` 0x1400ec220, branch 0x1400ec58b): used for the name `"error"`,
    /// for a texture whose file is missing or fails to load, and as the placeholder behind an `_rt_` name no render
    /// target has registered. 6×6, format 0 (RGBA8), flags 9 (point filtering, single mip), wrap addressing.
    /// Pixels from `ErrorTexture_Fill` 0x140170510: texel i (row-major) is (v, v, 0, 255) with
    /// v = 255 when (i / 6) & 1 != i & 1, else 0, i.e. a yellow/black checkerboard with black at (0, 0).
    public static let errorTexture: TexFile = {
        var t = TexFile(videoWidth: 6, height: 6, flags: [])
        t.flags = [.noInterpolation, .singleMip]
        var px = Data(count: 6 * 6 * 4)
        for i in 0..<36 {
            let v: UInt8 = ((i / 6) & 1) != (i & 1) ? 255 : 0
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = 0; px[i * 4 + 3] = 255
        }
        t.images = [[Mip(width: 6, height: 6, depth: 1, data: px)]]
        return t
    }()
}

#if canImport(ImageIO)
extension TexFile {
    /// The sprite sheet the editor's resource compiler makes from a GIF wallpaper with `scenes/gifs/materials/
    /// background.tex-json` (rgba8888, nointerpolation, clampuvs, nomip, nonpoweroftwo): every frame packed into one
    /// RGBA8 image, one TEXS frame per GIF frame. The packing and the delay handling are the compiler's (editor code,
    /// not traced); the layout here is a row-major grid at most 8192 wide, and a delay below 0.011 s counts as 0.1 s
    /// (Inferred: the common browser rule). Pixels and timing per frame are what a viewer sees either way.
    public static func spriteSheet(gif data: Data) -> TexFile? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0, let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = first.width, h = first.height
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
        let cols = max(1, min(n, 8192 / w)), rows = (n + cols - 1) / cols
        guard rows * h <= 8192 else { return nil }
        let sw = cols * w, sh = rows * h
        var pixels = Data(count: sw * sh * 4)
        var frames: [Frame] = []
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            for i in 0..<n {
                guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                let c = i % cols, r = i / cols
                // CGContext's origin is bottom-left; row r of the sheet starts at the top.
                ctx.draw(img, in: CGRect(x: c * w, y: sh - (r + 1) * h, width: w, height: h))
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                var delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                if delay < 0.011 { delay = 0.1 }
                frames.append(Frame(imageIndex: 0, frameTime: Float(delay), u: Float(c * w) / Float(sw), v: Float(r * h) / Float(sh),
                                    xAxis: SIMD2(Float(w) / Float(sw), 0), yAxis: SIMD2(0, Float(h) / Float(sh))))
            }
            return true
        }
        guard ok, !frames.isEmpty else { return nil }
        unpremultiply(&pixels)
        var t = TexFile(videoWidth: sw, height: sh, flags: [])
        t.flags = [.noInterpolation, .clampUVs, .singleMip, .spriteSheet]
        t.images = [[Mip(width: sw, height: sh, depth: 1, data: pixels)]]
        t.frames = frames
        t.sheetWidth = w; t.sheetHeight = h
        return t
    }
}
#endif

extension TexFile {
    /// `UserImage_CenterCrop` 0x1401702f0 on straight RGBA8 rows: `aspect` 0 keeps the image; otherwise, when the image is
    /// wider than `aspect` (w/h > aspect) it keeps the middle `trunc(h·aspect)` columns starting at `(w − newW) / 2`, else
    /// the middle `trunc(w / aspect)` rows starting at `(h − newH) / 2` (a "cover" crop).
    public static func centerCrop(_ pixels: Data, width: Int, height: Int, aspect: Float) -> (Data, Int, Int) {
        guard aspect != 0, width > 0, height > 0 else { return (pixels, width, height) }
        let imageAspect = Float(width) / Float(height)
        if imageAspect > aspect {
            let nw = max(0, min(width, Int(Float(height) * aspect)))
            let x0 = (width - nw) / 2
            var out = Data(count: nw * height * 4)
            for y in 0..<height {
                out.replaceSubrange(y * nw * 4..<(y + 1) * nw * 4, with: pixels[(y * width + x0) * 4..<(y * width + x0 + nw) * 4])
            }
            return (out, nw, height)
        }
        let nh = max(0, min(height, Int(Float(width) / aspect)))
        let y0 = (height - nh) / 2
        return (pixels.subdata(in: y0 * width * 4..<(y0 + nh) * width * 4), width, nh)
    }

#if canImport(ImageIO)
    /// A user texture made from an image file (`UserTexture` ctor 0x1400eb570, plain-file branch 0x1400ebe23–0x1400ebee6):
    /// decoded to straight RGBA8 (media services vt+0x60), centre-cropped to `aspect` (0 = keep), one mip, format 0,
    /// texture size = image size, sampler flags = `flags` (8 | clamp | point from the request).
    public static func userImage(_ data: Data, aspect: Float, flags: Flags) -> TexFile? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let decoded = decodeImage(data, width: image.width, height: image.height) else { return nil }
        let (px, w, h) = centerCrop(decoded, width: image.width, height: image.height, aspect: aspect)
        guard w > 0, h > 0 else { return nil }
        var t = TexFile(videoWidth: w, height: h, flags: [])
        t.flags = flags.union(.singleMip)
        t.images = [[Mip(width: w, height: h, depth: 1, data: px)]]
        return t
    }
#endif
}

#if canImport(ImageIO)
extension TexFile {
    /// Every frame of a GIF as straight RGBA8 canvases (`OpenGIF`/`AdvanceGIF` in resourceutil64.dll decode with
    /// stb_image's GIF loader, which composites each frame over the previous canvas; ImageIO returns the same composited
    /// frames) and the frame delays in seconds (stb: `delay = 10 × centiseconds` ms, used unclamped, so 0 stays 0).
    public static func gifFrames(_ data: Data) -> (frames: [Data], delays: [Float], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(source)
        guard n > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = first.width, h = first.height
        var frames: [Data] = [], delays: [Float] = []
        for i in 0..<n {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            var out = Data(count: w * h * 4)
            let ok = out.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { continue }
            unpremultiply(&out)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.floatValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.floatValue ?? 0
            // stb reads the 16-bit centisecond count; round the seconds back to whole centiseconds.
            frames.append(out)
            delays.append((delay * 100).rounded() * 10 / 1000)
        }
        return frames.isEmpty ? nil : (frames, delays, w, h)
    }
}
#endif

extension TexFile {
    /// A one-mip straight-RGBA8 user texture of `width`×`height` (format 0, texture size = image size).
    public static func userRGBA(_ pixels: Data, width: Int, height: Int, flags: Flags) -> TexFile {
        var t = TexFile(videoWidth: width, height: height, flags: [])
        t.flags = flags.union(.singleMip)
        t.images = [[Mip(width: width, height: height, depth: 1, data: pixels)]]
        return t
    }
}

extension TexFile {
    /// The `usershortcut` user texture (UserTexture ctor 0x1400ebc76–0x1400ebe01): the shortcut icon is **letterboxed**,
    /// not cropped, to `aspect`: when w/h > aspect the image is copied into `trunc(w / aspect)` zeroed rows starting at row
    /// `(newH − h) >> 1`, otherwise into `trunc(h · aspect)` zeroed columns starting at `(newW − w) >> 1` (transparent
    /// padding). `aspect` 0 (keepaspect) copies the icon as is (0x1400ebcaf).
    public static func letterbox(_ pixels: Data, width w: Int, height h: Int, aspect: Float) -> (Data, Int, Int) {
        guard aspect != 0, w > 0, h > 0 else { return (pixels, w, h) }
        if Float(w) / Float(h) > aspect {
            let nh = Int(Float(w) / aspect), y0 = max(0, (nh - h) >> 1)
            var out = Data(count: w * nh * 4)
            out.replaceSubrange(y0 * w * 4..<(y0 + h) * w * 4, with: pixels.prefix(w * h * 4))
            return (out, w, nh)
        }
        let nw = Int(Float(h) * aspect), x0 = max(0, (nw - w) >> 1)
        guard nw >= w else { return (pixels, w, h) }
        var out = Data(count: nw * h * 4)
        for y in 0..<h {
            out.replaceSubrange((y * nw + x0) * 4..<(y * nw + x0 + w) * 4, with: pixels[(y * w) * 4..<(y * w + w) * 4])
        }
        return (out, nw, h)
    }
}
