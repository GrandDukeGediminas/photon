import AppKit
import PhotonApp
import PhotonRender
import SwiftUI

/// The browser's playlist panel, after the engine UI's (scripts.js): the playlist of the selected display, edited in
/// place (every change is sent at once, like the UI's `y()` → `selectPlaylist`), with Load / Save / Configure / Clear,
/// the settings dialog (`BrowsePlaylistSettingsModalCtrl`) and, for time of day, each wallpaper's end time.
struct PlaylistPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var playlists: PlaylistController
    /// The wallpaper selected in the grid ("Add wallpaper").
    let selection: String?
    @State private var target = AppState.allDisplays
    @State private var showSettings = false
    @State private var saveName = ""
    @State private var showSave = false

    init(state: AppState, selection: String?) {
        self.state = state
        playlists = state.playlists
        self.selection = selection
    }

    private func t(_ key: String, _ fallback: String) -> String {
        let l = state.strings.label(key)
        return l == key || l.isEmpty ? fallback : l
    }

    /// The display's playlist in the engine's JSON form, or an empty one with the UI's defaults (`_e()`).
    private var json: [String: Any] {
        playlists.assigned[target]?.json ?? playlists.drafts[target]
            ?? ["name": "", "items": [Any](), "settings": PlaylistPanel.defaultSettings]
    }
    static let defaultSettings: [String: Any] = PlaylistEditing.defaultSettings

    private var items: [[String: Any]] {
        (json["items"] as? [Any] ?? []).map { ($0 as? String).map { ["file": $0] } ?? ($0 as? [String: Any] ?? [:]) }
    }
    private var settings: [String: Any] { json["settings"] as? [String: Any] ?? Self.defaultSettings }
    private var mode: String { settings["mode"] as? String ?? "timer" }

    /// Sends the edited playlist.
    private func commit(items newItems: [[String: Any]]? = nil, settings newSettings: [String: Any]? = nil) {
        let s = newSettings ?? settings
        let out = Self.cleanItems(newItems ?? items, mode: s["mode"] as? String)
        playlists.assign(["name": json["name"] ?? "", "settings": s, "items": out], to: target)
    }

    /// The UI's `y()` before `selectPlaylist` (PlaylistEditing, PhotonApp).
    static func cleanItems(_ items: [[String: Any]], mode: String?) -> [Any] { PlaylistEditing.cleanItems(items, mode: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(items.count > 1 ? "\(t("ui_browse_playlist_header", "Playlist")) (\(items.count))" : t("ui_browse_playlist_header", "Playlist"))
                    .font(.headline)
                Picker("", selection: $target) {
                    Text("All displays").tag(AppState.allDisplays)
                    ForEach(state.wallpaperTargets) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(t("ui_browse_playlist_button_add", "Add wallpaper")) {
                    guard let id = selection else { return }
                    if mode == "dayofweek", items.count >= 7 { return }
                    commit(items: items + [["file": id]])
                }
                .disabled(selection == nil || state.item(selection ?? "")?.unsupportedReason != nil)
                Menu(t("ui_browse_playlist_button_load", "Load")) {
                    if playlists.saved.isEmpty { Text(t("ui_browse_playlist_empty", "You have not created any playlists yet.")) }
                    ForEach(playlists.saved, id: \.name) { p in
                        Button(p.name) { playlists.assign(p.json, to: target) }
                    }
                    if !playlists.saved.isEmpty {
                        Divider()
                        Menu(t("ui_browse_playlist_modal_delete", "Delete")) {
                            ForEach(playlists.saved, id: \.name) { p in Button(p.name) { playlists.delete(named: p.name) } }
                        }
                    }
                }
                .fixedSize()
                Button(t("ui_browse_playlist_button_save", "Save")) {
                    saveName = json["name"] as? String ?? ""
                    showSave = true
                }
                .disabled(items.count < 2)
                Button(t("ui_browse_playlist_button_configure", "Configure")) { showSettings = true }
                    .disabled(items.isEmpty)
                Button(t("ui_browse_playlist_button_clear", "Clear")) { commit(items: []) }
                    .disabled(items.isEmpty)
                Button("Next") { playlists.next(display: target == AppState.allDisplays ? nil : target) }
                    .disabled(!playlists.offersNext)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, entry in
                        itemView(i, entry)
                    }
                    if items.isEmpty {
                        Text("Select a wallpaper and choose Add wallpaper (or right-click a wallpaper). A playlist needs two or more.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 118)
            if let summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sheet(isPresented: $showSettings) {
            PlaylistSettingsSheet(state: state, settings: settings, itemCount: items.count) { new in
                var list = items
                if (new["mode"] as? String) == "dayofweek", list.count > 7 { list = Array(list.prefix(7)) }
                commit(items: list, settings: new)
            }
        }
        .sheet(isPresented: $showSave) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("ui_browse_playlist_modal_save_header", "Save Playlist")).font(.headline)
                TextField(t("ui_browse_playlist_modal_save_name", "Name"), text: $saveName)
                Text(t("ui_browse_playlist_modal_save_description", "If a playlist with the same name exists already, it will be overwritten."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showSave = false }
                    Button("OK") {
                        var j = json
                        j["name"] = saveName
                        playlists.save(j)
                        showSave = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }

    private var summary: String? {
        guard items.count > 1, let p = playlists.assigned[target] else { return nil }
        switch p.mode {
        case .timer: return p.delay >= 0.01 ? "Changes every \(Int(p.delay) / 60) h \(Int(p.delay) % 60) min" : "Timer off"
        case .logon: return "Changes at every start of photon"
        case .daytime: return "Changes by time of day"
        case .dayOfWeek: return "Changes by day of week"
        case .never: return "Never changes on its own (Next Wallpaper still works)"
        }
    }

    @ViewBuilder private func itemView(_ i: Int, _ entry: [String: Any]) -> some View {
        let file = entry["file"] as? String ?? ""
        let item = state.item(file)
        VStack(spacing: 2) {
            Thumbnail(url: item?.preview, maxPixels: 240)
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topTrailing) {
                    Button { var l = items; l.remove(at: i); commit(items: l) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.borderless)
                    .help(t("ui_browse_playlist_button_remove", "Remove wallpaper"))
                }
            Text(item?.title ?? file).font(.caption2).lineLimit(1).frame(width: 96)
                // The item's saved property preset (UI "Choose preset"; applied on selection, PropertyPresets.swift).
                .contextMenu {
                    let current = entry["preset"] as? String ?? ""
                    Button((current.isEmpty ? "✓ " : "") + "No preset") { var l = items; l[i]["preset"] = nil; commit(items: l) }
                    ForEach(state.presets(of: file).map(\.name), id: \.self) { n in
                        Button((current == n ? "✓ " : "") + n) { var l = items; l[i]["preset"] = n; commit(items: l) }
                    }
                }
            HStack(spacing: 2) {
                Button { var l = items; l.swapAt(i, i - 1); commit(items: l) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(i == 0)
                slotLabel(i).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button { var l = items; l.swapAt(i, i + 1); commit(items: l) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(i == items.count - 1)
            }
        }
    }

    /// Time of day: the item's end (editable except for the last, which ends at midnight); day of week: its days.
    @ViewBuilder private func slotLabel(_ i: Int) -> some View {
        if mode == "daytime", let p = playlists.assigned[target], i < p.items.count {
            if i == items.count - 1 {
                Text("–24:00")
            } else {
                let minutes = Int((Double(p.items[i].daytimeEnd) * 1440).rounded())
                Menu("–" + String(format: "%02d:%02d", minutes / 60, minutes % 60)) {
                    ForEach(Array(stride(from: 30, to: 1440, by: 30)), id: \.self) { m in
                        Button(String(format: "%02d:%02d", m / 60, m % 60)) {
                            var l = items
                            l[i]["daytimeend"] = Double(m) / 1440
                            commit(items: l)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else if mode == "dayofweek", let p = playlists.assigned[target], i < p.items.count, i < 7 {
            Text(Self.dayRange(p.items, i))
        } else {
            Text("\(i + 1)")
        }
    }

    static func dayRange(_ items: [EnginePlaylist.Item], _ i: Int) -> String { PlaylistEditing.dayRange(items, i) }
}

/// `BrowsePlaylistSettingsModalCtrl`: change wallpaper (timing), timer hours / minutes, order, transition (and its
/// pool and time), and the timer-only options.
struct PlaylistSettingsSheet: View {
    let state: AppState
    @State var settings: [String: Any]
    let itemCount: Int
    let done: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, settings: [String: Any], itemCount: Int, done: @escaping ([String: Any]) -> Void) {
        self.state = state
        var s = settings
        // The dialog's own defaults: delay 60, transition true → "0", other non-strings → "-2", time 1000.
        if (s["delay"] as? NSNumber)?.doubleValue ?? 0 == 0 { s["delay"] = 60 }
        if let b = s["transition"] as? Bool { s["transition"] = b ? "0" : "-2" }
        if !(s["transition"] is String) { s["transition"] = "-2" }
        if !(s["transitiontime"] is NSNumber) { s["transitiontime"] = 1000 }
        _settings = State(initialValue: s)
        self.itemCount = itemCount
        self.done = done
    }

    private func t(_ key: String) -> String {
        let l = state.strings.label(key)
        return l == key || l.isEmpty ? SettingsView.transitionFallback(key.replacingOccurrences(of: "ui_browse_playlist_modal_settings_", with: "ui_browse_playlist_modal_settings_transition_")) : l
    }
    private func bool(_ k: String) -> Binding<Bool> {
        Binding(get: { settings[k] as? Bool ?? false }, set: { settings[k] = $0 })
    }
    private var mode: String { settings["mode"] as? String ?? "timer" }
    private var delay: Int { (settings["delay"] as? NSNumber)?.intValue ?? 60 }
    private var transitionValue: Int {
        switch settings["transition"] as? String {
        case "none": return -1
        case "random": return -3
        case let s?: return TransitionSettings.atoi(s)
        default: return -2
        }
    }

    var body: some View {
        Form {
            Picker(t("ui_browse_playlist_modal_settings_timing_label"), selection: Binding(get: { mode }, set: { settings["mode"] = $0 })) {
                ForEach([("logon", "ui_browse_playlist_modal_settings_timing_on_logon"), ("timer", "ui_browse_playlist_modal_settings_timing_on_timer"),
                         ("daytime", "ui_browse_playlist_modal_settings_timing_daytime"), ("dayofweek", "ui_browse_playlist_modal_settings_timing_dayofweek"),
                         ("never", "ui_browse_playlist_modal_settings_timing_never")], id: \.0) { Text(t($0.1)).tag($0.0) }
            }
            if mode == "timer" {
                HStack {
                    Stepper("\(t("ui_browse_playlist_modal_settings_timing_hours")) \(delay / 60)",
                            value: Binding(get: { delay / 60 }, set: { settings["delay"] = max($0, 0) * 60 + delay % 60 }), in: 0...999)
                    Stepper("\(t("ui_browse_playlist_modal_settings_timing_minutes")) \(delay % 60)",
                            value: Binding(get: { delay % 60 }, set: { settings["delay"] = (delay / 60) * 60 + min(max($0, 0), 59) }), in: 0...59)
                }
            }
            if mode != "daytime" && mode != "dayofweek" {
                Picker(t("ui_browse_playlist_modal_settings_order_label"),
                       selection: Binding(get: { settings["order"] as? String == "sorted" ? "sorted" : "random" }, set: { settings["order"] = $0 })) {
                    Text(t("ui_browse_playlist_modal_settings_order_random")).tag("random")
                    Text(t("ui_browse_playlist_modal_settings_order_sorted")).tag("sorted")
                }
            }
            if mode == "dayofweek" && itemCount > 7 {
                Text(t("ui_browse_playlist_modal_settings_day_of_week_warning_message")).font(.caption).foregroundStyle(.orange)
            }
            Picker(t("ui_browse_playlist_modal_settings_transition_enabled"), selection: Binding(get: { transitionValue }, set: { v in
                settings["transition"] = v == -1 ? "none" : v == -3 ? "random" : String(v)
            })) {
                ForEach(SettingsView.transitionOptions, id: \.1) { Text(t($0.0)).tag($0.1) }
            }
            if transitionValue == -3 {
                // transitionPoolToggle: absent pool = every effect.
                let pool = settings["transitionpool"] as? [String]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                    ForEach(SettingsView.transitionOptions.filter { $0.1 >= 0 }, id: \.1) { option in
                        Toggle(t(option.0), isOn: Binding(get: { pool?.contains(String(option.1)) ?? true }, set: { on in
                            var p = pool ?? SettingsView.transitionOptions.filter { $0.1 >= 0 }.map { String($0.1) }
                            p.removeAll { $0 == String(option.1) }
                            if on { p.append(String(option.1)) }
                            settings["transitionpool"] = p
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if transitionValue != -1 && transitionValue != -2 {
                Slider(value: Binding(get: { (settings["transitiontime"] as? NSNumber)?.doubleValue ?? 1000 },
                                      set: { settings["transitiontime"] = Int($0) }), in: 0...3000, step: 50) {
                    Text("\(t("ui_browse_playlist_modal_settings_transition_time")) \((settings["transitiontime"] as? NSNumber)?.intValue ?? 1000) ms")
                }
            }
            if mode == "timer" {
                Toggle(t("ui_browse_playlist_modal_settings_video_sequence"), isOn: bool("videosequence"))
                Toggle(t("ui_browse_playlist_modal_settings_update_on_pause"), isOn: bool("updateonpause"))
                Toggle(t("ui_browse_playlist_modal_settings_begin_first_wallpaper"), isOn: bool("beginfirst"))
                Toggle(t("ui_browse_playlist_modal_settings_intro_wallpaper"), isOn: bool("playintro"))
                    .disabled(!(settings["beginfirst"] as? Bool ?? false))
                    .padding(.leading, 16)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK") { done(settings); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}
