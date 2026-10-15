#if os(Linux)
import CGtk3
import CPhotonApp
import Foundation
import PhotonApp
import PhotonRender

/// Settings (macOS SettingsView, the engine's Settings → Performance tab as far as photon implements it): the playback
/// rules, application rules, performance (frame rate, post-processing, MSAA, texture resolution), the wallpaper-switch
/// transition, the display layout, audio, and on Linux the library folders and start at login.
final class SettingsWindow {
    unowned let app: LinuxApp
    var state: AppState { app.state }
    let window: Widget
    /// The settings page (unscrolled), for full-height snapshots.
    let content: Widget
    private var statusLabel: Widget?
    /// Controls by setting key (self-test).
    private(set) var controls: [String: Widget] = [:]

    init(app: LinuxApp) {
        self.app = app
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "photon Settings")
        gtk_window_set_default_size(G(window), 600, 720)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        content = box(true, spacing: 8)
        margins(content, 16)
        gtk_container_add(G(window), scrolled(content))
        onEvent(window, "delete-event") { [weak self] in gtk_widget_hide(self?.window); return true }
        build()
    }

    func present() {
        gtk_widget_show_all(window)
        gtk_window_present(G(window))
    }

    private func t(_ key: String, _ fallback: String) -> String { app.label(key, fallback) }

    private func section(_ title: String) {
        let l = label(title, css: "photon-section")
        gtk_widget_set_margin_top(l, 10)
        pack(content, l)
    }

    private func row(_ text: String, _ w: Widget, key: String? = nil) {
        let r = box(false, spacing: 10)
        let l = label(text)
        gtk_label_set_ellipsize(G(l), PANGO_ELLIPSIZE_END)
        pack(r, l, expand: true)
        pack(r, w)
        pack(content, r)
        if let key { controls[key] = w }
    }

    private func note(_ text: String) { pack(content, label(text, css: "photon-dim", wrap: true)) }

    /// The engine's UI offers "pause all" and per-display "pause" only with several displays (`runtime.multimonitor`).
    private var multi: Bool { state.displays.count > 1 }

    func build() {
        removeChildren(content)
        controls = [:]
        let state = self.state

        section("Playback")
        for (key, labelKey) in SettingsCatalog.rules {
            let options = SettingsCatalog.options(key, multiMonitor: multi)
            let current = state.playback[keyPath: key]
            let list = options.contains(current) ? options : options + [current]
            let text = state.strings.label(labelKey)
            let c = Combo(list.map { ($0.engineString, $0.label) }, selected: current.engineString) { [weak self] v in
                self?.state.playback[keyPath: key] = PlaybackAction(engineString: v)
            }
            objc_keep(c.widget, c)
            row(text.isEmpty || text.hasPrefix("ui_") ? SettingsCatalog.ruleFallback(key) : text, c.widget, key: labelKey)
        }
        let vram = gtk_check_button_new_with_label("Stop when video memory runs out")!
        gtk_toggle_button_set_active(G(vram), state.playback.pauseOnVRAMExhaustion ? 1 : 0)
        on(vram, "toggled") { [weak self] in self?.state.playback.pauseOnVRAMExhaustion = gtk_toggle_button_get_active(G(vram)) != 0 }
        pack(content, vram)
        let rate = gtk_spin_button_new_with_range(50, 5000, 50)!
        gtk_spin_button_set_value(G(rate), Double(state.playback.windowUpdateRate))
        on(rate, "value-changed") { [weak self] in self?.state.playback.windowUpdateRate = Int(gtk_spin_button_get_value(G(rate))) }
        row("Check every (ms)", rate, key: "windowupdaterate")
        let status = label("", css: "photon-dim")
        statusLabel = status
        pack(content, status)
        note("The rules run in the desktop hosts: window states from EWMH (X11) or wlr-foreign-toplevel (Wayland), battery from UPower, "
             + "sleep and lock from logind, the screensaver over D-Bus. \"Playing audio\" and video-memory exhaustion have no Linux input yet.")

        section(t("ui_settings_playback_application_rules_header", "Application rules"))
        for (i, rule) in state.rules.enumerated() {
            let r = box(false, spacing: 6)
            let entry = gtk_entry_new()!
            gtk_entry_set_text(G(entry), rule.application)
            gtk_entry_set_placeholder_text(G(entry), "Application")
            on(entry, "changed") { [weak self] in
                guard let self, i < self.state.rules.count else { return }
                self.state.rules[i].application = String(cString: gtk_entry_get_text(G(entry)))
            }
            pack(r, entry, expand: true)
            let cond = Combo(AppRule.Condition.allCases.map { (String($0.rawValue), $0.label) }, selected: String(rule.condition.rawValue)) { [weak self] v in
                guard let self, i < self.state.rules.count, let c = Int(v).flatMap(AppRule.Condition.init(rawValue:)) else { return }
                self.state.rules[i].condition = c
            }
            objc_keep(cond.widget, cond)
            pack(r, cond.widget)
            let act = Combo([PlaybackAction.mute, .pause, .pauseAll, .stop].map { ($0.engineString, $0.label) }, selected: rule.action.engineString) { [weak self] v in
                guard let self, i < self.state.rules.count else { return }
                self.state.rules[i].action = PlaybackAction(engineString: v)
            }
            objc_keep(act.widget, act)
            pack(r, act.widget)
            pack(r, button("Remove") { [weak self] in
                guard let self, i < self.state.rules.count else { return }
                self.state.rules.remove(at: i)
                self.build()
                gtk_widget_show_all(self.content)
            })
            pack(content, r)
        }
        let add = box(false, spacing: 6)
        let addRule = gtk_button_new_with_label("Add rule for…")!
        on(addRule, "clicked") { [weak self] in
            guard let self else { return }
            popupMenu(Self.runningApplications().map { name in (name, { [weak self] in
                guard let self else { return }
                self.state.rules.append(AppRule(application: name, condition: .focused, action: .pause))
                self.build(); gtk_widget_show_all(self.content)
            }) }, at: addRule)
        }
        pack(add, addRule)
        pack(add, button("Add empty rule") { [weak self] in
            guard let self else { return }
            self.state.rules.append(AppRule(application: "", condition: .running, action: .pause))
            self.build(); gtk_widget_show_all(self.content)
        })
        pack(content, add)
        note("Applications match by name or executable name. The rules are saved with the macOS keys; the Linux hosts do not apply them yet.")

        section("Performance")
        let fps = gtk_spin_button_new_with_range(0, 240, 5)!
        gtk_spin_button_set_value(G(fps), Double(state.fps))
        on(fps, "value-changed") { [weak self] in self?.state.fps = Int(gtk_spin_button_get_value(G(fps))) }
        row("Frame rate limit (fps, 0 = unlimited)", fps, key: "fps")
        let post = Combo(SettingsCatalog.postProcessingLabels, selected: state.postProcessing.rawValue) { [weak self] v in
            if let p = SceneRenderer.PostProcessing(rawValue: v) { self?.state.postProcessing = p }
        }
        objc_keep(post.widget, post)
        row("Post-processing", post.widget, key: "postprocessing")
        // `msaa` (Project_Prescan 0x14010ecb1): only scenes with 3D model objects are multisampled.
        let msaa = Combo(SettingsCatalog.msaaOptions, selected: state.msaa) { [weak self] v in self?.state.msaa = v }
        objc_keep(msaa.widget, msaa)
        row("Anti-aliasing (MSAA)", msaa.widget, key: "msaa")
        let res = Combo(SettingsCatalog.resolutionOptions, selected: state.resolution) { [weak self] v in self?.state.resolution = v }
        objc_keep(res.widget, res)
        row("Texture resolution", res.widget, key: "resolution")

        section(t("ui_settings_wallpaper_browser_transition", "Wallpaper switch"))
        let trans = Combo(SettingsCatalog.transitionOptions.map { (String($0.1), t($0.0, SettingsCatalog.transitionFallback($0.0))) },
                          selected: String(state.browseTransition.mode)) { [weak self] v in
            guard let self, let n = Int(v) else { return }
            self.state.browseTransition.mode = n
        }
        objc_keep(trans.widget, trans)
        row("Transition", trans.widget, key: "browsetransition")
        let dur = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 3000, 50)!
        gtk_widget_set_size_request(dur, 220, -1)
        gtk_range_set_value(G(dur), Double(state.browseTransition.timeMs))
        on(dur, "value-changed") { [weak self] in self?.state.browseTransition.timeMs = Int((gtk_range_get_value(G(dur)) / 50).rounded() * 50) }
        row("Duration (ms)", dur, key: "transitiontime")
        note("Saved for macOS compatibility; on Linux a switch restarts the desktop host without a transition.")

        section("Displays")
        let layout = Combo(SettingsCatalog.layoutOptions.map { (String($0.0), t($0.1, $0.2)) }, selected: String(state.layout)) { [weak self] v in
            guard let self, let n = Int(v) else { return }
            self.state.layout = n
            self.build(); gtk_widget_show_all(self.content)
        }
        objc_keep(layout.widget, layout)
        row("Layout", layout.widget, key: "layout")
        note(state.layout == 0 ? "Stretch and clone groups join some displays under one wallpaper (one desktop host per group)."
             : "Stretch and clone show the first display's wallpaper on every display. Stretch spans the displays on X11; Wayland "
             + "has no surface across outputs, so there every output shows the whole wallpaper.")
        if state.displays.count > 1 {
            if state.layout == 2 { cloneControls(group: nil, members: state.displays.map(\.id)) }
            if state.layout == 0 { groupControls() }
        }
        if state.layout == 0 { splitControls() }
        if let flipNote { note(flipNote) }

        section("Audio")
        let volume = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1)!
        gtk_widget_set_size_request(volume, 220, -1)
        gtk_range_set_value(G(volume), state.volume * 100)
        on(volume, "value-changed") { [weak self] in self?.state.volume = gtk_range_get_value(G(volume)) / 100 }
        row("Master volume (%)", volume, key: "mastervolume")
        let mute = gtk_check_button_new_with_label("Mute")!
        gtk_toggle_button_set_active(G(mute), state.muted ? 1 : 0)
        on(mute, "toggled") { [weak self] in self?.state.muted = gtk_toggle_button_get_active(G(mute)) != 0 }
        pack(content, mute)
        controls["muted"] = mute

        section("Library")
        let ws = gtk_file_chooser_button_new("Steam Workshop folder (content/431960)", GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)!
        _ = gtk_file_chooser_set_filename(G(ws), LibraryPaths.workshop(app.defaults).path)
        on(ws, "file-set") { [weak self] in
            guard let self, let f = gtk_file_chooser_get_filename(G(ws)) else { return }
            self.app.defaults.set(String(cString: f), forKey: LibraryPaths.workshopKey)
            g_free(f)
        }
        row("Workshop folder", ws, key: LibraryPaths.workshopKey)
        let we = gtk_file_chooser_button_new("Wallpaper Engine folder (with assets/)", GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)!
        _ = gtk_file_chooser_set_filename(G(we), state.engineAssets.deletingLastPathComponent().path)
        on(we, "file-set") { [weak self] in
            guard let self, let f = gtk_file_chooser_get_filename(G(we)) else { return }
            self.app.defaults.set(String(cString: f), forKey: LibraryPaths.installKey)
            g_free(f)
        }
        row("Wallpaper Engine install", we, key: LibraryPaths.installKey)
        let found = FileManager.default.fileExists(atPath: state.engineAssets.path)
        note((found ? "Engine assets: \(state.engineAssets.path)." : "No Wallpaper Engine assets at \(state.engineAssets.path): install Wallpaper Engine "
              + "through Steam (Proton) or choose its folder.") + " \(state.items.count) wallpapers. Changed folders apply after a restart of photon.")
        let lib = box(false, spacing: 6)
        pack(lib, button("Reload library") { [weak self] in self?.state.reloadLibrary() })
        pack(lib, button("Restart photon") { Autostart.restart() })
        pack(content, lib)

        section("Steam Workshop")
        let user = gtk_entry_new()!
        gtk_entry_set_text(G(user), state.workshop.username)
        gtk_entry_set_placeholder_text(G(user), "account name")
        on(user, "changed") { [weak self] in self?.state.workshop.username = String(cString: gtk_entry_get_text(G(user))) }
        row("Steam username", user, key: WorkshopController.usernameKey)
        note("Only the account name is stored. Downloads use the login steamcmd saved when you ran `"
             + DownloadQueue.loginCommand(username: state.workshop.username)
             + "` once in a terminal (password and Steam Guard code are typed there, never in photon).")
        let cmd = gtk_entry_new()!
        gtk_entry_set_text(G(cmd), state.workshop.steamcmdPath)
        gtk_entry_set_placeholder_text(G(cmd), "automatic")
        on(cmd, "changed") { [weak self] in self?.state.workshop.steamcmdPath = String(cString: gtk_entry_get_text(G(cmd))) }
        row("steamcmd path", cmd, key: WorkshopController.steamcmdKey)
        note(state.workshop.steamcmdExecutable.map { "Using \($0). " } ?? "steamcmd not found: install your distribution's steamcmd package or set its path. ")
        let rating = Combo(WorkshopRatingFilter.allCases.map { ($0.rawValue, $0.label) }, selected: state.workshop.rating.rawValue) { [weak self] v in
            if let r = WorkshopRatingFilter(rawValue: v) { self?.state.workshop.rating = r }
        }
        objc_keep(rating.widget, rating)
        row("Age ratings shown", rating.widget, key: WorkshopController.ratingKey)
        note("Downloads go to \(state.workshop.downloadDirectory.path)."
             + (state.hiddenIDs.isEmpty ? "" : " \(state.hiddenIDs.count) item(s) are hidden by \(state.hiddenFile?.path ?? "the blocklist")."))
        pack(content, button("Open Workshop…") { [weak self] in self?.app.showWorkshop() })

        section("Startup")
        let login = gtk_check_button_new_with_label("Start photon when I log in")!
        gtk_toggle_button_set_active(G(login), Autostart.enabled ? 1 : 0)
        on(login, "toggled") { Autostart.set(gtk_toggle_button_get_active(G(login)) != 0) }
        pack(content, login)
        controls["autostart"] = login
        note(Autostart.describe)
        refreshStatus()
    }

    // MARK: Displays (the browser's monitor panel: groups, clone source and flip; docs/re/09 §8.3)

    /// `ui_browse_monitors_clone_flip_limitation_message` after a flip the UI refuses.
    private var flipNote: String?
    private static let automatic = "\u{1}auto"

    private func rebuild() { onMain { [weak self] in guard let self else { return }; self.build(); gtk_widget_show_all(self.content) } }

    private func displayName(_ key: String) -> String { state.displays.first { $0.id == key }?.name ?? key }

    /// The layout with the outputs' geometry (`desktop --list-outputs`): the automatic clone source depends on it.
    private var layoutPlan: LayoutPlan {
        state.layoutPlan(state.displays.map { d in
            let g = HostSupervisor.geometry[d.id] ?? (0, 0, 0, 0)
            return LayoutPlan.Monitor(key: d.id, rect: CGRect(x: g.0, y: g.1, width: g.2, height: g.3))
        })
    }

    /// Clone source and per-display flip of layout 2 (`group` nil: the profile's `source` / `monitorconfig`) or of a
    /// clone group.
    private func cloneControls(group: String?, members: [String]) {
        let locked = group.map { state.profile.groups[$0]?.source ?? "" } ?? state.profile.source
        let flips = group.map { state.profile.groups[$0]?.flip ?? [] } ?? state.profile.flip
        let auto = layoutPlan.instances.first { $0.key == (group ?? state.displays.first?.id ?? "") }?.host
        let entries = [(Self.automatic, "Automatic" + (locked.isEmpty ? auto.map { " (\(displayName($0)))" } ?? "" : ""))]
            + members.map { ($0, displayName($0)) }
        let c = Combo(entries, selected: locked.isEmpty ? Self.automatic : locked) { [weak self] v in
            guard let self else { return }
            let m = v == Self.automatic ? nil : v
            if let group { self.state.profile.setGroupSource(group, m) } else { self.state.profile.setSource(m) }
            self.rebuild()
        }
        objc_keep(c.widget, c)
        row(t("ui_browse_monitors_clone_set_source", "Clone source"), c.widget, key: "clonesource" + (group.map { ":" + $0 } ?? ""))
        for m in members {
            let cb = gtk_check_button_new_with_label("\(t("ui_browse_monitors_clone_flip", "Flip")): \(displayName(m))")!
            gtk_toggle_button_set_active(G(cb), flips.contains(m) ? 1 : 0)
            on(cb, "toggled") { [weak self] in
                guard let self else { return }
                let hit = group.map { self.state.profile.toggleGroupFlip($0, m) } ?? self.state.profile.toggleFlip(m, among: members)
                self.flipNote = hit ? self.t("ui_browse_monitors_clone_flip_limitation_message",
                                             "At least one display of a clone must not be flipped.") : nil
                self.rebuild()
            }
            pack(content, cb)
            controls["cloneflip:" + (group.map { $0 + ":" } ?? "") + m] = cb
        }
    }

    /// Stretch and clone groups of layout 0 (`groups`): kind, members, clone source and flips, removal; and a new group
    /// from two or more displays (`callbackCreateGroup`).
    private func groupControls() {
        for name in state.profile.groups.keys.sorted() {
            guard let g = state.profile.groups[name] else { continue }
            let r = box(false, spacing: 10)
            let kind = g.isClone ? t("ui_browse_monitors_clone", "Clone") : t("ui_browse_monitors_stretch", "Stretch")
            pack(r, label(kind + ": " + g.monitors.map(displayName).joined(separator: ", ")), expand: true)
            let rm = button(t("ui_browse_monitors_remove_group", "Remove group")) { [weak self] in
                self?.state.profile.removeGroup(name)
                self?.rebuild()
            }
            pack(r, rm)
            controls["removegroup:" + name] = rm
            pack(content, r)
            if g.isClone { cloneControls(group: name, members: g.monitors) }
        }
        pack(content, label("New group from:"))
        var checks: [(String, Widget)] = []
        for d in state.displays {
            let cb = gtk_check_button_new_with_label(d.name + (state.profile.group(containing: d.id) != nil ? " (in a group)" : ""))!
            pack(content, cb)
            checks.append((d.id, cb))
            controls["newgroup:" + d.id] = cb
        }
        let r = box(false, spacing: 10)
        for (layout, key, fallback) in [(1, "ui_browse_monitors_add_stretch_group", "Add stretch group"),
                                        (2, "ui_browse_monitors_add_clone_group", "Add clone group")] {
            let b = button(t(key, fallback)) { [weak self] in
                let picked = checks.filter { gtk_toggle_button_get_active(G($0.1)) != 0 }.map(\.0)
                guard let self, picked.count >= 2 else { return }
                self.state.profile.createGroup(picked, layout: layout)
                self.rebuild()
            }
            pack(r, b)
            controls[layout == 1 ? "addstretchgroup" : "addclonegroup"] = b
        }
        pack(content, r)
    }

    // MARK: Splits (`splits`; scripts.js `callbackSplitSelectedMonitor`, `browseSplitMonitor`, `Rt`, `Tt`)

    /// The display or region picked for a new split and the split dialog's direction and position (pixels).
    private var splitTarget = ""
    private var splitDirection = 0
    private var splitPixels: Double?

    private func regionName(_ key: String, _ plan: LayoutPlan) -> String {
        if let inst = plan.instance(key) { return inst.name }
        let root = MonitorProfile.splitRoot(key)
        return displayName(root) + key.dropFirst(root.count)
    }

    private func directionLabel(_ d: Int) -> String {
        d == 1 ? t("ui_browse_monitors_horizontal", "Horizontal") : t("ui_browse_monitors_vertical", "Vertical")
    }

    /// Each applied split (direction, divider position in pixels, removal) and "Add split" on a display or region that
    /// is not a group and not in one (the UI's monitor menu), with "Remove all splits" on a region.
    private func splitControls() {
        let plan = layoutPlan
        func pixels(_ key: String) -> (w: Int, h: Int)? { plan.records.first { $0.key == key }?.pixelSize }
        let applied = state.profile.splits.keys.filter { k in plan.records.contains { $0.key.hasPrefix(k + "/") } }.sorted()
        for key in applied {
            guard let s = state.profile.splits[key], let px = pixels(key) else { continue }
            let size = s.direction == 1 ? px.h : px.w
            let r = box(false, spacing: 10)
            pack(r, label("\(t("ui_browse_monitors_split", "Split")): \(regionName(key, plan))"), expand: true)
            let dir = Combo([("0", directionLabel(0)), ("1", directionLabel(1))], selected: s.direction == 1 ? "1" : "0") { [weak self] v in
                guard let self, let d = Int(v) else { return }
                let p = Double(MonitorProfile.splitPixels(s.position, size: size))
                self.state.profile.editSplit(key, direction: d, position: MonitorProfile.splitFraction(pixels: p, size: d == 1 ? px.h : px.w))
                self.rebuild()
            }
            objc_keep(dir.widget, dir)
            pack(r, dir.widget)
            controls["splitdirection:" + key] = dir.widget
            let pos = gtk_spin_button_new_with_range(1, Double(max(size - 1, 1)), 1)!
            gtk_spin_button_set_value(G(pos), Double(MonitorProfile.splitPixels(s.position, size: size)))
            on(pos, "value-changed") { [weak self] in
                guard let self, let cur = self.state.profile.splits[key] else { return }
                self.state.profile.editSplit(key, direction: cur.direction,
                                             position: MonitorProfile.splitFraction(pixels: gtk_spin_button_get_value(G(pos)), size: size))
            }
            pack(r, pos)
            controls["splitposition:" + key] = pos
            let rm = button(t("ui_browse_monitors_remove_split", "Remove split")) { [weak self] in
                self?.state.profile.removeSplit(region: key + "/L")
                self?.rebuild()
            }
            pack(r, rm)
            controls["removesplit:" + key] = rm
            pack(content, r)
        }
        let targets = plan.instances.filter { ($0.kind == .display || $0.kind == .split) && state.profile.group(containing: $0.key) == nil }.map(\.key)
        guard !targets.isEmpty else { return }
        if !targets.contains(splitTarget) { splitTarget = targets[0] }
        let r = box(false, spacing: 10)
        pack(r, label(t("ui_browse_monitors_add_split", "Add split") + ":"), expand: true)
        let target = Combo(targets.map { ($0, regionName($0, plan)) }, selected: splitTarget) { [weak self] v in
            self?.splitTarget = v
            self?.rebuild()
        }
        objc_keep(target.widget, target)
        pack(r, target.widget)
        controls["splittarget"] = target.widget
        let dir = Combo([("0", directionLabel(0)), ("1", directionLabel(1))], selected: String(splitDirection)) { [weak self] v in
            self?.splitDirection = Int(v) ?? 0
            self?.rebuild()
        }
        objc_keep(dir.widget, dir)
        pack(r, dir.widget)
        controls["newsplitdirection"] = dir.widget
        pack(content, r)
        guard let px = pixels(splitTarget) else { return }
        let size = splitDirection == 1 ? px.h : px.w
        let r2 = box(false, spacing: 10)
        pack(r2, label("\(t("ui_browse_monitors_posititon", "Position")) (px)"), expand: true)
        let pos = gtk_spin_button_new_with_range(1, Double(max(size - 1, 1)), 1)!
        gtk_spin_button_set_value(G(pos), splitPixels ?? Double(size / 2))
        on(pos, "value-changed") { [weak self] in self?.splitPixels = gtk_spin_button_get_value(G(pos)) }
        pack(r2, pos)
        controls["newsplitposition"] = pos
        let add = button(t("ui_browse_monitors_add_split", "Add split")) { [weak self] in
            // The target and direction as they are now (their combos rebuild the page only afterwards).
            guard let self, let px = self.layoutPlan.records.first(where: { $0.key == self.splitTarget })?.pixelSize else { return }
            self.state.addSplit(self.splitTarget, direction: self.splitDirection,
                                position: MonitorProfile.splitFraction(pixels: self.splitPixels, size: self.splitDirection == 1 ? px.h : px.w))
            self.splitPixels = nil
            self.rebuild()
        }
        pack(r2, add)
        controls["addsplit"] = add
        if MonitorProfile.splitParent(splitTarget) != nil {
            let all = button(t("ui_browse_monitors_remove_all_splits", "Remove all splits")) { [weak self] in
                guard let self else { return }
                self.state.profile.removeAllSplits(region: self.splitTarget)
                self.rebuild()
            }
            pack(r2, all)
            controls["removeallsplits"] = all
        }
        pack(content, r2)
        note("A split cuts a display into regions, each with its own wallpaper, playlist and properties (one desktop host per region).")
    }

    func refreshStatus() {
        guard let statusLabel else { return }
        let s = app.supervisor.status
        let running = app.supervisor.hosts.count
        gtk_label_set_text(G(statusLabel), "Now: \(state.paused ? "paused" : "running") · \(running) desktop host\(running == 1 ? "" : "s")"
                           + (s.isEmpty ? "" : " · last rule change: \(s)"))
    }

    /// Visible applications for "Add rule for…": the X11 client list's WM_CLASS names, else running processes' names.
    static func runningApplications() -> [String] {
        var names = Set<String>()
        if let dir = try? FileManager.default.contentsOfDirectory(atPath: "/proc") {
            for pid in dir where pid.allSatisfy(\.isNumber) {
                guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { continue }
                // Only processes of this user with a desktop session (they inherit DISPLAY or WAYLAND_DISPLAY).
                guard let env = FileManager.default.contents(atPath: "/proc/\(pid)/environ"),
                      env.range(of: Data("DISPLAY=".utf8)) != nil else { continue }
                names.insert(comm.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return names.filter { !$0.isEmpty && !$0.hasPrefix("photon") }.sorted().prefix(40).map { $0 }
    }
}

/// Start at login: the systemd user unit (`photon2.service`, packaging/linux) when it is installed, else an XDG autostart
/// entry in `~/.config/autostart/photon2.desktop` running `photon-linux app --background`.
enum Autostart {
    static var autostartFile: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("autostart/photon2.desktop")
    }

    /// The unit file systemd would load for `--user` (packaged: /usr/lib/systemd/user; local: ~/.config/systemd/user).
    static var unitInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/lib/systemd/user/photon2.service", "/usr/local/lib/systemd/user/photon2.service", "\(home)/.config/systemd/user/photon2.service",
                "\(home)/.local/share/systemd/user/photon2.service"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var unitEnabled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "\(home)/.config/systemd/user/graphical-session.target.wants/photon2.service")
    }

    static var enabled: Bool { unitEnabled || FileManager.default.fileExists(atPath: autostartFile.path) }

    static var describe: String {
        flatpak ? "Asks the Background portal to start photon at login." : unitInstalled ? "Uses the systemd user unit photon2.service (systemctl --user enable photon2), started with the graphical session."
            : "Writes \(autostartFile.path) (XDG autostart), which runs photon in the background at login."
    }

    static var flatpak: Bool { ProcessInfo.processInfo.environment["FLATPAK_ID"] != nil }

    static func set(_ on: Bool) {
        if flatpak {
            // Inside the sandbox ~/.config is the app's own; the Background portal writes the host's autostart entry.
            let words: [String] = ["photon-linux", "app", "--background"]
            let owned: [UnsafeMutablePointer<CChar>?] = words.map { (w: String) -> UnsafeMutablePointer<CChar>? in strdup(w) }
            defer { owned.forEach { free($0) } }
            var cargv: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
            cargv.append(nil)
            _ = photon_portal_request_background(on ? 1 : 0, &cargv, "Show wallpapers on the desktop after login")
            return
        }
        if unitInstalled {
            _ = StaticBackground.spawn(["systemctl", "--user", on ? "enable" : "disable", "photon2.service"])
            return
        }
        if on {
            try? FileManager.default.createDirectory(at: autostartFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entry = """
            [Desktop Entry]
            Type=Application
            Name=photon
            Comment=Wallpaper Engine wallpapers on the desktop
            Exec=\(LinuxApp.selfPath) app --background
            Icon=photon2
            X-GNOME-Autostart-enabled=true
            NoDisplay=true

            """
            try? entry.write(to: autostartFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: autostartFile)
        }
    }

    /// Restarts the app in place (library folder changes): the hosts stop with the old process's pipes.
    static func restart() {
        LinuxApp.current?.supervisor.stopAll()
        let args = CommandLine.arguments
        var argv = [strdup(LinuxApp.selfPath)] + args.dropFirst().map { strdup($0) } + [nil]
        after(300) { execv(LinuxApp.selfPath, &argv) }
    }
}
#endif
