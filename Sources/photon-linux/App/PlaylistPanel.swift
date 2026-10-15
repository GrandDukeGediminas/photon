#if os(Linux)
import CGtk3
import CPhotonApp
import Foundation
import PhotonApp
import PhotonRender

/// The browser's playlist panel (macOS PlaylistPanel, after the engine UI's scripts.js): the playlist of the chosen
/// display edited in place (every change is sent at once, like the UI's `y()` → `selectPlaylist`), with Add / Load /
/// Save / Configure / Clear / Next, per-item preset (right-click), reordering, removal and, for time of day, each
/// wallpaper's end time.
final class PlaylistPanel {
    unowned let browser: BrowserWindow
    var state: AppState { browser.state }
    let widget: Widget
    private let header: Widget
    private let itemsBox: Widget
    private let summary: Widget
    private var target = AppState.allDisplays
    private let displays: Combo
    private var buttons: [String: Widget] = [:]

    init(browser: BrowserWindow) {
        self.browser = browser
        widget = box(true, spacing: 6)
        margins(widget, 8)
        let top = box(false, spacing: 8)
        header = label("Playlist", css: "photon-section")
        pack(top, header)
        var pick: (String) -> Void = { _ in }
        displays = Combo([], selected: nil) { pick($0) }
        pack(top, displays.widget)
        pack(widget, top)
        itemsBox = box(false, spacing: 8)
        let sw = scrolled(itemsBox, h: true, v: false)
        gtk_widget_set_size_request(sw, -1, 128)
        pack(widget, sw)
        summary = label("", css: "photon-caption")
        pack(widget, summary)
        let t = { [unowned browser] (k: String, f: String) in browser.app.label(k, f) }
        let defs: [(String, String, () -> Void)] = [
            ("add", t("ui_browse_playlist_button_add", "Add wallpaper"), { [weak self] in self?.addSelection() }),
            ("load", t("ui_browse_playlist_button_load", "Load") + " ▾", { [weak self] in self?.loadMenu() }),
            ("save", t("ui_browse_playlist_button_save", "Save"), { [weak self] in self?.saveDialog() }),
            ("configure", t("ui_browse_playlist_button_configure", "Configure"), { [weak self] in self?.configure() }),
            ("clear", t("ui_browse_playlist_button_clear", "Clear"), { [weak self] in self?.commit(items: []) }),
            ("next", "Next", { [weak self] in
                guard let self else { return }
                self.state.playlists.next(display: self.target == AppState.allDisplays ? nil : self.target)
            }),
        ]
        for (key, text, action) in defs.reversed() {
            let b = button(text, action)
            buttons[key] = b
            packEnd(top, b)
        }
        // The display picker changes the edited playlist (the combo's own handler, blocked while refresh() fills it).
        pick = { [weak self] id in
            guard let self else { return }
            self.target = id
            self.refresh()
        }
    }

    private func t(_ key: String, _ fallback: String) -> String { browser.app.label(key, fallback) }

    /// The display's playlist in the engine's JSON form, or an empty one with the UI's defaults.
    var json: [String: Any] {
        state.playlists.assigned[target]?.json ?? state.playlists.drafts[target]
            ?? ["name": "", "items": [Any](), "settings": PlaylistEditing.defaultSettings]
    }

    var items: [[String: Any]] {
        (json["items"] as? [Any] ?? []).map { ($0 as? String).map { ["file": $0] } ?? ($0 as? [String: Any] ?? [:]) }
    }

    private var settings: [String: Any] { json["settings"] as? [String: Any] ?? PlaylistEditing.defaultSettings }
    private var mode: String { settings["mode"] as? String ?? "timer" }

    func commit(items newItems: [[String: Any]]? = nil, settings newSettings: [String: Any]? = nil) {
        let s = newSettings ?? settings
        let out = PlaylistEditing.cleanItems(newItems ?? items, mode: s["mode"] as? String)
        state.playlists.assign(["name": json["name"] ?? "", "settings": s, "items": out], to: target)
    }

    func addSelection() {
        guard let id = browser.selection, state.item(id)?.unsupportedReason == nil else { return }
        if mode == "dayofweek", items.count >= 7 { return }
        commit(items: items + [["file": id]])
    }

    private func loadMenu() {
        let pl = state.playlists!
        var entries: [(String, (() -> Void)?)] = []
        if pl.saved.isEmpty { entries.append((t("ui_browse_playlist_empty", "You have not created any playlists yet."), nil)) }
        for p in pl.saved {
            let json = p.json
            entries.append((p.name, { [weak self] in guard let self else { return }; self.state.playlists.assign(json, to: self.target) }))
        }
        if !pl.saved.isEmpty {
            entries.append(("---", nil))
            for p in pl.saved {
                let name = p.name
                entries.append((t("ui_browse_playlist_modal_delete", "Delete") + " “\(name)”", { [weak self] in self?.state.playlists.delete(named: name) }))
            }
        }
        popupMenu(entries, at: buttons["load"])
    }

    func saveDialog(name: String? = nil) {
        let save = { [weak self] (n: String) in
            guard let self else { return }
            var j = self.json
            j["name"] = n
            self.state.playlists.save(j)
        }
        if let name { save(name); return }
        Prompt.text(parent: browser.window, title: t("ui_browse_playlist_modal_save_header", "Save Playlist"),
                    message: t("ui_browse_playlist_modal_save_description", "If a playlist with the same name exists already, it will be overwritten."),
                    initial: json["name"] as? String ?? "") { n in
            if let n, !n.isEmpty { save(n) }
        }
    }

    func configure() {
        PlaylistSettingsDialog.show(app: browser.app, parent: browser.window, settings: settings, itemCount: items.count) { [weak self] new in
            guard let self else { return }
            var list = self.items
            if (new["mode"] as? String) == "dayofweek", list.count > 7 { list = Array(list.prefix(7)) }
            self.commit(items: list, settings: new)
        }
    }

    func refresh() {
        let st = state
        displays.replace([(AppState.allDisplays, "All displays")] + st.wallpaperTargets.map { ($0.id, $0.name) }, selected: target)
        let list = items
        gtk_label_set_text(G(header), list.count > 1 ? "\(t("ui_browse_playlist_header", "Playlist")) (\(list.count))" : t("ui_browse_playlist_header", "Playlist"))
        let sel = browser.selection
        gtk_widget_set_sensitive(buttons["add"], sel != nil && st.item(sel ?? "")?.unsupportedReason == nil ? 1 : 0)
        gtk_widget_set_sensitive(buttons["save"], list.count >= 2 ? 1 : 0)
        gtk_widget_set_sensitive(buttons["configure"], list.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(buttons["clear"], list.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(buttons["next"], st.playlists.offersNext ? 1 : 0)
        removeChildren(itemsBox)
        if list.isEmpty {
            pack(itemsBox, label("Select a wallpaper and choose Add wallpaper. A playlist needs two or more.", css: "photon-dim"))
        }
        for (i, entry) in list.enumerated() { pack(itemsBox, itemView(i, entry, count: list.count)) }
        gtk_widget_show_all(itemsBox)
        gtk_label_set_text(G(summary), summaryText ?? "")
    }

    private var summaryText: String? {
        guard items.count > 1, let p = state.playlists.assigned[target] else { return nil }
        switch p.mode {
        case .timer: return p.delay >= 0.01 ? "Changes every \(Int(p.delay) / 60) h \(Int(p.delay) % 60) min" : "Timer off"
        case .logon: return "Changes at every start of photon"
        case .daytime: return "Changes by time of day"
        case .dayOfWeek: return "Changes by day of week"
        case .never: return "Never changes on its own (Next Wallpaper still works)"
        }
    }

    private func itemView(_ i: Int, _ entry: [String: Any], count: Int) -> Widget {
        let file = entry["file"] as? String ?? ""
        let item = state.item(file)
        let v = box(true, spacing: 2)
        addClass(v, "photon-playlist-item")
        let overlay = gtk_overlay_new()!
        let image = gtk_image_new_from_icon_name("image-x-generic", GTK_ICON_SIZE_DND)!
        gtk_widget_set_size_request(image, 96, 60)
        gtk_container_add(G(overlay), image)
        if let p = item?.preview { Thumbnails.load(p.path, size: (96, 60), into: image) }
        let remove = button("✕") { [weak self] in
            guard let self else { return }
            var l = self.items
            l.remove(at: i)
            self.commit(items: l)
        }
        gtk_button_set_relief(G(remove), GTK_RELIEF_NONE)
        gtk_widget_set_tooltip_text(remove, t("ui_browse_playlist_button_remove", "Remove wallpaper"))
        gtk_widget_set_halign(remove, GTK_ALIGN_END)
        gtk_widget_set_valign(remove, GTK_ALIGN_START)
        gtk_overlay_add_overlay(G(overlay), remove)
        // Right-click: the item's saved property preset (UI "Choose preset"; applied on selection).
        let events = gtk_event_box_new()!
        gtk_container_add(G(events), overlay)
        onEvent(events, "button-press-event") { [weak self] in
            self?.presetMenu(i, file: file, current: entry["preset"] as? String ?? "", anchor: events)
            return true
        }
        pack(v, events)
        let title = label(item?.title ?? file, css: "photon-caption")
        gtk_label_set_ellipsize(G(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(G(title), 12)
        if let preset = entry["preset"] as? String, !preset.isEmpty { gtk_widget_set_tooltip_text(title, "Preset: \(preset)") }
        pack(v, title)
        let nav = box(false, spacing: 2)
        let left = button("◀") { [weak self] in
            guard let self else { return }
            var l = self.items; l.swapAt(i, i - 1); self.commit(items: l)
        }
        gtk_button_set_relief(G(left), GTK_RELIEF_NONE)
        gtk_widget_set_sensitive(left, i == 0 ? 0 : 1)
        let right = button("▶") { [weak self] in
            guard let self else { return }
            var l = self.items; l.swapAt(i, i + 1); self.commit(items: l)
        }
        gtk_button_set_relief(G(right), GTK_RELIEF_NONE)
        gtk_widget_set_sensitive(right, i == count - 1 ? 0 : 1)
        pack(nav, left)
        pack(nav, slotWidget(i, count: count), expand: true)
        pack(nav, right)
        pack(v, nav)
        return v
    }

    private func presetMenu(_ i: Int, file: String, current: String, anchor: Widget) {
        var entries: [(String, (() -> Void)?)] = [((current.isEmpty ? "✓ " : "") + "No preset", { [weak self] in
            guard let self else { return }
            var l = self.items; l[i]["preset"] = nil; self.commit(items: l)
        })]
        for n in state.presets(of: file).map(\.name) {
            entries.append(((current == n ? "✓ " : "") + n, { [weak self] in
                guard let self else { return }
                var l = self.items; l[i]["preset"] = n; self.commit(items: l)
            }))
        }
        popupMenu(entries, at: anchor)
    }

    /// Time of day: the item's end (a menu of half hours, except for the last, which ends at midnight); day of week: its days.
    private func slotWidget(_ i: Int, count: Int) -> Widget {
        if mode == "daytime", let p = state.playlists.assigned[target], i < p.items.count {
            if i == count - 1 { return label("–24:00", css: "photon-caption", xalign: 0.5) }
            let minutes = Int((Double(p.items[i].daytimeEnd) * 1440).rounded())
            let b = gtk_button_new_with_label("–" + String(format: "%02d:%02d", minutes / 60, minutes % 60))!
            gtk_button_set_relief(G(b), GTK_RELIEF_NONE)
            on(b, "clicked") { [weak self] in
                guard let self else { return }
                popupMenu(stride(from: 30, to: 1440, by: 30).map { m in
                    (String(format: "%02d:%02d", m / 60, m % 60), { [weak self] in
                        guard let self else { return }
                        var l = self.items
                        l[i]["daytimeend"] = Double(m) / 1440
                        self.commit(items: l)
                    })
                }, at: b)
            }
            return b
        }
        if mode == "dayofweek", let p = state.playlists.assigned[target], i < p.items.count, i < 7 {
            return label(PlaylistEditing.dayRange(p.items, i), css: "photon-caption", xalign: 0.5)
        }
        return label("\(i + 1)", css: "photon-caption", xalign: 0.5)
    }

    func setTarget(_ id: String) {
        target = id
        refresh()
    }
}

/// `BrowsePlaylistSettingsModalCtrl` (macOS PlaylistSettingsSheet): when to change, timer hours and minutes, order,
/// transition with its pool and time, and the timer-only options.
enum PlaylistSettingsDialog {
    nonisolated(unsafe) static var current: (dialog: Widget, settings: () -> [String: Any], set: (String, Any) -> Void)?

    static func show(app: LinuxApp, parent: Widget, settings initial: [String: Any], itemCount: Int, done: @escaping ([String: Any]) -> Void) {
        var s = PlaylistEditing.dialogSettings(initial)
        let t = { (key: String) -> String in
            let l = app.state.strings.label(key)
            return l == key || l.isEmpty
                ? SettingsCatalog.transitionFallback(key.replacingOccurrences(of: "ui_browse_playlist_modal_settings_",
                                                                             with: "ui_browse_playlist_modal_settings_transition_")) : l
        }
        let d = photon_dialog_new(G(parent), "Playlist Settings", "OK")!
        gtk_window_set_default_size(G(d), 520, 460)
        let area = gtk_dialog_get_content_area(G(d))!
        margins(area, 12)
        gtk_box_set_spacing(G(area), 8)
        let grid = box(true, spacing: 8)
        pack(area, grid, expand: true)
        var rebuild: () -> Void = {}
        rebuild = {
            removeChildren(grid)
            let mode = s["mode"] as? String ?? "timer"
            let delay = (s["delay"] as? NSNumber)?.intValue ?? 60
            func row(_ text: String, _ w: Widget) {
                let r = box(false, spacing: 8)
                pack(r, label(text), expand: true)
                pack(r, w)
                pack(grid, r)
            }
            let modes = [("logon", "ui_browse_playlist_modal_settings_timing_on_logon"), ("timer", "ui_browse_playlist_modal_settings_timing_on_timer"),
                         ("daytime", "ui_browse_playlist_modal_settings_timing_daytime"),
                         ("dayofweek", "ui_browse_playlist_modal_settings_timing_dayofweek"), ("never", "ui_browse_playlist_modal_settings_timing_never")]
            let modeCombo = Combo(modes.map { ($0.0, t($0.1)) }, selected: mode) { v in s["mode"] = v; onMain { rebuild() } }
            objc_keep(grid, modeCombo)
            row(t("ui_browse_playlist_modal_settings_timing_label"), modeCombo.widget)
            if mode == "timer" {
                let hours = gtk_spin_button_new_with_range(0, 999, 1)!
                gtk_spin_button_set_value(G(hours), Double(delay / 60))
                let minutes = gtk_spin_button_new_with_range(0, 59, 1)!
                gtk_spin_button_set_value(G(minutes), Double(delay % 60))
                let update = {
                    s["delay"] = Int(gtk_spin_button_get_value(G(hours))) * 60 + Int(gtk_spin_button_get_value(G(minutes)))
                }
                on(hours, "value-changed", update)
                on(minutes, "value-changed", update)
                row(t("ui_browse_playlist_modal_settings_timing_hours"), hours)
                row(t("ui_browse_playlist_modal_settings_timing_minutes"), minutes)
            }
            if mode != "daytime" && mode != "dayofweek" {
                let order = Combo([("random", t("ui_browse_playlist_modal_settings_order_random")), ("sorted", t("ui_browse_playlist_modal_settings_order_sorted"))],
                                  selected: s["order"] as? String == "sorted" ? "sorted" : "random") { v in s["order"] = v }
                objc_keep(grid, order)
                row(t("ui_browse_playlist_modal_settings_order_label"), order.widget)
            }
            if mode == "dayofweek" && itemCount > 7 {
                pack(grid, label(t("ui_browse_playlist_modal_settings_day_of_week_warning_message"), css: "photon-warning", wrap: true))
            }
            let tv = PlaylistEditing.transitionValue(s)
            let trans = Combo(SettingsCatalog.transitionOptions.map { (String($0.1), t($0.0)) }, selected: String(tv)) { v in
                let n = Int(v) ?? -2
                s["transition"] = n == -1 ? "none" : n == -3 ? "random" : String(n)
                onMain { rebuild() }
            }
            objc_keep(grid, trans)
            row(t("ui_browse_playlist_modal_settings_transition_enabled"), trans.widget)
            if tv == -3 {
                // transitionPoolToggle: absent pool = every effect.
                let flow = gtk_flow_box_new()!
                gtk_flow_box_set_selection_mode(G(flow), GTK_SELECTION_NONE)
                gtk_flow_box_set_max_children_per_line(G(flow), 4)
                let all = SettingsCatalog.transitionOptions.filter { $0.1 >= 0 }
                for option in all {
                    let c = gtk_check_button_new_with_label(t(option.0))!
                    let pool = s["transitionpool"] as? [String]
                    gtk_toggle_button_set_active(G(c), (pool?.contains(String(option.1)) ?? true) ? 1 : 0)
                    on(c, "toggled") {
                        var p = (s["transitionpool"] as? [String]) ?? all.map { String($0.1) }
                        p.removeAll { $0 == String(option.1) }
                        if gtk_toggle_button_get_active(G(c)) != 0 { p.append(String(option.1)) }
                        s["transitionpool"] = p
                    }
                    gtk_flow_box_insert(G(flow), c, -1)
                }
                pack(grid, flow)
            }
            if tv != -1 && tv != -2 {
                let time = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 3000, 50)!
                gtk_widget_set_size_request(time, 220, -1)
                gtk_range_set_value(G(time), (s["transitiontime"] as? NSNumber)?.doubleValue ?? 1000)
                on(time, "value-changed") { s["transitiontime"] = Int((gtk_range_get_value(G(time)) / 50).rounded() * 50) }
                row(t("ui_browse_playlist_modal_settings_transition_time") + " (ms)", time)
            }
            if mode == "timer" {
                for (key, text) in [("videosequence", "ui_browse_playlist_modal_settings_video_sequence"),
                                    ("updateonpause", "ui_browse_playlist_modal_settings_update_on_pause"),
                                    ("beginfirst", "ui_browse_playlist_modal_settings_begin_first_wallpaper"),
                                    ("playintro", "ui_browse_playlist_modal_settings_intro_wallpaper")] {
                    let c = gtk_check_button_new_with_label(t(text))!
                    gtk_toggle_button_set_active(G(c), (s[key] as? Bool ?? (s[key] as? NSNumber)?.boolValue ?? false) ? 1 : 0)
                    if key == "playintro" {
                        gtk_widget_set_margin_start(c, 16)
                        gtk_widget_set_sensitive(c, (s["beginfirst"] as? Bool ?? false) ? 1 : 0)
                    }
                    on(c, "toggled") {
                        s[key] = gtk_toggle_button_get_active(G(c)) != 0
                        if key == "beginfirst" { onMain { rebuild() } }
                    }
                    pack(grid, c)
                }
            }
            gtk_widget_show_all(grid)
        }
        rebuild()
        current = (d, { s }, { k, v in s[k] = v; rebuild() })
        on1(d, "response") { resp in
            let r = Int32(truncatingIfNeeded: Int(bitPattern: resp))
            current = nil
            gtk_widget_destroy(d)
            if r == 1 { done(s) }
        }
        gtk_widget_show_all(d)
    }

    /// Sets values in the open dialog and confirms it (self-test).
    static func confirm(_ values: [String: Any]) -> Bool {
        guard let c = current else { return false }
        for (k, v) in values { c.set(k, v) }
        gtk_dialog_response(G(c.dialog), 1)
        return true
    }
}
#endif
