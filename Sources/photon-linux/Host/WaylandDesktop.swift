#if os(Linux)
import CPhotonSystem
import CPhotonWayland
import CX11
import Foundation
import PhotonCore
import PhotonGPU
import PhotonProto
import PhotonRender
import PhotonVulkan

// Wayland desktop host (docs/linux-port.md §5.2). Compositors do not let clients place windows below others, so each
// output gets a wlr-layer-shell surface on the `background` layer (CPhotonWayland), and frames reach it through a Vulkan
// swapchain on the wl_surface (VK_KHR_wayland_surface) or, as the fallback, read back into wl_shm buffers. Outputs are
// followed across hotplug, buffers are sized for the output's fractional (wp_fractional_scale_v1 + wp_viewporter) or
// integer scale, and the playback rules get their window masks from wlr-foreign-toplevel-management (wlroots) or
// org_kde_plasma_window_management (KWin). On GNOME, which has no layer-shell, each output gets a plain xdg_toplevel that
// the photon2 GNOME Shell extension (packaging/gnome-shell) shows inside the monitor's background actors; the extension
// also reports Mutter's window states over D-Bus for the rules. The scene loop (clock, pause and mute fades, sound) is
// the X11 host's.

enum WaylandHostError: Error, CustomStringConvertible {
    case connect(String)
    case noLayerShell(String)
    case noExtension(String)
    var description: String {
        switch self {
        case .connect(let s): return s
        case .noLayerShell(let s): return s
        case .noExtension(let s): return s
        }
    }
}

/// The GNOME host's names: the background windows' app_id, and their title prefix followed by the output's connector
/// (the extension finds the monitor with `get_monitor_for_connector`).
enum GnomeShellHost {
    static let appID = "io.github.photon2.Photon.Background"
    static let titlePrefix = "photon2 background "
    static let extensionUUID = "photon2@photon2.github.io"

    /// GNOME Shell is the session (XDG_CURRENT_DESKTOP lists GNOME; Ubuntu's "ubuntu:GNOME" included).
    static var isSession: Bool {
        (ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? "").uppercased().split(separator: ":").contains("GNOME")
    }
}

/// One output's background surface.
final class WaylandOutput: HostSurface {
    let global: UInt32
    var info: photon_wl_output
    let surface: OpaquePointer
    var swapchain: VulkanSwapchain?
    /// Readback + wl_shm (no WSI, `--present readback`, or the swapchain failed).
    var shm = false
    var paused = false
    var drawn = false
    var changes: UInt32 = 0
    var state = photon_wl_surface_state()
    /// A split region of the output (`--region`): the surface covers this rectangle (logical, from the output's origin).
    var region: CGRect?
    var name: String { withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
    var bufferSize: (Int, Int) { (Int(state.buffer_width), Int(state.buffer_height)) }

    init(info: photon_wl_output, surface: OpaquePointer) {
        self.global = info.global
        self.info = info
        self.surface = surface
    }

    deinit {
        swapchain = nil // before its wl_surface goes
        photon_wl_surface_destroy(surface)
    }

    var pixelSize: (Int, Int) { bufferSize }
    /// xdg_output logical position and the configured logical size (a region: its rectangle on the output).
    var logical: CGRect {
        let w = state.width > 0 ? Int(state.width) : Int(info.width), h = state.height > 0 ? Int(state.height) : Int(info.height)
        if let r = region { return CGRect(x: Int(info.x) + Int(r.minX), y: Int(info.y) + Int(r.minY), width: w, height: h) }
        return CGRect(x: Int(info.x), y: Int(info.y), width: w, height: h)
    }
    /// The whole output (the rules' monitor: a region pauses with its output).
    var outputLogical: CGRect {
        guard region != nil else { return logical }
        return CGRect(x: Int(info.x), y: Int(info.y), width: Int(info.width), height: Int(info.height))
    }
    var ready: Bool { state.configured != 0 && state.closed == 0 && state.buffer_width > 0 && state.buffer_height > 0 }
    func willPresent() { photon_wl_surface_prepare(surface) }
    func show(bgra: [UInt8], width: Int, height: Int) {
        _ = bgra.withUnsafeBytes { photon_wl_surface_present_shm(surface, $0.baseAddress, Int32(width), Int32(height)) }
    }
}

final class WaylandDesktopHost {
    typealias Options = X11DesktopHost.Options

    let wl: OpaquePointer
    let options: Options
    let host: SceneHost
    var source: DesktopFrameSource { host.source }
    private(set) var outputs: [WaylandOutput] = []
    private var outputsSerial: UInt32 = .max
    private var lastEvaluation = Date.distantPast
    let hasToplevels: Bool
    let hasPlasma: Bool
    /// GNOME: xdg_toplevel background windows shown by the Shell extension, rule inputs from its D-Bus state.
    let gnome: Bool
    private var gnomeState: [String: Any] = [:]
    private var gnomeSerial: UInt32 = .max
    private var gnomePresses: UInt32 = 0

    /// Connects and checks for layer-shell (without it there is no background layer: GNOME's Mutter). `gnome`: the
    /// GNOME host instead, which needs xdg_wm_base and the photon2 Shell extension on the session bus.
    init(host: SceneHost, options: Options, gnome: Bool = false) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let c = photon_wl_connect(nil, &err, err.count) else { throw WaylandHostError.connect(String(cString: err)) }
        if gnome {
            guard photon_wl_has(c, "xdg_wm_base") != 0 else {
                photon_wl_disconnect(c)
                throw WaylandHostError.connect("the compositor has no xdg_wm_base")
            }
            // Without the extension the windows would sit on the desktop as ordinary windows.
            photon_gnome_shell_watch_start()
            guard photon_gnome_shell_ping(3000) != 0 else {
                photon_wl_disconnect(c)
                throw WaylandHostError.noExtension("the photon2 GNOME Shell extension (\(GnomeShellHost.extensionUUID)) is not running: "
                                                   + "install and enable it (docs/linux-port.md §5.2)")
            }
        } else {
            guard photon_wl_has(c, "zwlr_layer_shell_v1") != 0 else {
                photon_wl_disconnect(c)
                throw WaylandHostError.noLayerShell("the compositor has no zwlr_layer_shell_v1 (GNOME/Mutter has none: see docs/linux-port.md §5.2)")
            }
        }
        wl = c
        self.gnome = gnome
        self.options = options
        self.host = host
        hasToplevels = photon_wl_has(c, "zwlr_foreign_toplevel_manager_v1") != 0
        hasPlasma = photon_wl_has(c, "org_kde_plasma_window_management") != 0
        let have = ["wp_viewporter", "wp_fractional_scale_manager_v1", "zxdg_output_manager_v1", "zwlr_foreign_toplevel_manager_v1",
                    "org_kde_plasma_window_management", "org_kde_plasma_virtual_desktop_management", "wl_seat"]
            .map { "\($0) \(photon_wl_has(c, $0) != 0 ? "yes" : "no")" }.joined(separator: ", ")
        if gnome {
            print("wayland: GNOME Shell extension yes (background windows), \(have)")
        } else {
            print("wayland: layer-shell yes, \(have)")
            if hasToplevels {
                print("wayland: window rules from wlr-foreign-toplevel-management")
            } else if hasPlasma {
                print("wayland: window rules from org_kde_plasma_window_management")
            } else if (ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? "").uppercased().contains("KDE") {
                print("wayland: KWin did not grant org_kde_plasma_window_management (photon-linux needs a .desktop entry with "
                      + "X-KDE-Wayland-Interfaces=org_kde_plasma_window_management, as the packages' photon2-kwin.desktop has, with the absolute path of this executable): the focus, "
                      + "maximized and fullscreen rules have no input")
            } else {
                print("wayland: no wlr-foreign-toplevel-management: the focus, maximized and fullscreen rules have no input")
            }
        }
        photon_system_watch_start()
        host.flush = { [c] in _ = photon_wl_dispatch(c, 0) }
    }

    deinit {
        host.dropSurfaces()
        outputs.removeAll()
        photon_wl_disconnect(wl)
    }

    private var device: VulkanDevice? {
        options.readback ? nil : source.vulkanDevice.flatMap { $0.supportsWaylandPresentation ? $0 : nil }
    }

    /// Output hotplug: a surface for every output that appeared, none for those that went (the compositor also closes a
    /// gone output's layer surfaces).
    private func syncOutputs() {
        let serial = photon_wl_outputs_serial(wl)
        guard serial != outputsSerial else { return }
        outputsSerial = serial
        var current: [photon_wl_output] = []
        for i in 0..<photon_wl_output_count(wl) {
            var o = photon_wl_output()
            if photon_wl_output_get(wl, i, &o) != 0, o.done != 0 { current.append(o) }
        }
        // `--output`: only the named outputs (indices are the compositor's advertisement order).
        current = current.enumerated().filter { i, o in
            let name = withUnsafeBytes(of: o.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return OutputFilter.matches(options.outputs, name: name, index: i)
        }.map(\.element)
        let ids = Set(current.map(\.global))
        for o in outputs where !ids.contains(o.global) { print("output \(o.name) removed") }
        outputs.removeAll { !ids.contains($0.global) }
        for (i, info) in current.enumerated() {
            if let o = outputs.first(where: { $0.global == info.global }) { o.info = info; continue }
            let name = withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let region = options.regions[name]
            let s: OpaquePointer?
            if let r = region {
                // A split region: a layer surface anchored top-left with the region's size and offset; on GNOME a window of
                // the region's size whose title tells the extension where its clone goes.
                let (x, y, w, h) = (Int32(r.minX), Int32(r.minY), Int32(r.width), Int32(r.height))
                s = gnome ? photon_wl_toplevel_surface_create_region(wl, info.global, GnomeShellHost.appID,
                                                                    GnomeShellHost.titlePrefix + name + " \(x),\(y),\(w),\(h)", w, h)
                          : photon_wl_surface_create_region(wl, info.global, "photon2", x, y, w, h)
            } else {
                s = gnome ? photon_wl_toplevel_surface_create(wl, info.global, GnomeShellHost.appID, GnomeShellHost.titlePrefix + name)
                          : photon_wl_surface_create(wl, info.global, "photon2")
            }
            guard let s else { continue }
            let o = WaylandOutput(info: info, surface: s)
            o.region = region
            outputs.insert(o, at: min(i, outputs.count))
            print("output \(o.name) \(info.width)x\(info.height)+\(info.x)+\(info.y) (integer scale \(info.scale)) added"
                  + (region.map { " (region \(Int($0.width))x\(Int($0.height))+\(Int($0.minX))+\(Int($0.minY)))" } ?? ""))
        }
        // Monitor order for the rules = the compositor's advertisement order.
        outputs.sort { a, b in (current.firstIndex { $0.global == a.global } ?? 0) < (current.firstIndex { $0.global == b.global } ?? 0) }
    }

    /// Applies configure and scale changes: the swapchain (created on the first configure) follows the buffer size.
    private func updateSurfaces() {
        for o in outputs {
            photon_wl_surface_get_state(o.surface, &o.state)
            if o.state.closed != 0 { continue }
            guard o.state.configured != 0, o.state.changes != o.changes else { continue }
            o.changes = o.state.changes
            let (w, h) = o.bufferSize
            guard w > 0, h > 0 else { continue }
            let scale = Double(o.state.scale120) / 120
            if let sc = o.swapchain {
                sc.resize(width: w, height: h)
            } else if !o.shm {
                if let device {
                    do {
                        photon_wl_surface_prepare(o.surface)
                        o.swapchain = try VulkanSwapchain(device: device, waylandDisplay: photon_wl_display(wl)!,
                                                          surface: photon_wl_surface_handle(o.surface)!, width: w, height: h,
                                                          vsync: options.vsync && options.waylandFIFO)
                    } catch {
                        print("output \(o.name): no swapchain (\(error)), using readback")
                    }
                }
                o.shm = o.swapchain == nil
            }
            let how = (o.swapchain.map { "Vulkan swapchain, \($0.presentModeName)" } ?? "readback, wl_shm") + (gnome ? ", GNOME background window" : "")
            print("output \(o.name): configured \(o.state.width)x\(o.state.height) logical, scale \(String(format: "%g", scale)), buffer \(w)x\(h) (\(how))")
            o.drawn = false
        }
        outputs.removeAll { o in
            if o.state.closed != 0 { print("output \(o.name): layer surface closed"); return true }
            return false
        }
    }

    func toplevels() -> [WaylandToplevel] {
        var out: [WaylandToplevel] = []
        for i in 0..<photon_wl_toplevel_count(wl) {
            var t = photon_wl_toplevel()
            guard photon_wl_toplevel_get(wl, i, &t) != 0 else { continue }
            let outs = withUnsafeBytes(of: t.outputs) { Array($0.bindMemory(to: UInt32.self).prefix(Int(t.n_outputs))) }
            let app = withUnsafeBytes(of: t.app_id) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            out.append(WaylandToplevel(activated: t.activated != 0, maximized: t.maximized != 0, minimized: t.minimized != 0,
                                       fullscreen: t.fullscreen != 0, outputs: outs, appID: app))
        }
        return out
    }

    /// KWin's windows (org_kde_plasma_window_management).
    func plasmaWindows() -> [PlasmaWindow] {
        var out: [PlasmaWindow] = []
        for i in 0..<photon_wl_plasma_window_count(wl) {
            var w = photon_wl_plasma_window()
            guard photon_wl_plasma_window_get(wl, i, &w) != 0 else { continue }
            let app = withUnsafeBytes(of: w.app_id) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            out.append(PlasmaWindow(id: w.id, state: w.state, x: Int(w.x), y: Int(w.y), width: Int(w.width), height: Int(w.height),
                                    pid: Int32(bitPattern: w.pid), appID: app, onCurrentDesktop: w.on_current_desktop != 0, ready: w.ready != 0))
        }
        return out
    }

    /// The host's outputs as monitors in global logical coordinates (rule bit i = outputs[i]).
    private var monitors: [DesktopMonitor] {
        outputs.map { o in
            let l = o.outputLogical
            return DesktopMonitor(name: o.name, x: Int(l.minX), y: Int(l.minY), width: Int(l.width), height: Int(l.height))
        }
    }

    /// The extension's last state (JSON from GetState / StateChanged), parsed when it changed.
    private func gnomeWindows() -> [String: Any] {
        var serial: UInt32 = 0
        guard let raw = photon_gnome_shell_state_json(&serial) else { return gnomeState }
        defer { free(raw) }
        if serial != gnomeSerial {
            gnomeSerial = serial
            let text = String(cString: raw)
            gnomeState = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        return gnomeState
    }

    func evaluate() {
        let probe: DesktopProbe
        if gnome {
            let snap = DesktopPauseRules.gnomeSnapshot(gnomeWindows(), outputs: monitors) { LinuxProcesses.identity(pid: $0, appID: $1) }
            probe = DesktopPauseRules.probe(snap, monitors: monitors, rules: options.appRules)
        } else if !hasToplevels, hasPlasma {
            let snap = DesktopPauseRules.plasmaSnapshot(plasmaWindows(), showingDesktop: photon_wl_plasma_showing_desktop(wl) != 0) {
                LinuxProcesses.identity(pid: $0.pid, appID: $0.appID)
            }
            probe = DesktopPauseRules.probe(snap, monitors: monitors, rules: options.appRules)
        } else {
            probe = DesktopPauseRules.probe(toplevels: toplevels(), outputs: outputs.map(\.global), rules: options.appRules)
        }
        host.evaluate(outputs, probe: probe, inputs: DesktopSystemInputs.fromBus())
    }

    /// The cursor over the background surfaces: position in global logical coordinates (the output's xdg_output
    /// position plus the surface-local position) and the left button. Over a window the surfaces get no events, so the
    /// last position stays (macOS reads the global position; Wayland gives none).
    private func updatePointer() {
        if gnome {
            // The extension reports the global position and presses on the desktop (the background windows are hidden
            // and get no input of their own).
            var g = photon_gnome_shell_info()
            photon_gnome_shell_get(&g)
            if g.pointer_known != 0 { host.pointer = CGPoint(x: g.x, y: g.y) }
            if g.presses != gnomePresses { gnomePresses = g.presses; host.pointerDown = true } else if g.pressed == 0 { host.pointerDown = false }
            return
        }
        var p = photon_wl_pointer()
        photon_wl_pointer_get(wl, &p)
        if let f = p.focus, let o = outputs.first(where: { $0.surface == f }) {
            host.pointer = CGPoint(x: Double(o.logical.minX) + p.x, y: Double(o.logical.minY) + p.y) // a region: from its corner
        }
        host.pointerDown = p.left != 0
    }

    /// GNOME: the extension left the bus (disabled, or the shell restarted without it) for more than 2 s.
    private var extensionLostSince: Date?
    private func extensionGone(_ now: Date) -> Bool {
        guard gnome else { return false }
        var g = photon_gnome_shell_info()
        photon_gnome_shell_get(&g)
        if g.present != 0 { extensionLostSince = nil; return false }
        let since = extensionLostSince ?? now
        extensionLostSince = since
        return now.timeIntervalSince(since) > 2
    }

    func run() throws {
        let start = Date()
        var nextFrame = Date()
        while true {
            if photon_wl_dispatch(wl, 0) < 0 { print("wayland: connection lost"); break }
            if extensionGone(Date()) {
                // Without it the background windows would be ordinary (minimized) windows.
                print("gnome: the photon2 Shell extension left the session bus: stopping")
                break
            }
            syncOutputs()
            updateSurfaces()
            let now = Date()
            if let secs = options.seconds, now.timeIntervalSince(start) >= secs { break }
            let t = now.timeIntervalSince(start)
            host.handleControl(outputs, now: t)
            if host.quit { break }
            if now.timeIntervalSince(lastEvaluation) >= options.windowUpdateRate {
                lastEvaluation = now
                evaluate()
            }
            updatePointer()
            try host.frame(outputs, now: t)
            let interval = 1 / max(host.switching ? max(options.fps, 60) : options.fps, 1)
            nextFrame = max(nextFrame.addingTimeInterval(interval), Date())
            // Wait for the next frame while handling Wayland events (configure, hotplug, toplevel states, the pointer).
            while true {
                let wait = nextFrame.timeIntervalSinceNow
                if wait <= 0 { break }
                if photon_wl_dispatch(wl, Int32(min(wait * 1000, 50))) < 0 { break }
            }
        }
        source.vulkanDevice?.waitIdle()
        _ = photon_wl_roundtrip(wl)
        print("ran \(String(format: "%.1f", Date().timeIntervalSince(start)))s, \(host.frames) frame tick(s)")
        if let f = host.firstFrameEnd, host.frames > 1 {
            let t = Date().timeIntervalSince(f)
            print(String(format: "steady state: %d frames in %.2fs = %.2f fps", host.frames - 1, t, Double(host.frames - 1) / t))
        }
        // `--hold`: keep the last frames on screen (tests take their screenshot from outside).
        if let hold = options.hold {
            let until = Date().addingTimeInterval(hold)
            while Date() < until { if photon_wl_dispatch(wl, 50) < 0 { break } }
        }
        host.dropSurfaces()
        outputs.removeAll()
        _ = photon_wl_roundtrip(wl)
    }
}

/// `photon-linux desktop --list-outputs`: the outputs a host would cover, as JSON lines, for the app's display list
/// (Wayland: `xdg_output` names in advertisement order; X11: XRandR monitors, primary first).
enum OutputList {
    static func print(backend: String) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let wayland = backend == "wayland" || (backend == "auto" && env["WAYLAND_DISPLAY"].map { !$0.isEmpty } == true)
        var rows: [[String: Any]] = []
        if wayland {
            var err = [CChar](repeating: 0, count: 256)
            if let wl = photon_wl_connect(nil, &err, err.count) {
                _ = photon_wl_roundtrip(wl)
                _ = photon_wl_roundtrip(wl)
                for i in 0..<photon_wl_output_count(wl) {
                    var o = photon_wl_output()
                    guard photon_wl_output_get(wl, i, &o) != 0 else { continue }
                    let name = withUnsafeBytes(of: o.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    rows.append(["name": name.isEmpty ? "output\(i)" : name, "x": Int(o.x), "y": Int(o.y), "width": Int(o.width),
                                 "height": Int(o.height), "scale": Int(o.scale), "primary": i == 0, "backend": "wayland"])
                }
                photon_wl_disconnect(wl)
            } else if backend == "wayland" {
                Swift.print("{\"error\": \"\(String(cString: err))\"}")
                return 1
            }
        }
        if rows.isEmpty, let dpy = XOpenDisplay(nil) {
            for m in X11Monitors.query(dpy, root: XDefaultRootWindow(dpy)) {
                rows.append(["name": m.name, "x": m.x, "y": m.y, "width": m.width, "height": m.height, "scale": 1, "primary": m.primary,
                             "backend": "x11"])
            }
            XCloseDisplay(dpy)
        }
        for r in rows {
            if let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) { Swift.print(String(decoding: d, as: UTF8.self)) }
        }
        return rows.isEmpty ? 1 : 0
    }
}

/// Without layer-shell (GNOME's Mutter) a client cannot put a surface under the desktop. The fallback shows a still:
/// one frame rendered at the given size, written to `$XDG_CACHE_HOME/photon2/background.png` and set as GNOME's
/// background (`org.gnome.desktop.background picture-uri` and `picture-uri-dark`, `picture-options` zoom).
enum StaticBackground {
    static func apply(source: DesktopFrameSource, width: Int, height: Int, time: Double) throws -> URL {
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let dir = cache.appendingPathComponent("photon2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var px = try source.frame(time: time, width: width, height: height)
        ProtoFrameSource.swapRB(&px) // BGRA → RGBA
        let url = dir.appendingPathComponent("background.png")
        try PNGWriter.encode(rgba: px, width: width, height: height, keepAlpha: false).write(to: url)
        for (key, value) in [("picture-uri", url.absoluteString), ("picture-uri-dark", url.absoluteString), ("picture-options", "zoom")] {
            let status = spawn(["gsettings", "set", "org.gnome.desktop.background", key, value])
            if status != 0 { print("static background: gsettings set \(key) failed (\(status))") }
        }
        print("static background \(width)x\(height) → \(url.path) (org.gnome.desktop.background)")
        return url
    }

    /// posix_spawnp + waitpid (Foundation's Process.waitUntilExit did not return here once the child had exited).
    static func spawn(_ args: [String]) -> Int32 {
        var pid: pid_t = 0
        var argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawnp(&pid, args[0], nil, nil, &argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return (status >> 8) & 0xff
    }
}

extension DesktopSystemInputs {
    /// The D-Bus and sysfs inputs alone (Wayland has no DPMS or MIT-SCREEN-SAVER query; idle and lock come from logind and
    /// the screensaver services).
    static func fromBus() -> DesktopSystemInputs {
        var st = photon_system_state()
        photon_system_state_get(&st)
        var i = DesktopSystemInputs()
        i.onBattery = st.upower != 0 ? st.on_battery != 0 : DesktopPower.onBattery()
        i.locked = st.locked != 0
        i.preparingSleep = st.preparing_sleep != 0
        i.screensaver = st.screensaver != 0
        return i
    }
}
#endif
