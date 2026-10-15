#if canImport(QuartzCore)
import QuartzCore
#endif
import Combine
import Foundation
import PhotonRender

/// Playlists in the app (docs/re/09 §9): the saved playlists (`general.playlists`), the playlist on each display
/// (`selectedwallpapers[monitor].playlist`), the per-display schedulers and their saved state.
///
/// The engine keeps one node per monitor (map 0x1404e5328) and drives every node from the playback evaluator's
/// `windowupdaterate` timer (`Playlist_Tick` 0x140076be0). A playlist assigned to "all displays" here gives every display
/// without its own playlist its own node, as the engine's per-monitor selection does.
package final class PlaylistController: ObservableObject {
    /// Saved playlists, by name (the UI's Save overwrites a playlist of the same name).
    @Published package private(set) var saved: [EnginePlaylist] = []
    /// The playlist assigned to each display key (or `AppState.allDisplays`), in the engine's JSON form.
    @Published package private(set) var assigned: [String: EnginePlaylist] = [:]
    /// Schedulers by real display key.
    package private(set) var runners: [String: PlaylistRunner] = [:]
    /// A playlist being built in the panel that has fewer than two items: the engine drops it from the config
    /// (`SelectPlaylist` removes it below 2), but its UI keeps the list it is editing. By display key.
    @Published package private(set) var drafts: [String: [String: Any]] = [:]
    /// Local time for daytime / day-of-week selection (tests set a fixed clock).
    package var now: () -> Date = Date.init
    /// Wallpapers shown before on each display, for "Previous" (a photon2 addition; the engine's tray has only
    /// "Next Wallpaper").
    private var history: [String: [EnginePlaylist.Item]] = [:]

    /// Set while the browser window is visible: the engine re-evaluates daytime / day-of-week playlists only while its
    /// UI is not connected (0x14006dd9a).
    package var uiOpen = false

    private weak var state: AppState?
    private var random = PlaylistRandom()
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastTick: Double?
    private var ticksSinceSave = 0
    private var subscriptions: Set<AnyCancellable> = []

    package init(state: AppState) {
        self.state = state
        defaults = state.defaults
        saved = (defaults.data(forKey: "playlists").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? [])
            .map { EnginePlaylist.parse($0, random: &random) }
        let stored = defaults.data(forKey: "selectedplaylists").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: [String: Any]] ?? [:]
        for (key, json) in stored {
            let p = EnginePlaylist.parse(json, random: &random)
            if !p.items.isEmpty { assigned[key] = p }
        }
    }

    /// Starts the schedulers: restores the saved state and runs the startup selection (`0x14006beaa`, force off).
    package func start() {
        guard let state else { return }
        let savedState = (defaults.data(forKey: "playliststate").flatMap { try? JSONDecoder().decode([String: PlaylistRunner.Saved].self, from: $0) }) ?? [:]
        for display in activeDisplays {
            guard let p = playlist(forDisplay: display.id) else { continue }
            // The startup select runs from the config load, before the display's wallpaper object exists (node +0x30
            // null, 0x14006beaa → 0x1400683bd): the pick, the resume item included, counts as a change and the timer
            // restarts (0x1400684ea). The restored timer only decides whether the resume item is dropped.
            var r = PlaylistRunner(playlist: p)
            r.restore(savedState[display.id])
            runners[display.id] = r
            select(display.id, force: false, transition: false)
        }
        restartTimer()
        state.$playback.map(\.windowUpdateRate).removeDuplicates().dropFirst().sink { [weak self] _ in self?.restartTimer() }
            .store(in: &subscriptions)
        state.$displays.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.syncRunners() } }
            .store(in: &subscriptions)
        // Stretch / clone run one node on the source display only; groups and splits have a node each (docs/re/09 §8.3).
        state.$layout.removeDuplicates().dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.syncRunners() } }
            .store(in: &subscriptions)
        state.$profile.removeDuplicates().dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.syncRunners() } }
            .store(in: &subscriptions)
    }

    package func playlist(forDisplay key: String) -> EnginePlaylist? { assigned[key] ?? assigned[AppState.allDisplays] }

    /// The records that run a playlist node (the node map 0x1404e5328 is keyed like the monitor records): with the stretch
    /// / clone layouts only the first display has a wallpaper; a group or split region has its own.
    private var activeDisplays: [DisplayInfo] {
        guard let state else { return [] }
        return state.wallpaperTargets
    }

    // MARK: editing

    /// `SelectPlaylist` 0x140066aa0: the display's playlist becomes `json` (fewer than two items removes it). Every
    /// node's timer restarts; a display that already shows a wallpaper keeps it until the playlist next changes, a
    /// display without one picks now.
    package func assign(_ json: [String: Any], to key: String) {
        guard let state else { return }
        var p = EnginePlaylist.parse(json, random: &random)
        if p.mode == .dayOfWeek, p.items.count > 7 { // the settings dialog cuts a day-of-week playlist to 7 items
            var j = json
            j["items"] = Array((json["items"] as? [Any] ?? []).prefix(7))
            p = EnginePlaylist.parse(j, random: &random)
        }
        if p.items.isEmpty { assigned[key] = nil } else { assigned[key] = p }
        let draftCount = (json["items"] as? [Any])?.count ?? 0
        drafts[key] = p.items.isEmpty && draftCount > 0 ? json : nil
        persistAssigned()
        for k in runners.keys { runners[k]?.elapsed = 0 }
        let keys = key == AppState.allDisplays ? activeDisplays.map(\.id).filter { assigned[$0] == nil } : [key]
        for k in keys {
            guard let p = playlist(forDisplay: k), activeDisplays.contains(where: { $0.id == k }) else { runners[k] = nil; continue }
            let current = state.wallpaper(forDisplay: k).map { EnginePlaylist.Item(file: $0, preset: state.displayPresets[k] ?? "") }
            var r = runners[k] ?? PlaylistRunner(playlist: p)
            r.playlist = p
            r.current = current
            r.currentIsVideo = current.flatMap { state.item($0.file) }?.type == "video"
            runners[k] = r
            // A display without a wallpaper picks now; "never" only changes when forced, so it is forced here (Inferred:
            // otherwise such a display would stay empty).
            if current == nil || state.item(current!.file) == nil { select(k, force: p.mode == .never, transition: false) }
        }
        saveState()
    }

    /// Removes the display's playlist (the browser applying a single wallpaper, `removeWallpaper` with playlist). An
    /// all-displays playlist stays on the other displays.
    package func clear(_ key: String) {
        guard let state else { return }
        if key == AppState.allDisplays {
            assigned.removeAll()
            runners.removeAll()
            drafts.removeAll()
        } else {
            drafts[key] = nil
            if let all = assigned.removeValue(forKey: AppState.allDisplays) {
                for d in state.displays where d.id != key && assigned[d.id] == nil { assigned[d.id] = all }
            }
            assigned[key] = nil
            runners[key] = nil
        }
        persistAssigned()
        saveState()
    }

    package func save(_ json: [String: Any]) {
        let p = EnginePlaylist.parse(json, random: &random)
        guard !p.name.isEmpty else { return }
        if let i = saved.firstIndex(where: { $0.name == p.name }) { saved[i] = p } else { saved.append(p) }
        persistSaved()
    }

    package func delete(named name: String) {
        saved.removeAll { $0.name == name }
        persistSaved()
    }

    // MARK: commands

    /// Tray "Next Wallpaper" (0x1400679b0): every node selects with force on.
    package func next(display key: String? = nil) {
        for k in Array(runners.keys) where key == nil || key == k { select(k, force: true, transition: true) }
    }

    /// photon2 addition: back to the wallpaper shown before on the display(s).
    package func previous(display key: String? = nil) {
        guard let state else { return }
        for k in Array(runners.keys) where key == nil || key == k {
            guard var h = history[k], let item = h.popLast() else { continue }
            history[k] = h
            runners[k]?.current = item
            runners[k]?.elapsed = 0
            runners[k]?.currentIsVideo = state.item(item.file)?.type == "video"
            show(item, display: k, transition: true, record: false)
        }
        saveState()
    }

    package var offersNext: Bool { runners.values.contains { $0.offersNext } }
    package var offersPrevious: Bool { runners.keys.contains { !(history[$0]?.isEmpty ?? true) } }

    /// `Playlist_OnVideoEnded` 0x140067720, from the renderer when a video wallpaper wraps.
    package func videoEnded(display key: String) {
        guard let r = runners[key], r.videoEndedShouldAdvance() else { return }
        select(key, force: false, transition: true)
    }

    // MARK: scheduler

    package func restartTimer() {
        timer?.invalidate()
        let ms = min(max(state?.playback.windowUpdateRate ?? 1000, 50), 5000)
        timer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// `Playlist_Tick` 0x140076be0: dt = min(time since the last tick, 5 s).
    private func tick() {
        guard let state, !state.isStopped else { lastTick = nil; return }
        #if canImport(QuartzCore)
        let now = CACurrentMediaTime()
        #else
        let now = ProcessInfo.processInfo.systemUptime
        #endif
        let dt = Float(min(lastTick.map { now - $0 } ?? 0, 5))
        lastTick = now
        tick(dt: dt)
    }

    package func tick(dt: Float) {
        guard let state, !state.isStopped else { return }
        let indexOf = Dictionary(state.displays.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for k in Array(runners.keys) {
            let paused = state.paused || indexOf[k].map { $0 < 32 && (state.decision.pauseMask >> UInt32($0)) & 1 != 0 } ?? false
            if runners[k]?.tick(dt: dt, paused: paused, uiOpen: uiOpen) == true {
                select(k, force: false, transition: true)
            }
        }
        ticksSinceSave += 1
        if ticksSinceSave >= 60 { saveState() }
    }

    /// Runs the node's selection and shows the result.
    private func select(_ key: String, force: Bool, transition: Bool) {
        guard let state, var r = runners[key] else { return }
        var ctx = PlaylistRunner.Context()
        ctx.now = now()
        ctx.isValid = { item in
            if item.file.hasPrefix("http://") || item.file.hasPrefix("https://") { return true }
            return state.item(item.file).map { $0.unsupportedReason == nil } ?? false
        }
        let before = r.current
        guard let pick = r.select(force: force, context: ctx, random: &random) else { runners[key] = r; return }
        r.currentIsVideo = state.item(pick.file)?.type == "video"
        runners[key] = r
        if let before, before.key != pick.key { history[key, default: []].append(before); history[key] = Array(history[key]!.suffix(32)) }
        show(pick, display: key, transition: transition, record: true)
        saveState()
    }

    private func show(_ item: EnginePlaylist.Item, display key: String, transition: Bool, record: Bool) {
        guard let state, state.item(item.file) != nil else { return }
        // A playlist without a settings object keeps the ctor's transition (−2, 0 ms; docs/re/09 §9.2 +0x48).
        let settings = runners[key].map {
            $0.playlist.transitionSettings == nil ? TransitionSettings(mode: -2, timeMs: 0) : TransitionSettings.parse($0.playlist.transitionSettings)
        }
        state.showFromPlaylist(item.file, display: key, transition: transition ? settings : nil, preset: item.preset)
    }

    /// Displays came or went: nodes for new displays, none for removed ones.
    private func syncRunners() {
        guard let state else { return }
        let active = Set(activeDisplays.map(\.id))
        for k in Array(runners.keys) where !active.contains(k) { runners[k] = nil }
        for d in activeDisplays where runners[d.id] == nil {
            guard let p = playlist(forDisplay: d.id) else { continue }
            var r = PlaylistRunner(playlist: p)
            r.current = state.wallpaper(forDisplay: d.id).map { EnginePlaylist.Item(file: $0, preset: state.displayPresets[d.id] ?? "") }
            runners[d.id] = r
            if r.current == nil { select(d.id, force: false, transition: false) }
        }
    }

    // MARK: persistence

    private func persistSaved() {
        if let d = try? JSONSerialization.data(withJSONObject: saved.map(\.json)) { defaults.set(d, forKey: "playlists") }
    }

    private func persistAssigned() {
        if let d = try? JSONSerialization.data(withJSONObject: assigned.mapValues(\.json)) { defaults.set(d, forKey: "selectedplaylists") }
    }

    /// `bin/playliststate.bin` + `bin/playliststatetime.bin`: written on changes and every 60 ticks here.
    package func saveState() {
        ticksSinceSave = 0
        if let d = try? JSONEncoder().encode(runners.mapValues(\.saved)) { defaults.set(d, forKey: "playliststate") }
    }
}
