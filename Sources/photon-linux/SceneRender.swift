#if os(Linux)
import Foundation
import Metal
import PhotonCore
import PhotonProto
import PhotonRender

/// The full renderer on Linux: PhotonRender's SceneRenderer through the Metal facade on Vulkan. Same frame sequence as
/// `photon-tool render` on macOS (simulate to t − 0.1, PHOTON_WARMUP frames at 30 fps, then the frame at t), so the
/// PNGs compare pixel for pixel.
enum SceneRender {
    /// One frame source per wallpaper and output size; `frame(time:)` returns top-down BGRA8 rows.
    final class Source {
        let device: MTLDevice
        let scene: SceneRenderer
        let width: Int, height: Int
        let target: MTLTexture
        var pointer = CGPoint(x: 0.5, y: 0.5)

        init(directory: URL, engineAssets: URL, width: Int, height: Int, overrides: [String: Any] = [:]) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "photon", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no Vulkan device"]) }
            self.device = device
            self.width = width
            self.height = height
            SceneRenderer.resolutionScreenSize = SIMD2(width, height)
            scene = try SceneRenderer(device: device, wallpaperDirectory: directory, engineAssets: engineAssets, propertyOverrides: overrides)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            guard let t = device.makeTexture(descriptor: d) else { throw NSError(domain: "photon", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "cannot create the output texture"]) }
            target = t
        }

        /// Renders one frame and waits for it (readback and PNG paths).
        func render(time: Double) {
            guard let cb = encode(time: time) else { return }
            cb.commit()
            cb.waitUntilCompleted()
        }

        /// Encodes one frame into `target`; the caller commits (and may present first).
        func encode(time: Double) -> MTLCommandBuffer? {
            scene.render(into: target, time: time, outputSize: CGSize(width: width, height: height), pointer: pointer)
        }

        func bgra() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return bytes
        }
    }

    static func main(_ args: [String], workshop: URL, engineAssets: URL) {
        guard args.count >= 2 else { fail("usage: photon-linux render <id|dir> <out.png> [seconds] [width] [height]") }
        let env = ProcessInfo.processInfo.environment
        SceneRenderer.soundEnabled = false
        SceneRenderer.simulatedScriptClock = true
        SceneRenderer.audioCaptureEnabled = false
        let id = args[0], out = URL(fileURLWithPath: args[1])
        let t = args.count > 2 ? Double(args[2]) ?? 1 : 1
        let w = args.count > 3 ? Int(args[3]) ?? 1920 : 1920, h = args.count > 4 ? Int(args[4]) ?? 1080 : 1080
        let dir = id.hasPrefix("/") || id.hasPrefix(".") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id)
        let start = Date()
        let source: Source
        do { source = try Source(directory: dir, engineAssets: engineAssets, width: w, height: h) } catch { fail("load failed: \(error)") }
        print("device \(source.device.name), loaded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s, ortho \(source.scene.orthoSize)")
        if let g = env["PHOTON_GENERAL"], let data = g.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            source.scene.applyGeneralProperties(dict)
        }
        let v = (env["PHOTON_POINTER"] ?? "").split(separator: ",").compactMap { Double($0) }
        if v.count == 2 { source.pointer = CGPoint(x: v[0], y: v[1]) }
        source.scene.simulate(to: max(0, t - 0.1))
        let warm = env["PHOTON_WARMUP"].flatMap(Int.init) ?? 3
        for i in 0..<warm { source.render(time: max(0, t - Double(warm - i) / 30)) }
        source.render(time: t)
        print("draws: \(source.scene.lastDrawCount), total \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        var px = source.bgra()
        for i in stride(from: 0, to: px.count, by: 4) {
            let b = px[i]; px[i] = px[i + 2]; px[i + 2] = b
            if env["PHOTON_ALPHA"] != nil { let a = px[i + 3]; px[i] = a; px[i + 1] = a; px[i + 2] = a }
        }
        do { try PNGWriter.encode(rgba: px, width: w, height: h, keepAlpha: false).write(to: out) } catch { fail("\(error)") }
        print("wrote \(out.path)")
    }

    static func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        exit(1)
    }
}
#endif
