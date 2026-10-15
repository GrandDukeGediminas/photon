#if os(Linux)
import Foundation
import Metal
import PhotonRender

/// `photon-linux bench <id|dir> [frames] [width] [height] [--sync] [--readback]`: renders `frames` consecutive frames of
/// the full renderer at 30 fps scene time and prints frames per second (scripts/linux/bench.sh).
///   default     commit each frame and keep at most two frames in flight (the desktop host's swapchain path)
///   --sync      wait for every frame before encoding the next (the readback host path, and every frame before phase 1)
///   --readback  also read each frame back to the CPU (what the XShmPutImage path pays per frame)
enum Bench {
    static func main(_ args: [String], workshop: URL, engineAssets: URL) {
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let rest = args.filter { !$0.hasPrefix("--") }
        guard let id = rest.first else { SceneRender.fail("usage: photon-linux bench <id|dir> [frames] [width] [height] [--sync] [--readback]") }
        let frames = rest.count > 1 ? Int(rest[1]) ?? 60 : 60
        let w = rest.count > 2 ? Int(rest[2]) ?? 1280 : 1280, h = rest.count > 3 ? Int(rest[3]) ?? 720 : 720
        let sync = flags.contains("--sync"), readback = flags.contains("--readback")
        SceneRenderer.soundEnabled = false
        SceneRenderer.simulatedScriptClock = true
        SceneRenderer.audioCaptureEnabled = false
        let dir = id.hasPrefix("/") || id.hasPrefix(".") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id)
        let loadStart = Date()
        let source: SceneRender.Source
        do { source = try SceneRender.Source(directory: dir, engineAssets: engineAssets, width: w, height: h) } catch {
            SceneRender.fail("load failed: \(error)")
        }
        let load = Date().timeIntervalSince(loadStart)
        source.scene.simulate(to: 1)
        // Warm-up: pipelines and textures created on first use are not part of the steady state.
        for i in 0..<5 { source.render(time: 1 + Double(i) / 30) }
        var inFlight: [MTLCommandBuffer] = []
        // Where a frame's time goes: encoding (scene update, scripts, particles, command recording on the CPU), commit
        // (on lavapipe the submit also runs the command buffer's state setup and binning), and waiting for the GPU.
        var encode = 0.0, submit = 0.0, wait = 0.0
        func timed(_ acc: inout Double, _ body: () -> Void) {
            let t0 = Date()
            body()
            acc += Date().timeIntervalSince(t0)
        }
        let start = Date()
        for i in 0..<frames {
            let t = 1 + Double(i + 5) / 30
            var cb: MTLCommandBuffer?
            timed(&encode) { cb = source.scene.render(into: source.target, time: t, outputSize: CGSize(width: w, height: h), pointer: source.pointer) }
            guard let cb else { continue }
            timed(&submit) { cb.commit() }
            timed(&wait) {
                if sync || readback {
                    cb.waitUntilCompleted()
                    if readback { _ = source.bgra() }
                } else {
                    inFlight.append(cb)
                    if inFlight.count > 2 { inFlight.removeFirst().waitUntilCompleted() }
                }
            }
        }
        timed(&wait) { for cb in inFlight { cb.waitUntilCompleted() } }
        let elapsed = Date().timeIntervalSince(start)
        let mode = readback ? "readback" : sync ? "sync" : "async"
        let ms = { (x: Double) in x * 1000 / Double(max(frames, 1)) }
        print(String(format: "bench %@ %dx%d %@: %d frames in %.2fs = %.2f fps (load %.1fs; per frame: encode %.1f ms, commit %.1f ms, wait %.1f ms)",
                     id, w, h, mode, frames, elapsed, Double(frames) / elapsed, load, ms(encode), ms(submit), ms(wait)))
    }
}
#endif
