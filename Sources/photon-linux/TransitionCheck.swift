#if os(Linux)
import Foundation
import Metal
import PhotonCore
import PhotonProto
import PhotonRender

/// `photon-linux transition <old> <new> <effect> <progress> out.png [width] [height]`: one frame of the wallpaper-switch
/// overlay (docs/re/frame-graph.md §T), the Linux side of `photon-tool transition`. `old`/`new` are a workshop id or
/// wallpaper folder (rendered at 1 s), a PNG file, or `color:r,g,b` (0–255); `progress` is g_Progress (0…1).
/// `PHOTON_TRANSITION_SEED=n` seeds the overlay's rand() as photon-tool does, so both renders take the same random
/// values; `PHOTON_TRANSITION_MS` is the transition time (1000).
enum TransitionCheck {
    static func main(_ args: [String], workshop: URL, engineAssets: URL) -> Int32 {
        guard args.count >= 5, let effect = Int(args[2]), let progress = Double(args[3]) else {
            print("usage: photon-linux transition <old> <new> <effect> <progress> out.png [width] [height]"); return 2
        }
        SceneRenderer.soundEnabled = false
        SceneRenderer.simulatedScriptClock = true
        SceneRenderer.audioCaptureEnabled = false
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { print("no Vulkan device"); return 1 }
        let w = args.count > 5 ? Int(args[5]) ?? 1280 : 1280, h = args.count > 6 ? Int(args[6]) ?? 720 : 720
        func target() -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)!
        }
        func source(_ spec: String) -> MTLTexture? {
            let tex = target()
            if spec.hasPrefix("color:") {
                let c = spec.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                guard c.count == 3, let cb = queue.makeCommandBuffer() else { return nil }
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = tex
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
            } else if spec.hasSuffix(".png"), let data = FileManager.default.contents(atPath: spec), let img = TexFile.decodeStraightRGBA(data) {
                // Nearest resample into w×h, RGBA → BGRA (photon-tool's rule).
                var px = [UInt8](repeating: 255, count: w * h * 4)
                img.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    for y in 0..<h { for x in 0..<w {
                        let sx = x * img.width / w, sy = y * img.height / h, s = (sy * img.width + sx) * 4, d = (y * w + x) * 4
                        px[d] = src[s + 2]; px[d + 1] = src[s + 1]; px[d + 2] = src[s]; px[d + 3] = 255
                    } }
                }
                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            } else {
                let dir = spec.hasPrefix("/") ? URL(fileURLWithPath: spec) : workshop.appendingPathComponent(spec)
                do {
                    let scene = try SceneRenderer(device: device, wallpaperDirectory: dir, engineAssets: engineAssets)
                    scene.simulate(to: 0.9)
                    for t in [0.93, 0.97] { scene.render(into: tex, time: t, outputSize: CGSize(width: w, height: h), pointer: nil)?.commit() }
                    let cb = scene.render(into: tex, time: 1, outputSize: CGSize(width: w, height: h), pointer: nil)
                    cb?.commit(); cb?.waitUntilCompleted()
                } catch { print("load \(spec) failed: \(error)"); return nil }
            }
            return tex
        }
        guard let oldFrame = source(args[0]), let output = source(args[1]), let cb0 = queue.makeCommandBuffer() else { return 1 }
        // The host's readback of the old frame (SceneFrameSource.capture): opaque BGRA8.
        let old = target()
        WallpaperTransition.resolveSnapshot(oldFrame, into: old, hdrScale: 1, commandBuffer: cb0)
        cb0.commit(); cb0.waitUntilCompleted()
        let timeMs = Int(ProcessInfo.processInfo.environment["PHOTON_TRANSITION_MS"] ?? "1000") ?? 1000
        if let seed = ProcessInfo.processInfo.environment["PHOTON_TRANSITION_SEED"].flatMap(UInt32.init) { WallpaperTransition.seed(seed) }
        do {
            let tr = try WallpaperTransition(device: device, engineAssets: engineAssets, effect: effect, timeMs: timeMs, snapshot: old, commandQueue: queue)
            tr.start(at: 0)
            let t = WallpaperTransition.startDelay + progress * Double(timeMs) * 0.001
            guard let cb = queue.makeCommandBuffer() else { return 1 }
            tr.encode(over: output, commandBuffer: cb, time: t)
            cb.commit(); cb.waitUntilCompleted()
            print(String(format: "effect %d progress %.3f (time %.3f s)", effect, tr.progress(at: t), t))
        } catch { print("transition failed: \(error)"); return 1 }
        var px = SceneHost.read(output)
        ProtoFrameSource.swapRB(&px)
        do { try PNGWriter.encode(rgba: px, width: w, height: h, keepAlpha: false).write(to: URL(fileURLWithPath: args[4])) } catch { print("\(error)"); return 1 }
        print("wrote \(args[4])")
        return 0
    }
}
#endif
