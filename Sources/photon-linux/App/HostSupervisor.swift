#if os(Linux)
import Combine
import Foundation
import PhotonApp
import PhotonRender

/// Runs the desktop hosts for the app (docs/linux-port.md §6.1): `photon-linux desktop <wallpaper> --control --output …`
/// child processes, one per group of displays that show the same wallpaper with the same property values, so the X11,
/// Wayland and web hosts of phases 1–5 do the drawing and the app only decides what runs where.
///
/// - What a host gets on its command line (a change starts a new host): the wallpaper folder, its outputs, the user
///   property values with the display's running preset applied (`effectiveOverrides`), the playback rules, the
///   application rules, `pausevram`, `windowupdaterate`, `fps`, `msaa`, `resolution`, `postprocessing`, the layout.
/// - What it gets on stdin (HostControl.swift, live): the tray pause and mute, the wallpaper volume × master volume, the
///   `rate` and the other general properties (alignment, colour options, flip), which the engine applies without a
///   reload; and `load`, another scene or video wallpaper on the same outputs with the switch transition.
/// - Wallpaper switches (docs/re/frame-graph.md §T, docs/linux-port.md §6.1): between scene and video wallpapers on the
///   same outputs the running host switches itself (`load`), drawing the transition over its own frames. Every other
///   change hands over between processes: the old host writes its frames (`snapshot`) when the new wallpaper comes with
///   an effect or a −2 hold, the new host starts with them (`--switch-snapshot`, `--transition`) and shows the overlay
///   before its wallpaper has loaded, and the old host is ended once the new one reports `host: ready`. A restart
///   without a wallpaper change (settings, properties, display groups) overlaps the same way, so there is no black
///   frame between the two; "none" between two types ends the old host at once, as the engine destroys the wallpaper.
/// - Layouts (docs/re/09 §8.2, §8.3): per display; stretch and clone (layout 1 / 2, or a stretch / clone group of the
///   profile) = one host over the instance's outputs with `--layout`, which renders one shared frame and shows each output
///   its part (stretch: its rectangle of the bounding box; clone: the `--clone-source` output's frame cover-fitted,
///   mirrored on `--clone-flip` outputs). Web wallpapers stay per display. A split region (profile `splits`) is a
///   wallpaper instance of its own: one host per region with `--region OUTPUT=X,Y,W,H`, whose surface covers the region;
///   a region in a stretch / clone group is one of the group host's outputs, cut to its rectangle.
/// - Sound: the first host showing a wallpaper (display order, then the regions) plays it; later ones get `--no-sound`
///   (the macOS renderer's first-drawn rule).
/// - Video wallpapers report each loop (`video: ended`), which drives the playlists' "change when a video ends".
/// - The playback rules run in each host (EWMH / wlr-foreign-toplevel probes, D-Bus, /proc, PipeWire inputs); their
///   `playback:` lines become the app's status text.
final class HostSupervisor {
    struct Spec: Equatable {
        var id: String
        var directory: String
        /// The item type ("scene", "video", "web"): the engine's wallpaper types for the switch rules.
        var type: String
        var outputs: [String]
        /// The wallpaper keys the host shows (`selectedwallpapers` keys: its displays, or a group's / the first display's
        /// key for a shared instance): their transitions and playlists.
        var keys: [String]
        var overrides: String     // sorted JSON
        var settings: [String]
    }

    struct Live: Equatable {
        var general: String
        var volume: Int
        var rate: Int
        var paused: Bool
        var muted: Bool
    }

    final class Host {
        var spec: Spec
        let process: ChildProcess
        var live: Live?
        let started = Date()
        var lastLines: [String] = []
        /// The host's `switch:` lines and every line (the self-test reads them).
        var switchLines: [String] = []
        var allLines: [String] = []
        var exited = false
        var ready = false
        /// Run once when the host reports `host: ready` (or ends): the hosts it takes over from are ended then.
        var onReady: [() -> Void] = []
        /// Run when the host answers `snapshot`.
        var onSnapshot: (() -> Void)?
        /// Handovers still waiting for this (old) host's frame or for its successor; it ends when none is left.
        var holds = 0

        init(spec: Spec, process: ChildProcess) {
            self.spec = spec
            self.process = process
        }

        func send(_ line: String) {
            guard !exited else { return }
            process.send(line)
        }

        func fireReady() {
            ready = true
            let r = onReady
            onReady = []
            r.forEach { $0() }
        }
    }

    let state: AppState
    let executable: String
    private(set) var hosts: [String: Host] = [:]
    /// Hosts being replaced: kept until their successors are ready.
    private(set) var retiring: [Host] = []
    /// Specs whose host failed right after starting (load errors): not restarted until something changes.
    private var failed: [String: Spec] = [:]
    /// The latest `playback:` line of any host (status text for the tray and the settings window).
    private(set) var status = ""
    var onStatus: (() -> Void)?
    /// Hosts are not started (tests of the UI alone, `--no-hosts`).
    var enabled = true
    var log: (String) -> Void = { print($0) }
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var debouncer = Debouncer(ms: 300) { [weak self] in self?.reconcile() }
    private var handovers = 0
    /// Switch transitions handed to hosts, newest last (the self-test reads them).
    private(set) var switchLog: [String] = []

    init(state: AppState, executable: String) {
        self.state = state
        self.executable = executable
        state.objectWillChange.sink { [weak self] in self?.debouncer.poke() }.store(in: &subscriptions)
    }

    /// The outputs the hosts would cover, from `photon-linux desktop --list-outputs`.
    static func listOutputs(executable: String) -> [DisplayInfo] {
        let text = ChildProcess.capture([executable, "desktop", "--list-outputs"])
        var displays: [DisplayInfo] = []
        for line in text.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let name = o["name"] as? String else { continue }
            let w = (o["width"] as? NSNumber)?.intValue ?? 0, h = (o["height"] as? NSNumber)?.intValue ?? 0
            let x = (o["x"] as? NSNumber)?.intValue ?? 0, y = (o["y"] as? NSNumber)?.intValue ?? 0
            displays.append(DisplayInfo(id: name, displayID: UInt32(displays.count), name: "\(name) (\(w)×\(h)\(x != 0 || y != 0 ? " at \(x),\(y)" : ""))"))
            geometry[name] = (x, y, w, h)
        }
        return displays
    }

    /// Output geometry by name.
    nonisolated(unsafe) static var geometry: [String: (Int, Int, Int, Int)] = [:]

    private static func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The command-line settings every host shares.
    private var settingsArgs: [String] {
        let pb = state.playback
        var a = ["--fps", state.fps == 0 ? "240" : String(state.fps), "--msaa", state.msaa, "--resolution", state.resolution,
                 "--postprocessing", state.postProcessing.rawValue, "--window-update-rate", String(pb.windowUpdateRate),
                 "--focus", pb.focus.engineString, "--maximized", pb.maximized.engineString, "--fullscreen", pb.fullscreen.engineString,
                 "--battery", pb.battery.engineString, "--sleep", pb.sleep.engineString, "--audio", pb.audio.engineString]
        if !state.rules.isEmpty, let d = try? JSONEncoder().encode(state.rules) { a += ["--app-rules", String(decoding: d, as: UTF8.self)] }
        if pb.pauseOnVRAMExhaustion { a.append("--pause-vram") }
        if ProcessInfo.processInfo.environment["PHOTON_HOST_ARGS"].map({ !$0.isEmpty }) == true {
            a += ProcessInfo.processInfo.environment["PHOTON_HOST_ARGS"]!.split(separator: " ").map(String.init)
        }
        return a
    }

    /// What should run now: (key, spec, live) per group of displays; the key is the group's outputs. The engine's monitor
    /// records (`LayoutPlan`, docs/re/09 §8.3) decide the groups: a host per stretch / clone instance (layout 1 or 2, or a
    /// stretch / clone group) over its displays, with `--layout`, `--clone-source` and `--clone-flip`; otherwise the
    /// displays showing the same wallpaper with the same values share a host. Web pages stay per display.
    func plan() -> [(String, Spec, Live)] {
        guard !state.isStopped else { return [] }
        var groups: [(spec: Spec, live: Live)] = []
        let displays = state.displays
        let monitors = displays.map { d -> LayoutPlan.Monitor in
            let g = Self.geometry[d.id] ?? (0, 0, 0, 0)
            return LayoutPlan.Monitor(key: d.id, rect: CGRect(x: g.0, y: g.1, width: g.2, height: g.3))
        }
        func regionArgs(_ hg: LayoutPlan.HostGroup) -> [String] {
            hg.outputs.compactMap { o in hg.regions[o].map { r in
                "\(o)=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" } }.flatMap { ["--region", $0] }
        }
        for hg in state.layoutPlan(monitors).hostGroups(displays: displays.map(\.id)) {
            let key = hg.key
            guard let id = state.wallpaper(forDisplay: key), let item = state.item(id), item.unsupportedReason == nil else { continue }
            let overrides = Self.json(state.effectiveOverrides(id, display: key))
            let general = state.generalValues(of: id, display: key)
            let volume = Int(((general["volume"] as? NSNumber)?.doubleValue ?? 50) * state.volume)
            let rate = (general["rate"] as? NSNumber)?.intValue ?? 100
            let live = Live(general: Self.json(general), volume: volume, rate: rate, paused: state.paused, muted: state.muted)
            if hg.layout != 0, item.type != "web", hg.outputs.count > 1 {
                // One host renders the shared frame for every output of the instance.
                var settings = settingsArgs + ["--layout", hg.layout == 1 ? "stretch" : "clone"]
                if let s = hg.cloneSource { settings += ["--clone-source", s] }
                if !hg.flips.isEmpty { settings += ["--clone-flip", hg.flips.joined(separator: ",")] }
                groups.append((Spec(id: id, directory: item.directory.path, type: item.type, outputs: hg.outputs, keys: [key],
                                    overrides: overrides, settings: settings + regionArgs(hg)), live))
                continue
            }
            if !hg.regions.isEmpty {
                // A split region: a host of its own over its rectangle (never merged: its outputs are shared with the
                // display's other regions).
                groups.append((Spec(id: id, directory: item.directory.path, type: item.type, outputs: hg.outputs, keys: [key],
                                    overrides: overrides, settings: settingsArgs + regionArgs(hg)), live))
                continue
            }
            for o in hg.outputs {
                if let i = groups.firstIndex(where: { $0.spec.id == id && $0.spec.overrides == overrides && $0.live == live
                                                      && !$0.spec.settings.contains("--layout") && !$0.spec.settings.contains("--region") }) {
                    groups[i].spec.outputs.append(o)
                    if !groups[i].spec.keys.contains(key) { groups[i].spec.keys.append(key) }
                } else {
                    groups.append((Spec(id: id, directory: item.directory.path, type: item.type, outputs: [o], keys: [key],
                                        overrides: overrides, settings: settingsArgs), live))
                }
            }
        }
        // The first host showing a wallpaper plays its sound (scene sound objects, a video's audio).
        var sounding: Set<String> = []
        for i in groups.indices where groups[i].spec.type != "web" {
            if sounding.contains(groups[i].spec.id) { groups[i].spec.settings.append("--no-sound") } else { sounding.insert(groups[i].spec.id) }
        }
        // Keyed by outputs, and by the instance for hosts over regions (several share an output).
        return groups.map { g in
            let regions = g.spec.settings.contains("--region")
            return ((regions ? g.spec.keys.joined(separator: "+") + "@" : "") + g.spec.outputs.joined(separator: ","), g.spec, g.live)
        }
    }

    /// Starts, switches, hands over and stops hosts to match the plan; sends live changes to the ones that keep running.
    func reconcile() {
        guard enabled else { return }
        let wanted = plan()
        let keys = Set(wanted.map(\.0))
        var replaced: [Host] = []
        for (k, h) in hosts where !keys.contains(k) {
            hosts[k] = nil
            replaced.append(h)
        }
        failed = failed.filter { k, s in wanted.contains { $0.0 == k && $0.1 == s } }
        for (k, spec, live) in wanted {
            if let h = hosts[k] {
                if h.spec == spec {
                    update(h, live)
                } else if Self.canSwitchInPlace(h.spec, spec) {
                    switchInPlace(h, spec, live)
                } else {
                    hosts[k] = nil
                    if failed[k] != spec { handover(from: [h], key: k, spec: spec, live: live) } else { stop(h) }
                }
                continue
            }
            guard failed[k] != spec else { continue }
            let olds = (replaced + retiring.filter { !$0.exited && $0.holds > 0 }).filter { !Set($0.spec.outputs).isDisjoint(with: spec.outputs) }
            handover(from: Array(Set(olds.map(ObjectIdentifier.init)).compactMap { id in olds.first { ObjectIdentifier($0) == id } }),
                     key: k, spec: spec, live: live)
        }
        for h in replaced where h.holds == 0 && !retiring.contains(where: { $0 === h }) { stop(h) }
    }

    /// Scene and video wallpapers on the same outputs with the same settings: the host loads the new one itself.
    static func canSwitchInPlace(_ old: Spec, _ new: Spec) -> Bool {
        old.type != "web" && new.type != "web" && old.outputs == new.outputs && old.settings == new.settings
    }

    /// The transition for a group whose wallpaper changed (`Transition_Begin` gets the playlist's settings or
    /// `browsetransition`); consumed for every display of the group.
    private func takeTransition(_ keys: [String]) -> TransitionSettings {
        let all = keys.map { state.takeTransition(display: $0) }
        return all.first ?? state.browseTransition
    }

    private func record(_ what: String) {
        switchLog.append(what)
        log("switch: \(what)")
    }

    private func switchInPlace(_ h: Host, _ spec: Spec, _ live: Live) {
        var o: [String: Any] = ["dir": spec.directory, "volume": live.volume, "rate": live.rate,
                                "properties": (try? JSONSerialization.jsonObject(with: Data(spec.overrides.utf8))) ?? [:],
                                "general": (try? JSONSerialization.jsonObject(with: Data(live.general.utf8))) ?? [:]]
        if h.spec.id != spec.id {
            let t = takeTransition(spec.keys)
            o["transition"] = t.jsonObject
            record("\(h.spec.id) → \(spec.id) in host \(h.process.pid) (\(SceneHost.describe(t)))")
        }
        h.send("load " + Self.json(o))
        h.spec = spec
        var l = live
        // Volume, rate and the general properties came with `load`; pause and mute go as commands.
        if let old = h.live {
            if old.paused != live.paused { h.send("pause \(live.paused ? 1 : 0)") }
            if old.muted != live.muted { h.send("mute \(live.muted ? 1 : 0)") }
        }
        l.general = live.general
        h.live = l
    }

    /// A new host for `spec` takes over from `olds` (docs/re/frame-graph.md §T2 across processes).
    private func handover(from olds: [Host], key: String, spec: Spec, live: Live) {
        let changed = olds.contains { $0.spec.id != spec.id }
        let settings: TransitionSettings? = changed ? takeTransition(spec.keys) : nil
        for o in olds where !retiring.contains(where: { $0 === o }) { retiring.append(o) }
        for o in olds { o.holds += 1 }
        let release = { [weak self] in
            for o in olds {
                o.holds -= 1
                if o.holds <= 0 { self?.stop(o) }
            }
        }
        guard !olds.isEmpty, let settings else {
            // First start, or a restart without a wallpaper change: the old frame stays until the new host has drawn.
            start(key, spec, live, extra: [], onReady: release)
            return
        }
        let sameType = olds.allSatisfy { $0.spec.type == spec.type }
        record("\(olds.map(\.spec.id).joined(separator: "+")) → \(spec.id) by handover (\(SceneHost.describe(settings))\(sameType ? "" : ", type change"))")
        if settings.mode == -1 {
            if sameType {
                start(key, spec, live, extra: [], onReady: release)
            } else {
                // "none" between types: the old wallpaper is destroyed at once (0x140073402).
                release()
                start(key, spec, live, extra: [], onReady: {})
            }
            return
        }
        // An effect or a −2 hold: the old hosts' frames first (vt+0x60; a web page's is waited for up to 3 s).
        handovers += 1
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photon2-switch-\(getpid())-\(handovers)").path
        var waiting = olds.filter { !$0.exited }
        var started = false
        let go = { [weak self] in
            guard let self, !started else { return }
            started = true
            self.start(key, spec, live, extra: ["--switch-snapshot", dir, "--transition", Self.json(settings.jsonObject)], onReady: {
                release()
                after(5000) { try? FileManager.default.removeItem(atPath: dir) }
            })
        }
        if waiting.isEmpty { go(); return }
        for o in waiting {
            o.onSnapshot = {
                waiting.removeAll { $0 === o }
                if waiting.isEmpty { go() }
            }
            o.send("snapshot \(dir)")
        }
        after(3500) { go() }
    }

    private func update(_ h: Host, _ live: Live) {
        guard h.live != live else { return }
        let old = h.live
        if old?.general != live.general { h.send("general " + live.general) }
        if old?.volume != live.volume { h.send("volume \(live.volume)") }
        if old?.rate != live.rate { h.send("rate \(live.rate)") }
        if old?.paused != live.paused { h.send("pause \(live.paused ? 1 : 0)") }
        if old?.muted != live.muted { h.send("mute \(live.muted ? 1 : 0)") }
        h.live = live
    }

    private func start(_ key: String, _ spec: Spec, _ live: Live, extra: [String], onReady: @escaping () -> Void) {
        var args = [executable, "desktop", spec.directory, "--control", "--volume", String(live.volume), "--rate", String(live.rate),
                    "--general", live.general, "--properties", spec.overrides, "--output", spec.outputs.joined(separator: ",")]
        args += spec.settings + extra
        var env = ProcessInfo.processInfo.environment
        env["PHOTON_WE_ASSETS"] = state.engineAssets.path
        guard let p = ChildProcess(args, environment: env) else {
            failed[key] = spec
            state.errors[spec.id] = "cannot start \(executable)"
            onReady()
            return
        }
        let host = Host(spec: spec, process: p)
        host.onReady = [onReady]
        // A successor that never reports ready still takes over after 30 s.
        after(30000) { [weak host] in host?.fireReady() }
        p.onLine = { [weak self, weak host] l in
            guard let self, let host else { return }
            self.log("[host \(host.spec.id)] \(l)")
            host.lastLines = Array((host.lastLines + [l]).suffix(12))
            if l.hasPrefix("switch:") { host.switchLines = Array((host.switchLines + [l]).suffix(40)) }
            host.allLines = Array((host.allLines + [l]).suffix(400))
            if l.hasPrefix("playback: ") {
                self.status = String(l.dropFirst("playback: ".count))
                self.onStatus?()
            } else if l == "host: ready" {
                host.fireReady()
            } else if l.hasPrefix("snapshot: written") {
                let s = host.onSnapshot
                host.onSnapshot = nil
                s?()
            } else if l.hasPrefix("video: ended") {
                self.videoEnded(host)
            }
        }
        p.onExit = { [weak self, weak host] code in
            guard let self, let host else { return }
            host.exited = true
            host.fireReady()
            if let s = host.onSnapshot { host.onSnapshot = nil; s() }
            self.retiring.removeAll { $0 === host }
            guard let k = self.hosts.first(where: { $0.value === host })?.key else { return }
            self.hosts[k] = nil
            // A host that ends on its own within 10 s failed to load: show the error, do not retry in a loop.
            let quick = Date().timeIntervalSince(host.started) < 10
            self.log("host \(host.spec.id) exited (\(code))")
            if code != 0 || quick {
                self.failed[k] = host.spec
                let reason = host.lastLines.last(where: { $0.contains("desktop:") || $0.contains("error") || $0.contains("failed") })
                    ?? host.lastLines.last ?? "exit \(code)"
                self.state.errors[host.spec.id] = reason
            } else {
                self.debouncer.poke()
            }
        }
        hosts[key] = host
        host.live = live
        if live.paused { host.send("pause 1") }
        if live.muted { host.send("mute 1") }
        log("host \(spec.id) started on \(spec.outputs.joined(separator: ","))\(extra.isEmpty ? "" : " (switch from the previous host's frames)") (pid \(p.pid))")
    }

    /// `Playlist_OnVideoEnded` 0x140067720 for the records the host shows (a shared instance's key in stretch / clone).
    private func videoEnded(_ host: Host) {
        guard hosts.values.contains(where: { $0 === host }) else { return }
        for k in host.spec.keys { state.playlists.videoEnded(display: k) }
    }

    private func stop(_ h: Host) {
        retiring.removeAll { $0 === h }
        guard !h.exited else { return }
        h.process.send("quit")
        h.process.closeInput()
        h.exited = true
        after(3000) { h.process.terminate() }
    }

    func stopAll() {
        for (k, h) in hosts { hosts[k] = nil; stop(h) }
        for h in retiring { stop(h) }
    }
}
#endif
