#if canImport(AppKit)
import AppKit
#endif
import Combine
import Foundation
import PhotonRender

/// A connected display, keyed by its persistent UUID so choices survive reconnects and reboots. On Linux the key is the
/// output's connector name (XRandR monitor / `xdg_output` name, e.g. "HDMI-A-1"), which the desktop hosts select by
/// (`photon-linux desktop --output`), and `displayID` its index in the host's output order.
package struct DisplayInfo: Identifiable, Hashable {
    package let id: String
    package let displayID: UInt32
    package let name: String

    package init(id: String, displayID: UInt32, name: String) {
        self.id = id
        self.displayID = displayID
        self.name = name
    }

    #if os(macOS)
    package static func key(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "display-\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    package static var current: [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return DisplayInfo(id: key(for: id), displayID: id, name: screen.localizedName)
        }
    }
    #else
    /// The displays the platform layer reports (set by the Linux app from the desktop host's output list).
    nonisolated(unsafe) package static var provider: () -> [DisplayInfo] = { [] }
    package static var current: [DisplayInfo] { provider() }
    #endif
}

/// Everything the user chooses in the UI, persisted in the `photon2` defaults domain.
package final class AppState: ObservableObject {
    /// Assignment key meaning "every display without its own choice".
    package static let allDisplays = "*"

    package let engineAssets: URL
    /// Folders scanned for wallpapers, in precedence order (the first copy of an id wins).
    package private(set) var libraryDirectories: [URL]
    /// The content filter's blocklist file (HiddenItems); nil = nothing hidden.
    package let hiddenFile: URL?
    /// Ids the blocklist hides: they are left out of `items` (so the browser, playlists and the renderer never see them),
    /// out of Workshop results, and aren't downloaded. Re-read with every library scan.
    @Published package private(set) var hiddenIDs: Set<String> = []
    package let strings: LocalizedStrings

    @Published package private(set) var items: [WallpaperItem] = []
    @Published package private(set) var displays: [DisplayInfo] = DisplayInfo.current
    @Published package private(set) var assignments: [String: String]
    @Published package private(set) var overrides: [String: [String: Any]]
    /// photon's master volume (0–1) on top of each wallpaper's own `volume` property (the engine has no master volume;
    /// its tray only mutes).
    @Published package var volume: Double { didSet { defaults.set(volume, forKey: "mastervolume") } }
    /// Tray mute and pause (wallpaper64 host flags 0x40 and 0x1).
    @Published package var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    @Published package var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    /// Automatic playback rules (docs/re/09 §1), stored under the engine's config key names.
    @Published package var playback: PlaybackSettings { didSet { savePlayback() } }
    @Published package var rules: [AppRule] {
        didSet { if let d = try? JSONEncoder().encode(rules) { defaults.set(d, forKey: "apprules") } }
    }
    /// Host state the rules read (battery, sleep, screensaver, VRAM) and the current automatic decision.
    @Published package var hostFlags: HostFlags = []
    @Published package var decision = PlaybackDecision()
    /// The engine's `fps` setting (default 15): frame cap, particle half-steps, audio poll period.
    @Published package var fps: Int {
        didSet {
            defaults.set(fps, forKey: "fps")
            SceneRenderer.fpsSetting = fps
        }
    }
    /// The engine's post-processing quality: disabled turns bloom off, ultra enables the HDR path.
    @Published package var postProcessing: SceneRenderer.PostProcessing {
        didSet {
            defaults.set(postProcessing.rawValue, forKey: "postprocessing")
            SceneRenderer.postProcessing = postProcessing
            for id in activeIDs { revisions[id, default: 0] += 1 }
        }
    }
    /// The engine's wallpaperconfig `layout` (0x14006a574 → 0x1404e52e0): 0 a wallpaper per display, 1 one wallpaper
    /// stretched over every display, 2 one wallpaper cloned to every display (UI `W.layouts`). docs/re/09 §8.2.
    @Published package var layout: Int { didSet { defaults.set(layout, forKey: "layout") } }
    /// The wallpaperconfig `profile` (MonitorLayout.swift, docs/re/09 §8.3): the clone source and flips of layout 2 and
    /// the groups and splits of layout 0, stored as the engine's JSON object under `profile`.
    @Published package var profile: MonitorProfile {
        didSet { if let d = try? JSONSerialization.data(withJSONObject: profile.json, options: [.sortedKeys]) { defaults.set(d, forKey: "profile") } }
    }
    /// Clone layout: displays whose cloned picture is mirrored horizontally (the profile's `monitorconfig.<monitor>.flip`,
    /// UI `ui_browse_monitors_clone_flip`). Display keys.
    package var cloneFlip: Set<String> {
        get { profile.flip }
        set { profile.flip = newValue }
    }
    /// The engine's `msaa` setting ("none", "x2" default, "x4", "x8"; Multisample.swift, docs/re/09 §8.1).
    @Published package var msaa: String {
        didSet { defaults.set(msaa, forKey: "msaa"); Multisample.setting = msaa }
    }
    /// The wallpaper setting `resolution` ("full", "half", anything else = auto; `Wallpaper_ApplySettings` 0x1401155be,
    /// loader-keys.md §5). Applied here globally; it is read when a scene loads, so the shown wallpapers reload.
    @Published package var resolution: String {
        didSet {
            defaults.set(resolution, forKey: "resolution")
            SceneRenderer.resolutionSetting = resolution
            if resolution != oldValue { for id in activeIDs { revisions[id, default: 0] += 1 } }
        }
    }
    /// The engine's `browsetransition` general setting (`{transition, transitiontime, transitionpool}`, config default
    /// `{"transition":"none","transitiontime":1500}`, 0x140048253): the overlay drawn when a display switches wallpaper
    /// (docs/re/frame-graph.md §T).
    @Published package var browseTransition: TransitionSettings {
        didSet { defaults.set(browseTransition.jsonObject, forKey: "browsetransition") }
    }
    /// Load errors by wallpaper id, reported by the renderer.
    @Published package var errors: [String: String] = [:]
    /// Playlists (docs/re/09 §9): saved playlists, the playlist on each display and their schedulers.
    package private(set) var playlists: PlaylistController!
    /// The transition for the next wallpaper switch on a display: the playlist's `transition` settings when the
    /// playlist changed the wallpaper (`Playlist_Select` passes node +0x80 to `Transition_Begin`, 0x140068459), else
    /// `browsetransition` (0x14006cdfd).
    private var pendingTransitions: [String: TransitionSettings] = [:]

    /// Bumped when a wallpaper's properties change; the renderer reloads scenes whose revision is stale.
    package private(set) var revisions: [String: Int] = [:]
    /// The saved property preset each display runs (playlist item `preset`; `Playlist_Select` 0x1400684e1 →
    /// `Preset_Find` 0x140063f00 → App_LoadWallpaper, wallpaper +0x120 = the name). Display key → name. PropertyPresets.swift.
    @Published package private(set) var displayPresets: [String: String] = [:]

    /// A display starts running `id` with preset `name` ("" = none). A changed preset reloads the wallpaper, as the
    /// engine loads it again (same file, other preset: `Playlist_Select` 0x1400683b4 only skips file + preset equal).
    package func setDisplayPreset(_ name: String, display: String, id: String) {
        guard (displayPresets[display] ?? "") != name else { return }
        displayPresets[display] = name.isEmpty ? nil : name
        revisions[id, default: 0] += 1
    }
    private var pendingReloads: [String: DispatchWorkItem] = [:]
    /// The `photon2` defaults domain (tests pass their own suite).
    package let defaults: UserDefaults
    private var itemsByID: [String: WallpaperItem] = [:]
    /// Every scanned item, hidden ones included (whether something is on disk, for the Workshop).
    private var installedByID: [String: WallpaperItem] = [:]
    /// Workshop browsing and steamcmd downloads.
    package private(set) var workshop: WorkshopController!
    private static let extraDirectoriesKey = "workshopdirs"

    package static let defaultsSuite = "photon2"

    package init(engineAssets: URL, libraryDirectories: [URL], defaults: UserDefaults = UserDefaults(suiteName: AppState.defaultsSuite)!,
                 hiddenFile: URL? = HiddenItems.defaultFile) {
        self.defaults = defaults
        self.engineAssets = engineAssets
        // Folders steamcmd downloads reported earlier, after the given ones.
        let extra = (defaults.stringArray(forKey: Self.extraDirectoriesKey) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        self.libraryDirectories = WorkshopPaths.unique(libraryDirectories + extra)
        self.hiddenFile = hiddenFile
        strings = LocalizedStrings(installDirectory: engineAssets.deletingLastPathComponent())
        Library.lutFilterFiles = Library.loadLUTFilters(install: engineAssets.deletingLastPathComponent())
        assignments = (defaults.dictionary(forKey: "assignments") as? [String: String]) ?? [:]
        overrides = defaults.data(forKey: "overrides")
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: Any]] } ?? [:]
        volume = defaults.object(forKey: "mastervolume") as? Double ?? 1
        muted = defaults.bool(forKey: "muted")
        paused = false
        let ud = defaults
        var pb = PlaybackSettings()
        let action = { (key: String, fallback: PlaybackAction) -> PlaybackAction in
            ud.string(forKey: key).map(PlaybackAction.init(engineString:)) ?? fallback
        }
        pb.focus = action("playbackfocus", pb.focus)
        pb.maximized = action("playbackmaximized", pb.maximized)
        pb.fullscreen = action("playbackfullscreen", pb.fullscreen)
        pb.battery = action("playbackonbattery", pb.battery)
        pb.sleep = action("playbacksleep", pb.sleep)
        pb.audio = action("playbackaudio", pb.audio)
        pb.windowUpdateRate = ud.object(forKey: "windowupdaterate") as? Int ?? pb.windowUpdateRate
        pb.pauseOnVRAMExhaustion = ud.bool(forKey: "pausevram")
        playback = pb
        rules = ud.data(forKey: "apprules").flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? []
        // Environment PHOTON_FPS wins (SceneRenderer reads it at startup), then the saved setting, then 15.
        let fpsValue = ProcessInfo.processInfo.environment["PHOTON_FPS"] != nil ? SceneRenderer.fpsSetting
            : (ud.object(forKey: "fps") as? Int ?? SceneRenderer.fpsSetting)
        fps = fpsValue
        SceneRenderer.fpsSetting = fpsValue
        layout = min(max(defaults.integer(forKey: "layout"), 0), 2)
        var p = defaults.data(forKey: "profile").map { MonitorProfile(json: try? JSONSerialization.jsonObject(with: $0)) } ?? MonitorProfile()
        if defaults.object(forKey: "profile") == nil, let old = defaults.stringArray(forKey: "cloneflip") { p.flip = Set(old) } // before profiles
        profile = p
        msaa = ProcessInfo.processInfo.environment["PHOTON_MSAA"] ?? defaults.string(forKey: "msaa") ?? "x2"
        resolution = ProcessInfo.processInfo.environment["PHOTON_RESOLUTION"] ?? defaults.string(forKey: "resolution") ?? "full"
        browseTransition = defaults.object(forKey: "browsetransition").map(TransitionSettings.parse) ?? .browseDefault
        postProcessing = defaults.string(forKey: "postprocessing").flatMap(SceneRenderer.PostProcessing.init(rawValue:))
            ?? SceneRenderer.postProcessing
        SceneRenderer.postProcessing = postProcessing
        Multisample.setting = msaa
        SceneRenderer.resolutionSetting = resolution
        reloadLibrary()
        workshop = WorkshopController(state: self, defaults: defaults)
        playlists = PlaylistController(state: self)
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displays = DisplayInfo.current
        }
        #endif
    }

    /// Displays came or went (Linux: the app re-reads the hosts' output list on a GDK monitor change).
    package func refreshDisplays() {
        let now = DisplayInfo.current
        if now != displays { displays = now }
    }

    private func savePlayback() {
        defaults.set(playback.focus.engineString, forKey: "playbackfocus")
        defaults.set(playback.maximized.engineString, forKey: "playbackmaximized")
        defaults.set(playback.fullscreen.engineString, forKey: "playbackfullscreen")
        defaults.set(playback.battery.engineString, forKey: "playbackonbattery")
        defaults.set(playback.sleep.engineString, forKey: "playbacksleep")
        defaults.set(playback.audio.engineString, forKey: "playbackaudio")
        defaults.set(playback.windowUpdateRate, forKey: "windowupdaterate")
        defaults.set(playback.pauseOnVRAMExhaustion, forKey: "pausevram")
    }

    /// Whether the wallpaper on display `index` (in `NSScreen.screens` order) is paused: the tray pause or sleep flag
    /// (host flags & 0x21) or its bit in the rule mask (`0x1400739a0`).
    package func isPaused(displayIndex index: Int) -> Bool {
        paused || hostFlags.contains(.asleep) || (index < 32 && (decision.pauseMask >> UInt32(index)) & 1 != 0)
    }

    /// Tray mute or a rule mute (host flags & 0xc0).
    package var isMuted: Bool { muted || decision.mute }

    /// A rule stopped every wallpaper (host flags & 0xc → `0x140073ac0` destroys them).
    package var isStopped: Bool { decision.stop }

    /// The general settings object web wallpapers receive in `applyGeneralProperties` (CEFWallpaper 0x140119a60 sends the
    /// user's whole general settings; the web host maps `language`). Only the settings photon has are included.
    package var generalSettingsForWeb: [String: Any] {
        ["fps": fps, "language": "en-us", "postprocessing": postProcessing.rawValue,
         "playbackfocus": playback.focus.engineString, "playbackmaximized": playback.maximized.engineString,
         "playbackfullscreen": playback.fullscreen.engineString, "playbackonbattery": playback.battery.engineString,
         "playbacksleep": playback.sleep.engineString, "playbackaudio": playback.audio.engineString]
    }

    // MARK: general properties (docs/re/09 §5)

    /// Values of the UI-injected general properties for a wallpaper (`UI_BuildGeneralProps` 0x140104b60), with the
    /// UI's shared defaults (`getSharedDefaultProperties`: alignment 0, alignmentposition 50, rate 100, volume 50,
    /// cameraparallax true) and the neutral x/y 50, zoom 100, no flip.
    package func generalValues(of id: String) -> [String: Any] {
        var v: [String: Any] = ["alignment": 0, "alignmentposition": 50, "alignmentx": 50, "alignmenty": 50, "alignmentz": 100,
                                "alignmentfliph": false, "rate": 100, "volume": 50, "cameraparallax": true, "audioprocessing": true,
                                "wcc_v": "", "wcc_amt": 100, "wec_e": false, "wec_brs": 50, "wec_con": 50, "wec_sa": 50, "wec_hue": 50]
        for k in Self.generalKeys { if let o = overrides[id]?[k] { v[k] = o } }
        return v
    }

    package static let generalKeys = ["alignment", "alignmentposition", "alignmentx", "alignmenty", "alignmentz", "alignmentfliph",
                              "rate", "volume", "cameraparallax", "audioprocessing",
                              "wcc_v", "wcc_amt", "wec_e", "wec_brs", "wec_con", "wec_sa", "wec_hue"]

    /// Changes a general property without reloading the scene (the engine applies them live).
    package func setGeneral(_ key: String, to value: Any, of id: String) {
        overrides[id, default: [:]][key] = value
        saveOverrides()
    }

    package func reloadLibrary() {
        let hidden = HiddenItems.load(hiddenFile)
        if hidden != hiddenIDs { hiddenIDs = hidden }
        let all = Library.scan(directories: libraryDirectories)
        installedByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A preset of a hidden wallpaper is hidden too.
        items = all.filter { !hidden.contains($0.id) && !($0.dependency.map(hidden.contains) ?? false) }
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    package func item(_ id: String) -> WallpaperItem? { itemsByID[id] }

    /// The item on disk with this id, hidden or not.
    package func installedItem(_ id: String) -> WallpaperItem? { installedByID[id] }

    /// Adds a folder to scan (where a steamcmd download landed), remembered across launches.
    package func addLibraryDirectory(_ dir: URL) {
        let key = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !libraryDirectories.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == key }) else { return }
        libraryDirectories.append(dir)
        var saved = defaults.stringArray(forKey: Self.extraDirectoriesKey) ?? []
        if !saved.contains(dir.path) { saved.append(dir.path); defaults.set(saved, forKey: Self.extraDirectoriesKey) }
    }

    package func wallpaper(forDisplay key: String) -> String? { assignments[key] ?? assignments[Self.allDisplays] }

    /// Shows a wallpaper on one display, or on all of them when `display` is nil. A single wallpaper replaces the
    /// display's playlist (the UI's `removeWallpaper` with playlist before `selectWallpaper`).
    package func apply(_ id: String, display: String?) {
        playlists?.clear(display ?? Self.allDisplays)
        if let display {
            setDisplayPreset("", display: display, id: id)
            assignments[display] = id
            pendingTransitions[display] = nil
        } else {
            for k in Array(displayPresets.keys) { setDisplayPreset("", display: k, id: id) }
            assignments = [Self.allDisplays: id]
            pendingTransitions.removeAll()
        }
        errors[id] = nil
        defaults.set(assignments, forKey: "assignments")
    }

    /// A playlist changed the wallpaper on a display (real display key): no playlist is cleared, and the switch uses
    /// the playlist's transition (nil: no transition, e.g. at startup).
    package func showFromPlaylist(_ id: String, display: String, transition: TransitionSettings?, preset: String = "") {
        pendingTransitions[display] = transition ?? TransitionSettings(mode: -1, timeMs: 0)
        setDisplayPreset(preset, display: display, id: id)
        assignments[display] = id
        errors[id] = nil
        defaults.set(assignments, forKey: "assignments")
    }

    /// The transition settings for a switch that is starting on `display` (consumed).
    package func takeTransition(display: String) -> TransitionSettings {
        pendingTransitions.removeValue(forKey: display) ?? browseTransition
    }

    /// Ids currently on some display.
    package var activeIDs: Set<String> {
        Set(wallpaperTargets.compactMap { wallpaper(forDisplay: $0.id) })
    }

    // MARK: multi-monitor layout (docs/re/09 §8.2, §8.3)

    /// The engine's monitor records for the layout and profile over `monitors` (display rectangles; without them every
    /// display is an empty rectangle, which gives the same wallpaper keys).
    package func layoutPlan(_ monitors: [LayoutPlan.Monitor]? = nil) -> LayoutPlan {
        let ms = monitors ?? displays.map { LayoutPlan.Monitor(key: $0.id, rect: .zero) }
        return LayoutPlan.compute(layout: layout, profile: profile, monitors: ms,
                                  names: Dictionary(displays.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }

    /// "Add split" (`callbackSplitSelectedMonitor`): `splits.<key>` is set, and the region's wallpaper and playlist move
    /// to its new `/L` part (the UI re-applies them to the left region it selects: `l(t)`, `nt(a)`). `position` is a
    /// fraction (MonitorProfile.splitFraction for the dialog's pixels).
    package func addSplit(_ key: String, direction: Int, position: Double) {
        let left = key + "/L"
        profile.addSplit(key, direction: direction, position: position)
        if let id = assignments[key] {
            setDisplayPreset(displayPresets[key] ?? "", display: left, id: id)
            assignments[left] = id
            defaults.set(assignments, forKey: "assignments")
        }
        if let p = playlists?.assigned[key] { playlists.assign(p.json, to: left) }
    }

    /// What wallpapers are assigned to (`selectedwallpapers` keys): every record with a wallpaper of its own — a display,
    /// a split region, a group (by its name), or with layouts 1 and 2 the first display. Playlists run on these.
    package var wallpaperTargets: [DisplayInfo] {
        layoutPlan().instances.map { i in
            DisplayInfo(id: i.key, displayID: displays.first { $0.id == i.host }?.displayID ?? 0, name: i.name)
        }
    }

    // MARK: properties

    package func value(_ spec: PropertySpec, of id: String) -> Any {
        overrides[id]?[spec.id] ?? spec.defaultValue
    }

    package func values(_ specs: [PropertySpec], of id: String) -> [String: Any] {
        Dictionary(specs.map { ($0.id, value($0, of: id)) }, uniquingKeysWith: { a, _ in a })
    }

    package func setProperty(_ key: String, to value: Any, of id: String) {
        overrides[id, default: [:]][key] = value
        saveOverrides()
        scheduleReload(id)
    }

    package func resetProperties(of id: String) {
        overrides[id] = nil
        saveOverrides()
        scheduleReload(id)
    }

    package func revision(_ id: String) -> Int { revisions[id] ?? 0 }

    private func saveOverrides() {
        if let data = try? JSONSerialization.data(withJSONObject: overrides) { defaults.set(data, forKey: "overrides") }
    }

    /// Debounced so dragging a slider reloads once it settles rather than every tick.
    private func scheduleReload(_ id: String) {
        pendingReloads[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.revisions[id, default: 0] += 1 }
        pendingReloads[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
