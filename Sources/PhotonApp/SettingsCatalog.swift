import Foundation
import PhotonRender

/// The option lists and labels the settings and playlist UIs share (macOS SwiftUI views and the Linux GTK app).
package enum SettingsCatalog {
    /// scripts.js `getTransitionOptions` (label key, engine value; "none" = -1, "-2" = none without flicker, "random" = -3).
    package static let transitionOptions: [(String, Int)] = [
        ("ui_browse_playlist_modal_settings_transition_none_no_flicker", -2), ("ui_browse_playlist_modal_settings_transition_none", -1),
        ("ui_browse_playlist_modal_settings_transition_random", -3), ("ui_browse_playlist_modal_settings_transition_fade", 0),
        ("ui_browse_playlist_modal_settings_transition_fade_to_black", 18), ("ui_browse_playlist_modal_settings_transition_mosaic", 1),
        ("ui_browse_playlist_modal_settings_transition_diffuse", 2), ("ui_browse_playlist_modal_settings_transition_horizontal_slide", 3),
        ("ui_browse_playlist_modal_settings_transition_vertical_slide", 4), ("ui_browse_playlist_modal_settings_transition_horizontal_fade", 5),
        ("ui_browse_playlist_modal_settings_transition_vertical_fade", 6), ("ui_browse_playlist_modal_settings_transition_clouds", 7),
        ("ui_browse_playlist_modal_settings_transition_burnt_paper", 8), ("ui_browse_playlist_modal_settings_transition_circular", 9),
        ("ui_browse_playlist_modal_settings_transition_zipper", 10), ("ui_browse_playlist_modal_settings_transition_door", 11),
        ("ui_browse_playlist_modal_settings_transition_lines", 12), ("ui_browse_playlist_modal_settings_transition_radial_wipe", 22),
        ("ui_browse_playlist_modal_settings_transition_zoom", 13), ("ui_browse_playlist_modal_settings_transition_twister", 19),
        ("ui_browse_playlist_modal_settings_transition_drip", 14), ("ui_browse_playlist_modal_settings_transition_pixelate", 15),
        ("ui_browse_playlist_modal_settings_transition_bricks", 16), ("ui_browse_playlist_modal_settings_transition_paint", 17),
        ("ui_browse_playlist_modal_settings_transition_black_hole", 20), ("ui_browse_playlist_modal_settings_transition_crt", 21),
        ("ui_browse_playlist_modal_settings_transition_glass_shatter", 23), ("ui_browse_playlist_modal_settings_transition_bullets", 24),
        ("ui_browse_playlist_modal_settings_transition_ice", 25), ("ui_browse_playlist_modal_settings_transition_boilover", 26),
    ]

    /// "ui_browse_playlist_modal_settings_transition_fade_to_black" → "Fade to black".
    package static func transitionFallback(_ key: String) -> String {
        let tail = key.replacingOccurrences(of: "ui_browse_playlist_modal_settings_transition_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    package static func ruleFallback(_ key: WritableKeyPath<PlaybackSettings, PlaybackAction>) -> String {
        switch key {
        case \.focus: return "Other application focused"
        case \.maximized: return "Other application maximized"
        case \.fullscreen: return "Other application fullscreen"
        case \.audio: return "Other application playing audio"
        case \.sleep: return "Displays asleep"
        case \.battery: return "Laptop on battery"
        default: return "?"
        }
    }

    /// The engine's playback rules in the order of its settings page, with their UI string keys.
    package static let rules: [(key: WritableKeyPath<PlaybackSettings, PlaybackAction>, label: String)] = [
        (\.focus, "ui_settings_playback_focused"), (\.maximized, "ui_settings_playback_maximized"),
        (\.fullscreen, "ui_settings_playback_fullscreen"), (\.audio, "ui_settings_playback_playing_audio"),
        (\.sleep, "ui_settings_playback_sleep"), (\.battery, "ui_settings_playback_battery"),
    ]

    /// The options the engine's UI offers for a rule (`runtime.multimonitor` adds "pause all" and per-display pause).
    package static func options(_ key: WritableKeyPath<PlaybackSettings, PlaybackAction>, multiMonitor multi: Bool) -> [PlaybackAction] {
        switch key {
        case \.focus: return multi ? PlaybackSettings.focusOptions : [.run, .mute, .pause]
        case \.maximized, \.fullscreen: return multi ? PlaybackSettings.windowOptions : [.run, .mute, .pause, .stop]
        case \.audio: return PlaybackSettings.audioOptions
        default: return PlaybackSettings.powerOptions
        }
    }

    /// Post-processing qualities with their labels.
    package static let postProcessingLabels: [(String, String)] = [
        ("disabled", "Disabled"), ("enabled", "Enabled"), ("ultra", "Ultra (HDR)"), ("displayhdr", "Display HDR"),
    ]
    package static let msaaOptions: [(String, String)] = [("none", "None"), ("x2", "2×"), ("x4", "4×"), ("x8", "8×")]
    package static let resolutionOptions: [(String, String)] = [("full", "Full"), ("half", "Half"), ("auto", "Auto")]
    package static let layoutOptions: [(Int, String, String)] = [
        (0, "ui_browse_monitors_layout_per_monitor", "Wallpaper per display"),
        (1, "ui_browse_monitors_layout_fit", "Stretch single wallpaper"),
        (2, "ui_browse_monitors_layout_clone_wallpaper", "Clone single wallpaper"),
    ]
}

/// The playlist panel's editing rules (the engine UI's scripts.js), shared by both UIs.
package enum PlaylistEditing {
    /// The UI's defaults for a new playlist (`_e()`).
    package static let defaultSettings: [String: Any] = ["delay": 60, "order": "random", "mode": "timer", "transition": "0",
                                                         "transitiontime": 1500, "videosequence": false, "updateonpause": false]

    /// The UI's `y()` before `selectPlaylist`: the last item's end and any end that is not increasing are dropped (all
    /// of them outside time-of-day mode); an item left with only its file goes back to a plain string.
    package static func cleanItems(_ items: [[String: Any]], mode: String?) -> [Any] {
        var list = items
        var last: Double = 0
        for i in list.indices {
            if i == list.count - 1 { list[i]["daytimeend"] = nil }
            // Ends read back from JSON are NSNumbers; a Float in `Any` would not cast to Double.
            if let e = (list[i]["daytimeend"] as? NSNumber)?.doubleValue {
                if e < last || mode != "daytime" { list[i]["daytimeend"] = nil } else { last = e }
            }
        }
        return list.map { o -> Any in o.count == 1 ? (o["file"] ?? "") : o }
    }

    package static func dayRange(_ items: [EnginePlaylist.Item], _ i: Int) -> String {
        // Days counted from the locale's first day (0x14003dcf0).
        let names = Calendar.current.shortWeekdaySymbols // Sunday first
        let first = PlaylistRunner.localeFirstDayOfWeek() // 0 = Monday
        func name(_ day: Int) -> String { names[(day + first + 1) % 7] }
        let start = i == 0 ? 0 : Int(items[i - 1].daytimeEnd)
        let end = Int(items[i].daytimeEnd) - 1
        return start == end ? name(start) : "\(name(start))–\(name(end))"
    }

    /// The settings dialog's own defaults (`BrowsePlaylistSettingsModalCtrl`): delay 60, transition true → "0", other
    /// non-strings → "-2", time 1000.
    package static func dialogSettings(_ settings: [String: Any]) -> [String: Any] {
        var s = settings
        if (s["delay"] as? NSNumber)?.doubleValue ?? 0 == 0 { s["delay"] = 60 }
        if let b = s["transition"] as? Bool { s["transition"] = b ? "0" : "-2" }
        if !(s["transition"] is String) { s["transition"] = "-2" }
        if !(s["transitiontime"] is NSNumber) { s["transitiontime"] = 1000 }
        return s
    }

    /// The transition value of a settings object ("none" -1, "random" -3, a number string, else -2).
    package static func transitionValue(_ settings: [String: Any]) -> Int {
        switch settings["transition"] as? String {
        case "none": return -1
        case "random": return -3
        case let s?: return TransitionSettings.atoi(s)
        default: return -2
        }
    }
}
