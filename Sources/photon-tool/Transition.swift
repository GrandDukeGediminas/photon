import CoreGraphics
import Foundation
import ImageIO
import Metal
import PhotonCore
import PhotonRender

/// `transition <old> <new> <effect> <progress> out.png [width] [height]`: one frame of the wallpaper-switch overlay
/// (docs/re/frame-graph.md §T). `old`/`new` are a workshop id or wallpaper folder (rendered at 1 s), a PNG file, or
/// `color:r,g,b` (0–255). `progress` is the overlay's g_Progress (0…1). With `PHOTON_TRANSITION_EDR=1` both frames are
/// fp16 extended-linear (colours given as r,g,b / 255 in linear EDR units, so 510 = 2.0): the old frame goes through
/// the engine's snapshot readback (passthroughlinear → BGRA8) and the overlay is composited over the fp16 output; the
/// centre pixel's values are printed. `PHOTON_TRANSITION_SEED=n` seeds the overlay's rand() (cross-platform comparisons).
func renderTransition(_ args: [String]) {
    guard args.count >= 5, let effect = Int(args[2]), let progress = Double(args[3]) else {
        print("usage: photon-tool transition <old> <new> <effect> <progress> out.png [width] [height]"); exit(2)
    }
    SceneRenderer.soundEnabled = false
    SceneRenderer.simulatedScriptClock = true
    SceneRenderer.audioCaptureEnabled = false
    let device = MTLCreateSystemDefaultDevice()!
    let queue = device.makeCommandQueue()!
    let w = args.count > 5 ? Int(args[5])! : 1280, h = args.count > 6 ? Int(args[6])! : 720
    let edr = ProcessInfo.processInfo.environment["PHOTON_TRANSITION_EDR"] == "1"
    func target(_ format: MTLPixelFormat? = nil) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format ?? (edr ? .rgba16Float : .bgra8Unorm), width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)!
    }
    func source(_ spec: String) -> MTLTexture {
        let tex = target()
        if spec.hasPrefix("color:") {
            let c = spec.dropFirst(6).split(separator: ",").compactMap { Double($0) }
            let cb = queue.makeCommandBuffer()!
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
        } else if spec.hasSuffix(".png"), edr {
            print("PHOTON_TRANSITION_EDR takes color: or wallpaper frames"); exit(2)
        } else if spec.hasSuffix(".png"), let data = FileManager.default.contents(atPath: spec), let img = TexFile.decodeStraightRGBA(data) {
            // Nearest resample into w×h, RGBA → BGRA.
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
                let cb = scene.render(into: tex, time: 1, outputSize: CGSize(width: w, height: h), pointer: nil)!
                cb.commit(); cb.waitUntilCompleted()
            } catch { print("load \(spec) failed: \(error)"); exit(1) }
        }
        return tex
    }
    let oldFrame = source(args[0]), output = source(args[1])
    // The app's readback of the old frame (WallpaperRenderer.captureScene): opaque BGRA8, fp16 through passthroughlinear.
    let old = target(.bgra8Unorm)
    do {
        let cb = queue.makeCommandBuffer()!
        WallpaperTransition.resolveSnapshot(oldFrame, into: old, hdrScale: 1, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
    }
    let timeMs = Int(ProcessInfo.processInfo.environment["PHOTON_TRANSITION_MS"] ?? "1000") ?? 1000
    // PHOTON_TRANSITION_SEED=n: the overlay's rand() as MSVC's from srand(n), so Linux (`photon-linux transition`)
    // renders the same g_Hash / g_Random / shatter sites.
    if let seed = ProcessInfo.processInfo.environment["PHOTON_TRANSITION_SEED"].flatMap(UInt32.init) { WallpaperTransition.seed(seed) }
    do {
        let tr = try WallpaperTransition(device: device, engineAssets: engineAssets, effect: effect, timeMs: timeMs,
                                         snapshot: old, commandQueue: queue)
        tr.start(at: 0)
        let t = WallpaperTransition.startDelay + progress * Double(timeMs) * 0.001
        let cb = queue.makeCommandBuffer()!
        tr.encode(over: output, commandBuffer: cb, time: t)
        cb.commit(); cb.waitUntilCompleted()
        if let e = cb.error { print("GPU error: \(e)") }
        print(String(format: "effect %d progress %.3f (time %.3f s)", effect, tr.progress(at: t), t))
    } catch { print("transition failed: \(error)"); exit(1) }
    if edr {
        func px(_ t: MTLTexture) -> String {
            if t.pixelFormat == .rgba16Float {
                var v = [Float16](repeating: 0, count: 4)
                t.getBytes(&v, bytesPerRow: w * 8, from: MTLRegionMake2D(w / 2, h / 2, 1, 1), mipmapLevel: 0)
                return v.map { String(format: "%.4f", Float($0)) }.joined(separator: " ")
            }
            var v = [UInt8](repeating: 0, count: 4)
            t.getBytes(&v, bytesPerRow: w * 4, from: MTLRegionMake2D(w / 2, h / 2, 1, 1), mipmapLevel: 0)
            return "bgra " + v.map { String($0) }.joined(separator: " ")
        }
        print("old fp16 \(px(oldFrame)) → snapshot \(px(old)); output \(px(output))")
        let shared = target(.bgra8Unorm)
        let cb = queue.makeCommandBuffer()!
        WallpaperTransition.resolveSnapshot(output, into: shared, hdrScale: 1, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        return writePNG(shared, w, h, args[4])
    }
    writePNG(output, w, h, args[4])
}

private func writePNG(_ output: MTLTexture, _ w: Int, _ h: Int, _ path: String) {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    output.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}
