#if os(Linux)
import CPhotonMedia
import Foundation
import Metal
import PhotonApp
import PhotonCore
import PhotonGPU
import PhotonRender
import PhotonVulkan

// What the X11 and Wayland scene hosts share (docs/linux-port.md §5, §5.2, §5.4): the scene loop (clock, pause and mute
// fades, rate, sound, a video wallpaper's audio and its loop count), the app's control commands, the playback-rule
// evaluation with its application, audio and VRAM inputs, the multi-display layouts (a shared frame for stretch and
// clone), the cursor, and wallpaper switches with the engine's transition overlay (docs/re/frame-graph.md §T), in the
// host itself (`load`) or handed over from another host process (`--switch-snapshot`).

/// An output the scene host draws: an X11 desktop window (or a region of the root window) or a Wayland layer surface.
protocol HostSurface: AnyObject {
    var name: String { get }
    /// Buffer size in pixels.
    var pixelSize: (Int, Int) { get }
    /// Geometry in the window system's global logical coordinates (layout box, cursor).
    var logical: CGRect { get }
    var swapchain: VulkanSwapchain? { get }
    /// The surface can be drawn (Wayland: configured, not closed).
    var ready: Bool { get }
    var paused: Bool { get set }
    var drawn: Bool { get set }
    /// Called right before a Vulkan present on the surface (Wayland: viewport and opaque region for the commit).
    func willPresent()
    /// Readback path: tightly packed BGRA8 rows of `pixelSize`.
    func show(bgra: [UInt8], width: Int, height: Int)
}

/// A frame the old host hands to the next one across a process switch: `PSN1`, width and height (UInt32 LE), then
/// opaque BGRA8 rows. One file per output (`<name>.bgra`), `shared.bgra` for a stretch / clone frame.
enum HostSnapshot {
    static func write(_ bgra: [UInt8], width: Int, height: Int, to url: URL) throws {
        var d = Data("PSN1".utf8)
        for v in [UInt32(width), UInt32(height)] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: bgra)
        let tmp = url.appendingPathExtension("part")
        try d.write(to: tmp)
        _ = rename(tmp.path, url.path)
    }

    static func read(_ url: URL) -> (bgra: [UInt8], width: Int, height: Int)? {
        guard let d = try? Data(contentsOf: url), d.count >= 12, d.prefix(4) == Data("PSN1".utf8) else { return nil }
        let b = [UInt8](d)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let w = u32(4), h = u32(8)
        guard w > 0, h > 0, b.count >= 12 + w * h * 4 else { return nil }
        return (Array(b[12..<(12 + w * h * 4)]), w, h)
    }

    static func fileName(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined() + ".bgra"
    }
}

final class SceneHost {
    typealias Options = X11DesktopHost.Options

    /// A unit of drawing: one output (a wallpaper per display), or the shared frame of a stretch / clone layout and the
    /// region of it each output shows (docs/re/09 §8.2; DisplayLayout.swift on macOS).
    struct Unit {
        var key: String
        var width: Int, height: Int
        var parts: [(surface: HostSurface, region: GPUBlitRect)]
        /// The logical rectangle the cursor is mapped into (UV, y down).
        var pointerRect: CGRect
    }

    /// One switch in progress on a unit (WallpaperRenderer.Switch on macOS).
    struct Switch {
        enum Kind: String {
            /// An effect (`Transition_Start` 0x140058430): the overlay animates the old frame away.
            case transition
            /// "none (no flicker)" (−2, 0x14005aaf0): the old frame holds until the new wallpaper draws.
            case hold
            /// "none" (−1) between wallpapers of the same type: the last frame stays, frozen, until the new one presents.
            case frozen
            /// "none" between types: the old wallpaper is gone at once; black until the new one draws.
            case cut
        }
        var kind: Kind
        var transition: WallpaperTransition?
        var snapshot: MTLTexture?
        let begun: Double
        var shown = false
        var started = false
    }

    let options: Options
    let engineAssets: URL
    private(set) var source: DesktopFrameSource
    private(set) var wallpaper: URL
    private(set) var kind: ProjectKind
    let rules: DesktopRuleState
    let layout: Int
    /// Frames per second for the host loop: the frame rate in use after the energy controls (unlimited = 240).
    var frameRate: Double { EnergyOptions.loopRate(rules.energy.fps) }
    let cloneFlip: Set<String>
    var videoAudio: VideoAudio?
    var isVideoWallpaper: Bool { kind == .video }

    private var speed: Float = 1, volumeFade: Float = 1
    private var clock: Double = 0
    private var clockStarted = false
    private(set) var stopped = false
    private var lastTick: Double?
    private lazy var ratePercent = options.ratePercent
    private lazy var volumePercent = options.volumePercent
    private var appPaused = false, appMuted = false
    /// `snapshot` was answered: the next host is taking over, this one stops drawing and goes quiet.
    private var handedOver = false
    private(set) var quit = false
    private let control: HostControl?
    private(set) var frames = 0
    private(set) var firstFrameEnd: Date?
    private var readyAnnounced = false

    /// Video wallpapers: the file's duration and the completed loops (the playlist's "change when a video ends",
    /// `Playlist_OnVideoEnded` 0x140067720; macOS counts loops of the slot clock the same way).
    private var videoDuration: Double = 0
    private var videoLoops = 0

    /// Cursor in global logical coordinates and the left button pressed on the desktop (DesktopPointer on macOS).
    var pointer: CGPoint?
    var pointerDown = false {
        didSet { if pointerDown != oldValue, Self.pointerLog { print("pointer: \(pointerDown ? "down" : "up")\(pointer.map { String(format: " at %.0f,%.0f", $0.x, $0.y) } ?? "")") } }
    }
    static let pointerLog = ProcessInfo.processInfo.environment["PHOTON_POINTER_LOG"] == "1"
    private var lastPointerLog: CGPoint?

    private var switches: [String: Switch] = [:]
    /// A switch handed over from another host process: its frames and the transition settings, applied to each unit
    /// the first time it is drawn.
    private var pendingSnapshot: (dir: URL, settings: TransitionSettings)?
    private var seenUnits: Set<String> = []
    private(set) var lastUnits: [Unit] = []
    private var lastTargets: [String: MTLTexture] = [:]
    private var scratch: [String: MTLTexture] = [:]
    private var loadFailed = false
    /// Flushes presented frames to the window system before a blocking scene load (XSync / wl_display_flush).
    var flush: () -> Void = {}

    private lazy var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var queue: MTLCommandQueue? = device?.makeCommandQueue()

    init(source: DesktopFrameSource, wallpaper: URL, options: Options, engineAssets: URL) {
        self.source = source
        self.wallpaper = wallpaper
        self.options = options
        self.engineAssets = engineAssets
        kind = ProjectKind.classify(file: (SceneRenderer.readProject(wallpaper)["file"] as? String) ?? "")
        rules = DesktopRuleState(settings: options.settings)
        rules.energySettings = options.energy
        rules.baseFPS = EnergyOptions.baseFPS(options.fps)
        SceneRenderer.fpsSetting = rules.energy.fps
        rules.appRules = options.appRules
        layout = options.layout
        rules.layout = options.layout
        cloneFlip = Set(options.cloneFlip)
        control = options.control ? HostControl() : nil
        if let dir = options.switchSnapshot {
            pendingSnapshot = (URL(fileURLWithPath: dir), options.switchTransition ?? TransitionSettings(mode: -1, timeMs: 0))
        }
        videoDuration = isVideoWallpaper ? Self.videoDuration(wallpaper) : 0
        if options.settings.pauseOnVRAMExhaustion, let b = vramReading(real: true) {
            print(String(format: "vram: %.0f of %.0f MB in use (VK_EXT_memory_budget)", b.used / 1e6, b.budget / 1e6))
        }
    }

    /// Scene seconds per wall-clock second (`--rate`, `rate`): at least 0.1 for scenes, as is for videos.
    var rate: Double {
        let r = Double(ratePercent) / 100
        return isVideoWallpaper ? r : max(r, 0.1)
    }

    /// The container duration (what AVURLAsset.duration gives the macOS app's loop count).
    static func videoDuration(_ dir: URL) -> Double {
        guard let file = SceneRenderer.readProject(dir)["file"] as? String else { return 0 }
        var err = [CChar](repeating: 0, count: 256)
        guard let v = photon_video_open(dir.appendingPathComponent(file).path, &err, err.count) else { return 0 }
        defer { photon_video_close(v) }
        let d = photon_video_duration(v)
        return d.isFinite && d > 0 ? d : 0
    }

    // MARK: Control

    /// The app's commands (HostControl.swift).
    func handleControl(_ surfaces: [HostSurface], now: Double) {
        guard let control else { return }
        for c in control.poll() {
            switch c {
            case .pause(let p): appPaused = p; print("control: pause \(p)")
            case .mute(let m): appMuted = m; print("control: mute \(m)")
            case .volume(let v): volumePercent = v
            case .rate(let r): ratePercent = r
            case .general(let g): source.applyGeneral(g)
            case .load(let o): load(o, now: now)
            case .snapshot(let dir): writeSnapshot(dir)
            case .quit: quit = true
            }
        }
    }

    /// `load {json}`: another scene or video wallpaper on the same outputs. As `Transition_Begin` 0x140068fc0 then
    /// `App_LoadWallpaper` 0x140072a70: the old frame is read back for the overlay (or held, or frozen), the old scene
    /// is freed, and the new one loads (synchronously, behind the overlay drawn at progress 0).
    func load(_ o: [String: Any], now: Double) {
        guard let path = o["dir"] as? String else { print("switch: load without dir"); return }
        let dir = URL(fileURLWithPath: path)
        let newKind = ProjectKind.classify(file: (SceneRenderer.readProject(dir)["file"] as? String) ?? "")
        guard newKind == .scene || newKind == .video else { print("switch: \(path) is not a scene or video wallpaper"); return }
        let settings = (o["transition"] as? [String: Any]).map { TransitionSettings.parse($0) } ?? TransitionSettings(mode: -1, timeMs: 0)
        print("switch: \(wallpaper.lastPathComponent) → \(dir.lastPathComponent), transition \(Self.describe(settings))")
        if !stopped { beginSwitch(settings, sameType: newKind == kind, now: now) }
        (source as? SceneFrameSource)?.unloadAll()
        let props = (o["properties"] as? [String: Any]) ?? [:]
        let general = (o["general"] as? [String: Any]) ?? [:]
        source = SceneFrameSource(wallpaper: dir, engineAssets: engineAssets, still: options.still ? Double(options.time) : nil,
                                  sound: options.sound, overrides: props, general: general)
        wallpaper = dir
        kind = newKind
        if let v = (o["volume"] as? NSNumber)?.floatValue { volumePercent = v }
        if let r = (o["rate"] as? NSNumber)?.floatValue { ratePercent = r }
        videoAudio = isVideoWallpaper && !options.still && options.sound ? VideoAudio(project: dir) : nil
        videoDuration = isVideoWallpaper ? Self.videoDuration(dir) : 0
        videoLoops = 0
        clockStarted = false
        loadFailed = false
        for u in lastUnits { for p in u.parts { p.surface.drawn = false } }
    }

    static func describe(_ s: TransitionSettings) -> String {
        switch s.mode {
        case -1: return "none"
        case -2: return "none (no flicker)"
        case -3: return "random\(s.pool.isEmpty ? "" : " of \(s.pool)") \(s.timeMs) ms"
        default: return "effect \(s.mode) \(s.timeMs) ms"
        }
    }

    /// `Transition_Begin`: per unit, the old frame is captured (vt+0x60) and the switch begins (frame-graph §T2).
    private func beginSwitch(_ settings: TransitionSettings, sameType: Bool, now: Double) {
        guard let scene = source as? SceneFrameSource else { return }
        for u in lastUnits {
            guard scene.isLoaded(u.width, u.height), u.parts.contains(where: { $0.surface.drawn }) else { continue }
            if settings.mode == -1 {
                // Same type: the wallpaper object is reused and its last frame stays until the new scene presents.
                if sameType, let snap = scene.capture(u.width, u.height, time: clock) {
                    switches[u.key] = Switch(kind: .frozen, snapshot: snap, begun: now)
                } else {
                    switches[u.key] = Switch(kind: .cut, begun: now)
                }
                continue
            }
            guard let snap = scene.capture(u.width, u.height, time: clock) else { continue }
            startSwitch(settings, snapshot: snap, key: u.key, now: now)
        }
    }

    private func startSwitch(_ settings: TransitionSettings, snapshot: MTLTexture, key: String, now: Double) {
        var transition: WallpaperTransition?
        if let effect = settings.pickEffect(), let device, let queue {
            do {
                transition = try WallpaperTransition(device: device, engineAssets: engineAssets, effect: effect, timeMs: settings.timeMs,
                                                     snapshot: snapshot, commandQueue: queue)
            } catch {
                // As the macOS app: no overlay; the old wallpaper is gone and the new one appears when it has loaded.
                print("switch: transition \(effect) failed: \(error)")
                switches[key] = Switch(kind: .cut, begun: now)
                return
            }
        }
        switches[key] = Switch(kind: transition == nil ? .hold : .transition, transition: transition, snapshot: snapshot, begun: now)
        print("switch: \(key) \(transition.map { "effect \($0.effect), \(settings.timeMs) ms" } ?? "hold (no flicker)")")
    }

    /// `snapshot DIR`: this host's frames for the host that takes over (`R_ReadBackbuffer` per output); then it stops
    /// drawing and goes quiet until it is ended.
    func writeSnapshot(_ path: String) {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0
        if let scene = source as? SceneFrameSource, !stopped {
            for u in lastUnits where scene.isLoaded(u.width, u.height) {
                guard let tex = scene.capture(u.width, u.height, time: clock) else { continue }
                let px = Self.read(tex)
                let name = u.key == "shared" ? "shared" : u.key
                if (try? HostSnapshot.write(px, width: u.width, height: u.height, to: dir.appendingPathComponent(HostSnapshot.fileName(name)))) != nil {
                    written += 1
                }
            }
        }
        handedOver = true
        print("snapshot: written \(path) (\(written) frame(s))")
    }

    /// Seeds a unit's switch from the previous host's frame (`--switch-snapshot`), before its scene loads.
    private func seedSwitch(_ u: Unit, now: Double) {
        guard let (dir, settings) = pendingSnapshot else { return }
        var names = [u.key == "shared" ? "shared" : u.key]
        if u.key == "shared" { names += u.parts.map(\.surface.name) } else { names.append("shared") }
        guard let file = names.lazy.compactMap({ HostSnapshot.read(dir.appendingPathComponent(HostSnapshot.fileName($0))) }).first,
              let snap = texture(file.bgra, width: file.width, height: file.height, size: (u.width, u.height)) else {
            print("switch: no frame from the previous host for \(u.key)")
            return
        }
        if settings.mode == -1 {
            switches[u.key] = Switch(kind: .frozen, snapshot: snap, begun: now)
            print("switch: \(u.key) frozen (previous host's frame)")
        } else {
            startSwitch(settings, snapshot: snap, key: u.key, now: now)
        }
    }

    /// BGRA8 rows as a texture of `size` (scaled by a linear blit when the frame came at another size).
    private func texture(_ bgra: [UInt8], width: Int, height: Int, size: (Int, Int)) -> MTLTexture? {
        guard let device, let queue else { return nil }
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)
        }
        guard let t = make(width, height) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bgra, bytesPerRow: width * 4)
        if (width, height) == size { return t }
        guard let s = make(size.0, size.1), let cb = queue.makeCommandBuffer() else { return nil }
        cb.gpuCommandBuffer.blit(t.gpuTexture, from: GPUBlitRect(width: width, height: height), to: s.gpuTexture,
                                 at: GPUBlitRect(width: size.0, height: size.1))
        cb.commit()
        cb.waitUntilCompleted()
        return s
    }

    static func read(_ t: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return bytes
    }

    // MARK: Rules

    /// The playback evaluator tick (WM_TIMER 0x68): the window probe's masks and rule windows, the system inputs, the
    /// process and audio inputs and the VRAM budget; pauses or resumes each output.
    func evaluate(_ surfaces: [HostSurface], probe: DesktopProbe, inputs: DesktopSystemInputs) {
        let app = LinuxProcesses.appInputs(settings: rules.settings, rules: rules.appRules)
        let wasMuted = rules.muted
        for line in rules.tick(masks: probe.masks, inputs: inputs, monitorCount: surfaces.count, windows: probe.windows, app: app,
                               vram: vramReading(real: false)) {
            print("playback: \(line)")
        }
        // The renderer's `fps` setting (particle half-steps, audio poll period) follows the rate in use.
        if SceneRenderer.fpsSetting != rules.energy.fps {
            SceneRenderer.fpsSetting = rules.energy.fps
            AudioSystem.shared.pollPeriodMs = AudioSystem.pollPeriod(fps: rules.energy.fps)
        }
        if rules.stopped != stopped {
            stopped = rules.stopped
            print("playback: \(stopped ? "stop" : "resume from stop")")
            if stopped {
                // Stop destroys the wallpapers (0x140073ac0); they load again when the rule ends.
                (source as? SceneFrameSource)?.unloadAll()
                switches.removeAll()
                lastTargets.removeAll()
                for s in surfaces { s.drawn = false }
            }
        }
        if rules.muted != wasMuted { print("playback: \(rules.muted ? "mute" : "unmute")") }
        guard !stopped else { return } // the engine keeps the previous pause state while stopped
        let masks = probe.masks
        for (i, o) in surfaces.enumerated() {
            let p = rules.outputPaused(i)
            if p != o.paused {
                let bit = DesktopPauseRules.bit(i)
                let flags = rules.flags
                let why = flags.contains(.asleep) ? "asleep" : flags.contains(.userPause) ? "locked"
                    : flags.contains(.screensaver) ? "screensaver" : flags.contains(.onBattery) && rules.settings.battery != .run ? "battery"
                    : masks.fullscreen & bit != 0 ? "fullscreen" : masks.maximized & bit != 0 ? "maximized" : masks.focus & bit != 0 ? "focus"
                    : app.otherAudio && rules.settings.audio == .pause ? "audio" : "application rule"
                print("playback: \(o.name) \(p ? "paused (\(why))" : "resumed")")
            }
            o.paused = p
        }
    }

    /// Device-local usage and budget in bytes for `pausevram`: VK_EXT_memory_budget, or `PHOTON_VRAM_TEST` (a file
    /// holding "used budget" in MB, read every tick: the rule's hysteresis is checked with it).
    private func vramReading(real: Bool) -> (used: Double, budget: Double)? {
        guard rules.settings.pauseOnVRAMExhaustion || real else { return nil }
        if !real, let path = ProcessInfo.processInfo.environment["PHOTON_VRAM_TEST"] {
            let v = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
            return v.count == 2 ? (v[0] * 1e6, v[1] * 1e6) : nil
        }
        guard let dev = (MTLCreateSystemDefaultDevice()?.gpuDevice as? VulkanDevice), let b = dev.memoryBudget() else { return nil }
        return (Double(b.used), Double(b.budget))
    }

    // MARK: Layout

    func units(_ surfaces: [HostSurface]) -> [Unit] {
        let ready = surfaces.filter { $0.ready && $0.pixelSize.0 > 0 && $0.pixelSize.1 > 0 }
        guard let first = ready.first else { return [] }
        func full(_ w: Int, _ h: Int) -> GPUBlitRect { GPUBlitRect(width: w, height: h) }
        switch layout {
        case 1:
            // Stretch: the bounding box of every output at the smallest scale (clamped to 16384), each output its part.
            let rects = ready.map { (id: $0.name, rect: $0.logical, scale: $0.logical.width > 0 ? CGFloat($0.pixelSize.0) / $0.logical.width : 1) }
            let (box, uv) = LayoutGeometry.spanRegions(rects)
            let scale = rects.map(\.scale).min() ?? 1
            var w = box.width * scale, h = box.height * scale
            if w > 16384 || h > 16384 { let k = 16384 / max(w, h); w *= k; h *= k }
            let W = max(Int(w.rounded()), 2), H = max(Int(h.rounded()), 2)
            let parts = ready.map { s -> (HostSurface, GPUBlitRect) in
                let r = uv[s.name] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                return (s, GPUBlitRect(x0: Int((r.minX * CGFloat(W)).rounded()), y0: Int((r.minY * CGFloat(H)).rounded()),
                                       x1: Int((r.maxX * CGFloat(W)).rounded()), y1: Int((r.maxY * CGFloat(H)).rounded())))
            }
            return [Unit(key: "shared", width: W, height: H, parts: parts, pointerRect: box)]
        case 2:
            // Clone: the source output's frame (`--clone-source`: the profile's `source` or the size / orientation rule,
            // LayoutPlan; default the first output), cover-fitted onto the others; a flipped clone target mirrors it.
            let src = options.cloneSource.flatMap { n in ready.first { $0.name == n } } ?? first
            let (W, H) = src.pixelSize
            let parts = ready.map { s -> (HostSurface, GPUBlitRect) in
                if s === src { return (s, full(W, H)) }
                let (w, h) = s.pixelSize
                let r = LayoutGeometry.coverUV(source: CGFloat(W) / CGFloat(H), target: CGFloat(w) / CGFloat(h))
                var g = GPUBlitRect(x0: Int((r.minX * CGFloat(W)).rounded()), y0: Int((r.minY * CGFloat(H)).rounded()),
                                    x1: Int((r.maxX * CGFloat(W)).rounded()), y1: Int((r.maxY * CGFloat(H)).rounded()))
                if cloneFlip.contains(s.name) { let x = g.x0; g.x0 = g.x1; g.x1 = x }
                return (s, g)
            }
            return [Unit(key: "shared", width: W, height: H, parts: parts, pointerRect: src.logical)]
        default:
            return ready.map { Unit(key: $0.name, width: $0.pixelSize.0, height: $0.pixelSize.1, parts: [($0, full($0.pixelSize.0, $0.pixelSize.1))],
                                    pointerRect: $0.logical) }
        }
    }

    private func pointerUV(_ u: Unit) -> CGPoint? {
        guard let p = pointer, u.pointerRect.width > 0, u.pointerRect.height > 0 else { return nil }
        return CGPoint(x: (p.x - u.pointerRect.minX) / u.pointerRect.width, y: (p.y - u.pointerRect.minY) / u.pointerRect.height)
    }

    // MARK: Frame

    /// The pause / mute fades of the scene loop (0x14011137f–0x14011144d), WallpaperRenderer.fade on macOS.
    static func fade(_ value: Float, toward target: Float, dt: Float) -> Float {
        abs(value - target) < 0.01 ? target : value + (target - value) * min(dt * 6, 1)
    }

    /// A switch overlay runs at display rate (the engine's transition thread: Sleep(15) per frame, 0x14005a790).
    var switching: Bool { switches.values.contains { $0.transition != nil } }

    /// One pass of the scene loop (docs/re/09 §2, as WallpaperRenderer on macOS): dt clamped to [0.0001, 0.25], the time
    /// scale fades toward the pause state and the volume toward the mute state, the scene steps by
    /// clamp(rate · speed · dt, 0.0001, 0.25); fully paused, it stops stepping. Then every unit that needs it is drawn.
    func frame(_ surfaces: [HostSurface], now: Double) throws {
        let dt = Float(min(max(now - (lastTick ?? now), 0.0001), 0.25))
        lastTick = now
        let allPaused = stopped || appPaused || handedOver || surfaces.allSatisfy { $0.paused }
        speed = Self.fade(speed, toward: allPaused ? 0 : 1, dt: dt)
        volumeFade = Self.fade(volumeFade, toward: rules.muted || appMuted || handedOver ? 0 : 1, dt: dt)
        if options.still || !clockStarted {
            clock = Double(options.time)
        } else if !(allPaused && speed <= 0) {
            clock += Double(min(max(Float(rate) * speed * dt, 0.0001), 0.25))
        }
        let units = self.units(surfaces)
        let gain = volumePercent / 100 * volumeFade
        // Sound objects: the first output's scene plays them (the first display showing the wallpaper on macOS).
        source.setSound(owner: units.first.map { ($0.width, $0.height) }, volume: gain,
                        paused: stopped || appPaused || handedOver || (surfaces.first?.paused ?? true), timeScale: Float(rate) * speed)
        videoAudio?.sync(clock: clock, rate: Float(rate), volume: gain, paused: allPaused || speed <= 0)
        if videoDuration > 0, clockStarted {
            let loops = Int(clock / videoDuration)
            if loops > videoLoops {
                videoLoops = loops
                print("video: ended \(loops)")
            }
        }
        if Self.pointerLog, let p = pointer, p != lastPointerLog {
            lastPointerLog = p
            if let u = units.first, let uv = pointerUV(u) { print(String(format: "pointer: %.0f,%.0f uv %.3f,%.3f", p.x, p.y, uv.x, uv.y)) }
        }
        guard !stopped, !handedOver else { return }
        lastUnits = units
        var drew = false
        for u in units {
            if !seenUnits.contains(u.key) {
                seenUnits.insert(u.key)
                seedSwitch(u, now: now)
            }
            let sw = switches[u.key] != nil
            let live = u.parts.filter { !($0.surface.paused || appPaused) || sw }
            guard !live.isEmpty else { continue }
            let needed = sw || (source.animates && !options.still) || live.contains { !$0.surface.drawn }
            guard needed else { continue }
            try draw(u, parts: live, now: now)
            drew = true
        }
        if drew {
            clockStarted = true
            frames += 1
            if frames == 1 { firstFrameEnd = Date() }
        }
        if !readyAnnounced, !units.isEmpty, units.allSatisfy({ $0.parts.allSatisfy { $0.surface.drawn } }) {
            readyAnnounced = true
            print("host: ready")
        }
    }

    private func draw(_ u: Unit, parts: [(surface: HostSurface, region: GPUBlitRect)], now: Double) throws {
        guard let scene = source as? SceneFrameSource, let queue else {
            // Readback-only sources (PhotonProto): a frame per output.
            for p in parts {
                let (w, h) = p.surface.pixelSize
                p.surface.show(bgra: try source.frame(time: clock, width: w, height: h), width: w, height: h)
                p.surface.drawn = true
            }
            return
        }
        if var sw = switches[u.key], !scene.isLoaded(u.width, u.height) || loadFailed {
            // The new wallpaper is not loaded: the overlay at progress 0 (or the held / frozen frame, or black) goes up
            // first, then the scene loads behind it. A wallpaper that fails to load gets the effect after 3 s anyway
            // (0x14006a17f) and black after it.
            guard let target = scratchTexture("loading:\(u.key)", u.width, u.height), let cb = queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            if let tr = sw.transition {
                if loadFailed, now - sw.begun >= 3 { tr.start(at: now) }
                if tr.width == target.width, tr.height == target.height { tr.encode(over: target, commandBuffer: cb, time: now) }
                if tr.isFinished(at: now) { switches[u.key] = nil }
            } else if let snap = sw.snapshot, sw.kind != .cut, snap.width == target.width, snap.height == target.height {
                WallpaperTransition.drawHeld(snap, over: target, commandBuffer: cb)
            }
            try present(target, cb, u, parts)
            flush()
            if !sw.shown {
                sw.shown = true
                if switches[u.key] != nil { switches[u.key] = sw }
                print("switch: \(u.key) \(sw.kind.rawValue) shown")
            }
            guard !loadFailed else { return }
            do {
                try scene.load(u.width, u.height)
            } catch {
                print("desktop: load failed: \(error)")
                loadFailed = true
            }
            return
        }
        guard let (cb, target) = try scene.encode(time: clock, width: u.width, height: u.height, pointer: pointerUV(u), down: pointerDown) else { return }
        if var sw = switches[u.key] {
            if let tr = sw.transition, tr.width == target.width, tr.height == target.height {
                // The new wallpaper is ready: the effect starts now (`Transition_StartTick` 0x14006a030).
                tr.start(at: now)
                if !sw.started { sw.started = true; switches[u.key] = sw; print("switch: \(u.key) effect \(tr.effect) started") }
                tr.encode(over: target, commandBuffer: cb, time: now)
                if tr.isFinished(at: now) { switches[u.key] = nil; print("switch: \(u.key) finished") }
            } else {
                // Hold, frozen and cut end with the new wallpaper's first frame.
                switches[u.key] = nil
                print("switch: \(u.key) finished")
            }
        }
        try present(target, cb, u, parts)
    }

    private func scratchTexture(_ key: String, _ w: Int, _ h: Int) -> MTLTexture? {
        if let t = scratch[key], t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let t = device?.makeTexture(descriptor: d)
        scratch[key] = t
        return t
    }

    /// Shows `target` (the unit's frame) on its outputs: the whole texture through the frame's own command buffer for a
    /// single output, else a region per output (scaled or mirrored), through the swapchain or read back.
    private func present(_ target: MTLTexture, _ cb: MTLCommandBuffer, _ u: Unit, _ parts: [(surface: HostSurface, region: GPUBlitRect)]) throws {
        let whole = GPUBlitRect(width: u.width, height: u.height)
        if parts.count == 1, let p = parts.first, p.region == whole, p.surface.pixelSize == (u.width, u.height) {
            if let sc = p.surface.swapchain {
                p.surface.willPresent()
                if let drawable = try sc.nextDrawable() { cb.gpuCommandBuffer.present(target.gpuTexture, to: drawable) }
                cb.commit()
            } else {
                cb.commit()
                cb.waitUntilCompleted()
                p.surface.show(bgra: Self.read(target), width: u.width, height: u.height)
            }
        } else {
            cb.commit()
            for p in parts {
                guard let cb2 = queue?.makeCommandBuffer() else { continue }
                if let sc = p.surface.swapchain {
                    p.surface.willPresent()
                    if let drawable = try sc.nextDrawable() { cb2.gpuCommandBuffer.present(target.gpuTexture, region: p.region, to: drawable) }
                    cb2.commit()
                } else {
                    let (w, h) = p.surface.pixelSize
                    guard let tmp = scratchTexture("part:\(p.surface.name)", w, h) else { continue }
                    cb2.gpuCommandBuffer.blit(target.gpuTexture, from: p.region, to: tmp.gpuTexture, at: GPUBlitRect(width: w, height: h))
                    cb2.commit()
                    cb2.waitUntilCompleted()
                    p.surface.show(bgra: Self.read(tmp), width: w, height: h)
                }
            }
        }
        for p in parts { p.surface.drawn = true }
        lastTargets[u.key] = target
    }

    /// The window system is going away: forget its surfaces (they must be destroyed before its connection closes).
    func dropSurfaces() {
        lastUnits.removeAll()
        lastTargets.removeAll()
    }

    /// Expose on an output: its part of the last frame again.
    func representLast(_ surface: HostSurface) {
        guard let u = lastUnits.first(where: { $0.parts.contains { $0.surface === surface } }), let t = lastTargets[u.key],
              let p = u.parts.first(where: { $0.surface === surface }), let sc = surface.swapchain, let cb = queue?.makeCommandBuffer(),
              let drawable = try? sc.nextDrawable() else { return }
        surface.willPresent()
        cb.gpuCommandBuffer.present(t.gpuTexture, region: p.region, to: drawable)
        cb.commit()
    }
}
#endif
