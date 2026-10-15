#if os(Linux)
import CPhotonLinux
import Foundation

// Linux stand-ins for the Apple frameworks PhotonCore uses (docs/linux-port.md §5). Each function keeps the signature
// of the macOS implementation it replaces, so the callers in TexFile/VideoTexFile/MediaImage/MdlFile are unchanged.

// MARK: - Compression → liblz4

/// `Compression.compression_algorithm` value for raw LZ4 blocks; only this algorithm is used.
let COMPRESSION_LZ4_RAW = 0x101

/// `compression_decode_buffer` for `COMPRESSION_LZ4_RAW`, backed by `LZ4_decompress_safe` — the same liblz4 entry point
/// the engine calls (`sub_14014c160`, docs/re/01 §3.3). Returns the number of bytes written, 0 on failure.
func compression_decode_buffer(_ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
                               _ scratch: UnsafeMutableRawPointer?, _ algorithm: Int) -> Int {
    precondition(algorithm == COMPRESSION_LZ4_RAW, "only LZ4 raw blocks are supported")
    let n = src.withMemoryRebound(to: CChar.self, capacity: srcSize) { s in
        dst.withMemoryRebound(to: CChar.self, capacity: dstSize) { d in
            LZ4_decompress_safe(s, d, Int32(srcSize), Int32(dstSize))
        }
    }
    return n > 0 ? Int(n) : 0
}

// MARK: - CoreFoundation boolean test

/// JSON booleans: on macOS `CFGetTypeID(n) == CFBooleanGetTypeID()`. swift-corelibs-foundation has no CF type ids, but
/// its JSONSerialization returns booleans as `NSNumber(value: Bool)`, whose objCType is "c"; JSON numbers are "q"/"Q"/"d".
/// Public: PhotonRender's JSON readers use the same test.
public typealias CFTypeID = UInt
public func CFBooleanGetTypeID() -> CFTypeID { 1 }
public func CFGetTypeID(_ n: NSNumber) -> CFTypeID { n.objCType.pointee == CChar(UInt8(ascii: "c")) ? 1 : 0 }
/// `CFNumberIsFloatType`: objCType "f"/"d" (JSONSerialization makes doubles for numbers with a fraction or exponent).
public func CFNumberIsFloatType(_ n: NSNumber) -> Bool {
    let c = n.objCType.pointee
    return c == CChar(UInt8(ascii: "d")) || c == CChar(UInt8(ascii: "f"))
}
public typealias CFAbsoluteTime = Double
/// Seconds since 2001-01-01 00:00:00 UTC, as CoreFoundation.
public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Date().timeIntervalSinceReferenceDate }

// MARK: - ImageIO → libpng / libjpeg-turbo

enum LinuxImageDecoder {
    /// Straight (non-premultiplied) RGBA8 rows of a PNG or JPEG, at the file's own size.
    /// The engine decodes with wuffs; libpng and libjpeg-turbo give the same PNG pixels, and JPEG pixels within the
    /// IDCT differences every decoder has (ImageIO on macOS has the same caveat). GIFs go through `LinuxGIF` (stb_image);
    /// BMP/TGA are not handled yet.
    static func decode(_ blob: Data) -> (pixels: Data, width: Int, height: Int)? {
        guard blob.count > 8 else { return nil }
        let b0 = blob[blob.startIndex], b1 = blob[blob.startIndex + 1]
        if b0 == 0x89 && b1 == 0x50 { return png(blob) }
        if b0 == 0xFF && b1 == 0xD8 { return jpeg(blob) }
        if b0 == 0x47 && b1 == 0x49, let gif = LinuxGIF.decode(blob), let first = gif.frames.first { return (first, gif.width, gif.height) }
        return nil
    }

    static func png(_ blob: Data) -> (pixels: Data, width: Int, height: Int)? {
        var image = png_image()
        image.version = 1 // PNG_IMAGE_VERSION
        let ok = blob.withUnsafeBytes { raw -> Bool in
            png_image_begin_read_from_memory(&image, raw.baseAddress, raw.count) != 0
        }
        guard ok else { return nil }
        // PNG_FORMAT_RGBA = PNG_FORMAT_FLAG_COLOR (2) | PNG_FORMAT_FLAG_ALPHA (1): 8-bit sRGB, straight alpha.
        image.format = 3
        let w = Int(image.width), h = Int(image.height)
        var out = Data(count: w * h * 4)
        let done = out.withUnsafeMutableBytes { dst -> Bool in
            png_image_finish_read(&image, nil, dst.baseAddress, Int32(w * 4), nil) != 0
        }
        png_image_free(&image)
        return done ? (out, w, h) : nil
    }

    static func jpeg(_ blob: Data) -> (pixels: Data, width: Int, height: Int)? {
        guard let handle = tjInitDecompress() else { return nil }
        defer { tjDestroy(handle) }
        var w: Int32 = 0, h: Int32 = 0, subsamp: Int32 = 0, colorspace: Int32 = 0
        let size = UInt(blob.count)
        let header = blob.withUnsafeBytes { raw in
            tjDecompressHeader3(handle, raw.bindMemory(to: UInt8.self).baseAddress, size, &w, &h, &subsamp, &colorspace)
        }
        guard header == 0, w > 0, h > 0 else { return nil }
        var out = Data(count: Int(w) * Int(h) * 4)
        let r = out.withUnsafeMutableBytes { dst in
            blob.withUnsafeBytes { raw in
                tjDecompress2(handle, raw.bindMemory(to: UInt8.self).baseAddress, size, dst.bindMemory(to: UInt8.self).baseAddress,
                              w, 0, h, Int32(TJPF_RGBA.rawValue), 0)
            }
        }
        return r == 0 ? (out, Int(w), Int(h)) : nil
    }

    /// Nearest-neighbour resize for the rare call that asks for a size other than the file's own.
    static func resize(_ px: Data, _ w: Int, _ h: Int, to nw: Int, _ nh: Int) -> Data {
        guard nw != w || nh != h else { return px }
        var out = Data(count: nw * nh * 4)
        for y in 0..<nh {
            let sy = min(h - 1, y * h / nh)
            for x in 0..<nw {
                let sx = min(w - 1, x * w / nw), s = (sy * w + sx) * 4, d = (y * nw + x) * 4
                for c in 0..<4 { out[d + c] = px[s + c] }
            }
        }
        return out
    }
}

/// stb_image's GIF loader (the engine's decoder): all frames, composited, straight RGBA8.
enum LinuxGIF {
    struct Animation { var frames: [Data]; var delaysMs: [Int32]; var width: Int; var height: Int }

    static func decode(_ data: Data) -> Animation? {
        guard data.count > 6, data.prefix(3) == Data("GIF".utf8) else { return nil }
        var delays: UnsafeMutablePointer<Int32>?
        var w: Int32 = 0, h: Int32 = 0, n: Int32 = 0, comp: Int32 = 0
        let pixels = data.withUnsafeBytes { raw -> UnsafeMutablePointer<UInt8>? in
            stbi_load_gif_from_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &delays, &w, &h, &n, &comp, 4)
        }
        guard let pixels else { return nil }
        defer {
            stbi_image_free(pixels)
            if let delays { stbi_image_free(delays) }
        }
        guard w > 0, h > 0, n > 0 else { return nil }
        let frameBytes = Int(w) * Int(h) * 4
        var frames: [Data] = []
        frames.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            var f = Data(bytes: pixels + i * frameBytes, count: frameBytes)
            f.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var k = 0
                while k < p.count {
                    if p[k + 3] == 0 { p[k] = 0; p[k + 1] = 0; p[k + 2] = 0 }
                    k += 4
                }
            }
            frames.append(f)
        }
        let d = (0..<Int(n)).map { delays?[$0] ?? 0 }
        return Animation(frames: frames, delaysMs: d, width: Int(w), height: Int(h))
    }
}

extension TexFile {
    static func decodeImage(_ blob: Data, width: Int, height: Int) -> Data? {
        guard let d = LinuxImageDecoder.decode(blob) else { return nil }
        let w = width > 0 ? width : d.width, h = height > 0 ? height : d.height
        return LinuxImageDecoder.resize(d.pixels, d.width, d.height, to: w, h)
    }

    public static func decodeStraightRGBA(_ blob: Data) -> (pixels: Data, width: Int, height: Int)? {
        LinuxImageDecoder.decode(blob)
    }

    public static func userImage(_ data: Data, aspect: Float, flags: Flags) -> TexFile? {
        guard let d = LinuxImageDecoder.decode(data) else { return nil }
        let (px, w, h) = centerCrop(d.pixels, width: d.width, height: d.height, aspect: aspect)
        guard w > 0, h > 0 else { return nil }
        var t = TexFile(videoWidth: w, height: h, flags: [])
        t.flags = flags.union(.singleMip)
        t.images = [[Mip(width: w, height: h, depth: 1, data: px)]]
        return t
    }

    /// Every frame of a GIF as straight RGBA8 canvases and the frame delays in seconds, from stb_image's GIF loader
    /// (`stbi_load_gif_from_memory`): the decoder of the engine's `OpenGIF`/`AdvanceGIF` (resourceutil64.dll), which
    /// composites each frame over the previous canvas. Delays are stb's `10 × centiseconds` ms / 1000, used unclamped
    /// (0 stays 0), as on macOS (VideoTexFile.swift). Fully transparent pixels get zero colour, as the macOS path's
    /// premultiplied CGContext leaves them.
    public static func gifFrames(_ data: Data) -> (frames: [Data], delays: [Float], width: Int, height: Int)? {
        guard let gif = LinuxGIF.decode(data) else { return nil }
        return (gif.frames, gif.delaysMs.map { Float(Double($0) / 1000) }, gif.width, gif.height)
    }

    /// The GIF wallpaper's sprite sheet (VideoTexFile.swift `spriteSheet(gif:)`, same layout and delay rule) from the
    /// stb_image frames: a row-major grid at most 8192 wide, one TEXS frame per GIF frame, a delay below 0.011 s
    /// counting as 0.1 s.
    public static func spriteSheet(gif data: Data) -> TexFile? {
        guard let gif = LinuxGIF.decode(data) else { return nil }
        let n = gif.frames.count, w = gif.width, h = gif.height
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
        let cols = max(1, min(n, 8192 / w)), rows = (n + cols - 1) / cols
        guard rows * h <= 8192 else { return nil }
        let sw = cols * w, sh = rows * h
        var pixels = Data(count: sw * sh * 4)
        var frames: [Frame] = []
        pixels.withUnsafeMutableBytes { dst in
            for (i, f) in gif.frames.enumerated() {
                let c = i % cols, r = i / cols
                f.withUnsafeBytes { src in
                    for y in 0..<h {
                        let d = dst.baseAddress! + ((r * h + y) * sw + c * w) * 4
                        d.copyMemory(from: src.baseAddress! + y * w * 4, byteCount: w * 4)
                    }
                }
                // ImageIO's kCGImagePropertyGIFUnclampedDelayTime is centiseconds / 100, the same double as ms / 1000.
                var delay = Double(gif.delaysMs[i]) / 1000
                if delay < 0.011 { delay = 0.1 }
                frames.append(Frame(imageIndex: 0, frameTime: Float(delay), u: Float(c * w) / Float(sw), v: Float(r * h) / Float(sh),
                                    xAxis: SIMD2(Float(w) / Float(sw), 0), yAxis: SIMD2(0, Float(h) / Float(sh))))
            }
        }
        guard !frames.isEmpty else { return nil }
        var t = TexFile(videoWidth: sw, height: sh, flags: [])
        t.flags = [.noInterpolation, .clampUVs, .singleMip, .spriteSheet]
        t.images = [[Mip(width: sw, height: sh, depth: 1, data: pixels)]]
        t.frames = frames
        t.sheetWidth = w; t.sheetHeight = h
        return t
    }
}
#endif
