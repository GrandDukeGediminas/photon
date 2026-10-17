#if os(Linux)
import CPhotonSystem
import CPhotonWayland
import CPhotonWeb
import CX11
import Foundation
import Metal
import PhotonApp
import PhotonCore
import PhotonGPU
import PhotonProto
import PhotonRender

// Web wallpapers on Linux (docs/linux-port.md §5.3): the counterpart of the macOS WKWebView host
// (Sources/PhotonRender/WebWallpaper.swift) on WebKitGTK 4.1 (CPhotonWeb). One web view per monitor, in a GTK window
// that is a layer-shell background surface on Wayland or a desktop-type window on X11. The page API is the macOS one
// (WebPageScripts, shared): user and general properties, directory properties with the random-file request, the audio
// listener fed from the PipeWire/PulseAudio capture every 33 ms, the five media listeners fed from MPRIS
// (WebMediaSourceLinux), the LED plugin stubs, utilities, the CSS colour filter and flip, pause and mute from the
// playback rules. The rules' window masks come from a second connection: EWMH on X11, wlr-foreign-toplevel on Wayland.

/// One page (the engine runs a CEF wallpaper per monitor).
final class LinuxWebPage {
    let view: Int32
    /// GDK monitor index the page covers.
    let monitor: Int
    var loaded = false
    var paused = false
    var muted = false
    /// `AudioContextRegistered`: the page registered an audio listener.
    var audioRequested = false
    var mediaRegistered = false
    var lastAudio = Date.distantPast
    var appliedFilter: String?
    var appliedFlip: Bool?
    /// The output name the app knows this monitor by (XRandR monitor / xdg_output name), for snapshots.
    var outputName = ""
    /// Pixel size of the page (monitor geometry × scale): the overlay's size.
    var pixelSize = (0, 0)
    /// A wallpaper switch onto this page (the engine's transition child window over the new web wallpaper).
    var switchState: WebSwitch?

    init(view: Int32, monitor: Int) {
        self.view = view
        self.monitor = monitor
    }
}

/// The overlay over a new web page (frame-graph §T2/T3, WallpaperRenderer.drawWebSwitch on macOS): a page is never
/// "ready" (web vt+0x78 0x1400a36d0 returns false), so an effect starts 0.5 s after the switch; a −2 hold and a "none"
/// frozen frame stay until the page has loaded, 3 s at most.
final class WebSwitch {
    let transition: WallpaperTransition?
    let snapshot: MTLTexture
    let begun: Date
    var lastFrame = Date.distantPast
    init(transition: WallpaperTransition?, snapshot: MTLTexture, begun: Date) {
        self.transition = transition
        self.snapshot = snapshot
        self.begun = begun
    }
}

final class WebDesktopHost {
    struct Options {
        var seconds: Double?
        var settings = PlaybackSettings()
        var windowUpdateRate: Double = 1
        var volumePercent: Float = 50
        /// The wallpaper's general properties (wec_* colour filter, alignmentfliph, audioprocessing): `--general JSON`
        /// or PHOTON_GENERAL, as `photon-tool render` takes them.
        var general: [String: Any] = [:]
        /// User property overrides (`--property name=value`).
        var overrides: [String: Any] = [:]
        /// The host's general settings object for `applyGeneralProperties` (AppState.generalSettingsForWeb on macOS).
        var fps = 30
        /// `--dump-text`: print each page's `document.body.innerText` before exit (tests).
        var dumpText = false
        /// `--eval JS`: print the value of a script in each page before exit (tests).
        var evals: [String] = []
        /// `--output NAME,…`: only these monitors (GDK model / connector name, or index).
        var outputs: [String]?
        /// `--control`: commands on stdin (HostControl.swift).
        var control = false
        /// `--switch-snapshot DIR` + `--transition JSON`: the previous host's frames and the switch transition.
        var switchSnapshot: String?
        var switchTransition: TransitionSettings?
        var engineAssets: URL?
        /// `--app-rules JSON` (the application rules; pages are paused, muted or stopped like scenes).
        var appRules: [AppRule] = []
        /// `--region NAME=X,Y,W,H`: a split region of that output (the page's window covers only the rectangle).
        var regions: [String: CGRect] = [:]
        /// photon's energy controls (`--battery-fps`, `--low-power`, `--cap-web`; EnergyOptions).
        var energy = EnergySettings()
    }

    let options: Options
    let directory: URL
    let pageURI: String
    /// The pages' frame cap (`WebPageScripts.frameLimiter`; 0 = the display's rate).
    private var webFPS = 0
    let properties: [String: Any]
    let userDirectories: [String: (url: URL, mode: String, fileType: String)]
    let supportsAudio: Bool
    private var web: OpaquePointer!
    private(set) var pages: [LinuxWebPage] = []
    private var rules: DesktopRuleState
    private var stopped = false
    private var media: WebMediaSourceLinux?
    private var monitorsChanged = false
    private var x11Probe: X11Probe?
    private var x11Display: OpaquePointer?
    private var wlProbe: OpaquePointer?
    private var results: [Int: String] = [:]
    /// The app's tray pause and mute and live general properties (`--control`).
    private var appPaused = false, appMuted = false
    private lazy var general = options.general
    private lazy var volumePercent = options.volumePercent
    private lazy var control: HostControl? = options.control ? HostControl() : nil
    /// `snapshot DIR` in progress: pages still writing, the deadline (the engine waits 300 × 10 ms for a web frame).
    private var snapshotPending: (dir: String, views: Set<Int32>, deadline: Date)?
    /// Answered `snapshot`: the next host is taking over; pages pause and go quiet.
    private var handedOver = false
    private var readyAnnounced = false
    private lazy var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var queue: MTLCommandQueue? = device?.makeCommandQueue()

    var generalSettings: [String: Any] {
        let s = options.settings
        return ["fps": options.fps, "language": "en-us", "postprocessing": "enabled",
                "playbackfocus": s.focus.engineString, "playbackmaximized": s.maximized.engineString,
                "playbackfullscreen": s.fullscreen.engineString, "playbackonbattery": s.battery.engineString,
                "playbacksleep": s.sleep.engineString, "playbackaudio": s.audio.engineString]
    }

    init(directory: URL, project: [String: Any], engineInstall: URL, options: Options) throws {
        self.options = options
        self.directory = directory
        let file = (project["file"] as? String) ?? ""
        if file.hasPrefix("http://") || file.hasPrefix("https://") {
            pageURI = file
        } else {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                throw GPUError.failed("missing page \(directory.appendingPathComponent(file).path)")
            }
            pageURI = "\(WebPageScripts.scheme)://wallpaper/" + (file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file)
        }
        properties = WebPageScripts.typedProperties(project: project, overrides: options.overrides)
        userDirectories = WebPageScripts.userDirectories(properties)
        supportsAudio = ((project["general"] as? [String: Any])?["supportsaudioprocessing"] as? Bool) ?? false
        rules = DesktopRuleState(settings: options.settings)
        rules.energySettings = options.energy
        rules.baseFPS = EnergyOptions.baseFPS(Double(options.fps))
        rules.appRules = options.appRules
        guard photon_web_init() != 0 else { throw GPUError.failed("GTK cannot open a display (DISPLAY / WAYLAND_DISPLAY)") }
        let backend = String(cString: photon_web_backend())
        if backend == "wayland", photon_web_layer_shell() == 0 {
            throw WaylandHostError.noLayerShell("the compositor has no zwlr_layer_shell_v1 (GNOME/Mutter has none: see docs/linux-port.md §5.2)")
        }
        let extra = userDirectories.values.map { $0.url.standardizedFileURL.path }
        var cExtra = extra.map { strdup($0) }
        defer { cExtra.forEach { free($0) } }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        web = cExtra.withUnsafeMutableBufferPointer { buf -> OpaquePointer? in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                photon_web_create({ ctx, view, kind, text in
                    Unmanaged<WebDesktopHost>.fromOpaque(ctx!).takeUnretainedValue().event(view: view, kind: kind, text: text.map { String(cString: $0) } ?? "")
                }, ctx, directory.standardizedFileURL.path, p, Int32(extra.count))
            }
        }
        webFPS = rules.energy.webFPS
        for script in WebPageScripts.userScripts(engineInstall: engineInstall, fps: webFPS) { photon_web_add_user_script(web, script) }
        let runtime = WebPageScripts.engineRuntime(engineInstall) != nil
        print("web: WebKitGTK on \(backend)\(backend == "wayland" ? " (layer-shell)" : " (desktop-type windows)"), page \(pageURI), "
              + "engine runtime \(runtime ? "injected" : "not found (\(engineInstall.path)/distribution/bin/webwallpaper64.exe)"), "
              + "audio \(supportsAudio ? "supported" : "not supported by the project")")
        // The rules' window probe, on a connection of its own.
        if backend == "wayland" {
            var err = [CChar](repeating: 0, count: 256)
            wlProbe = photon_wl_connect(nil, &err, err.count)
            if let p = wlProbe, photon_wl_has(p, "zwlr_foreign_toplevel_manager_v1") == 0 {
                print("web: no wlr-foreign-toplevel-management: the focus, maximized and fullscreen rules have no input")
            }
        } else if let d = XOpenDisplay(nil) {
            x11Display = d
            x11Probe = X11Probe(dpy: d, root: XDefaultRootWindow(d), atoms: X11Atoms(d))
        }
        photon_system_watch_start()
    }

    deinit {
        pages.removeAll()
        if let web { photon_web_destroy(web) }
        if let wlProbe { photon_wl_disconnect(wlProbe) }
        if let x11Display { XCloseDisplay(x11Display) }
    }

    // MARK: Pages

    private func run(_ page: LinuxWebPage, _ js: String) { photon_web_view_run(web, page.view, js) }

    private func monitors() -> [photon_web_monitor] {
        (0..<photon_web_monitor_count(web)).compactMap { i in
            var m = photon_web_monitor()
            return photon_web_monitor_get(web, i, &m) != 0 ? m : nil
        }
    }

    /// A page per monitor (rebuilt on hotplug, and after a stop rule ends).
    private func buildPages() {
        for p in pages { photon_web_view_destroy(web, p.view) }
        pages.removeAll()
        for (i, m) in monitors().enumerated() {
            let connector = withUnsafeBytes(of: m.connector) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            // `--output` names the window system's outputs (XRandR / xdg_output, from `--list-outputs`); GDK's model is the
            // connector on X11 but not on every Wayland compositor, so the name comes from the probe connection.
            let name = outputName(m, index: i, connector: connector)
            guard OutputFilter.matches(options.outputs, name: name, index: i) || OutputFilter.matches(options.outputs, name: connector, index: i)
            else { continue }
            let region = options.regions[name] ?? options.regions[connector]
            let v = region.map { photon_web_view_create_region(web, Int32(i), Int32($0.minX), Int32($0.minY), Int32($0.width), Int32($0.height)) }
                ?? photon_web_view_create(web, Int32(i))
            guard v >= 0 else { continue }
            let page = LinuxWebPage(view: v, monitor: i)
            page.outputName = name
            let (lw, lh) = region.map { (Int($0.width), Int($0.height)) } ?? (Int(m.width), Int(m.height))
            page.pixelSize = (lw * Int(max(m.scale, 1)), lh * Int(max(m.scale, 1)))
            pages.append(page)
            seedSwitch(page)
            photon_web_view_load(web, v, pageURI)
            print("web: monitor \(i) \(m.width)x\(m.height)+\(m.x)+\(m.y) scale \(m.scale) → view \(v)")
        }
    }

    private func page(_ view: Int32) -> LinuxWebPage? { pages.first { $0.view == view } }

    fileprivate func event(view: Int32, kind: Int32, text: String) {
        switch Int(kind) {
        case 0: // PHOTON_WEB_LOADED
            guard let p = page(view) else { return }
            p.loaded = true
            // The frame cap may have changed since the user scripts were added.
            run(p, WebPageScripts.setFrameRate(webFPS))
            // didFinish on macOS: general settings, user properties, fetchall directories, a pause that came first.
            run(p, WebPageScripts.applyGeneral(generalSettings))
            run(p, WebPageScripts.applyUser(properties))
            for (name, d) in userDirectories where d.mode.lowercased() == "fetchall" {
                run(p, WebPageScripts.directoryFiles(name, WebPageScripts.files(in: d.url, fileType: d.fileType)))
            }
            if p.paused { run(p, WebPageScripts.setPaused(true)) }
            p.appliedFilter = nil
            p.appliedFlip = nil
            print("web: view \(view) loaded \(text)")
        case 1: // PHOTON_WEB_MESSAGE
            guard let p = page(view) else { return }
            if text == "__audio" { p.audioRequested = true; return }
            if text == "__media" { startMedia(p); return }
            if text.hasPrefix("__random:") {
                let name = String(text.dropFirst("__random:".count))
                let file = userDirectories[name].flatMap { WebPageScripts.files(in: $0.url, fileType: $0.fileType).randomElement() }
                run(p, WebPageScripts.randomFile(name, file))
                return
            }
            if WebPageScripts.debug { print("photon web: \(text)") }
        case 2: // PHOTON_WEB_MONITORS
            monitorsChanged = true
        case 3: // PHOTON_WEB_CRASHED
            print("web: view \(view) web process \(text)")
        case 5: // PHOTON_WEB_FAILED
            print("web: view \(view) load failed: \(text)")
        case 4: // PHOTON_WEB_RESULT
            results[Int(view)] = text
        case 6: // PHOTON_WEB_SNAPSHOT
            snapshotPending?.views.remove(view)
            if text.isEmpty { print("web: view \(view) snapshot failed") }
        default: break
        }
    }

    /// The first registration starts the MPRIS source; later ones get the current state again.
    private func startMedia(_ p: LinuxWebPage) {
        p.mediaRegistered = true
        if let media {
            media.resend()
        } else {
            let m = WebMediaSourceLinux { rgba, w, h in PNGWriter.encode(rgba: rgba, width: w, height: h, keepAlpha: true) }
            media = m
            m.start()
        }
    }

    // MARK: Rules

    /// The window probe indexed by GDK monitor (masks and application-rule windows): probe monitors (XRandR /
    /// wl_output) matched to GDK's by logical geometry.
    private func probe(_ mons: [photon_web_monitor]) -> DesktopProbe {
        func remap(_ p: DesktopProbe, _ geometry: [(Int, Int, Int, Int)]) -> DesktopProbe {
            var out = DesktopProbe()
            var index: [Int: Int] = [:]
            for (gi, g) in mons.enumerated() {
                guard let pi = geometry.firstIndex(where: { $0 == (Int(g.x), Int(g.y), Int(g.width), Int(g.height)) }) else { continue }
                index[pi] = gi
                let pb = DesktopPauseRules.bit(pi), gb = DesktopPauseRules.bit(gi)
                if p.masks.focus & pb != 0 { out.masks.focus |= gb }
                if p.masks.maximized & pb != 0 { out.masks.maximized |= gb }
                if p.masks.fullscreen & pb != 0 { out.masks.fullscreen |= gb }
            }
            out.windows = p.windows.compactMap { w in index[w.display].map { (w.app, $0, w.condition) } }
            return out
        }
        if let wl = wlProbe {
            _ = photon_wl_dispatch(wl, 0)
            var globals: [UInt32] = [], geometry: [(Int, Int, Int, Int)] = []
            for i in 0..<photon_wl_output_count(wl) {
                var o = photon_wl_output()
                guard photon_wl_output_get(wl, i, &o) != 0 else { continue }
                globals.append(o.global)
                geometry.append((Int(o.x), Int(o.y), Int(o.width), Int(o.height)))
            }
            var tl: [WaylandToplevel] = []
            for i in 0..<photon_wl_toplevel_count(wl) {
                var t = photon_wl_toplevel()
                guard photon_wl_toplevel_get(wl, i, &t) != 0 else { continue }
                let outs = withUnsafeBytes(of: t.outputs) { Array($0.bindMemory(to: UInt32.self).prefix(Int(t.n_outputs))) }
                let app = withUnsafeBytes(of: t.app_id) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                tl.append(WaylandToplevel(activated: t.activated != 0, maximized: t.maximized != 0, minimized: t.minimized != 0,
                                          fullscreen: t.fullscreen != 0, outputs: outs, appID: app))
            }
            return remap(DesktopPauseRules.probe(toplevels: tl, outputs: globals, rules: options.appRules), geometry)
        }
        if let x = x11Probe {
            let xm = X11Monitors.query(x.dpy, root: x.rootWindow)
            let p = DesktopPauseRules.probe(x.snapshot(own: [], apps: !options.appRules.isEmpty), monitors: xm, rules: options.appRules)
            return remap(p, xm.map { ($0.x, $0.y, $0.width, $0.height) })
        }
        return DesktopProbe()
    }

    /// The window system's name for a GDK monitor (what `--list-outputs` printed and the app passes to `--output`):
    /// matched by logical geometry on the probe connection, else GDK's model, else "monitor<i>".
    private func outputName(_ m: photon_web_monitor, index: Int, connector: String) -> String {
        let g = (Int(m.x), Int(m.y), Int(m.width), Int(m.height))
        if let wl = wlProbe {
            for i in 0..<photon_wl_output_count(wl) {
                var o = photon_wl_output()
                guard photon_wl_output_get(wl, i, &o) != 0, (Int(o.x), Int(o.y), Int(o.width), Int(o.height)) == g else { continue }
                return withUnsafeBytes(of: o.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
        } else if let probe = x11Probe, let mon = X11Monitors.query(probe.dpy, root: probe.rootWindow).first(where: { ($0.x, $0.y, $0.width, $0.height) == g }) {
            return mon.name
        }
        return connector.isEmpty ? "monitor\(index)" : connector
    }

    // MARK: Switch

    /// `--switch-snapshot`: the previous host's frame for this page and the switch transition.
    private func seedSwitch(_ p: LinuxWebPage) {
        guard let dirPath = options.switchSnapshot, let device, let queue else { return }
        let dir = URL(fileURLWithPath: dirPath)
        let settings = options.switchTransition ?? TransitionSettings(mode: -1, timeMs: 0)
        let names = [p.outputName, "shared"] + ((try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []).filter { $0.hasSuffix(".bgra") }
            .map { String($0.dropLast(5)) }.sorted()
        guard let file = names.lazy.compactMap({ HostSnapshot.read(dir.appendingPathComponent(HostSnapshot.fileName($0))) }).first,
              let snap = Self.texture(file.bgra, width: file.width, height: file.height, size: p.pixelSize, device: device, queue: queue) else {
            print("switch: no frame from the previous host for \(p.outputName)")
            return
        }
        var transition: WallpaperTransition?
        if let effect = settings.pickEffect(), let assets = options.engineAssets {
            do {
                transition = try WallpaperTransition(device: device, engineAssets: assets, effect: effect, timeMs: settings.timeMs,
                                                     snapshot: snap, commandQueue: queue)
            } catch {
                // As the macOS app: no overlay when the effect cannot be made.
                print("switch: transition \(effect) failed: \(error)")
                return
            }
        }
        p.switchState = WebSwitch(transition: transition, snapshot: snap, begun: Date())
        // The held / frozen frame (or the overlay at progress 0) goes up at once, before the page has drawn.
        drawSwitch(p, now: Date())
        print("switch: \(p.outputName) \(transition.map { "effect \($0.effect), \(settings.timeMs) ms" } ?? (settings.mode == -2 ? "hold (no flicker)" : "frozen")) shown")
    }

    /// One overlay frame: the effect rendered offscreen over transparent black and read back (premultiplied), or the
    /// held frame; removed when the effect finishes or the hold ends.
    private func drawSwitch(_ p: LinuxWebPage, now: Date) {
        guard let sw = p.switchState else { return }
        let elapsed = now.timeIntervalSince(sw.begun)
        if let tr = sw.transition {
            if elapsed >= 0.5 { tr.start(at: elapsed) }
            if tr.isFinished(at: elapsed) {
                photon_web_view_set_overlay(web, p.view, nil, 0, 0)
                p.switchState = nil
                print("switch: \(p.outputName) finished")
                return
            }
            guard now.timeIntervalSince(sw.lastFrame) >= 1.0 / 60, let device, let queue, let cb = queue.makeCommandBuffer() else { return }
            sw.lastFrame = now
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: tr.width, height: tr.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            guard let target = device.makeTexture(descriptor: d) else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            tr.encode(over: target, commandBuffer: cb, time: elapsed)
            cb.commit()
            cb.waitUntilCompleted()
            let px = SceneHost.read(target)
            px.withUnsafeBytes { photon_web_view_set_overlay(web, p.view, $0.baseAddress, Int32(tr.width), Int32(tr.height)) }
        } else {
            if p.loaded || elapsed >= 3 {
                photon_web_view_set_overlay(web, p.view, nil, 0, 0)
                p.switchState = nil
                print("switch: \(p.outputName) finished")
                return
            }
            if sw.lastFrame == .distantPast {
                sw.lastFrame = now
                let px = SceneHost.read(sw.snapshot)
                px.withUnsafeBytes { photon_web_view_set_overlay(web, p.view, $0.baseAddress, Int32(sw.snapshot.width), Int32(sw.snapshot.height)) }
            }
        }
    }

    static func texture(_ bgra: [UInt8], width: Int, height: Int, size: (Int, Int), device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)
        }
        guard size.0 > 0, size.1 > 0, let t = make(width, height) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bgra, bytesPerRow: width * 4)
        if (width, height) == size { return t }
        guard let s = make(size.0, size.1), let cb = queue.makeCommandBuffer() else { return nil }
        cb.gpuCommandBuffer.blit(t.gpuTexture, from: GPUBlitRect(width: width, height: height), to: s.gpuTexture,
                                 at: GPUBlitRect(width: size.0, height: size.1))
        cb.commit()
        cb.waitUntilCompleted()
        return s
    }

    /// `snapshot DIR`: every page's visible frame, written asynchronously; answered when all are written or after 3 s.
    private func startSnapshot(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var views = Set<Int32>()
        for p in pages {
            photon_web_view_snapshot(web, p.view, URL(fileURLWithPath: dir).appendingPathComponent(HostSnapshot.fileName(p.outputName)).path)
            views.insert(p.view)
        }
        snapshotPending = (dir, views, Date().addingTimeInterval(3))
    }

    private func finishSnapshotIfDone() {
        guard let s = snapshotPending, s.views.isEmpty || Date() >= s.deadline else { return }
        snapshotPending = nil
        handedOver = true
        for p in pages {
            if p.loaded { run(p, WebPageScripts.setPaused(true)) }
            photon_web_view_set_muted(web, p.view, 1)
        }
        print("snapshot: written \(s.dir) (\(pages.count - s.views.count) frame(s))")
    }

    private func evaluate() {
        guard !handedOver else { return }
        let mons = monitors()
        let pr = probe(mons)
        let m = pr.masks
        let inputs = x11Probe?.systemInputs() ?? DesktopSystemInputs.fromBus()
        let wasMuted = rules.muted
        let app = LinuxProcesses.appInputs(settings: rules.settings, rules: options.appRules)
        for line in rules.tick(masks: m, inputs: inputs, monitorCount: mons.count, windows: pr.windows, app: app) { print("playback: \(line)") }
        if rules.muted != wasMuted { print("playback: \(rules.muted ? "mute" : "unmute")") }
        if rules.energy.webFPS != webFPS {
            webFPS = rules.energy.webFPS
            for p in pages where p.loaded { run(p, WebPageScripts.setFrameRate(webFPS)) }
        }
        if rules.stopped != stopped {
            stopped = rules.stopped
            print("playback: \(stopped ? "stop" : "resume from stop")")
            // Stop frees every web view; they reload when the rule ends (docs/re/09 §1.6).
            if stopped {
                for p in pages { photon_web_view_destroy(web, p.view) }
                pages.removeAll()
            } else {
                buildPages()
            }
        }
        guard !stopped else { return }
        let mute = rules.muted || appMuted || volumePercent <= 0
        for p in pages {
            let paused = rules.outputPaused(p.monitor) || appPaused
            if paused != p.paused {
                p.paused = paused
                print("playback: monitor \(p.monitor) \(paused ? "paused" : "resumed")")
                if p.loaded { run(p, WebPageScripts.setPaused(paused)) }
            }
            if mute != p.muted {
                p.muted = mute
                photon_web_view_set_muted(web, p.view, mute ? 1 : 0)
            }
        }
    }

    // MARK: Loop

    func run() {
        buildPages()
        let start = Date()
        var lastEvaluation = Date.distantPast
        var audioAllowed: Bool { supportsAudio && ((general["audioprocessing"] as? Bool) ?? true) }
        var quit = false
        while true {
            _ = photon_web_iterate(5)
            let now = Date()
            if let s = options.seconds, now.timeIntervalSince(start) >= s { break }
            for c in control?.poll() ?? [] {
                switch c {
                case .pause(let p): appPaused = p; lastEvaluation = .distantPast
                case .mute(let m): appMuted = m; lastEvaluation = .distantPast
                case .volume(let v): volumePercent = v; lastEvaluation = .distantPast
                case .general(let g): general = g
                case .rate: break // pages run at their own speed
                case .load: print("switch: a web host does not load other wallpapers (the app starts a new host)")
                case .snapshot(let dir): startSnapshot(dir)
                case .quit: quit = true
                }
            }
            if quit { break }
            finishSnapshotIfDone()
            for p in pages where p.switchState != nil { drawSwitch(p, now: now) }
            if !readyAnnounced, !pages.isEmpty, pages.allSatisfy({ $0.loaded || $0.switchState != nil }) {
                readyAnnounced = true
                print("host: ready")
            }
            if monitorsChanged {
                monitorsChanged = false
                print("web: monitors changed")
                if !stopped { buildPages() }
            }
            if now.timeIntervalSince(lastEvaluation) >= options.windowUpdateRate {
                lastEvaluation = now
                evaluate()
            }
            // Colour filter and flip (applied when changed, like WallpaperRenderer every frame).
            let (filter, flip) = WebPageScripts.generalStyle(general)
            for p in pages where p.loaded {
                if filter != p.appliedFilter { p.appliedFilter = filter; run(p, filter) }
                if flip != p.appliedFlip { p.appliedFlip = flip; run(p, WebPageScripts.flipScript(flip)) }
            }
            // CEFWallpaper audio thread (0x14011af50): the analyzer's raw 128 floats every 33 ms, once the page
            // registered a listener and the project allows audio processing.
            if audioAllowed, pages.contains(where: { $0.audioRequested }) {
                if !AudioSystem.shared.isRunning, SceneRenderer.audioCaptureEnabled { AudioSystem.shared.start() }
                for p in pages where p.audioRequested && p.loaded && !p.paused && now.timeIntervalSince(p.lastAudio) >= 0.033 {
                    p.lastAudio = now
                    if let js = WebPageScripts.audio(AudioSystem.shared.latestSpectrum()) { run(p, js) }
                }
            }
            if let media {
                for (kind, payload) in media.drain() {
                    for p in pages where p.mediaRegistered && p.loaded { run(p, WebPageScripts.media(kind, payload)) }
                }
            }
        }
        // Test output: the page text and the requested expressions, per page.
        var queries: [(LinuxWebPage, String, Int)] = []
        for p in pages {
            if options.dumpText { queries.append((p, "document.body ? document.body.innerText : ''", queries.count + 1)) }
            for e in options.evals { queries.append((p, e, queries.count + 1)) }
        }
        for (p, js, tag) in queries { photon_web_view_query(web, p.view, js, Int32(tag)) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, queries.contains(where: { results[Int($0.0.view) | ($0.2 << 16)] == nil }) { _ = photon_web_iterate(10) }
        for (p, js, tag) in queries {
            let r = results[Int(p.view) | (tag << 16)] ?? "(no result)"
            print("web: view \(p.view) \(js == "document.body ? document.body.innerText : ''" ? "text" : js) =\n\(r)")
        }
        AudioSystem.shared.stop()
        for p in pages { photon_web_view_destroy(web, p.view) }
        pages.removeAll()
        _ = photon_web_iterate(0)
    }
}

enum WebDesktopCommand {
    /// `photon-linux desktop <web wallpaper> [options]` (DesktopCommand hands web projects here).
    static func main(dir: URL, engineAssets: URL, args: [String]) -> Int32 {
        var o = WebDesktopHost.Options()
        var rest = args
        if let g = ProcessInfo.processInfo.environment["PHOTON_GENERAL"].flatMap({ $0.data(using: .utf8) }),
           let v = (try? JSONSerialization.jsonObject(with: g)) as? [String: Any] { o.general = v }
        while !rest.isEmpty {
            let a = rest.removeFirst()
            func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
            switch a {
            case "--seconds": o.seconds = value().flatMap(Double.init)
            case "--volume": o.volumePercent = value().flatMap(Float.init) ?? o.volumePercent
            case "--mute": o.volumePercent = 0
            case "--fps": o.fps = value().flatMap(Int.init) ?? o.fps
            case "--general":
                if let d = value()?.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { o.general = v }
            case "--property":
                if let kv = value(), let eq = kv.firstIndex(of: "=") {
                    let k = String(kv[..<eq]), v = String(kv[kv.index(after: eq)...])
                    o.overrides[k] = Double(v).map { $0 as Any } ?? (v == "true" || v == "false" ? (v == "true") as Any : v as Any)
                }
            case "--properties":
                if let d = value()?.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    o.overrides.merge(v) { _, b in b }
                }
            case "--output": o.outputs = value()?.split(separator: ",").map(String.init)
            case "--region": if let (n, r) = X11DesktopHost.Options.region(value()) { o.regions[n] = r }
            case "--control": o.control = true
            case "--switch-snapshot": o.switchSnapshot = value()
            case "--app-rules":
                if let d = value()?.data(using: .utf8), let r = try? JSONDecoder().decode([AppRule].self, from: d) { o.appRules = r }
            case "--transition":
                if let d = value()?.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) { o.switchTransition = TransitionSettings.parse(v) }
            case "--audio": o.settings.audio = value().map(PlaybackAction.init(engineString:)) ?? o.settings.audio
            case "--window-update-rate":
                if let ms = value().flatMap(Double.init) { o.windowUpdateRate = min(max(ms, 50), 5000) / 1000 }
            case "--dump-text": o.dumpText = true
            case "--eval": if let e = value() { o.evals.append(e) }
            case "--fullscreen": o.settings.fullscreen = value().map(PlaybackAction.init(engineString:)) ?? o.settings.fullscreen
            case "--maximized": o.settings.maximized = value().map(PlaybackAction.init(engineString:)) ?? o.settings.maximized
            case "--focus": o.settings.focus = value().map(PlaybackAction.init(engineString:)) ?? o.settings.focus
            case "--battery": o.settings.battery = value().map(PlaybackAction.init(engineString:)) ?? o.settings.battery
            case "--battery-fps", "--low-power", "--cap-web": EnergyOptions.parse(a, value(), into: &o.energy)
            case "--sleep": o.settings.sleep = value().map(PlaybackAction.init(engineString:)) ?? o.settings.sleep
            case "--backend":
                // GTK picks its backend from GDK_BACKEND.
                if let b = value(), b != "auto" { setenv("GDK_BACKEND", b, 1) }
            default: break // scene-only options (--still, --present, …) do not apply to web pages
            }
        }
        o.engineAssets = engineAssets
        do {
            let host = try WebDesktopHost(directory: dir, project: SceneRenderer.readProject(dir), engineInstall: engineAssets.deletingLastPathComponent(),
                                          options: o)
            host.run()
            return 0
        } catch {
            print("desktop: \(error)")
            return 1
        }
    }
}
#endif
