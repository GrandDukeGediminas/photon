#if os(Linux)
import CGtk3
import Combine
import CPhotonApp
import Foundation
import PhotonApp
import PhotonRender

/// The wallpaper browser (macOS BrowserView): the library grid with search and the unsupported filter on the left, the
/// selected wallpaper's details, display picker and properties on the right, the playlist panel and the playback bar
/// along the bottom. Double-click applies to every display; Apply with a display chosen applies to that one.
final class BrowserWindow {
    unowned let app: LinuxApp
    var state: AppState { app.state }
    let window: Widget
    private let flow: Widget
    private let countLabel: Widget
    private let detailBox: Widget
    private var search = ""
    private var showUnsupported = false
    private(set) var selection: String?
    /// Grid children by wallpaper id, with their badge labels.
    private var tiles: [String: (child: Widget, badge: Widget, image: Widget)] = [:]
    private var tileOrder: [String] = []
    private(set) var detail: DetailPane?
    private(set) var playlist: PlaylistPanel!
    private var playbackBar: PlaybackBar!
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var refresh = Debouncer(ms: 50) { [weak self] in self?.modelChanged() }
    private var lastItems: [String] = []

    init(app: LinuxApp) {
        self.app = app
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "photon")
        gtk_window_set_default_size(G(window), 1180, 760)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        let root = box(true, spacing: 0)
        gtk_container_add(G(window), root)

        // Library (left) | details (right)
        let paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        pack(root, paned, expand: true)
        let left = box(true, spacing: 0)
        let top = box(false, spacing: 8)
        margins(top, 8)
        let entry = gtk_search_entry_new()!
        gtk_entry_set_placeholder_text(G(entry), "Search title, tag or id")
        pack(top, entry, expand: true)
        let unsupported = gtk_check_button_new_with_label("Show unsupported")!
        pack(top, unsupported)
        pack(left, top)
        pack(left, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        flow = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(G(flow), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_activate_on_single_click(G(flow), 0)
        gtk_flow_box_set_homogeneous(G(flow), 1)
        gtk_flow_box_set_min_children_per_line(G(flow), 2)
        gtk_flow_box_set_max_children_per_line(G(flow), 12)
        gtk_flow_box_set_column_spacing(G(flow), 6)
        gtk_flow_box_set_row_spacing(G(flow), 6)
        gtk_widget_set_valign(flow, GTK_ALIGN_START)
        margins(flow, 8)
        pack(left, scrolled(flow), expand: true)
        pack(left, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        countLabel = label("", css: "photon-caption", xalign: 0.5)
        margins(countLabel, 4)
        pack(left, countLabel)
        gtk_paned_pack1(G(paned), left, 1, 0)
        detailBox = box(true, spacing: 0)
        gtk_widget_set_size_request(detailBox, 340, -1)
        gtk_paned_pack2(G(paned), detailBox, 0, 0)
        gtk_paned_set_position(G(paned), 800)

        pack(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        playlist = PlaylistPanel(browser: self)
        pack(root, playlist.widget)
        pack(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        playbackBar = PlaybackBar(app: app)
        pack(root, playbackBar.widget)

        on(entry, "search-changed") { [weak self] in
            guard let self else { return }
            self.search = String(cString: gtk_entry_get_text(G(entry)))
            self.applyFilter()
        }
        on(unsupported, "toggled") { [weak self] in
            guard let self else { return }
            self.showUnsupported = gtk_toggle_button_get_active(G(unsupported)) != 0
            self.applyFilter()
        }
        on(flow, "selected-children-changed") { [weak self] in self?.selectionChanged() }
        on1(flow, "child-activated") { [weak self] child in
            guard let self, let child else { return }
            let idx = Int(gtk_flow_box_child_get_index(child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
            guard self.tileOrder.indices.contains(idx) else { return }
            let id = self.tileOrder[idx]
            self.select(id)
            self.apply(id, display: nil)
        }
        onEvent(window, "delete-event") { [weak self] in
            gtk_widget_hide(self?.window)
            self?.app.browserClosed()
            return true // keep the window for the next open (the app lives in the status icon)
        }
        buildTiles()
        state.objectWillChange.sink { [weak self] in self?.refresh.poke() }.store(in: &subscriptions)
        // The playlists are their own observable object (macOS PlaylistPanel observes both).
        state.playlists.objectWillChange.sink { [weak self] in self?.refresh.poke() }.store(in: &subscriptions)
        let initial = state.wallpaper(forDisplay: AppState.allDisplays) ?? state.activeIDs.sorted().first
        if let initial { select(initial) } else { showDetail(nil) }
        gtk_widget_show_all(root)
        playlist.refresh()
    }

    /// `startupID`: a second launch's activation token (xdg-activation / startup notification), so the window manager
    /// lets the running instance raise its window.
    func present(startupID: String? = nil) {
        gtk_widget_show_all(window)
        detail?.updateVisibility()
        if let id = startupID, !id.isEmpty { gtk_window_set_startup_id(G(window), id) }
        gtk_window_present(G(window))
    }

    var filtered: [WallpaperItem] {
        state.items.filter { item in
            (showUnsupported || item.unsupportedReason == nil)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
                    || item.tags.contains { $0.localizedCaseInsensitiveContains(search) } || item.id == search)
        }
    }

    // MARK: grid

    private func buildTiles() {
        removeChildren(flow)
        tiles = [:]
        tileOrder = state.items.map(\.id)
        lastItems = tileOrder
        for item in state.items {
            let tile = box(true, spacing: 4)
            addClass(tile, "photon-tile")
            let overlay = gtk_overlay_new()!
            let image = gtk_image_new_from_icon_name("image-x-generic", GTK_ICON_SIZE_DIALOG)!
            gtk_widget_set_size_request(image, 168, 168)
            gtk_container_add(G(overlay), image)
            let badge = label("")
            gtk_widget_set_halign(badge, GTK_ALIGN_END)
            gtk_widget_set_valign(badge, GTK_ALIGN_START)
            margins(badge, 6)
            gtk_overlay_add_overlay(G(overlay), badge)
            pack(tile, overlay)
            let title = label(item.title, css: "photon-caption", xalign: 0)
            gtk_label_set_ellipsize(G(title), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(G(title), 20)
            gtk_label_set_lines(G(title), 2)
            pack(tile, title)
            if item.unsupportedReason != nil { gtk_widget_set_opacity(overlay, 0.4) }
            gtk_widget_set_tooltip_text(tile, item.unsupportedReason ?? item.title)
            gtk_flow_box_insert(G(flow), tile, -1)
            let child = gtk_widget_get_parent(tile)!
            tiles[item.id] = (child, badge, image)
            if let preview = item.preview { Thumbnails.load(preview.path, size: (168, 168), into: image) }
        }
        updateBadges()
        applyFilter()
    }

    private func applyFilter() {
        let visible = Set(filtered.map(\.id))
        for (id, t) in tiles { gtk_widget_set_visible(t.child, visible.contains(id) ? 1 : 0) }
        gtk_label_set_text(G(countLabel), "\(visible.count) of \(state.items.count) wallpapers · double-click to apply to all displays")
    }

    private func updateBadges() {
        let active = state.activeIDs
        for (id, t) in tiles {
            removeClass(t.badge, "photon-active-badge"); removeClass(t.badge, "photon-failed-badge")
            if active.contains(id) {
                gtk_label_set_text(G(t.badge), "✓"); addClass(t.badge, "photon-active-badge"); gtk_widget_show(t.badge)
            } else if state.errors[id] != nil {
                gtk_label_set_text(G(t.badge), "!"); addClass(t.badge, "photon-failed-badge"); gtk_widget_show(t.badge)
            } else {
                gtk_label_set_text(G(t.badge), ""); gtk_widget_hide(t.badge)
            }
        }
    }

    private var selecting = false
    private func selectionChanged() {
        guard !selecting, let list = gtk_flow_box_get_selected_children(G(flow)) else { return }
        defer { g_list_free(list) }
        guard let child = list.pointee.data else { return }
        let idx = Int(gtk_flow_box_child_get_index(child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
        guard tileOrder.indices.contains(idx), tileOrder[idx] != selection else { return }
        selection = tileOrder[idx]
        showDetail(selection)
        playlist.refresh()
    }

    func select(_ id: String) {
        guard let t = tiles[id] else { return }
        selecting = true
        gtk_flow_box_select_child(G(flow), G(t.child))
        selecting = false
        if selection != id {
            selection = id
            showDetail(id)
            playlist?.refresh()
        }
    }

    func apply(_ id: String, display: String?) {
        state.apply(id, display: display)
    }

    private func showDetail(_ id: String?) {
        removeChildren(detailBox)
        detail = nil
        guard let id, let item = state.item(id) else {
            let l = label("Select a wallpaper", css: "photon-dim", xalign: 0.5)
            gtk_widget_set_valign(l, GTK_ALIGN_CENTER)
            pack(detailBox, l, expand: true)
            gtk_widget_show_all(detailBox)
            return
        }
        let d = DetailPane(app: app, item: item)
        detail = d
        pack(detailBox, d.widget, expand: true)
        gtk_widget_show_all(detailBox)
        d.updateVisibility()
    }

    private func modelChanged() {
        if state.items.map(\.id) != lastItems {
            buildTiles()
            if let s = selection { select(s) }
        }
        updateBadges()
        detail?.refresh()
        playlist.refresh()
        playbackBar.refresh()
    }

    /// The tile widget of a wallpaper (self-test).
    func tile(_ id: String) -> Widget? { tiles[id]?.child }
}

/// Preview images decoded off the main thread.
enum Thumbnails {
    static let queue = DispatchQueue(label: "photon.thumbnails", qos: .userInitiated, attributes: .concurrent)

    static func load(_ path: String, size: (Int32, Int32), into image: Widget) {
        g_object_ref(raw(image))
        queue.async {
            let pb = Pixbufs.load(path, width: size.0, height: size.1, fill: true)
            onMain {
                if let pb {
                    gtk_image_set_from_pixbuf(G(image), pb)
                    g_object_unref(UnsafeMutableRawPointer(pb))
                }
                g_object_unref(raw(image))
            }
        }
    }
}

/// The selected wallpaper: preview, title, display picker and Apply, load errors, the general properties ("Wallpaper")
/// and the project's own properties with presets and Reset (macOS DetailView).
final class DetailPane {
    unowned let app: LinuxApp
    var state: AppState { app.state }
    let item: WallpaperItem
    let widget: Widget
    /// The pane's content (unscrolled), for full-height snapshots.
    let content: Widget
    private let showing: Widget
    private let errorLabel: Widget
    private var displayCombo: Combo?
    private(set) var general: PropertiesPanel?
    private(set) var properties: PropertiesPanel?
    private var resetButton: Widget?

    init(app: LinuxApp, item: WallpaperItem) {
        self.app = app
        self.item = item
        content = box(true, spacing: 10)
        margins(content, 14)
        widget = scrolled(content)
        let image = gtk_image_new_from_icon_name("image-x-generic", GTK_ICON_SIZE_DIALOG)!
        gtk_widget_set_size_request(image, 312, 176)
        pack(content, image)
        if let p = item.preview { Thumbnails.load(p.path, size: (312, 176), into: image) }
        let title = label(item.title, css: "photon-title", wrap: true)
        gtk_label_set_selectable(G(title), 1)
        pack(content, title)
        let sub = label("\(item.type.isEmpty ? "preset" : item.type) · \(item.id)", css: "photon-dim", xalign: 0)
        gtk_label_set_selectable(G(sub), 1)
        pack(content, sub)
        showing = label("", css: "photon-caption", wrap: true)
        errorLabel = label("", css: "photon-error", wrap: true)
        let state = app.state
        if let reason = item.unsupportedReason {
            pack(content, label("⚠ " + reason, css: "photon-warning", wrap: true))
        } else {
            let row = box(false, spacing: 6)
            let combo = Combo([(AppState.allDisplays, "All displays")] + state.wallpaperTargets.map { ($0.id, $0.name) }, selected: AppState.allDisplays) { _ in }
            displayCombo = combo
            pack(row, combo.widget, expand: true)
            let apply = button("Apply") { [weak self] in
                guard let self else { return }
                let target = self.displayCombo?.selected ?? AppState.allDisplays
                self.app.browser?.apply(item.id, display: target == AppState.allDisplays ? nil : target)
            }
            gtk_widget_set_can_default(apply, 1)
            pack(row, apply)
            pack(content, row)
            pack(content, showing)
        }
        pack(content, errorLabel)
        let generalSpecs = Library.generalProperties(for: item, strings: state.strings)
        if !generalSpecs.isEmpty && item.unsupportedReason == nil {
            pack(content, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            pack(content, label("Wallpaper", css: "photon-section"))
            let g = PropertiesPanel(specs: generalSpecs, values: { [weak app] in app?.state.generalValues(of: item.id) ?? [:] },
                                    set: { [weak app] k, v in app?.state.setGeneral(k, to: v, of: item.id) })
            general = g
            pack(content, g.widget)
        }
        let specs = Library.properties(for: item, strings: state.strings)
        if !specs.isEmpty {
            pack(content, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            let header = box(false, spacing: 6)
            pack(header, label("Properties", css: "photon-section"), expand: true)
            let presets = gtk_button_new_with_label("Presets ▾")!
            on(presets, "clicked") { [weak self] in self?.presetMenu(presets, specs: specs) }
            pack(header, presets)
            let reset = button("Reset") { [weak app] in app?.state.resetProperties(of: item.id) }
            resetButton = reset
            pack(header, reset)
            pack(content, header)
            let p = PropertiesPanel(specs: specs, values: { [weak app] in app.map { $0.state.values(specs, of: item.id) } ?? [:] },
                                    set: { [weak app] k, v in app?.state.setProperty(k, to: v, of: item.id) })
            properties = p
            pack(content, p.widget)
        }
        refresh()
    }

    /// Saved property presets (`general.wpresets`, PropertyPresets.swift, docs/re/09 §9.6).
    private func presetMenu(_ anchor: Widget, specs: [PropertySpec]) {
        let id = item.id
        let names = state.presets(of: id).map(\.name)
        var entries: [(String, (() -> Void)?)] = names.map { n in (n, { [weak app] in app?.state.loadPreset(named: n, of: id) }) }
        if !names.isEmpty { entries.append(("---", nil)) }
        entries.append(("Save Current…", { [weak self] in self?.savePreset(specs: specs, existing: names) }))
        for n in names { entries.append(("Delete “\(n)”", { [weak app] in app?.state.deletePreset(named: n, of: id) })) }
        popupMenu(entries, at: anchor)
    }

    func savePreset(specs: [PropertySpec], existing: [String], name preset: String? = nil) {
        let save = { [weak self] (n: String) in
            guard let self else { return }
            let v = self.state.values(specs, of: self.item.id).merging(self.state.generalValues(of: self.item.id)) { a, _ in a }
            self.state.savePreset(named: n, of: self.item.id, values: v)
        }
        if let preset { save(preset); return }
        Prompt.text(parent: app.browser?.window, title: "Save Preset",
                    message: existing.isEmpty ? "Name of the preset." : "A preset with the same name is updated.") { name in
            if let name, !name.isEmpty { save(name) }
        }
    }

    func refresh() {
        let state = self.state
        let on = state.wallpaperTargets.filter { state.wallpaper(forDisplay: $0.id) == item.id }
        gtk_label_set_text(G(showing), on.isEmpty ? "" : "Showing on " + on.map(\.name).joined(separator: ", "))
        gtk_widget_set_visible(showing, on.isEmpty ? 0 : 1)
        let err = state.errors[item.id]
        gtk_label_set_text(G(errorLabel), err.map { "Failed to load: \($0)" } ?? "")
        gtk_widget_set_visible(errorLabel, err == nil ? 0 : 1)
        if let resetButton { gtk_widget_set_sensitive(resetButton, state.overrides[item.id] == nil ? 0 : 1) }
        general?.refresh()
        properties?.refresh()
    }

    func updateVisibility() {
        general?.updateVisibility()
        properties?.updateVisibility()
        refresh()
    }

    func chooseDisplay(_ id: String) { displayCombo?.select(id) }
}

/// The playback controls along the bottom (macOS PlaybackBar): pause, mute, master volume, post-processing, reload, settings.
final class PlaybackBar {
    unowned let app: LinuxApp
    let widget: Widget
    private let pause: Widget
    private let mute: Widget
    private let volume: Widget
    private var volumeHandler: gulong = 0
    private var muteHandler: gulong = 0
    private let post: Combo

    init(app: LinuxApp) {
        self.app = app
        widget = box(false, spacing: 12)
        margins(widget, 8)
        pause = gtk_button_new_with_label("Pause")
        on(pause, "clicked") { [weak app] in app?.state.paused.toggle() }
        pack(widget, pause)
        mute = gtk_toggle_button_new_with_label("Mute")
        pack(widget, mute)
        volume = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01)
        gtk_scale_set_draw_value(G(volume), 0)
        gtk_widget_set_size_request(volume, 140, -1)
        gtk_widget_set_tooltip_text(volume, "Master volume, on top of each wallpaper's own volume")
        pack(widget, volume)
        post = Combo(SettingsCatalog.postProcessingLabels, selected: app.state.postProcessing.rawValue) { [weak app] v in
            if let p = SceneRenderer.PostProcessing(rawValue: v) { app?.state.postProcessing = p }
        }
        gtk_widget_set_tooltip_text(post.widget, "Wallpaper Engine's post-processing quality. Ultra runs the HDR bloom path on HDR scenes.")
        let settings = button("Settings…") { [weak app] in app?.showSettings() }
        packEnd(widget, settings)
        packEnd(widget, button("Reload library") { [weak app] in app?.state.reloadLibrary() })
        packEnd(widget, button("Workshop…") { [weak app] in app?.showWorkshop() })
        packEnd(widget, post.widget)
        packEnd(widget, label("Post-processing"))
        muteHandler = on(mute, "toggled") { [weak self] in
            guard let self else { return }
            self.app.state.muted = gtk_toggle_button_get_active(G(self.mute)) != 0
        }
        volumeHandler = on(volume, "value-changed") { [weak self] in
            guard let self else { return }
            self.app.state.volume = gtk_range_get_value(G(self.volume))
        }
        refresh()
    }

    func refresh() {
        let s = app.state
        gtk_button_set_label(G(pause), s.paused ? "Play" : "Pause")
        quietly(mute, [muteHandler]) { gtk_toggle_button_set_active(G(mute), s.muted ? 1 : 0) }
        quietly(volume, [volumeHandler]) { gtk_range_set_value(G(volume), s.volume) }
        gtk_widget_set_sensitive(volume, s.muted ? 0 : 1)
        post.select(s.postProcessing.rawValue)
    }
}

/// A modal text prompt.
enum Prompt {
    static func text(parent: Widget?, title: String, message: String, initial: String = "", done: @escaping (String?) -> Void) {
        let d = photon_dialog_new(parent.map { G($0) }, title, "Save")!
        let area = gtk_dialog_get_content_area(G(d))!
        margins(area, 12)
        gtk_box_set_spacing(G(area), 8)
        pack(area, label(message, wrap: true))
        let entry = gtk_entry_new()!
        gtk_entry_set_text(G(entry), initial)
        gtk_entry_set_activates_default(G(entry), 1)
        pack(area, entry)
        gtk_widget_show_all(d)
        Prompt.current = (d, entry)
        on1(d, "response") { resp in
            let r = Int32(truncatingIfNeeded: Int(bitPattern: resp))
            let text = String(cString: gtk_entry_get_text(G(entry))).trimmingCharacters(in: .whitespaces)
            Prompt.current = nil
            gtk_widget_destroy(d)
            done(r == 1 ? text : nil)
        }
    }

    /// The open prompt (self-test answers it).
    nonisolated(unsafe) static var current: (dialog: Widget, entry: Widget)?

    static func answer(_ text: String) {
        guard let (d, entry) = current else { return }
        gtk_entry_set_text(G(entry), text)
        gtk_dialog_response(G(d), 1)
    }
}
#endif
