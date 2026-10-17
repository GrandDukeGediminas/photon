#if os(Linux)
import CPhotonSystem
import CPhotonWayland
import CX11
import Foundation
import PhotonApp
import PhotonCore
import PhotonGPU
import PhotonProto
import PhotonRender
import PhotonVulkan

// X11 desktop host (docs/linux-port.md §5): one _NET_WM_WINDOW_TYPE_DESKTOP window per XRandR monitor (or the root
// window itself with --root), frames from a DesktopFrameSource presented through a Vulkan swapchain on the window
// (VK_KHR_xlib_surface) or, as the fallback (root mode, --present readback, no WSI), read back and put with XShmPutImage
// (XPutImage without MIT-SHM), and the playback rules evaluated every `windowupdaterate` (1 s) from an EWMH snapshot and
// the system inputs (UPower, logind, screensaver, DPMS; DesktopPauseRules.swift).

// Xlib macros Swift cannot import (casts in the #define).
private let XA_ATOM_: Atom = 4, XA_CARDINAL_: Atom = 6, XA_PIXMAP_: Atom = 20, XA_WINDOW_: Atom = 33
private let AllPlanes_: UInt = ~0

/// Interned atoms the host reads and writes.
final class X11Atoms {
    private let dpy: OpaquePointer
    private var cache: [String: Atom] = [:]
    init(_ dpy: OpaquePointer) { self.dpy = dpy }
    subscript(_ name: String) -> Atom {
        if let a = cache[name] { return a }
        let a = XInternAtom(dpy, name, 0)
        cache[name] = a
        return a
    }
}

/// Reads window properties as arrays of 32-bit-format items (`unsigned long` in Xlib's client representation).
enum X11Props {
    static func longs(_ dpy: OpaquePointer, _ w: Window, _ prop: Atom, type: Atom) -> [UInt]? {
        var actualType: Atom = 0, actualFormat: Int32 = 0, n: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        let r = XGetWindowProperty(dpy, w, prop, 0, 4096, 0, type, &actualType, &actualFormat, &n, &after, &data)
        defer { if let data { XFree(data) } }
        guard r == 0 /* Success */, let data, actualFormat == 32, actualType == type else { return nil }
        return data.withMemoryRebound(to: UInt.self, capacity: Int(n)) { Array(UnsafeBufferPointer(start: $0, count: Int(n))) }
    }

    static func setLongs(_ dpy: OpaquePointer, _ w: Window, _ prop: Atom, type: Atom, _ values: [UInt]) {
        var v = values
        v.withUnsafeMutableBytes { p in
            _ = XChangeProperty(dpy, w, prop, type, 32, 0 /* PropModeReplace */, p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                Int32(values.count))
        }
    }
}

/// XRandR monitors (RandR 1.5 `XRRGetMonitors`), else the whole root window.
enum X11Monitors {
    static func query(_ dpy: OpaquePointer, root: Window) -> [DesktopMonitor] {
        // `PHOTON_X11_MONITORS=NAME=WxH+X+Y,…`: named monitors instead of XRandR's, for the app and every host it starts
        // (tests on Xvfb, whose RandR has one monitor and no `--setmonitor`).
        if let spec = ProcessInfo.processInfo.environment["PHOTON_X11_MONITORS"], !spec.isEmpty {
            return spec.split(separator: ",").enumerated().compactMap { i, e in
                let parts = e.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let g = parts[1].split(whereSeparator: { "x+".contains($0) }).compactMap { Int($0) }
                return g.count == 4 ? DesktopMonitor(name: String(parts[0]), x: g[2], y: g[3], width: g[0], height: g[1], primary: i == 0) : nil
            }
        }
        var n: Int32 = 0
        var result: [DesktopMonitor] = []
        if let mons = XRRGetMonitors(dpy, root, 1, &n), n > 0 {
            for i in 0..<Int(n) {
                let m = mons[i]
                var name = "monitor\(i)"
                if m.name != 0, let c = XGetAtomName(dpy, m.name) { name = String(cString: c); XFree(c) }
                result.append(DesktopMonitor(name: name, x: Int(m.x), y: Int(m.y), width: Int(m.width), height: Int(m.height),
                                             primary: m.primary != 0))
            }
            XRRFreeMonitors(mons)
        }
        if result.isEmpty {
            let s = XDefaultScreen(dpy)
            result = [DesktopMonitor(name: "root", x: 0, y: 0, width: Int(XDisplayWidth(dpy, s)), height: Int(XDisplayHeight(dpy, s)),
                                     primary: true)]
        }
        // The engine indexes displays primary first (EnumDisplayMonitors order); keep RandR order otherwise.
        return result.enumerated().sorted { ($0.element.primary ? 0 : 1, $0.offset) < ($1.element.primary ? 0 : 1, $1.offset) }.map(\.element)
    }
}

/// A BGRA8 image the host can put on a drawable: XShm segment when the server has MIT-SHM, else a client-side buffer.
final class X11Image {
    let dpy: OpaquePointer
    let width: Int, height: Int
    let image: UnsafeMutablePointer<XImage>
    /// XShmCreateImage keeps a pointer to the segment info in the image (`obdata`), so it lives on the heap with it.
    private var shm: UnsafeMutablePointer<XShmSegmentInfo>?
    private var heap: UnsafeMutableRawPointer?

    init?(dpy: OpaquePointer, width: Int, height: Int, useShm: Bool) {
        self.dpy = dpy
        self.width = width
        self.height = height
        let s = XDefaultScreen(dpy)
        let visual = XDefaultVisual(dpy, s), depth = UInt32(XDefaultDepth(dpy, s))
        if useShm {
            let info = UnsafeMutablePointer<XShmSegmentInfo>.allocate(capacity: 1)
            info.initialize(to: XShmSegmentInfo())
            if let img = XShmCreateImage(dpy, visual, depth, 2 /* ZPixmap */, nil, info, UInt32(width), UInt32(height)) {
                let size = Int(img.pointee.bytes_per_line) * Int(img.pointee.height)
                info.pointee.shmid = shmget(0 /* IPC_PRIVATE */, size, 0o1000 /* IPC_CREAT */ | 0o600)
                if info.pointee.shmid >= 0, let addr = shmat(info.pointee.shmid, nil, 0), addr != UnsafeMutableRawPointer(bitPattern: -1) {
                    info.pointee.shmaddr = addr.assumingMemoryBound(to: CChar.self)
                    img.pointee.data = info.pointee.shmaddr
                    info.pointee.readOnly = 0
                    if XShmAttach(dpy, info) != 0 {
                        XSync(dpy, 0)
                        shmctl(info.pointee.shmid, 0 /* IPC_RMID */, nil) // freed once both sides detach
                        shm = info
                        image = img
                        if ProcessInfo.processInfo.environment["PHOTON_X11_DEBUG"] != nil {
                            let ob = img.pointee.obdata.map { UInt(bitPattern: $0) } ?? 0
                            print(String(format: "shm: seg 0x%lx shmid %d obdata 0x%lx info 0x%lx", info.pointee.shmseg, info.pointee.shmid, ob,
                                         UInt(bitPattern: info)))
                        }
                        return
                    }
                    shmdt(addr)
                }
                if info.pointee.shmid >= 0 { shmctl(info.pointee.shmid, 0, nil) }
                img.pointee.data = nil
                _ = img.pointee.f.destroy_image(img)
            }
            info.deallocate()
        }
        let bytes = width * height * 4
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        heap = buf
        guard let img = XCreateImage(dpy, visual, depth, 2, 0, buf.assumingMemoryBound(to: CChar.self), UInt32(width), UInt32(height), 32,
                                     Int32(width * 4)) else { buf.deallocate(); return nil }
        image = img
    }

    var usesShm: Bool { shm != nil }

    deinit {
        if let info = shm {
            XShmDetach(dpy, info)
            XSync(dpy, 0)
            shmdt(info.pointee.shmaddr)
        }
        image.pointee.data = nil // not owned by Xlib
        _ = image.pointee.f.destroy_image(image)
        shm?.deallocate()
        heap?.deallocate()
    }

    /// Copies BGRA rows (top-down, tightly packed) into the image.
    func fill(_ bgra: [UInt8]) {
        let pitch = Int(image.pointee.bytes_per_line)
        guard let dst = UnsafeMutableRawPointer(image.pointee.data), bgra.count >= width * height * 4 else { return }
        bgra.withUnsafeBytes { src in
            if pitch == width * 4 { dst.copyMemory(from: src.baseAddress!, byteCount: width * height * 4); return }
            for y in 0..<height { (dst + y * pitch).copyMemory(from: src.baseAddress! + y * width * 4, byteCount: width * 4) }
        }
    }

    func put(on drawable: Drawable, gc: GC, x: Int, y: Int) {
        if usesShm {
            XShmPutImage(dpy, drawable, gc, image, 0, 0, Int32(x), Int32(y), UInt32(width), UInt32(height), 0)
        } else {
            XPutImage(dpy, drawable, gc, image, 0, 0, Int32(x), Int32(y), UInt32(width), UInt32(height))
        }
    }
}

/// One output: a desktop-type window over a monitor, or a monitor-sized region of the root window (--root).
final class X11Output: HostSurface {
    let monitor: DesktopMonitor
    let window: Window      // the drawable (the root window in root mode)
    let root: Bool
    /// Exactly one of the two: the swapchain on the window, or the readback image.
    var swapchain: VulkanSwapchain?
    let image: X11Image?
    var paused = false
    var drawn = false
    var lastFrame: [UInt8]?
    let gc: GC

    init(monitor: DesktopMonitor, window: Window, root: Bool, swapchain: VulkanSwapchain?, image: X11Image?, gc: GC) {
        self.monitor = monitor
        self.window = window
        self.root = root
        self.swapchain = swapchain
        self.image = image
        self.gc = gc
    }

    var name: String { monitor.name }
    var pixelSize: (Int, Int) { (monitor.width, monitor.height) }
    var logical: CGRect { CGRect(x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height) }
    var ready: Bool { true }
    func willPresent() {}

    func show(bgra: [UInt8], width: Int, height: Int) {
        guard let image else { return }
        image.fill(bgra)
        lastFrame = bgra
        put()
    }

    func put() { image?.put(on: window, gc: gc, x: root ? monitor.x : 0, y: root ? monitor.y : 0) }
}

final class X11Probe {
    let dpy: OpaquePointer
    let rootWindow: Window
    let atoms: X11Atoms

    init(dpy: OpaquePointer, root: Window, atoms: X11Atoms) {
        self.dpy = dpy
        self.rootWindow = root
        self.atoms = atoms
    }

    /// EWMH snapshot: _NET_CLIENT_LIST (or the root's mapped children when no WM publishes one), each client's
    /// _NET_WM_STATE, _NET_WM_WINDOW_TYPE and root-relative geometry, and _NET_ACTIVE_WINDOW. `apps`: each client's
    /// process (`_NET_WM_PID` → /proc) and `WM_CLASS`, for the application rules.
    func snapshot(own: Set<Window>, apps: Bool = false) -> DesktopSnapshot {
        var s = DesktopSnapshot()
        var ids = X11Props.longs(dpy, rootWindow, atoms["_NET_CLIENT_LIST"], type: XA_WINDOW_)
        if ids == nil {
            var rootRet: Window = 0, parent: Window = 0, kids: UnsafeMutablePointer<Window>?, n: UInt32 = 0
            if XQueryTree(dpy, rootWindow, &rootRet, &parent, &kids, &n) != 0, let kids {
                ids = Array(UnsafeBufferPointer(start: kids, count: Int(n)))
                XFree(kids)
            }
        }
        if let active = X11Props.longs(dpy, rootWindow, atoms["_NET_ACTIVE_WINDOW"], type: XA_WINDOW_)?.first, active != 0 {
            s.active = active
        }
        let fs = atoms["_NET_WM_STATE_FULLSCREEN"], mv = atoms["_NET_WM_STATE_MAXIMIZED_VERT"], mh = atoms["_NET_WM_STATE_MAXIMIZED_HORZ"]
        let hidden = atoms["_NET_WM_STATE_HIDDEN"]
        let deskTypes: Set<UInt> = [atoms["_NET_WM_WINDOW_TYPE_DESKTOP"], atoms["_NET_WM_WINDOW_TYPE_DOCK"]]
        for id in ids ?? [] {
            var wa = XWindowAttributes()
            guard XGetWindowAttributes(dpy, id, &wa) != 0, wa.`class` == InputOutput else { continue }
            var rx: Int32 = 0, ry: Int32 = 0, child: Window = 0
            XTranslateCoordinates(dpy, id, rootWindow, 0, 0, &rx, &ry, &child)
            let states = Set(X11Props.longs(dpy, id, atoms["_NET_WM_STATE"], type: XA_ATOM_) ?? [])
            let types = Set(X11Props.longs(dpy, id, atoms["_NET_WM_WINDOW_TYPE"], type: XA_ATOM_) ?? [])
            var app: AppIdentity?
            if apps, let pid = X11Props.longs(dpy, id, atoms["_NET_WM_PID"], type: XA_CARDINAL_)?.first, pid > 0 {
                app = LinuxProcesses.identity(pid: Int32(truncatingIfNeeded: pid), windowClass: windowClass(id))
            }
            s.clients.append(DesktopClient(id: id, x: Int(rx), y: Int(ry), width: Int(wa.width), height: Int(wa.height),
                                           mapped: wa.map_state == IsViewable, hidden: states.contains(hidden),
                                           fullscreen: states.contains(fs), maximized: states.contains(mv) && states.contains(mh),
                                           desktopType: !types.isDisjoint(with: deskTypes), own: own.contains(id), app: app))
        }
        return s
    }

    /// `WM_CLASS` class (the second string), "" when unset.
    func windowClass(_ w: Window) -> String {
        var hint = XClassHint()
        guard XGetClassHint(dpy, w, &hint) != 0 else { return "" }
        defer { if let n = hint.res_name { XFree(n) }; if let c = hint.res_class { XFree(c) } }
        return hint.res_class.map { String(cString: $0) } ?? ""
    }

    /// Whether `w` (a child of the root, as XQueryPointer reports it) is the desktop: the root itself, one of
    /// `own`, a `_NET_WM_WINDOW_TYPE_DESKTOP` window, or a window manager frame holding one of those.
    func isDesktop(_ w: Window, own: Set<Window>) -> Bool {
        if w == 0 || w == rootWindow || own.contains(w) { return true }
        let desk = atoms["_NET_WM_WINDOW_TYPE_DESKTOP"]
        func desktopType(_ x: Window) -> Bool { (X11Props.longs(dpy, x, atoms["_NET_WM_WINDOW_TYPE"], type: XA_ATOM_) ?? []).contains(desk) }
        if desktopType(w) { return true }
        var rootRet: Window = 0, parent: Window = 0, kids: UnsafeMutablePointer<Window>?, n: UInt32 = 0
        guard XQueryTree(dpy, w, &rootRet, &parent, &kids, &n) != 0, let kids else { return false }
        defer { XFree(kids) }
        return UnsafeBufferPointer(start: kids, count: Int(n)).contains { own.contains($0) || desktopType($0) }
    }

    /// DPMS: the monitors are in standby, suspend or off (Xvfb and most X servers carry the extension).
    func displayOff() -> Bool {
        var ev: Int32 = 0, er: Int32 = 0
        guard DPMSQueryExtension(dpy, &ev, &er) != 0, DPMSCapable(dpy) != 0 else { return false }
        var level: CARD16 = 0, enabled: BOOL = 0
        guard DPMSInfo(dpy, &level, &enabled) != 0 else { return false }
        return enabled != 0 && level != CARD16(DPMSModeOn)
    }

    /// MIT-SCREEN-SAVER: the X server's screensaver is active (`xset s activate`, or a blanking screensaver).
    func x11ScreensaverOn() -> Bool {
        var ev: Int32 = 0, er: Int32 = 0
        guard XScreenSaverQueryExtension(dpy, &ev, &er) != 0, let info = XScreenSaverAllocInfo() else { return false }
        defer { XFree(info) }
        guard XScreenSaverQueryInfo(dpy, rootWindow, info) != 0 else { return false }
        return info.pointee.state == ScreenSaverOn
    }

    /// The inputs of one evaluation: D-Bus state (photon_system.h), X11 DPMS / screensaver, sysfs when UPower is absent.
    func systemInputs() -> DesktopSystemInputs {
        var st = photon_system_state()
        photon_system_state_get(&st)
        var i = DesktopSystemInputs()
        i.onBattery = st.upower != 0 ? st.on_battery != 0 : DesktopPower.onBattery()
        i.lowPower = st.power_saver != 0
        i.locked = st.locked != 0
        i.preparingSleep = st.preparing_sleep != 0
        i.screensaver = st.screensaver != 0 || x11ScreensaverOn()
        i.displayOff = displayOff()
        return i
    }

}

final class X11DesktopHost {
    struct Options {
        var seconds: Double?
        var fps: Double = 30
        var screenshot: String?
        var rootMode = false
        var time: Float = 1
        var settings = PlaybackSettings()
        /// photon's energy controls (`--battery-fps N`, `--low-power follow|ignore`, `--cap-web on|off`).
        var energy = EnergySettings()
        var windowUpdateRate: Double = 1
        var noShm = false
        /// `--present swapchain|readback`: swapchain is the default wherever the device and window allow it.
        var readback = false
        /// `--no-vsync`: IMMEDIATE/MAILBOX presentation instead of FIFO (benchmarks).
        var vsync = true
        /// `--still`: every frame shows scene time `time`, prepared like `photon-linux render` (tests compare the two).
        var still = false
        /// `--monitors WxH+X+Y,…`: explicit monitor layout instead of XRandR (servers without RandR 1.5 monitors, tests).
        var monitors: [DesktopMonitor]?
        /// `--rate P` (percent, default 100): the wallpaper's `rate` general property (docs/re/09 §2, §7): scene time runs
        /// at P/100, at least 0.1 for scenes; video wallpapers take P/100 as is.
        var ratePercent: Float = 100
        /// `--volume P` (0–100, default 50, the engine's UI default): the wallpaper `volume` general property, the master
        /// gain of its sound objects and of a video wallpaper's audio (P/100); `--mute` 0.
        var volumePercent: Float = 50
        /// `--no-sound`: sound objects stay silent (no OpenAL device is opened).
        var sound = true
        /// `--hold S` (Wayland): keep the surfaces and their last frame for S seconds after the run (screenshots from outside).
        var hold: Double?
        /// `--wayland-fifo`: FIFO presentation on Wayland too (default there: MAILBOX/IMMEDIATE paced by `--fps`, because
        /// Mesa's FIFO waits for frame callbacks a compositor may withhold from a covered background surface).
        var waylandFIFO = false
        /// `--output NAME,…`: only these outputs (connector names from `--list-outputs`, or indices); the app runs one host
        /// per group of displays that show the same wallpaper.
        var outputs: [String]?
        /// `--control`: commands on stdin (HostControl.swift); end of input ends the host.
        var control = false
        /// `--property name=value`: user property overrides (SceneRenderer `propertyOverrides`, the app's stored values).
        var overrides: [String: Any] = [:]
        /// `--general JSON`: the wallpaper's general properties (alignment, colour options, parallax), applied live.
        var general: [String: Any] = [:]
        /// `--app-rules JSON`: the application rules (`apprules`, the app's AppRule array).
        var appRules: [AppRule] = []
        /// `--layout per-display|stretch|clone` (0, 1, 2), `--clone-source NAME` (the output the clone renders on; default
        /// the first) and `--clone-flip NAME,…` (docs/re/09 §8.2, §8.3).
        var layout = 0
        var cloneSource: String?
        var cloneFlip: [String] = []
        /// `--switch-snapshot DIR` + `--transition JSON`: the previous host's frames and the switch transition, when this
        /// host takes over from another process (HostSupervisor).
        var switchSnapshot: String?
        var switchTransition: TransitionSettings?
        /// `--region NAME=X,Y,W,H` (repeatable): the host covers only that rectangle of the output (logical units from the
        /// output's top-left): a split region (docs/re/09 §8.3), which is a wallpaper instance with its own window.
        var regions: [String: CGRect] = [:]

        /// Parses `NAME=X,Y,W,H`.
        static func region(_ arg: String?) -> (String, CGRect)? {
            guard let arg, let eq = arg.lastIndex(of: "=") else { return nil }
            let n = arg[arg.index(after: eq)...].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
            return (String(arg[..<eq]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
        }

        /// A monitor cut to its `--region` (the rectangle the host's window or surface covers).
        func cut(_ m: DesktopMonitor) -> DesktopMonitor {
            guard let r = regions[m.name] else { return m }
            return DesktopMonitor(name: m.name, x: m.x + Int(r.minX), y: m.y + Int(r.minY), width: Int(r.width), height: Int(r.height),
                                  primary: m.primary)
        }
    }

    let dpy: OpaquePointer
    let rootWindow: Window
    let atoms: X11Atoms
    let options: Options
    let host: SceneHost
    private(set) var outputs: [X11Output] = []
    private var gc: GC!
    private var monitors: [DesktopMonitor] = []
    private var lastEvaluation = Date.distantPast
    /// XInput2 major opcode (raw button events for the desktop clicks), nil without XInput 2.
    private var xiOpcode: Int32?

    init(host: SceneHost, options: Options) throws {
        // Mesa's WSI talks to the server from its own thread through the same connection.
        XInitThreads()
        guard let d = XOpenDisplay(nil) else { throw GPUError.failed("cannot open X display \(ProcessInfo.processInfo.environment["DISPLAY"] ?? "(DISPLAY unset)")") }
        dpy = d
        rootWindow = XDefaultRootWindow(d)
        atoms = X11Atoms(d)
        self.options = options
        self.host = host
        photon_system_watch_start()
        host.flush = { [weak self] in if let self { XSync(self.dpy, 0) } }
        selectRawButtons()
    }

    deinit {
        // Swapchains (their surfaces) and images (their SHM segments) go through the connection, so before it closes.
        host.dropSurfaces()
        outputs.removeAll()
        XCloseDisplay(dpy)
    }

    var source: DesktopFrameSource { host.source }

    private var shmAvailable: Bool {
        guard !options.noShm else { return false }
        var major: Int32 = 0, minor: Int32 = 0, pixmaps: Int32 = 0
        return XShmQueryVersion(dpy, &major, &minor, &pixmaps) != 0
    }

    /// Creates the per-monitor outputs (`DesktopHost.rebuildWindows` on macOS).
    func buildOutputs() {
        for o in outputs { o.swapchain = nil }
        for o in outputs where !o.root { XDestroyWindow(dpy, o.window) }
        outputs.removeAll()
        monitors = (options.monitors ?? X11Monitors.query(dpy, root: rootWindow)).enumerated()
            .filter { OutputFilter.matches(options.outputs, name: $0.element.name, index: $0.offset) }.map(\.element)
        gc = XDefaultGC(dpy, XDefaultScreen(dpy))
        let shm = shmAvailable
        // The root window is shared with the desktop's own background, so root mode keeps the readback path.
        let device = options.rootMode || options.readback ? nil : source.vulkanDevice
        // The rules probe the whole monitors; a split region's window covers its rectangle only.
        for full in monitors {
            let m = options.cut(full)
            let w: Window = options.rootMode ? rootWindow : makeDesktopWindow(m)
            var how: String
            var sc: VulkanSwapchain?
            if let device, device.supportsXlibPresentation {
                do {
                    sc = try VulkanSwapchain(device: device, display: UnsafeMutableRawPointer(dpy), window: w, width: m.width, height: m.height,
                                             vsync: options.vsync)
                } catch {
                    print("output \(m.name): no swapchain (\(error)), using readback")
                }
            }
            let img = sc == nil ? X11Image(dpy: dpy, width: m.width, height: m.height, useShm: shm) : nil
            if let sc {
                how = " (Vulkan swapchain, \(sc.presentModeName))"
            } else if let img {
                how = img.usesShm ? " (readback, MIT-SHM)" : " (readback, XPutImage)"
            } else { continue }
            outputs.append(X11Output(monitor: m, window: w, root: options.rootMode, swapchain: sc, image: img, gc: gc))
            print("output \(m.name) \(m.width)x\(m.height)+\(m.x)+\(m.y)\(m.primary ? " primary" : "")\(m != full ? " (region of \(full.width)x\(full.height)+\(full.x)+\(full.y))" : "") → "
                  + (options.rootMode ? "root window" : String(format: "window 0x%lx", w)) + how)
        }
        if options.layout != 0 {
            print("layout \(options.layout == 1 ? "stretch" : "clone") over \(outputs.count) output(s)"
                  + (options.layout == 2 ? ", source \(options.cloneSource ?? outputs.first?.monitor.name ?? "-")" : ""))
        }
        XSync(dpy, 0)
    }

    /// A desktop-type window over `m` (the X11 counterpart of PhotonHost's desktop-level NSWindow).
    private func makeDesktopWindow(_ m: DesktopMonitor) -> Window {
        let s = XDefaultScreen(dpy)
        var attrs = XSetWindowAttributes()
        attrs.background_pixel = XBlackPixel(dpy, s)
        attrs.event_mask = Int(ExposureMask | StructureNotifyMask)
        attrs.override_redirect = 0
        let mask = UInt(CWBackPixel | CWEventMask | CWOverrideRedirect)
        let w = XCreateWindow(dpy, rootWindow, Int32(m.x), Int32(m.y), UInt32(m.width), UInt32(m.height), 0,
                              XDefaultDepth(dpy, s), UInt32(InputOutput), XDefaultVisual(dpy, s), mask, &attrs)
        // EWMH: desktop type, below everything, on all workspaces, kept out of taskbars and pagers.
        X11Props.setLongs(dpy, w, atoms["_NET_WM_WINDOW_TYPE"], type: XA_ATOM_, [atoms["_NET_WM_WINDOW_TYPE_DESKTOP"]])
        X11Props.setLongs(dpy, w, atoms["_NET_WM_STATE"], type: XA_ATOM_,
                          ["_NET_WM_STATE_BELOW", "_NET_WM_STATE_STICKY", "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"].map { atoms[$0] })
        X11Props.setLongs(dpy, w, atoms["_NET_WM_DESKTOP"], type: XA_CARDINAL_, [0xFFFF_FFFF])
        X11Props.setLongs(dpy, w, atoms["_NET_WM_PID"], type: XA_CARDINAL_, [UInt(getpid())])
        // Never take focus (WM_HINTS input = False); the window is a picture, not an application window.
        if let hints = XAllocWMHints() {
            hints.pointee.flags = InputHint
            hints.pointee.input = 0
            XSetWMHints(dpy, w, hints)
            XFree(hints)
        }
        // Position and size are the monitor's, user-specified so WMs keep them.
        if let size = XAllocSizeHints() {
            size.pointee.flags = USPosition | USSize | PMinSize | PMaxSize
            size.pointee.x = Int32(m.x); size.pointee.y = Int32(m.y)
            size.pointee.width = Int32(m.width); size.pointee.height = Int32(m.height)
            size.pointee.min_width = Int32(m.width); size.pointee.min_height = Int32(m.height)
            size.pointee.max_width = Int32(m.width); size.pointee.max_height = Int32(m.height)
            XSetWMNormalHints(dpy, w, size)
            XFree(size)
        }
        if let ch = XAllocClassHint() {
            let name = strdup("photon2"), cls = strdup("photon2")
            ch.pointee.res_name = name
            ch.pointee.res_class = cls
            XSetClassHint(dpy, w, ch)
            XFree(ch); free(name); free(cls)
        }
        XStoreName(dpy, w, "photon2 desktop (\(m.name))")
        XMapWindow(dpy, w)
        XLowerWindow(dpy, w)
        return w
    }

    // MARK: Window probe

    private lazy var probe = X11Probe(dpy: dpy, root: rootWindow, atoms: atoms)
    private var ownWindows: Set<Window> { Set(outputs.filter { !$0.root }.map(\.window)) }
    func snapshot() -> DesktopSnapshot { probe.snapshot(own: ownWindows, apps: !options.appRules.isEmpty) }
    func systemInputs() -> DesktopSystemInputs { probe.systemInputs() }

    /// The playback evaluator tick (WM_TIMER 0x68): pauses or resumes each output.
    func evaluate() {
        host.evaluate(outputs, probe: DesktopPauseRules.probe(snapshot(), monitors: monitors, rules: options.appRules), inputs: systemInputs())
    }

    // MARK: Cursor

    /// XInput 2 raw button events on the root window: delivered whatever window the pointer is over, so a press can be
    /// classified (on the desktop or not) the way macOS DesktopPointer does with its global monitor.
    private func selectRawButtons() {
        var opcode: Int32 = 0, ev: Int32 = 0, err: Int32 = 0
        guard XQueryExtension(dpy, "XInputExtension", &opcode, &ev, &err) != 0 else { print("pointer: no XInput extension, clicks are not seen"); return }
        var major: Int32 = 2, minor: Int32 = 0
        guard XIQueryVersion(dpy, &major, &minor) == 0 /* Success */ else { print("pointer: XInput \(major).\(minor), clicks are not seen"); return }
        var bits = [UInt8](repeating: 0, count: 4)
        for e in [XI_RawButtonPress, XI_RawButtonRelease] { bits[Int(e) >> 3] |= UInt8(1 << (Int(e) & 7)) }
        bits.withUnsafeMutableBufferPointer { b in
            var m = XIEventMask(deviceid: XIAllMasterDevices, mask_len: Int32(b.count), mask: b.baseAddress)
            _ = XISelectEvents(dpy, rootWindow, &m, 1)
        }
        xiOpcode = opcode
    }

    /// A raw button event: the left button pressed while the pointer is over the desktop (photon's windows, the root, a
    /// desktop-type window) is held down until it is released anywhere.
    private func handleGeneric(_ event: inout XEvent) {
        guard let op = xiOpcode, event.xcookie.extension == op, XGetEventData(dpy, &event.xcookie) != 0 else { return }
        defer { XFreeEventData(dpy, &event.xcookie) }
        let type = event.xcookie.evtype
        guard type == XI_RawButtonPress || type == XI_RawButtonRelease, let data = event.xcookie.data else { return }
        let raw = data.assumingMemoryBound(to: XIRawEvent.self).pointee
        guard raw.detail == 1 else { return }
        if type == XI_RawButtonRelease { host.pointerDown = false; return }
        var rootRet: Window = 0, child: Window = 0, rx: Int32 = 0, ry: Int32 = 0, wx: Int32 = 0, wy: Int32 = 0, mask: UInt32 = 0
        XQueryPointer(dpy, rootWindow, &rootRet, &child, &rx, &ry, &wx, &wy, &mask)
        host.pointer = CGPoint(x: Int(rx), y: Int(ry))
        host.pointerDown = probe.isDesktop(child, own: ownWindows)
    }

    /// The cursor position in root coordinates (once per frame; macOS reads NSEvent.mouseLocation per frame).
    private func queryPointer() {
        var rootRet: Window = 0, child: Window = 0, rx: Int32 = 0, ry: Int32 = 0, wx: Int32 = 0, wy: Int32 = 0, mask: UInt32 = 0
        if XQueryPointer(dpy, rootWindow, &rootRet, &child, &rx, &ry, &wx, &wy, &mask) != 0 {
            host.pointer = CGPoint(x: Int(rx), y: Int(ry))
        }
    }

    // MARK: Loop

    func run() throws {
        buildOutputs()
        let start = Date()
        var nextFrame = Date()
        var event = XEvent()
        while true {
            // Drain events (Expose redraws the last frame, raw buttons give the desktop clicks).
            while XPending(dpy) > 0 {
                XNextEvent(dpy, &event)
                if event.type == Expose {
                    for o in outputs where o.window == event.xexpose.window && o.drawn {
                        if o.swapchain != nil { host.representLast(o) } else { o.put() }
                    }
                } else if event.type == GenericEvent {
                    handleGeneric(&event)
                }
            }
            let now = Date()
            if let secs = options.seconds, now.timeIntervalSince(start) >= secs { break }
            let t = now.timeIntervalSince(start)
            host.handleControl(outputs, now: t)
            if host.quit { break }
            if now.timeIntervalSince(lastEvaluation) >= options.windowUpdateRate {
                lastEvaluation = now
                evaluate()
            }
            queryPointer()
            try host.frame(outputs, now: t)
            XSync(dpy, 0)
            let interval = 1 / max(host.switching ? max(host.frameRate, 60) : host.frameRate, 1)
            nextFrame = max(nextFrame.addingTimeInterval(interval), Date())
            let wait = nextFrame.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        // Let queued frames reach the windows (screenshots, the steady-state count).
        source.vulkanDevice?.waitIdle()
        XSync(dpy, 0)
        print("ran \(String(format: "%.1f", Date().timeIntervalSince(start)))s, \(host.frames) frame tick(s)")
        // The first frame loads the scene; frames per second are counted from its end.
        if let f = host.firstFrameEnd, host.frames > 1 {
            let t = Date().timeIntervalSince(f)
            print(String(format: "steady state: %d frames in %.2fs = %.2f fps", host.frames - 1, t, Double(host.frames - 1) / t))
        }
        if let path = options.screenshot { try screenshot(path) }
        for o in outputs { o.swapchain = nil }
        if options.rootMode { setRootPixmap() } else { for o in outputs { XDestroyWindow(dpy, o.window) } }
        XSync(dpy, 0)
    }

    /// The pause / mute fades of the scene loop (SceneHost.fade).
    static func fade(_ value: Float, toward target: Float, dt: Float) -> Float { SceneHost.fade(value, toward: target, dt: dt) }

    /// Root-window capture (XGetImage, the same pixels `import -window root` reads) to PNG.
    func screenshot(_ path: String) throws {
        let s = XDefaultScreen(dpy)
        let w = Int(XDisplayWidth(dpy, s)), h = Int(XDisplayHeight(dpy, s))
        guard let img = XGetImage(dpy, rootWindow, 0, 0, UInt32(w), UInt32(h), AllPlanes_, 2 /* ZPixmap */) else {
            throw GPUError.failed("XGetImage failed")
        }
        defer { _ = img.pointee.f.destroy_image(img) }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let pitch = Int(img.pointee.bytes_per_line), bpp = Int(img.pointee.bits_per_pixel)
        let data = UnsafeRawPointer(img.pointee.data!)
        for y in 0..<h {
            for x in 0..<w {
                let p: UInt32
                if bpp == 32 { p = data.load(fromByteOffset: y * pitch + x * 4, as: UInt32.self) } else { p = UInt32(truncatingIfNeeded: img.pointee.f.get_pixel(img, Int32(x), Int32(y))) }
                let i = (y * w + x) * 4
                rgba[i] = UInt8((p >> 16) & 0xff); rgba[i + 1] = UInt8((p >> 8) & 0xff); rgba[i + 2] = UInt8(p & 0xff)
            }
        }
        try PNGWriter.encode(rgba: rgba, width: w, height: h, keepAlpha: false).write(to: URL(fileURLWithPath: path))
        print("screenshot \(w)x\(h) → \(path)")
    }

    /// --root on exit: leave the last frame as the root background pixmap and publish it as _XROOTPMAP_ID /
    /// ESETROOT_PMAP_ID, so pseudo-transparent terminals and panels pick it up, and keep it after the connection closes.
    func setRootPixmap() {
        let s = XDefaultScreen(dpy)
        let w = UInt32(XDisplayWidth(dpy, s)), h = UInt32(XDisplayHeight(dpy, s))
        let pm = XCreatePixmap(dpy, rootWindow, w, h, UInt32(XDefaultDepth(dpy, s)))
        XFillRectangle(dpy, pm, gc, 0, 0, w, h)
        for o in outputs {
            // A client-side copy of the last frame through plain XPutImage: the pixmap outlives this connection, so it must
            // not depend on the SHM segment that is detached when the outputs go away.
            guard let px = o.lastFrame, let img = X11Image(dpy: dpy, width: o.monitor.width, height: o.monitor.height, useShm: false)
            else { continue }
            img.fill(px)
            img.put(on: pm, gc: gc, x: o.monitor.x, y: o.monitor.y)
        }
        XSync(dpy, 0)
        X11Props.setLongs(dpy, rootWindow, atoms["_XROOTPMAP_ID"], type: XA_PIXMAP_, [pm])
        X11Props.setLongs(dpy, rootWindow, atoms["ESETROOT_PMAP_ID"], type: XA_PIXMAP_, [pm])
        XSetWindowBackgroundPixmap(dpy, rootWindow, pm)
        XClearWindow(dpy, rootWindow)
        XSetCloseDownMode(dpy, RetainPermanent)
        print(String(format: "root background pixmap 0x%lx (_XROOTPMAP_ID)", pm))
    }
}

// MARK: - Command

enum DesktopCommand {
    static let usage = """
    usage: photon-linux desktop <id|dir> [--backend auto|x11|wayland|gnome] [--seconds N] [--fps N] [--time T] [--screenshot out.png]
                                         [--root] [--no-shm] [--proto] [--monitors WxH+X+Y,…] [--present swapchain|readback]
                                         [--no-vsync] [--wayland-fifo] [--still] [--hold S] [--rate P] [--volume P | --mute]
                                         [--no-sound] [--fullscreen run|mute|pause|pauseall|stop] [--maximized …] [--focus …]
                                         [--battery run|pause|stop] [--sleep run|pause|stop] [--static-background WxH]
                                     web wallpapers: [--general JSON] [--property name=value] [--dump-text] [--eval JS]
           photon-linux desktop --list-outputs [--backend x11|wayland]   (JSON lines: name, geometry, primary)
           app control: [--output NAME,…] [--control] [--property name=value] [--general JSON] [--msaa none|x2|x4|x8]
                        [--resolution full|half|auto] [--postprocessing disabled|enabled|ultra|displayhdr]
                        [--window-update-rate MS] [--audio run|mute|pause] [--app-rules JSON] [--pause-vram]
                        [--layout per-display|stretch|clone] [--clone-source NAME] [--clone-flip NAME,…] [--switch-snapshot DIR --transition JSON]
                        [--region NAME=X,Y,W,H …]   (a split region of output NAME: the host covers only that rectangle)
           photon-linux desktop --self-test
           photon-linux desktop --test-client fullscreen|maximized|plain <x> <y> <w> <h> [--seconds N] [--class NAME]
           photon-linux desktop --wl-test-client fullscreen|maximized|plain [--seconds N] [--app-id ID] [--output NAME]
           photon-linux desktop --pointer-test move|click|press|release <x> <y> [… more actions, wait S]   (X11, XTEST)
           photon-linux desktop --wl-pointer-test <layout w> <layout h> move|click|press|release <x> <y> [… wait S]
                                                                                       (Wayland, wlr-virtual-pointer)
    """

    static func main(_ args: [String], workshop: URL, engineAssets: URL) -> Int32 {
        // Line-buffered: the app reads `host: ready`, `snapshot: written`, `video: ended` and the rule lines as they come.
        setlinebuf(stdout)
        var rest = Array(args.dropFirst()) // drop "desktop"
        if rest.first == "--self-test" {
            let failures = DesktopPauseRules.selfTest()
            for f in failures { print("FAIL: \(f)") }
            print(failures.isEmpty ? "pause rules: all checks passed" : "pause rules: \(failures.count) failure(s)")
            return failures.isEmpty ? 0 : 1
        }
        if rest.first == "--test-client" { return testClient(Array(rest.dropFirst())) }
        if rest.first == "--list-outputs" { return OutputList.print(backend: rest.count > 2 && rest[1] == "--backend" ? rest[2] : "auto") }
        if rest.first == "--wl-test-client" {
            let a = Array(rest.dropFirst())
            let seconds = a.firstIndex(of: "--seconds").flatMap { a.indices.contains($0 + 1) ? Double(a[$0 + 1]) : nil } ?? 5
            let appID = a.firstIndex(of: "--app-id").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } ?? "photon2-test-client"
            let output = a.firstIndex(of: "--output").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
            print("wayland test client \(a.first ?? "plain") (\(appID))\(output.map { " on \($0)" } ?? "") for \(seconds)s")
            return photon_wl_test_client_on(a.first ?? "plain", 640, 480, 0xffffff, seconds, appID, output)
        }
        if rest.first == "--pointer-test" { return PointerTest.x11(Array(rest.dropFirst())) }
        if rest.first == "--wl-pointer-test" { return PointerTest.wayland(Array(rest.dropFirst())) }
        var o = X11DesktopHost.Options()
        var target: String?
        var proto = false
        var backend = "auto"
        var staticSize: (Int, Int)?
        while !rest.isEmpty {
            let a = rest.removeFirst()
            func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
            switch a {
            case "--seconds": o.seconds = value().flatMap(Double.init)
            case "--fps": o.fps = value().flatMap(Double.init) ?? o.fps
            case "--time": o.time = value().flatMap(Float.init) ?? o.time
            case "--screenshot": o.screenshot = value()
            case "--root": o.rootMode = true
            case "--no-shm": o.noShm = true
            case "--present":
                switch value() {
                case "readback": o.readback = true
                case "swapchain": o.readback = false
                default: print(usage); return 2
                }
            case "--no-vsync": o.vsync = false
            case "--still": o.still = true
            case "--rate": o.ratePercent = value().flatMap(Float.init) ?? o.ratePercent
            case "--volume": o.volumePercent = value().flatMap(Float.init) ?? o.volumePercent
            case "--mute": o.volumePercent = 0
            case "--proto": proto = true // PhotonProto instead of the full renderer
            case "--monitors":
                // WxH+X+Y[,WxH+X+Y…]
                o.monitors = (value() ?? "").split(separator: ",").enumerated().compactMap { i, g in
                    let n = g.split(whereSeparator: { "x+".contains($0) }).compactMap { Int($0) }
                    return n.count == 4 ? DesktopMonitor(name: "monitor\(i)", x: n[2], y: n[3], width: n[0], height: n[1], primary: i == 0) : nil
                }
            case "--no-sound": o.sound = false
            case "--backend": backend = value() ?? backend
            // Web wallpaper options (WebDesktopCommand reads them from the original arguments).
            case "--dump-text": break
            case "--eval": _ = value()
            case "--general":
                if let d = value()?.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { o.general = v }
            case "--property":
                if let (k, v) = DesktopCommand.property(value()) { o.overrides[k] = v }
            case "--properties":
                if let d = value()?.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    o.overrides.merge(v) { _, b in b }
                }
            case "--output": o.outputs = value()?.split(separator: ",").map(String.init)
            case "--control": o.control = true
            case "--msaa": Multisample.setting = value() ?? Multisample.setting
            case "--resolution": SceneRenderer.resolutionSetting = value() ?? SceneRenderer.resolutionSetting
            case "--postprocessing":
                if let p = value().flatMap(SceneRenderer.PostProcessing.init(rawValue:)) { SceneRenderer.postProcessing = p }
            case "--window-update-rate":
                // `windowupdaterate` (ms), clamped 50…5000 like the engine's timer.
                if let ms = value().flatMap(Double.init) { o.windowUpdateRate = min(max(ms, 50), 5000) / 1000 }
            case "--audio": o.settings.audio = value().map(PlaybackAction.init(engineString:)) ?? o.settings.audio
            case "--pause-vram": o.settings.pauseOnVRAMExhaustion = true
            case "--app-rules":
                if let d = value()?.data(using: .utf8) {
                    if let r = try? JSONDecoder().decode([AppRule].self, from: d) { o.appRules = r } else { print("desktop: --app-rules: not an AppRule array") }
                }
            case "--layout":
                switch value() {
                case "stretch", "1": o.layout = 1
                case "clone", "2": o.layout = 2
                default: o.layout = 0
                }
            case "--clone-flip": o.cloneFlip = value()?.split(separator: ",").map(String.init) ?? []
            case "--clone-source": o.cloneSource = value()
            case "--region":
                guard let (name, r) = X11DesktopHost.Options.region(value()) else { print(usage); return 2 }
                o.regions[name] = r
            case "--switch-snapshot": o.switchSnapshot = value()
            case "--transition":
                if let d = value()?.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) { o.switchTransition = TransitionSettings.parse(v) }
            case "--hold": o.hold = value().flatMap(Double.init)
            case "--wayland-fifo": o.waylandFIFO = true
            case "--static-background":
                let n = (value() ?? "").split(separator: "x").compactMap { Int($0) }
                guard n.count == 2 else { print(usage); return 2 }
                staticSize = (n[0], n[1])
            case "--fullscreen": o.settings.fullscreen = value().map(PlaybackAction.init(engineString:)) ?? o.settings.fullscreen
            case "--maximized": o.settings.maximized = value().map(PlaybackAction.init(engineString:)) ?? o.settings.maximized
            case "--focus": o.settings.focus = value().map(PlaybackAction.init(engineString:)) ?? o.settings.focus
            case "--battery": o.settings.battery = value().map(PlaybackAction.init(engineString:)) ?? o.settings.battery
            case "--battery-fps", "--low-power", "--cap-web": EnergyOptions.parse(a, value(), into: &o.energy)
            case "--sleep": o.settings.sleep = value().map(PlaybackAction.init(engineString:)) ?? o.settings.sleep
            default:
                if a.hasPrefix("--") { print(usage); return 2 }
                target = a
            }
        }
        guard let id = target else { print(usage); return 2 }
        let dir = id.hasPrefix("/") || id.hasPrefix(".") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id)
        // Web wallpapers run in WebKitGTK (WebDesktop.swift), not in the scene renderer.
        if ProjectKind.classify(file: (SceneRenderer.readProject(dir)["file"] as? String) ?? "") == .web {
            return WebDesktopCommand.main(dir: dir, engineAssets: engineAssets, args: Array(args.dropFirst()))
        }
        do {
            let source: DesktopFrameSource
            if proto {
                source = ProtoFrameSource(device: try VulkanDevice(), wallpaper: dir, engineAssets: engineAssets, time: o.time)
            } else {
                // The static background is one frame prepared like `render` (--still).
                source = SceneFrameSource(wallpaper: dir, engineAssets: engineAssets, still: o.still || staticSize != nil ? Double(o.time) : nil,
                                          sound: o.sound && staticSize == nil, overrides: o.overrides, general: o.general)
            }
            let file = (SceneRenderer.readProject(dir)["file"] as? String) ?? ""
            let isVideo = ProjectKind.classify(file: file) == .video
            if let (w, h) = staticSize {
                _ = try StaticBackground.apply(source: source, width: w, height: h, time: Double(o.time))
                return 0
            }
            let env = ProcessInfo.processInfo.environment
            let host = SceneHost(source: source, wallpaper: dir, options: o, engineAssets: engineAssets)
            // A video wallpaper's sound (the engine plays it with the picture); not for --still test frames.
            // `--no-sound` (another display or region plays this wallpaper's sound) silences it too.
            if isVideo, !proto, !o.still, o.sound { host.videoAudio = VideoAudio(project: dir) }
            let useWayland = backend == "wayland" || backend == "gnome" || (backend == "auto" && env["WAYLAND_DISPLAY"].map { !$0.isEmpty } == true)
            if useWayland {
                do {
                    let wl: WaylandDesktopHost
                    do {
                        wl = try WaylandDesktopHost(host: host, options: o, gnome: backend == "gnome")
                    } catch WaylandHostError.noLayerShell(let why) where backend == "auto" && GnomeShellHost.isSession {
                        // GNOME: the Shell extension hosts the background windows (docs/linux-port.md §5.2).
                        print("desktop: \(why); trying the GNOME Shell extension")
                        wl = try WaylandDesktopHost(host: host, options: o, gnome: true)
                    }
                    try wl.run()
                    return 0
                } catch let e as WaylandHostError {
                    print("desktop: \(e)")
                    guard backend == "auto" else { return 1 }
                    if GnomeShellHost.isSession, env["DISPLAY"] == nil {
                        print("desktop: GNOME without the photon2 Shell extension: enable \(GnomeShellHost.extensionUUID), or use "
                              + "--static-background WxH (still frame as the GNOME background); see docs/linux-port.md §5.2")
                        return 1
                    }
                    print("desktop: falling back to X11 (DISPLAY=\(env["DISPLAY"] ?? "unset"))")
                }
            }
            let x11 = try X11DesktopHost(host: host, options: o)
            try x11.run()
            return 0
        } catch {
            print("desktop: \(error)")
            return 1
        }
    }

    /// `--property name=value`: numbers and booleans typed as the app stores them, anything else a string.
    static func property(_ kv: String?) -> (String, Any)? {
        guard let kv, let eq = kv.firstIndex(of: "=") else { return nil }
        let k = String(kv[..<eq]), v = String(kv[kv.index(after: eq)...])
        if v == "true" || v == "false" { return (k, v == "true") }
        if let d = Double(v), !v.contains(" ") { return (k, d) }
        return (k, v)
    }

    /// A stand-in application window for testing the pause rules on a bare X server: maps a window at the given root
    /// geometry with _NET_WM_STATE FULLSCREEN or MAXIMIZED_VERT+HORZ (as a WM would publish them), then waits.
    static func testClient(_ args: [String]) -> Int32 {
        guard args.count >= 5, let x = Int32(args[1]), let y = Int32(args[2]), let w = UInt32(args[3]), let h = UInt32(args[4]),
              let dpy = XOpenDisplay(nil) else { print(usage); return 2 }
        let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 5
        let windowClass = args.firstIndex(of: "--class").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "photon2-test-client"
        let atoms = X11Atoms(dpy)
        let s = XDefaultScreen(dpy), root = XDefaultRootWindow(dpy)
        let win = XCreateSimpleWindow(dpy, root, x, y, w, h, 0, XWhitePixel(dpy, s), XWhitePixel(dpy, s))
        let states: [String]
        switch args[0] {
        case "fullscreen": states = ["_NET_WM_STATE_FULLSCREEN"]
        case "maximized": states = ["_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"]
        default: states = []
        }
        X11Props.setLongs(dpy, win, atoms["_NET_WM_STATE"], type: XA_ATOM_, states.map { atoms[$0] })
        // _NET_WM_PID and WM_CLASS, as an application's window carries them (the application rules read both).
        X11Props.setLongs(dpy, win, atoms["_NET_WM_PID"], type: XA_CARDINAL_, [UInt(getpid())])
        if let ch = XAllocClassHint() {
            let name = strdup(windowClass), cls = strdup(windowClass)
            ch.pointee.res_name = name
            ch.pointee.res_class = cls
            XSetClassHint(dpy, win, ch)
            XFree(ch); free(name); free(cls)
        }
        XStoreName(dpy, win, "photon2 test client (\(args[0]))")
        XMapRaised(dpy, win)
        XSync(dpy, 0)
        print("test client \(args[0]) \(w)x\(h)+\(x)+\(y) for \(seconds)s")
        Thread.sleep(forTimeInterval: seconds)
        XDestroyWindow(dpy, win)
        XCloseDisplay(dpy)
        return 0
    }
}
#endif
