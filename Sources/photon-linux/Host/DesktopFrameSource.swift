#if os(Linux)
import Foundation
import Metal
import PhotonCore
import PhotonGPU
import PhotonProto
import PhotonRender
import PhotonVulkan

/// What the desktop host draws. Two paths: `present(time:to:)` renders and presents through a Vulkan swapchain (the
/// default), and `frame(time:width:height:)` returns one frame as tightly packed BGRA8 rows, top row first (the byte
/// order of a 24/32-bit TrueColor ZPixmap on little-endian X servers) for XShmPutImage (root mode, `--present
/// readback`, no WSI). SceneFrameSource is the full renderer; ProtoFrameSource (PhotonProto) has the readback path only.
protocol DesktopFrameSource: AnyObject {
    func frame(time: Double, width: Int, height: Int) throws -> [UInt8]
    /// False when frames do not change with time (the host then draws each monitor once).
    var animates: Bool { get }
    /// The Vulkan device frames are rendered on, when the source can present through a swapchain (nil: readback only).
    var vulkanDevice: VulkanDevice? { get }
    /// Renders a frame and presents it through `swapchain` without a CPU readback; returns without waiting for the GPU.
    func present(time: Double, to swapchain: VulkanSwapchain) throws
    /// Presents the last rendered frame again (Expose on a paused output).
    func presentLast(to swapchain: VulkanSwapchain) throws
    /// Host audio for the frame about to be drawn: the scene of the `owner` output size plays its sound objects at
    /// `volume` (wallpaper volume × mute fade), paused or not; `timeScale` is C+0x154 (rate × pause fade).
    func setSound(owner: (Int, Int)?, volume: Float, paused: Bool, timeScale: Float)
    /// The wallpaper's general properties changed (alignment, colour options, parallax: applied without a reload).
    func applyGeneral(_ general: [String: Any])
}

extension DesktopFrameSource {
    var vulkanDevice: VulkanDevice? { nil }
    func present(time: Double, to swapchain: VulkanSwapchain) throws { throw GPUError.unsupported("no swapchain path") }
    func presentLast(to swapchain: VulkanSwapchain) throws {}
    func setSound(owner: (Int, Int)?, volume: Float, paused: Bool, timeScale: Float) {}
    func applyGeneral(_ general: [String: Any]) {}
}

/// The full renderer (PhotonRender's SceneRenderer through the Metal facade), one scene per monitor size. Sound objects
/// play through OpenAL Soft and the audio spectrum comes from PipeWire/PulseAudio capture (docs/linux-port.md §3.6),
/// both off for `--still` test frames.
final class SceneFrameSource: DesktopFrameSource {
    let wallpaper: URL
    let engineAssets: URL
    private var scenes: [String: SceneRender.Source] = [:]
    var animates: Bool { true }

    /// `still`: the scene time of every frame (host `--still`); scenes are then simulated to it as `photon-linux render`
    /// does, with the script clock simulated, so the host shows exactly the headless render's frame.
    let still: Double?

    /// The app's stored user property values (`--property`), and the general properties (`--general`, `general` command).
    let overrides: [String: Any]
    private(set) var general: [String: Any]

    init(wallpaper: URL, engineAssets: URL, still: Double? = nil, sound: Bool = true, overrides: [String: Any] = [:],
         general: [String: Any] = [:]) {
        self.wallpaper = wallpaper
        self.engineAssets = engineAssets
        self.still = still
        self.overrides = overrides
        self.general = general
        SceneRenderer.soundEnabled = sound && still == nil
        SceneRenderer.audioCaptureEnabled = still == nil
        if still != nil { SceneRenderer.simulatedScriptClock = true }
    }

    /// The host's last audio settings, applied to scenes as they are created (a new scene must not play before the host
    /// has said whether it owns the sound).
    private var sound: (owner: String?, volume: Float, paused: Bool, timeScale: Float) = (nil, 0, true, 1)

    func setSound(owner: (Int, Int)?, volume: Float, paused: Bool, timeScale: Float) {
        sound = (owner.map { "\($0.0)x\($0.1)" }, volume, paused, timeScale)
        for (key, s) in scenes { apply(key, s) }
    }

    private func apply(_ key: String, _ s: SceneRender.Source) {
        s.scene.setSound(enabled: key == sound.owner, volume: sound.volume, paused: sound.paused)
        s.scene.resources.timeScale = sound.timeScale
    }

    func applyGeneral(_ general: [String: Any]) {
        self.general = general
        for s in scenes.values { applyGeneral(to: s) }
    }

    /// As WallpaperRenderer does every frame on macOS: alignment, flip, parallax, colour options, audio processing.
    private func applyGeneral(to s: SceneRender.Source) {
        guard !general.isEmpty else { return }
        s.scene.applyGeneralProperties(general)
        s.scene.audioProcessing = (general["audioprocessing"] as? Bool) ?? ((general["audioprocessing"] as? NSNumber)?.boolValue ?? true)
    }

    private func source(_ width: Int, _ height: Int) throws -> SceneRender.Source {
        let key = "\(width)x\(height)"
        if let s = scenes[key] { return s }
        let s = try SceneRender.Source(directory: wallpaper, engineAssets: engineAssets, width: width, height: height, overrides: overrides)
        apply(key, s)
        applyGeneral(to: s)
        if let t = still { s.scene.simulate(to: max(0, t - 0.1)) }
        scenes[key] = s
        return s
    }

    func frame(time: Double, width: Int, height: Int) throws -> [UInt8] {
        let source = try source(width, height)
        source.render(time: time)
        return source.bgra()
    }

    var vulkanDevice: VulkanDevice? { MTLCreateSystemDefaultDevice()?.gpuDevice as? VulkanDevice }

    /// The scene for this output size is loaded (the host draws a switch overlay before a load blocks the loop).
    func isLoaded(_ width: Int, _ height: Int) -> Bool { scenes["\(width)x\(height)"] != nil }

    /// Loads the scene for this output size now (synchronous: the engine's render thread loads a scene the same way).
    func load(_ width: Int, _ height: Int) throws { _ = try source(width, height) }

    /// Frees every scene (a stop rule destroys the wallpapers, 0x140073ac0; they load again on the next frame).
    func unloadAll() { scenes.removeAll() }

    /// Encodes the frame at `time` into the scene's output texture for this size, with the cursor (UV in the output,
    /// y down) and the left button; the caller commits (and may draw a transition over the texture and present first).
    func encode(time: Double, width: Int, height: Int, pointer: CGPoint?, down: Bool) throws -> (MTLCommandBuffer, MTLTexture)? {
        let s = try source(width, height)
        if let pointer { s.pointer = pointer }
        s.scene.pointerDown = down
        guard let cb = s.encode(time: time) else { return nil }
        return (cb, s.target)
    }

    /// The scene's frame at `time` as the engine reads it back for a switch (`R_ReadBackbuffer` 0x14009b7b0, the macOS
    /// app's `captureScene`): rendered at the output size, resolved to opaque BGRA8. Waits for the GPU.
    func capture(_ width: Int, _ height: Int, time: Double) -> MTLTexture? {
        guard let s = scenes["\(width)x\(height)"], let device = MTLCreateSystemDefaultDevice() else { return nil }
        func tex() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)
        }
        guard let frame = tex(), let snap = tex(),
              let cb = s.scene.render(into: frame, time: time, outputSize: CGSize(width: width, height: height), pointer: nil) else { return nil }
        WallpaperTransition.resolveSnapshot(frame, into: snap, hdrScale: 1, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return snap
    }

    /// The swapchain path: the frame's command buffer ends with the copy into the acquired image, and the present is
    /// queued behind it. Nothing is read back and nothing waits, except `nextDrawable` once two frames are in flight.
    func present(time: Double, to swapchain: VulkanSwapchain) throws {
        let source = try source(swapchain.width, swapchain.height)
        guard let cb = source.encode(time: time) else { return }
        if let drawable = try swapchain.nextDrawable() { cb.gpuCommandBuffer.present(source.target.gpuTexture, to: drawable) }
        cb.commit()
    }

    private lazy var queue: MTLCommandQueue? = MTLCreateSystemDefaultDevice()?.makeCommandQueue()

    func presentLast(to swapchain: VulkanSwapchain) throws {
        guard let source = scenes["\(swapchain.width)x\(swapchain.height)"], let cb = queue?.makeCommandBuffer(),
              let drawable = try swapchain.nextDrawable() else { return }
        cb.gpuCommandBuffer.present(source.target.gpuTexture, to: drawable)
        cb.commit()
    }
}

/// PhotonProto's headless scene (clear + plain image layers) as a frame source, one ProtoScene per output size.
/// ProtoScene fixes its time at load, so its frames are static and cached.
final class ProtoFrameSource: DesktopFrameSource {
    let device: GPUDevice
    let wallpaper: URL
    let engineAssets: URL
    let time: Float
    private var cache: [String: [UInt8]] = [:]
    var animates: Bool { false }

    init(device: GPUDevice, wallpaper: URL, engineAssets: URL, time: Float) {
        self.device = device
        self.wallpaper = wallpaper
        self.engineAssets = engineAssets
        self.time = time
    }

    func frame(time _: Double, width: Int, height: Int) throws -> [UInt8] {
        let key = "\(width)x\(height)"
        if let f = cache[key] { return f }
        var o = ProtoScene.Options()
        o.width = width
        o.height = height
        o.time = time
        let scene = try ProtoScene(device: device, wallpaper: wallpaper, engineAssets: engineAssets, options: o)
        for line in scene.log { print("note: \(line)") }
        var px = try scene.render()
        px.removeSubrange((width * height * 4)...)  // an HDR target reads back wider texels; only the 8-bit path is shown
        Self.swapRB(&px)
        cache[key] = px
        return px
    }

    /// RGBA ↔ BGRA in place.
    static func swapRB(_ px: inout [UInt8]) {
        px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i + 3 < p.count { let r = p[i]; p[i] = p[i + 2]; p[i + 2] = r; i += 4 }
        }
    }
}
#endif
