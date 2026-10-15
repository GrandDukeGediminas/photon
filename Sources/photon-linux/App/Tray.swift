#if os(Linux)
import CGtk3
import CPhotonApp
import Foundation
import PhotonApp

/// The status icon (StatusNotifierItem, CPhotonApp/photon_tray.c) and its menu, the macOS menu-bar menu
/// (`AppController.menuNeedsUpdate`): the wallpapers shown, Next / Previous Wallpaper and Saved Playlists while a playlist
/// runs, Browse, Settings, Pause, Mute, what the playback rules are doing, Quit. A left click opens the browser.
final class Tray {
    unowned let app: LinuxApp
    private var tray: OpaquePointer?
    private(set) var visible = false
    /// Menu actions by item id (rebuilt with the menu).
    private var actions: [Int32: () -> Void] = [:]
    /// The last menu, for the self-test: (id, parent, label, enabled, checked).
    private(set) var entries: [(id: Int32, parent: Int32, label: String, enabled: Bool, checked: Bool)] = []

    init(app: LinuxApp) {
        self.app = app
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tray = photon_tray_new("photon2", "photon", "photon2", Self.iconFile, { ctx, event, item in
            let t = Unmanaged<Tray>.fromOpaque(ctx!).takeUnretainedValue()
            t.event(event, item)
        }, ctx)
        if tray == nil { print("photon: no status icon (no session bus)") }
        rebuild()
    }

    deinit { photon_tray_free(tray) }

    var busName: String { tray.map { String(cString: photon_tray_bus_name($0)) } ?? "" }

    /// The icon for hosts that cannot read the icon theme (IconPixmap): the installed PNG, else the one next to the binary.
    static var iconFile: String? {
        let exe = URL(fileURLWithPath: LinuxApp.selfPath).deletingLastPathComponent()
        let candidates = [exe.appendingPathComponent("../share/icons/hicolor/256x256/apps/photon2.png").standardized.path,
                          "/usr/share/icons/hicolor/256x256/apps/photon2.png", "/app/share/icons/hicolor/256x256/apps/photon2.png",
                          exe.appendingPathComponent("photon2.png").path]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func event(_ event: Int32, _ item: Int32) {
        switch Int(event) {
        case Int(PHOTON_TRAY_ACTIVATE): app.showBrowser()
        case Int(PHOTON_TRAY_SECONDARY): app.state.paused.toggle()
        case Int(PHOTON_TRAY_MENU_ITEM): actions[item]?()
        case Int(PHOTON_TRAY_MENU_OPENING): rebuild()
        case Int(PHOTON_TRAY_REGISTERED):
            visible = item != 0
            print("photon: status icon \(visible ? "registered with the StatusNotifierWatcher (\(busName))" : "has no host")")
        case Int(PHOTON_TRAY_CONTEXT_MENU):
            // Hosts without dbusmenu support ask the item to show its own menu.
            showGtkMenu()
        default: break
        }
    }

    func rebuild() {
        let state = app.state
        var items: [(id: Int32, parent: Int32, label: String, separator: Bool, enabled: Bool, toggle: Bool, checked: Bool)] = []
        actions = [:]
        var next: Int32 = 100
        func add(_ label: String, parent: Int32 = 0, enabled: Bool = true, toggle: Bool = false, checked: Bool = false,
                 id fixed: Int32? = nil, _ action: (() -> Void)? = nil) -> Int32 {
            let id = fixed ?? { next += 1; return next }()
            items.append((id, parent, label, false, enabled && (action != nil || toggle), toggle, checked))
            if let action { actions[id] = action }
            return id
        }
        func separator() { next += 1; items.append((next, 0, "", true, true, false, false)) }

        for id in state.activeIDs.sorted() { _ = add(state.item(id)?.title ?? id, enabled: false) }
        if !state.activeIDs.isEmpty { separator() }
        let pl = state.playlists!
        if pl.offersNext { _ = add(app.label("core_tray_next_wallpaper", "Next Wallpaper"), id: 5) { [weak app] in app?.state.playlists.next() } }
        if pl.offersPrevious { _ = add("Previous Wallpaper", id: 6) { [weak app] in app?.state.playlists.previous() } }
        if !pl.saved.isEmpty {
            let parent = add(app.label("core_tray_saved_playlists", "Saved Playlists"), id: 7, { })
            for p in pl.saved {
                let json = p.json
                _ = add(p.name, parent: parent) { [weak app] in app?.state.playlists.assign(json, to: AppState.allDisplays) }
            }
        }
        if pl.offersNext || pl.offersPrevious || !pl.saved.isEmpty { separator() }
        _ = add("Browse Wallpapers…", id: 1) { [weak app] in app?.showBrowser() }
        _ = add("Settings…", id: 2) { [weak app] in app?.showSettings() }
        separator()
        _ = add(state.paused ? "Resume" : "Pause", id: 3) { [weak app] in app?.state.paused.toggle() }
        _ = add("Mute", toggle: true, checked: state.muted, id: 4) { [weak app] in app?.state.muted.toggle() }
        if let reason = app.autoStateDescription { _ = add(reason, enabled: false) }
        separator()
        _ = add("Quit photon", id: 9) { [weak app] in app?.quit() }

        entries = items.filter { !$0.separator }.map { ($0.id, $0.parent, $0.label, $0.enabled, $0.checked) }
        var cStrings = items.map { strdup($0.label) }
        defer { cStrings.forEach { free($0) } }
        var cItems = items.enumerated().map { i, e in
            photon_tray_item(id: e.id, parent: e.parent, label: cStrings[i], separator: e.separator ? 1 : 0, enabled: e.enabled ? 1 : 0,
                             toggle: e.toggle ? 1 : 0, checked: e.checked ? 1 : 0)
        }
        photon_tray_set_menu(tray, &cItems, Int32(cItems.count))
        let shown = state.activeIDs.compactMap { state.item($0)?.title }.sorted().joined(separator: ", ")
        photon_tray_set_tooltip(tray, "photon", state.paused ? "Paused" : (shown.isEmpty ? "No wallpaper" : shown))
        photon_tray_set_status(tray, state.paused ? "Passive" : "Active")
        _ = cStrings
    }

    /// The same menu as a GtkMenu at the pointer (ContextMenu from hosts without dbusmenu).
    private func showGtkMenu() {
        rebuild()
        var list: [(String, (() -> Void)?)] = []
        for e in entries where e.parent == 0 {
            let action = actions[e.id]
            list.append((e.checked ? "✓ " + e.label : e.label, e.enabled ? action : nil))
        }
        popupMenu(list, at: nil)
    }

    /// Runs a menu item as a host's click would (self-test).
    func click(_ id: Int32) { actions[id]?() }
}
#endif
