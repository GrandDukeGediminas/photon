import Foundation

// Wallpaper Engine's automatic playback rules (docs/re/09-host.md §1): the settings, the snapshot of what the window and
// system probes saw, and the evaluator (0x14006cea0). Foundation only, in PhotonApp, so the macOS app and the Linux
// desktop hosts run the same evaluator; the macOS probes and the monitor are in Sources/photon/PlaybackRules.swift, the X11
// and Wayland ones in Sources/photon-linux/Host.
// Settings reader 0x14006c280, mode parser 0x140141880, evaluator 0x14006cea0 (WM_TIMER 0x68, every `windowupdaterate` ms
// clamped to 50…5000, default 1000), app rules 0x140134b70 / 0x1401359c0.

/// One playback action (`PlaybackMode_Parse` 0x140141880): "stop" 4, "pauseall" 3, "pause" 2, "mute" 1, anything else 0 (run).
package enum PlaybackAction: Int, CaseIterable, Identifiable, Codable {
    case run = 0, mute = 1, pause = 2, pauseAll = 3, stop = 4
    package var id: Int { rawValue }

    package init(engineString s: String) {
        switch s {
        case "stop": self = .stop
        case "pauseall": self = .pauseAll
        case "pause": self = .pause
        case "mute": self = .mute
        default: self = .run
        }
    }

    package var engineString: String { ["run", "mute", "pause", "pauseall", "stop"][rawValue] }

    package var label: String {
        switch self {
        case .run: return "Keep running"
        case .mute: return "Mute"
        case .pause: return "Pause"
        case .pauseAll: return "Pause all"
        case .stop: return "Stop (free memory)"
        }
    }
}

/// The six global rules. Defaults are the config loader's (0x140046f20): focus run, maximized pause, fullscreen pause,
/// battery run, sleep stop, audio run. The UI (`ui/dist/scripts.js` function k) offers per rule:
/// focus run/mute/pause(/pauseall with several displays); maximized and fullscreen run/mute/pause(/pauseall)/stop;
/// sleep and battery run/pause/stop; audio run/mute/pause.
package struct PlaybackSettings: Equatable {
    package var focus = PlaybackAction.run
    package var maximized = PlaybackAction.pause
    package var fullscreen = PlaybackAction.pause
    package var battery = PlaybackAction.run
    package var sleep = PlaybackAction.stop
    package var audio = PlaybackAction.run
    /// `windowupdaterate` (ms), the WM_TIMER 0x68 period of the evaluator, clamped 50…5000 (0x14001f502).
    package var windowUpdateRate = 1000
    /// `unpauseaero` (default true): Aero Peek forces the wallpapers to run. No macOS counterpart is wired.
    package var pauseOnVRAMExhaustion = false

    package init(focus: PlaybackAction = .run, maximized: PlaybackAction = .pause, fullscreen: PlaybackAction = .pause,
                 battery: PlaybackAction = .run, sleep: PlaybackAction = .stop, audio: PlaybackAction = .run,
                 windowUpdateRate: Int = 1000, pauseOnVRAMExhaustion: Bool = false) {
        self.focus = focus; self.maximized = maximized; self.fullscreen = fullscreen
        self.battery = battery; self.sleep = sleep; self.audio = audio
        self.windowUpdateRate = windowUpdateRate; self.pauseOnVRAMExhaustion = pauseOnVRAMExhaustion
    }

    package static let focusOptions: [PlaybackAction] = [.run, .mute, .pause, .pauseAll]
    package static let windowOptions: [PlaybackAction] = [.run, .mute, .pause, .pauseAll, .stop]
    package static let powerOptions: [PlaybackAction] = [.run, .pause, .stop]
    package static let audioOptions: [PlaybackAction] = [.run, .mute, .pause]
}

/// A per-application rule (`apprules`, parsed by 0x140134b70): `executable`, `condition`, `action`.
/// Conditions (0x140134a40): "focused" 1, "maximized" 2, "fullscreen" 3, "playingaudio" 4, anything else 0 (= while the
/// application runs). Actions use `PlaybackMode_Parse`; the engine's other actions (loadwallpaper/loadplaylist/loadprofile)
/// switch content and are not ported.
package struct AppRule: Identifiable, Equatable, Codable {
    package enum Condition: Int, CaseIterable, Codable, Identifiable {
        case running = 0, focused = 1, maximized = 2, fullscreen = 3, playingAudio = 4
        package var id: Int { rawValue }
        package var label: String { ["Is running", "Is focused", "Is maximized", "Is fullscreen", "Is playing audio"][rawValue] }
    }
    package var id = UUID()
    /// Application name or bundle identifier (the engine matches the executable file name).
    package var application: String
    package var condition: Condition
    package var action: PlaybackAction

    package init(id: UUID = UUID(), application: String, condition: Condition, action: PlaybackAction) {
        self.id = id
        self.application = application
        self.condition = condition
        self.action = action
    }

    package func matches(_ app: AppIdentity) -> Bool {
        let a = application.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty else { return false }
        return a == app.name.lowercased() || a == app.bundleID.lowercased()
            || a == app.name.lowercased() + ".app" || a == app.executable.lowercased()
    }
}

package struct AppIdentity: Hashable {
    package let pid: pid_t
    package let name: String
    package let bundleID: String
    package let executable: String

    package init(pid: pid_t, name: String, bundleID: String = "", executable: String = "") {
        self.pid = pid; self.name = name; self.bundleID = bundleID; self.executable = executable
    }
}

/// What the probe saw in one tick. Display bits are indices into `NSScreen.screens`.
package struct SystemSnapshot {
    /// Bit of the display holding the foreground application window (E+0x10, 0x14003d34f).
    package var focusMask: UInt32 = 0
    /// Displays with a maximized window of any application (E+0x14, 0x14003be80).
    package var maximizedMask: UInt32 = 0
    /// Display of the foreground window when it covers the whole display (E+0x18, 0x14003bffe).
    package var fullscreenMask: UInt32 = 0
    /// Every display that shows a wallpaper (E52EC, 0x140074d28).
    package var allMask: UInt32 = 0
    /// Another process is playing audio (0x140138b80, WASAPI session events).
    package var otherAudio = false
    /// Windows by application and state, for app rules (rules+0x138: name, display, condition).
    package var windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = []
    /// Running applications (rules+0xf8), for condition-0 rules.
    package var running: [AppIdentity] = []
    /// Applications with an audio stream running, for "playingaudio" rules.
    package var audioApps: [AppIdentity] = []

    package init(focusMask: UInt32 = 0, maximizedMask: UInt32 = 0, fullscreenMask: UInt32 = 0, allMask: UInt32 = 0, otherAudio: Bool = false,
                 windows: [(app: AppIdentity, display: Int, condition: AppRule.Condition)] = [], running: [AppIdentity] = [],
                 audioApps: [AppIdentity] = []) {
        self.focusMask = focusMask; self.maximizedMask = maximizedMask; self.fullscreenMask = fullscreenMask; self.allMask = allMask
        self.otherAudio = otherAudio; self.windows = windows; self.running = running; self.audioApps = audioApps
    }
}

/// Result of one evaluation (`0x14006cea0`): which displays pause, and whether everything is muted or stopped.
package struct PlaybackDecision: Equatable {
    package var pauseMask: UInt32 = 0
    package var mute = false
    package var stop = false

    package init(pauseMask: UInt32 = 0, mute: Bool = false, stop: Bool = false) {
        self.pauseMask = pauseMask
        self.mute = mute
        self.stop = stop
    }
}

/// Host flags (wallpaper64 `0x1404e52e4`) that photon2 models.
package struct HostFlags: OptionSet {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }
    package static let userPause = HostFlags(rawValue: 1 << 0)     // tray / UI pause (0x14006eaf0)
    package static let peek = HostFlags(rawValue: 1 << 1)          // Aero Peek with `unpauseaero` (0x14002fc24): forces run
    package static let userStop = HostFlags(rawValue: 1 << 3)      // 0x14006eb10
    package static let onBattery = HostFlags(rawValue: 1 << 4)     // GUID_ACDC_POWER_SOURCE (0x140023d91)
    package static let asleep = HostFlags(rawValue: 1 << 5)        // display off with sleep = pause/stop (0x14006ed90)
    package static let userMute = HostFlags(rawValue: 1 << 6)      // 0x14006ed70
    package static let vramExhausted = HostFlags(rawValue: 1 << 10) // `pausevram` (0x14006d397)
    package static let screensaver = HostFlags(rawValue: 1 << 22)  // WM_COPYDATA 1014 from the screensaver (0x1400237b1)
}

package enum PlaybackEvaluator {
    /// `0x14006d0ef–0x14006d2b0` plus the app rules (0x1401359c0) and the stop test (0x14006d407).
    /// `layout` is the wallpaperconfig `layout` (E52E0): 0 = a wallpaper per display; non-zero = one wallpaper over
    /// several displays, where pause needs every display covered (or any focused app).
    package static func evaluate(_ s: SystemSnapshot, settings: PlaybackSettings, rules: [AppRule], flags: HostFlags,
                         layout: Int = 0) -> PlaybackDecision {
        var mask: UInt32 = 0, stop = false, mute = false
        let all = UInt32.max
        var maximized = s.maximizedMask
        let fullscreen = s.fullscreenMask
        if layout != 0 { maximized |= fullscreen }
        switch settings.fullscreen {
        case .mute: mute = fullscreen != 0
        case .pause: mask = (layout == 1 || layout == 2) ? (s.allMask == fullscreen ? all : 0) : fullscreen
        case .pauseAll: mask = fullscreen != 0 ? all : 0
        case .stop: stop = fullscreen != 0
        case .run: break
        }
        switch settings.maximized {
        case .mute: mute = mute || maximized != 0
        case .pause: mask |= (layout == 1 || layout == 2) ? (s.allMask == maximized ? all : 0) : maximized
        case .pauseAll: mask |= maximized != 0 ? all : 0
        case .stop: stop = stop || maximized != 0
        case .run: break
        }
        if s.focusMask != 0 {
            switch settings.focus {
            case .mute: mute = true
            case .pause: mask |= layout != 0 ? all : s.focusMask
            case .pauseAll: mask = all
            default: break
            }
        }
        if s.otherAudio {
            switch settings.audio {
            case .mute: mute = true
            case .pause: mask = all
            default: break
            }
        }
        if flags.contains(.peek) { mask = 0 }
        if flags.contains(.screensaver) { mask = all }
        if flags.contains(.onBattery) {
            if settings.battery == .stop { stop = true } else if settings.battery == .pause { mask = all }
        }
        // App rules, part 1 (0x140135a33): windows whose state matches a rule of their application.
        for w in s.windows {
            for r in rules where r.condition == w.condition && r.matches(w.app) {
                apply(r.action, display: w.display, mask: &mask, mute: &mute, stop: &stop)
            }
        }
        // Part 2 (0x140135b20): condition-0 rules of running applications (no display, so pause means all).
        for app in s.running {
            for r in rules where r.condition == .running && r.matches(app) {
                apply(r.action, display: nil, mask: &mask, mute: &mute, stop: &stop)
            }
        }
        // "playingaudio" rules (condition 4): Inferred to act on all displays.
        for app in s.audioApps {
            for r in rules where r.condition == .playingAudio && r.matches(app) {
                apply(r.action, display: nil, mask: &mask, mute: &mute, stop: &stop)
            }
        }
        if !flags.intersection([.userStop, .vramExhausted]).isEmpty { stop = true }
        return PlaybackDecision(pauseMask: mask, mute: mute, stop: stop)
    }

    private static func apply(_ a: PlaybackAction, display: Int?, mask: inout UInt32, mute: inout Bool, stop: inout Bool) {
        switch a {
        case .mute: mute = true
        case .pause: mask |= display.map { $0 < 32 ? UInt32(1) << UInt32($0) : 0 } ?? UInt32.max
        case .pauseAll: mask = UInt32.max
        case .stop: stop = true
        case .run: break
        }
    }
}

/// `pausevram` (0x14006d2e5–0x14006d3f5): usage ≥ 80 % of the budget sets host flag 0x400 (which stops everything) and
/// logs "VRAM exhausted (%u of %u)."; the flag clears when usage drops below 75 % after more than 15 s, or below 35 %.
/// The macOS app feeds it Metal's working-set numbers, the Linux hosts VK_EXT_memory_budget.
package struct VRAMRule {
    package private(set) var exhaustedAt: Date?

    package init() {}

    /// Updates `flags` for one evaluation; returns the log line when the rule fires.
    package mutating func update(used: Double, budget: Double, now: Date = Date(), flags: inout HostFlags) -> String? {
        guard budget > 0 else { return nil }
        if used >= 0.8 * budget {
            let fired = !flags.contains(.vramExhausted)
            flags.insert(.vramExhausted)
            exhaustedAt = now
            return fired ? String(format: "VRAM exhausted (%.0f of %.0f MB)", used / 1e6, budget / 1e6) : nil
        } else if flags.contains(.vramExhausted) {
            let elapsed = now.timeIntervalSince(exhaustedAt ?? .distantPast)
            if (elapsed > 15 && 0.75 * budget > used) || 0.35 * budget > used { flags.remove(.vramExhausted) }
        }
        return nil
    }
}
