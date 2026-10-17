#if os(Linux)
import Foundation
import PhotonApp

// Playback rules for the Linux desktop host (docs/re/09-host.md §1, docs/linux-port.md §5). The probe half (`0x14003d050`)
// becomes an EWMH snapshot (X11Desktop.swift); the evaluator is the macOS app's `PlaybackEvaluator` (0x14006cea0,
// Sources/PhotonApp/PlaybackEvaluator.swift, the library the macOS app uses too), fed with the masks and with host flags from the
// system inputs: UPower OnBattery (sysfs as fallback), logind PrepareForSleep and DPMS (display sleep), the session's
// Lock/Unlock (tray-pause path), and the screensaver (D-Bus ActiveChanged or MIT-SCREEN-SAVER). `DesktopRuleState` holds
// the event-driven state (sleep 0x14006ed90, lock 0x140023b09) so the whole decision is checked without an X server.

/// A monitor in root-window coordinates (XRandR monitor or the whole root).
struct DesktopMonitor: Equatable {
    var name: String
    var x: Int, y: Int, width: Int, height: Int
    var primary = false

    func contains(px: Int, py: Int) -> Bool { px >= x && py >= y && px < x + width && py < y + height }
}

/// One top-level client as the probe saw it (root coordinates, frame excluded).
struct DesktopClient: Equatable {
    var id: UInt
    var x: Int, y: Int, width: Int, height: Int
    var mapped = true
    var hidden = false            // _NET_WM_STATE_HIDDEN (iconic)
    var fullscreen = false        // _NET_WM_STATE_FULLSCREEN
    var maximized = false         // _NET_WM_STATE_MAXIMIZED_VERT and _MAXIMIZED_HORZ
    var desktopType = false       // _NET_WM_WINDOW_TYPE_DESKTOP / _DOCK: never counts (Progman/WorkerW in the engine)
    var own = false               // one of photon's windows
    /// The client's application (`_NET_WM_PID` → /proc, `WM_CLASS`), for the application rules; nil when unknown.
    var app: AppIdentity? = nil
    /// The monitor the window system itself assigns (Mutter's `get_monitor()`, reported by the GNOME Shell extension), in
    /// place of the centre rule; nil: from the geometry.
    var monitorHint: Int? = nil
}

struct DesktopSnapshot {
    var clients: [DesktopClient] = []
    /// _NET_ACTIVE_WINDOW; nil when the WM does not publish it (or there is no WM).
    var active: UInt?
    var onBattery = false
}

struct DesktopMasks: Equatable {
    var focus: UInt32 = 0
    var maximized: UInt32 = 0
    var fullscreen: UInt32 = 0
}

/// The window probe's result: the global masks, and the windows of applications that have a rule for the state they
/// are in (rules+0x138: name, display, condition), which the probe leaves out of the masks (0x14003be61).
struct DesktopProbe {
    var masks = DesktopMasks()
    var windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = []
}

/// The application-rule and audio inputs besides the windows (docs/re/09 §1.3, §1.5): running processes for
/// condition-0 rules, the processes with an audio stream playing, and whether any process other than photon plays audio.
struct DesktopAppInputs {
    var running: [AppIdentity] = []
    var audioApps: [AppIdentity] = []
    var otherAudio = false
}

enum DesktopPauseRules {
    /// `MonitorFromWindow(…, MONITOR_DEFAULTTONEAREST)`: the monitor holding the window centre, else the nearest one.
    static func monitorIndex(_ c: DesktopClient, _ monitors: [DesktopMonitor]) -> Int? {
        guard !monitors.isEmpty else { return nil }
        if let m = c.monitorHint { return monitors.indices.contains(m) ? m : nil }
        let cx = c.x + c.width / 2, cy = c.y + c.height / 2
        if let i = monitors.firstIndex(where: { $0.contains(px: cx, py: cy) }) { return i }
        func dist(_ m: DesktopMonitor) -> Int {
            let dx = max(m.x - cx, 0, cx - (m.x + m.width - 1)), dy = max(m.y - cy, 0, cy - (m.y + m.height - 1))
            return dx * dx + dy * dy
        }
        return monitors.indices.min { dist(monitors[$0]) < dist(monitors[$1]) }
    }

    static func bit(_ i: Int?) -> UInt32 { i.map { $0 < 32 ? UInt32(1) << UInt32($0) : 0 } ?? 0 }

    /// The window probe (`0x14003bba0`), X11 edition:
    /// - focus: the active client's monitor, unless it is photon's own window, a desktop/dock window, or hidden.
    /// - maximized: every visible, non-hidden client with both MAXIMIZED states (any client, as in the engine).
    /// - fullscreen: the foreground client when it has _NET_WM_STATE_FULLSCREEN or its geometry covers its monitor. Without
    ///   _NET_ACTIVE_WINDOW (no WM) every client with the FULLSCREEN state is taken as foreground, so a bare X server
    ///   still pauses under a fullscreen client.
    static func masks(_ s: DesktopSnapshot, monitors: [DesktopMonitor]) -> DesktopMasks { probe(s, monitors: monitors).masks }

    /// `masks` with the application rules: a window whose application has a rule for that state goes to `windows`
    /// instead of its mask bit (focus, maximized, fullscreen; 0x14003be61, PlaybackMonitor.snapshot on macOS).
    static func probe(_ s: DesktopSnapshot, monitors: [DesktopMonitor], rules: [AppRule] = []) -> DesktopProbe {
        var windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = []
        var focus: UInt32 = 0, maximized: UInt32 = 0, fullscreen: UInt32 = 0
        func eligible(_ c: DesktopClient) -> Bool { c.mapped && !c.hidden && !c.own && !c.desktopType }
        func add(_ c: DesktopClient, _ mi: Int?, _ cond: AppRule.Condition, _ mask: inout UInt32) {
            if let app = c.app, rules.contains(where: { $0.condition == cond && $0.matches(app) }) {
                if let mi { windows.append((app, mi, cond)) }
            } else {
                mask |= bit(mi)
            }
        }
        for c in s.clients where eligible(c) && c.maximized { add(c, monitorIndex(c, monitors), .maximized, &maximized) }
        if let a = s.active {
            if let c = s.clients.first(where: { $0.id == a }), eligible(c) {
                let mi = monitorIndex(c, monitors)
                add(c, mi, .focused, &focus)
                if let mi {
                    let mon = monitors[mi]
                    if c.fullscreen || (c.width >= mon.width && c.height >= mon.height) { add(c, mi, .fullscreen, &fullscreen) }
                }
            }
        } else {
            for c in s.clients where eligible(c) && c.fullscreen { add(c, monitorIndex(c, monitors), .fullscreen, &fullscreen) }
        }
        return DesktopProbe(masks: DesktopMasks(focus: focus, maximized: maximized, fullscreen: fullscreen), windows: windows)
    }

    /// The window probe on Wayland, from wlr-foreign-toplevel-management (WaylandDesktop.swift). Clients see no window
    /// geometry there, only each toplevel's states and the outputs it is on; a toplevel's monitor is the first output it
    /// entered (MonitorFromWindow picks one monitor; which one for a window spanning two is Inferred). Layer surfaces,
    /// photon's own included, are not toplevels, so nothing needs excluding.
    /// - focus: the activated toplevel's output, unless minimized.
    /// - maximized: every toplevel with the maximized state that is not minimized (any window, as in the engine).
    /// - fullscreen: the activated toplevel when fullscreen. When no toplevel is activated (focus on a layer surface, or a
    ///   compositor that does not report activation) every fullscreen toplevel counts, as on a bare X server.
    static func masks(toplevels: [WaylandToplevel], outputs: [UInt32]) -> DesktopMasks { probe(toplevels: toplevels, outputs: outputs).masks }

    /// `masks(toplevels:outputs:)` with the application rules (the toplevel's app_id is its application).
    static func probe(toplevels: [WaylandToplevel], outputs: [UInt32], rules: [AppRule] = []) -> DesktopProbe {
        var windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = []
        var focus: UInt32 = 0, maximized: UInt32 = 0, fullscreen: UInt32 = 0
        func index(_ t: WaylandToplevel) -> Int? { t.outputs.lazy.compactMap { outputs.firstIndex(of: $0) }.first }
        func add(_ t: WaylandToplevel, _ cond: AppRule.Condition, _ mask: inout UInt32) {
            let app = t.appID.isEmpty ? nil : LinuxProcesses.identity(appID: t.appID)
            if let app, rules.contains(where: { $0.condition == cond && $0.matches(app) }) {
                if let i = index(t) { windows.append((app, i, cond)) }
            } else {
                mask |= bit(index(t))
            }
        }
        let visible = toplevels.filter { !$0.minimized }
        for t in visible where t.maximized { add(t, .maximized, &maximized) }
        if let a = visible.first(where: { $0.activated }) {
            add(a, .focused, &focus)
            if a.fullscreen { add(a, .fullscreen, &fullscreen) }
        } else {
            for t in visible where t.fullscreen { add(t, .fullscreen, &fullscreen) }
        }
        return DesktopProbe(masks: DesktopMasks(focus: focus, maximized: maximized, fullscreen: fullscreen), windows: windows)
    }

    /// `0x14006cea0` through `PlaybackEvaluator`. `layout` 0 is a wallpaper per monitor; 1 and 2 (stretch, clone) pause
    /// only when every monitor is covered. `app` carries the application-rule windows and the process / audio inputs.
    static func evaluate(_ masks: DesktopMasks, settings: PlaybackSettings, flags: HostFlags = [], monitorCount: Int, layout: Int = 0,
                         rules: [AppRule] = [], windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = [],
                         app: DesktopAppInputs = DesktopAppInputs()) -> PlaybackDecision {
        var snap = SystemSnapshot()
        snap.focusMask = masks.focus
        snap.maximizedMask = masks.maximized
        snap.fullscreenMask = masks.fullscreen
        snap.allMask = monitorCount >= 32 ? UInt32.max : (UInt32(1) << UInt32(monitorCount)) - 1
        snap.windows = windows
        snap.running = app.running
        snap.audioApps = app.audioApps
        snap.otherAudio = app.otherAudio
        var d = PlaybackEvaluator.evaluate(snap, settings: settings, rules: rules, flags: flags, layout: layout)
        d.pauseMask &= snap.allMask
        return d
    }

    /// Unit-style checks of the functions above and of DesktopRuleState (`photon-linux desktop --self-test`).
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let mons = [DesktopMonitor(name: "A", x: 0, y: 0, width: 1280, height: 720),
                    DesktopMonitor(name: "B", x: 1280, y: 0, width: 1280, height: 720)]
        let d = PlaybackSettings()
        func run(_ s: DesktopSnapshot, _ settings: PlaybackSettings = PlaybackSettings()) -> UInt32 {
            evaluate(masks(s, monitors: mons), settings: settings, flags: s.onBattery ? [.onBattery] : [], monitorCount: mons.count).pauseMask
        }
        // Nothing open.
        check(run(DesktopSnapshot()) == 0, "empty desktop runs")
        // Fullscreen client on B, no WM: B pauses, A runs.
        let fsB = DesktopClient(id: 1, x: 1280, y: 0, width: 1280, height: 720, fullscreen: true)
        check(run(DesktopSnapshot(clients: [fsB])) == 0b10, "fullscreen state on B pauses B (no WM)")
        // With a WM that says another window is active, a background fullscreen client does not count (foreground only).
        let small = DesktopClient(id: 2, x: 10, y: 10, width: 300, height: 200)
        check(run(DesktopSnapshot(clients: [fsB, small], active: 2)) == 0, "background fullscreen does not pause")
        // Active window covering A by geometry counts as fullscreen.
        let coverA = DesktopClient(id: 3, x: 0, y: 0, width: 1280, height: 720)
        check(run(DesktopSnapshot(clients: [coverA], active: 3)) == 0b01, "active window covering A pauses A")
        // Maximized anywhere pauses its monitor even when not focused.
        let maxB = DesktopClient(id: 4, x: 1280, y: 30, width: 1280, height: 690, maximized: true)
        check(run(DesktopSnapshot(clients: [maxB, small], active: 2)) == 0b10, "maximized background window pauses B")
        // Hidden (minimised) maximized window does not.
        var hiddenMax = maxB; hiddenMax.hidden = true
        check(run(DesktopSnapshot(clients: [hiddenMax])) == 0, "minimised maximized window runs")
        // photon's own fullscreen-sized desktop windows never count.
        let own = DesktopClient(id: 5, x: 0, y: 0, width: 1280, height: 720, fullscreen: true, own: true)
        check(run(DesktopSnapshot(clients: [own], active: 5)) == 0, "own windows ignored")
        let desk = DesktopClient(id: 6, x: 0, y: 0, width: 1280, height: 720, maximized: true, desktopType: true)
        check(run(DesktopSnapshot(clients: [desk], active: 6)) == 0, "desktop-type windows ignored")
        // pauseall.
        var pa = d; pa.fullscreen = .pauseAll
        check(run(DesktopSnapshot(clients: [fsB]), pa) == 0b11, "fullscreen pauseall pauses both")
        // Focus rule pause: only the focused monitor.
        var fp = d; fp.focus = .pause
        check(run(DesktopSnapshot(clients: [small], active: 2), fp) == 0b01, "focus pause pauses A")
        // Battery pause.
        var bp = d; bp.battery = .pause
        check(run(DesktopSnapshot(onBattery: true), bp) == 0b11, "battery pause pauses all")
        // Stop.
        var st = d; st.fullscreen = .stop
        check(evaluate(masks(DesktopSnapshot(clients: [fsB]), monitors: mons), settings: st, monitorCount: 2).stop,
              "fullscreen stop")
        // Window straddling: centre decides.
        let straddle = DesktopClient(id: 7, x: 1000, y: 0, width: 1000, height: 720, maximized: true)
        check(run(DesktopSnapshot(clients: [straddle])) == 0b10, "centre on B")
        // Mute rules (the shared evaluator returns them; the host fades the sound to 0).
        var mu = d; mu.maximized = .mute
        let mm = evaluate(masks(DesktopSnapshot(clients: [maxB]), monitors: mons), settings: mu, monitorCount: 2)
        check(mm.mute && mm.pauseMask == 0, "maximized mute mutes, no pause")
        // Screensaver flag pauses everything (0x400000).
        check(evaluate(DesktopMasks(), settings: d, flags: [.screensaver], monitorCount: 2).pauseMask == 0b11, "screensaver pauses all")
        // Wayland (foreign-toplevel states): outputs 40 and 41 are monitors A and B.
        let outs: [UInt32] = [40, 41]
        func wl(_ t: [WaylandToplevel], _ settings: PlaybackSettings = PlaybackSettings()) -> UInt32 {
            evaluate(masks(toplevels: t, outputs: outs), settings: settings, monitorCount: 2).pauseMask
        }
        let wfs = WaylandToplevel(activated: true, fullscreen: true, outputs: [41])
        check(wl([wfs]) == 0b10, "wayland: activated fullscreen toplevel on B pauses B")
        var wfsBack = wfs; wfsBack.activated = false
        let wfocusA = WaylandToplevel(activated: true, outputs: [40])
        check(wl([wfsBack, wfocusA]) == 0, "wayland: background fullscreen toplevel does not pause")
        check(wl([wfsBack]) == 0b10, "wayland: fullscreen toplevel counts when nothing is activated")
        let wmax = WaylandToplevel(maximized: true, outputs: [40])
        check(wl([wmax, WaylandToplevel(activated: true, outputs: [41])]) == 0b01, "wayland: maximized background toplevel pauses A")
        var wmin = wmax; wmin.minimized = true
        check(wl([wmin]) == 0, "wayland: minimized maximized toplevel runs")
        check(wl([WaylandToplevel(maximized: true, outputs: [41, 40])]) == 0b10, "wayland: first entered output decides")
        check(wl([WaylandToplevel(fullscreen: true, outputs: [99])]) == 0, "wayland: toplevel on an unknown output is ignored")
        var wfp = d; wfp.focus = .pause
        check(wl([wfocusA], wfp) == 0b01, "wayland: focus pause pauses the activated toplevel's output")
        // Application rules (docs/re/09 §1.5): a window of an application with a rule for its state leaves the global
        // mask and its rule acts instead; condition-0 rules act on running processes; "playingaudio" on audio apps.
        let game = AppIdentity(pid: 42, name: "game", bundleID: "Game", executable: "game.bin")
        let muteFS = AppRule(application: "game", condition: .fullscreen, action: .mute)
        let fsGame = DesktopClient(id: 8, x: 0, y: 0, width: 1280, height: 720, fullscreen: true, app: game)
        let pr = probe(DesktopSnapshot(clients: [fsGame], active: 8), monitors: mons, rules: [muteFS])
        check(pr.masks.fullscreen == 0 && pr.windows.count == 1 && pr.windows[0].display == 0, "app rule: fullscreen window leaves the mask")
        let dr = evaluate(pr.masks, settings: d, monitorCount: 2, rules: [muteFS], windows: pr.windows)
        check(dr.mute && dr.pauseMask == 0, "app rule: mute instead of the global fullscreen pause")
        check(probe(DesktopSnapshot(clients: [fsGame], active: 8), monitors: mons).masks.fullscreen == 0b01, "no rule: the global mask")
        let pauseFocus = AppRule(application: "GAME.BIN", condition: .focused, action: .pause)
        let small8 = DesktopClient(id: 9, x: 1300, y: 10, width: 300, height: 200, app: game)
        let pf = probe(DesktopSnapshot(clients: [small8], active: 9), monitors: mons, rules: [pauseFocus])
        check(evaluate(pf.masks, settings: d, monitorCount: 2, rules: [pauseFocus], windows: pf.windows).pauseMask == 0b10,
              "app rule: focused pause pauses the window's monitor (executable match, case-insensitive)")
        let running = AppRule(application: "sleep", condition: .running, action: .pause)
        var ai = DesktopAppInputs()
        ai.running = [AppIdentity(pid: 7, name: "sleep", executable: "sleep")]
        check(evaluate(DesktopMasks(), settings: d, monitorCount: 2, rules: [running], app: ai).pauseMask == 0b11, "app rule: running process pauses all")
        let stopAudio = AppRule(application: "spotify", condition: .playingAudio, action: .stop)
        var aa = DesktopAppInputs()
        aa.audioApps = [AppIdentity(pid: 9, name: "spotify", executable: "spotify")]
        check(evaluate(DesktopMasks(), settings: d, monitorCount: 2, rules: [stopAudio], app: aa).stop, "app rule: playing audio stop")
        let wlRule = AppRule(application: "firefox", condition: .maximized, action: .mute)
        let wlp = probe(toplevels: [WaylandToplevel(maximized: true, outputs: [41], appID: "org.mozilla.firefox")], outputs: outs, rules: [wlRule])
        check(wlp.masks.maximized == 0 && wlp.windows.first?.display == 1, "wayland: app_id's last part matches the rule")
        // Another application plays audio (0x140138b80): mute or pause all.
        var other = DesktopAppInputs(); other.otherAudio = true
        var ap = d; ap.audio = .pause
        check(evaluate(DesktopMasks(), settings: ap, monitorCount: 2, app: other).pauseMask == 0b11, "audio pause pauses all")
        var am = d; am.audio = .mute
        check(evaluate(DesktopMasks(), settings: am, monitorCount: 2, app: other).mute, "audio mute mutes")
        // Stretch / clone (layout 1, 2): pause only when every monitor is covered.
        check(evaluate(DesktopMasks(maximized: 0b01), settings: d, monitorCount: 2, layout: 1).pauseMask == 0, "stretch: one covered monitor runs")
        check(evaluate(DesktopMasks(maximized: 0b01, fullscreen: 0b10), settings: d, monitorCount: 2, layout: 2).pauseMask == 0b11,
              "clone: both covered (fullscreen counts as maximized) pauses")
        failures += DesktopRuleState.selfTest()
        failures += desktopEnvironmentSelfTest()
        return failures
    }
}

/// One window as org_kde_plasma_window describes it (KWin, photon_wl_plasma_window).
struct PlasmaWindow: Equatable {
    static let active: UInt32 = 1 << 0, minimized: UInt32 = 1 << 1, maximized: UInt32 = 1 << 2, fullscreen: UInt32 = 1 << 3
    static let skipTaskbar: UInt32 = 1 << 12, skipSwitcher: UInt32 = 1 << 18
    var id: UInt32
    var state: UInt32 = 0
    var x = 0, y = 0, width = 0, height = 0
    var pid: Int32 = 0
    var appID = ""
    var onCurrentDesktop = true
    var ready = true
}

extension DesktopPauseRules {
    /// KWin's window list as the X11 probe's snapshot (docs/linux-port.md §5.2): org_kde_plasma_window gives geometry in
    /// global logical coordinates, so a window's monitor is the one holding its centre, and an active window covering
    /// its monitor counts as fullscreen, as with EWMH. Windows on another virtual desktop are unmapped; KWin's
    /// "show desktop" hides all; skip-taskbar windows (Plasma's desktop and panels, OSDs) take the place of the
    /// desktop / dock windows the X11 probe ignores (Inferred: the protocol carries no window type). The application is
    /// the window's pid (/proc) with its app_id.
    static func plasmaSnapshot(_ windows: [PlasmaWindow], showingDesktop: Bool, identity: (PlasmaWindow) -> AppIdentity?) -> DesktopSnapshot {
        var s = DesktopSnapshot()
        for w in windows where w.ready && w.width > 0 && w.height > 0 {
            var c = DesktopClient(id: UInt(w.id), x: w.x, y: w.y, width: w.width, height: w.height)
            c.mapped = w.onCurrentDesktop
            c.hidden = w.state & PlasmaWindow.minimized != 0 || showingDesktop
            c.fullscreen = w.state & PlasmaWindow.fullscreen != 0
            c.maximized = w.state & PlasmaWindow.maximized != 0
            c.desktopType = w.state & PlasmaWindow.skipTaskbar != 0
            c.own = w.pid != 0 && w.pid == getpid()
            c.app = identity(w)
            if w.state & PlasmaWindow.active != 0, c.mapped, !c.hidden { s.active = c.id }
            s.clients.append(c)
        }
        return s
    }

    /// The GNOME Shell extension's state (io.github.photon2.Shell1.GetState, JSON) as the probe's snapshot. Mutter's
    /// own monitor assignment (`monitor`, an index into `monitors`) is mapped onto the host's outputs by connector name,
    /// else by logical geometry; windows on another workspace are unmapped; DESKTOP and DOCK windows (desktop icons,
    /// docks) are ignored like EWMH desktop windows. photon's own background windows are not in the list.
    static func gnomeSnapshot(_ state: [String: Any], outputs: [DesktopMonitor], identity: (Int32, String) -> AppIdentity?) -> DesktopSnapshot {
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        var map: [Int: Int] = [:]
        for m in state["monitors"] as? [[String: Any]] ?? [] {
            guard let i = int(m["index"]) else { continue }
            let connector = m["connector"] as? String ?? ""
            if !connector.isEmpty, let o = outputs.firstIndex(where: { $0.name == connector }) { map[i] = o; continue }
            if let o = outputs.firstIndex(where: { $0.x == int(m["x"]) && $0.y == int(m["y"]) && $0.width == int(m["width"]) && $0.height == int(m["height"]) }) {
                map[i] = o
            }
        }
        var s = DesktopSnapshot()
        for w in state["windows"] as? [[String: Any]] ?? [] {
            guard let id = int(w["id"]) else { continue }
            var c = DesktopClient(id: UInt(truncatingIfNeeded: id), x: int(w["x"]) ?? 0, y: int(w["y"]) ?? 0,
                                  width: int(w["width"]) ?? 0, height: int(w["height"]) ?? 0)
            c.mapped = w["onWorkspace"] as? Bool ?? true
            c.hidden = w["minimized"] as? Bool ?? false
            c.fullscreen = w["fullscreen"] as? Bool ?? false
            c.maximized = w["maximized"] as? Bool ?? false
            c.desktopType = w["desktop"] as? Bool ?? false
            c.monitorHint = int(w["monitor"]).map { map[$0] ?? -1 }
            c.app = identity(Int32(truncatingIfNeeded: int(w["pid"]) ?? 0), w["appId"] as? String ?? "")
            if w["active"] as? Bool == true, c.mapped, !c.hidden { s.active = c.id }
            s.clients.append(c)
        }
        return s
    }

    /// Checks of the two conversions above (part of `--self-test`).
    static func desktopEnvironmentSelfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let mons = [DesktopMonitor(name: "Virtual-0", x: 0, y: 0, width: 1280, height: 720),
                    DesktopMonitor(name: "Virtual-1", x: 1280, y: 0, width: 1280, height: 720)]
        let d = PlaybackSettings()
        func run(_ s: DesktopSnapshot, _ settings: PlaybackSettings = PlaybackSettings(), rules: [AppRule] = []) -> PlaybackDecision {
            let p = probe(s, monitors: mons, rules: rules)
            return evaluate(p.masks, settings: settings, monitorCount: mons.count, rules: rules, windows: p.windows)
        }
        let id: (PlasmaWindow) -> AppIdentity? = { $0.appID.isEmpty ? nil : LinuxProcesses.identity(appID: $0.appID) }
        // KWin: fullscreen on the second output pauses it alone; the first output keeps running.
        let fs = PlasmaWindow(id: 1, state: PlasmaWindow.active | PlasmaWindow.fullscreen, x: 1280, y: 0, width: 1280, height: 720, appID: "org.example.game")
        check(run(plasmaSnapshot([fs], showingDesktop: false, identity: id)).pauseMask == 0b10, "kwin: fullscreen window on Virtual-1 pauses Virtual-1")
        // Maximized in the background on the first output pauses it (any window, as the engine).
        let mx = PlasmaWindow(id: 2, state: PlasmaWindow.maximized, x: 0, y: 0, width: 1280, height: 690)
        let small = PlasmaWindow(id: 3, state: PlasmaWindow.active, x: 1300, y: 10, width: 300, height: 200)
        check(run(plasmaSnapshot([mx, small], showingDesktop: false, identity: id)).pauseMask == 0b01, "kwin: maximized background window pauses Virtual-0")
        var mxMin = mx; mxMin.state |= PlasmaWindow.minimized
        check(run(plasmaSnapshot([mxMin], showingDesktop: false, identity: id)).pauseMask == 0, "kwin: minimized maximized window runs")
        var mxAway = mx; mxAway.onCurrentDesktop = false
        check(run(plasmaSnapshot([mxAway], showingDesktop: false, identity: id)).pauseMask == 0, "kwin: window on another virtual desktop runs")
        check(run(plasmaSnapshot([mx, fs], showingDesktop: true, identity: id)).pauseMask == 0, "kwin: show desktop runs")
        let panel = PlasmaWindow(id: 4, state: PlasmaWindow.active | PlasmaWindow.skipTaskbar | PlasmaWindow.maximized, x: 0, y: 0, width: 1280, height: 720)
        check(run(plasmaSnapshot([panel], showingDesktop: false, identity: id)).pauseMask == 0, "kwin: skip-taskbar (desktop, panel) windows ignored")
        let pending = PlasmaWindow(id: 5, state: PlasmaWindow.fullscreen, x: 0, y: 0, width: 1280, height: 720, ready: false)
        check(run(plasmaSnapshot([pending], showingDesktop: false, identity: id)).pauseMask == 0, "kwin: window before initial_state ignored")
        // An app_id rule: the fullscreen game mutes through its rule instead of the global fullscreen pause.
        let muteGame = AppRule(application: "game", condition: .fullscreen, action: .mute)
        let r = run(plasmaSnapshot([fs], showingDesktop: false, identity: id), d, rules: [muteGame])
        check(r.mute && r.pauseMask == 0, "kwin: app_id rule mutes instead of pausing")
        // GNOME: Mutter's monitor index, mapped by connector (index 0 is Virtual-1 here) or by geometry.
        let state: [String: Any] = [
            "monitors": [["index": 0, "connector": "Virtual-1", "x": 1280, "y": 0, "width": 1280, "height": 720],
                         ["index": 1, "x": 0, "y": 0, "width": 1280, "height": 720]],
            "windows": [["id": 10, "x": 1300, "y": 40, "width": 640, "height": 480, "monitor": 0, "active": true, "fullscreen": true,
                         "appId": "org.example.game", "pid": 0, "onWorkspace": true],
                        ["id": 11, "x": 0, "y": 32, "width": 1280, "height": 688, "monitor": 1, "maximized": true, "onWorkspace": true]]]
        let gid: (Int32, String) -> AppIdentity? = { _, a in a.isEmpty ? nil : LinuxProcesses.identity(appID: a) }
        let g = gnomeSnapshot(state, outputs: mons, identity: gid)
        check(g.active == 10 && g.clients.first?.monitorHint == 1 && g.clients.last?.monitorHint == 0, "gnome: monitors mapped by connector and geometry")
        check(run(g).pauseMask == 0b11, "gnome: fullscreen on Virtual-1 and maximized on Virtual-0 pause both")
        var away = state
        away["windows"] = [["id": 11, "x": 0, "y": 32, "width": 1280, "height": 688, "monitor": 1, "maximized": true, "onWorkspace": false],
                           ["id": 12, "x": 0, "y": 0, "width": 1280, "height": 720, "monitor": 1, "maximized": true, "desktop": true, "onWorkspace": true],
                           ["id": 13, "x": 0, "y": 0, "width": 1280, "height": 720, "monitor": 1, "maximized": true, "minimized": true, "onWorkspace": true]]
        check(run(gnomeSnapshot(away, outputs: mons, identity: gid)).pauseMask == 0, "gnome: other workspace, desktop-type and minimized windows run")
        let gr = run(g, d, rules: [muteGame])
        check(gr.mute && gr.pauseMask == 0b01, "gnome: app_id rule mutes; the maximized window still pauses Virtual-0")
        return failures
    }
}

/// One toplevel as zwlr_foreign_toplevel_handle_v1 describes it (photon_wl_toplevel).
struct WaylandToplevel: Equatable {
    var activated = false
    var maximized = false
    var minimized = false
    var fullscreen = false
    /// Output registry names, in output_enter order.
    var outputs: [UInt32] = []
    var appID = ""
}

/// System inputs the host polls each tick (photon_system_state, X11 DPMS / MIT-SCREEN-SAVER, sysfs).
struct DesktopSystemInputs: Equatable {
    var onBattery = false
    var locked = false
    /// logind PrepareForSleep(true) until PrepareForSleep(false).
    var preparingSleep = false
    /// DPMS standby/suspend/off: the engine's GUID_MONITOR_POWER_ON / GUID_SESSION_DISPLAY_STATUS "off".
    var displayOff = false
    var screensaver = false
    /// Last tick's audio input (for the log only).
    var otherAudio = false
    /// power-profiles-daemon's "power-saver" profile (the energy controls' Low Power Mode).
    var lowPower = false
}

/// The host's playback state: settings, host flags, the lock pause and the last decision; `tick` applies the event
/// inputs as wallpaper64's window procedure does (docs/re/09 §1.4) and then evaluates (§1.3), as macOS PlaybackMonitor.
final class DesktopRuleState {
    var settings: PlaybackSettings
    private(set) var flags: HostFlags = []
    private(set) var decision = PlaybackDecision()
    /// The lock handler paused playback (wallpaper64 `0x1404df540 & 0x40`), so unlock resumes it.
    private(set) var pausedByLock = false
    private var last = DesktopSystemInputs()
    private var asleepInput = false
    /// `apprules` (`--app-rules`), the layout (`--layout`: 1 and 2 pause only when every monitor is covered).
    var appRules: [AppRule] = []
    var layout = 0
    /// `pausevram` hysteresis (shared with macOS, PhotonApp).
    private var vramRule = VRAMRule()
    /// photon's energy controls (Energy.swift): `--fps`, `--battery-fps`, `--low-power`, `--cap-web`. Linux has no thermal
    /// probe, so only the battery frame rate and the power-saver profile apply.
    var energySettings = EnergySettings()
    var baseFPS = 30 { didSet { energy = EnergyPolicy.evaluate(fps: baseFPS, settings: energySettings, inputs: EnergyInputs()) } }
    /// The frame rate in use after the energy controls (updated every tick).
    private(set) var energy = EnergyState(fps: 30)

    init(settings: PlaybackSettings) { self.settings = settings }

    /// Applies `inputs` and evaluates; returns a line per state change. `windows` / `app`: the application-rule and audio
    /// inputs; `vram`: device-local usage and budget in bytes (with `pausevram`).
    @discardableResult
    func tick(masks: DesktopMasks, inputs: DesktopSystemInputs, monitorCount: Int,
              windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = [], app: DesktopAppInputs = DesktopAppInputs(),
              vram: (used: Double, budget: Double)? = nil) -> [String] {
        var log: [String] = []
        // pausevram (0x14006d2e5): flag 0x400 stops everything until usage falls back.
        if settings.pauseOnVRAMExhaustion, let v = vram {
            let was = flags.contains(.vramExhausted)
            if let line = vramRule.update(used: v.used, budget: v.budget, flags: &flags) { log.append(line) }
            if was && !flags.contains(.vramExhausted) {
                log.append(String(format: "VRAM available again (%.0f of %.0f MB)", v.used / 1e6, v.budget / 1e6))
            }
        } else {
            flags.remove(.vramExhausted)
        }
        if app.otherAudio != last.otherAudio {
            log.append(app.otherAudio ? "another application plays audio" : "no other application plays audio")
        }
        // WM_WTSSESSION_CHANGE: lock pauses through the tray pause path unless already paused; unlock resumes it.
        if inputs.locked != last.locked {
            if inputs.locked {
                if !flags.contains(.userPause) { pausedByLock = true; flags.insert(.userPause) }
                log.append("session locked\(pausedByLock ? ": pause" : "")")
            } else {
                if pausedByLock { pausedByLock = false; flags.remove(.userPause) }
                log.append("session unlocked")
            }
        }
        // Sleep(on) 0x14006ed90 for display off (DPMS) or system sleep (PrepareForSleep): pause sets 0x20, stop sets it
        // and stops, run ignores it; waking clears 0x20.
        let asleep = inputs.displayOff || inputs.preparingSleep
        if asleep != asleepInput {
            asleepInput = asleep
            if asleep {
                if settings.sleep != .run {
                    flags.insert(.asleep)
                    if settings.sleep == .stop { decision.stop = true }
                }
                log.append("sleep (\(inputs.preparingSleep ? "PrepareForSleep" : "display off")): \(settings.sleep.engineString)")
            } else {
                flags.remove(.asleep)
                log.append("wake")
            }
        }
        // WM_COPYDATA 1014 / SPI_GETSCREENSAVERRUNNING: 0x400000 while the screensaver runs.
        if inputs.screensaver { flags.insert(.screensaver) } else { flags.remove(.screensaver) }
        if inputs.screensaver != last.screensaver { log.append("screensaver \(inputs.screensaver ? "started" : "stopped")") }
        // GUID_ACDC_POWER_SOURCE: flag 0x10 when not on AC; with the energy controls also in power-saver mode.
        let e = EnergyPolicy.evaluate(fps: baseFPS, settings: energySettings,
                                      inputs: EnergyInputs(onBattery: inputs.onBattery, lowPower: inputs.lowPower))
        if e.saving { flags.insert(.onBattery) } else { flags.remove(.onBattery) }
        if inputs.onBattery != last.onBattery { log.append(inputs.onBattery ? "on battery" : "on AC power") }
        if inputs.lowPower != last.lowPower { log.append(inputs.lowPower ? "power-saver profile" : "power-saver profile off") }
        if e != energy { log.append("energy: \(e.summary)") }
        energy = e
        last = inputs
        last.otherAudio = app.otherAudio
        // While asleep the engine keeps the previous pause state (0x14006d45b); a stop decided by sleep stays.
        if flags.contains(.asleep) { return log }
        var d = DesktopPauseRules.evaluate(masks, settings: settings, flags: flags, monitorCount: monitorCount, layout: layout,
                                           rules: appRules, windows: windows, app: app)
        if d.stop { d.pauseMask = decision.pauseMask }
        decision = d
        return log
    }

    /// Apply (0x1400739a0): a wallpaper pauses with the tray pause or asleep flags (`F & 0x21`) or its monitor's bit.
    func outputPaused(_ index: Int) -> Bool {
        !flags.intersection([.userPause, .asleep]).isEmpty || decision.pauseMask & DesktopPauseRules.bit(index) != 0
    }
    /// Muted with the tray mute or a mute rule (`F & 0xc0`).
    var muted: Bool { flags.contains(.userMute) || decision.mute }
    var stopped: Bool { decision.stop }

    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let none = DesktopMasks()
        // Lock pauses every output, unlock resumes.
        let r = DesktopRuleState(settings: PlaybackSettings())
        r.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 2)
        r.tick(masks: none, inputs: DesktopSystemInputs(locked: true), monitorCount: 2)
        check(r.outputPaused(0) && r.outputPaused(1), "lock pauses")
        r.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 2)
        check(!r.outputPaused(0) && !r.outputPaused(1), "unlock resumes")
        // Default sleep rule is stop; waking lets the rules decide again.
        r.tick(masks: none, inputs: DesktopSystemInputs(displayOff: true), monitorCount: 2)
        check(r.stopped && r.outputPaused(0), "display off stops (sleep = stop)")
        r.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 2)
        check(!r.stopped && !r.outputPaused(0), "wake resumes")
        // Sleep = pause via PrepareForSleep.
        var sp = PlaybackSettings(); sp.sleep = .pause
        let p = DesktopRuleState(settings: sp)
        p.tick(masks: none, inputs: DesktopSystemInputs(preparingSleep: true), monitorCount: 1)
        check(p.outputPaused(0) && !p.stopped, "PrepareForSleep pauses (sleep = pause)")
        // Sleep = run ignores it.
        var sr = PlaybackSettings(); sr.sleep = .run
        let q = DesktopRuleState(settings: sr)
        q.tick(masks: none, inputs: DesktopSystemInputs(displayOff: true), monitorCount: 1)
        check(!q.outputPaused(0) && !q.stopped, "sleep = run keeps running")
        // Screensaver.
        let s = DesktopRuleState(settings: PlaybackSettings())
        s.tick(masks: none, inputs: DesktopSystemInputs(screensaver: true), monitorCount: 2)
        check(s.outputPaused(0) && s.outputPaused(1), "screensaver pauses")
        s.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 2)
        check(!s.outputPaused(0), "screensaver end resumes")
        // Battery = stop.
        var bs = PlaybackSettings(); bs.battery = .stop
        let b = DesktopRuleState(settings: bs)
        b.tick(masks: none, inputs: DesktopSystemInputs(onBattery: true), monitorCount: 1)
        check(b.stopped, "battery stop")
        b.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1)
        check(!b.stopped, "AC power resumes")
        // Energy controls: the battery frame rate, and power-saver counting as battery for the battery rule.
        var ps = PlaybackSettings(); ps.battery = .pause
        let en = DesktopRuleState(settings: ps)
        en.baseFPS = 60
        en.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1)
        check(en.energy.fps == 60 && !en.outputPaused(0), "on AC the frame rate is the setting")
        en.tick(masks: none, inputs: DesktopSystemInputs(onBattery: true), monitorCount: 1)
        check(en.energy.fps == 30 && en.outputPaused(0), "battery: 30 fps and the battery rule")
        en.tick(masks: none, inputs: DesktopSystemInputs(lowPower: true), monitorCount: 1)
        check(en.energy.fps == 30 && en.outputPaused(0), "power-saver counts as battery")
        en.energySettings.followLowPower = false
        en.tick(masks: none, inputs: DesktopSystemInputs(lowPower: true), monitorCount: 1)
        check(en.energy.fps == 60 && !en.outputPaused(0), "power-saver ignored when not followed")
        // pausevram: 80 % stops; under 75 % only after 15 s; under 35 % at once.
        var vs = PlaybackSettings(); vs.pauseOnVRAMExhaustion = true
        let v = DesktopRuleState(settings: vs)
        v.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1, vram: (700e6, 1000e6))
        check(!v.stopped, "VRAM 70 % runs")
        v.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1, vram: (850e6, 1000e6))
        check(v.stopped, "VRAM 85 % stops")
        v.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1, vram: (700e6, 1000e6))
        check(v.stopped, "VRAM 70 % within 15 s stays stopped")
        v.tick(masks: none, inputs: DesktopSystemInputs(), monitorCount: 1, vram: (300e6, 1000e6))
        check(!v.stopped, "VRAM 30 % resumes")
        return failures
    }
}

/// Power source from sysfs (`/sys/class/power_supply`): on battery when a battery exists and no mains/USB supply is
/// online. The fallback when UPower does not answer (docs/linux-port.md §5).
enum DesktopPower {
    static func onBattery(root: String = "/sys/class/power_supply") -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return false }
        var battery = false, mains = false
        for n in names {
            let type = (try? String(contentsOfFile: "\(root)/\(n)/type", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let online = (try? String(contentsOfFile: "\(root)/\(n)/online", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "Battery" { battery = true }
            if type == "Mains" || type == "USB", online == "1" { mains = true }
        }
        return battery && !mains
    }
}
#endif
