#if os(Linux)
import CoreText
import Foundation
import Metal
import PhotonCore
import PhotonProto
import PhotonRender

/// Checks for the phase-3 media and text backends (docs/linux-port.md §3.3, §3.5), each printing or writing what the
/// macOS counterpart can be compared with:
///   photon-linux video-frame <file> <seconds> <out.png>   the frame VideoTexture shows at that scene time (decoded from 0
///                                                          like a render), plus size and duration
///   photon-linux gif-frames <file.gif>                     size, frame count and per-frame delays (stb_image)
///   photon-linux text-shape <font name|file> <size> <text>  CTLine runs: font, glyph ids, advances, positions, indices
enum MediaCheck {
    static func videoFrame(_ args: [String]) -> Int32 {
        guard args.count >= 3, let t = Double(args[1]) else {
            FileHandle.standardError.write(Data("usage: photon-linux video-frame <file> <seconds> <out.png>\n".utf8))
            return 2
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let video = VideoTexture(device: device, url: URL(fileURLWithPath: args[0]), label: "video") else { return 1 }
        print("size \(video.width)x\(video.height) duration \(video.duration)")
        // The render's frame sequence (SceneRender: warm-up frames at 30 fps before t), so restarts match a render.
        for time in [max(0, t - 0.1), max(0, t - 0.1), max(0, t - 3.0 / 30), max(0, t - 2.0 / 30), max(0, t - 1.0 / 30), t] {
            guard let cb = queue.makeCommandBuffer() else { return 1 }
            video.update(time: time, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        var bgra = [UInt8](repeating: 0, count: video.width * video.height * 4)
        bgra.withUnsafeMutableBytes {
            video.texture.getBytes($0.baseAddress!, bytesPerRow: video.width * 4, from: MTLRegionMake2D(0, 0, video.width, video.height),
                                   mipmapLevel: 0)
        }
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i] = bgra[i + 2]; rgba[i + 2] = bgra[i] }
        do { try PNGWriter.encode(rgba: rgba, width: video.width, height: video.height, keepAlpha: false).write(to: URL(fileURLWithPath: args[2])) }
        catch { return 1 }
        return 0
    }

    static func gifFrames(_ args: [String]) -> Int32 {
        guard let path = args.first, let data = FileManager.default.contents(atPath: path),
              let gif = TexFile.gifFrames(data) else { return 1 }
        print("size \(gif.width)x\(gif.height) frames \(gif.frames.count)")
        print("delays " + gif.delays.map { String($0) }.joined(separator: " "))
        if args.count > 1 {
            // Every frame as PNG: <prefix>_<n>.png
            for (i, f) in gif.frames.enumerated() {
                let png = PNGWriter.encode(rgba: [UInt8](f), width: gif.width, height: gif.height, keepAlpha: true)
                try? png.write(to: URL(fileURLWithPath: "\(args[1])_\(i).png"))
            }
        }
        return 0
    }

    static func textShape(_ args: [String]) -> Int32 {
        guard args.count >= 3, let size = Double(args[1]) else {
            FileHandle.standardError.write(Data("usage: photon-linux text-shape <font name|file> <size> <text>\n".utf8))
            return 2
        }
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
        for run in CTLineGetGlyphRuns(line) {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), adv = [CGSize](repeating: .zero, count: n)
            var pos = [CGPoint](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
            print("run \(CTFontCopyPostScriptName(run.font) as String) \(n)")
            for k in 0..<n {
                print(String(format: "  %d g%d adv %.4f x %.4f y %.4f", idx[k], Int(glyphs[k]), Double(adv[k].width), Double(pos[k].x), Double(pos[k].y)))
            }
        }
        return 0
    }
}
#endif
