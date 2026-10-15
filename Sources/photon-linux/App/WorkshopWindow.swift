#if os(Linux)
import CGtk3
import Combine
import CPhotonApp
import Foundation
import PhotonApp

/// The Steam Workshop browser (macOS: the browser's Workshop tab): search, sort, type and tag filters over the public
/// Workshop pages, a grid of results with download state, paging, the selected item's details with Download / Update /
/// Remove, the steamcmd queue and the login notice. "Subscribed" switches the grid to the account's subscriptions as the
/// Steam client last recorded them (macOS: the Subscribed tab). The logic is PhotonApp's WorkshopController.
final class WorkshopWindow {
    unowned let app: LinuxApp
    var state: AppState { app.state }
    var workshop: WorkshopController { app.state.workshop }
    let window: Widget
    private let entry: Widget
    private let flow: Widget
    private let notice: Widget
    private let detailBox: Widget
    private let downloads: Widget
    private let pageLabel: Widget
    private let prev: Widget
    private let next: Widget
    private var sortCombo: Combo!
    private var typeCombo: Combo!
    private var tagCombo: Combo!
    private var modeCombo: Combo!
    /// The grid shows the subscriptions instead of the browse results.
    private var subscribedMode = false
    private let missingCheck: Widget
    private let downloadAll: Widget
    private var browseOnly: [Widget] = []
    /// Why Download All couldn't queue (shown in the summary line).
    private var subscribedMessage: String?
    /// Items in grid order, with their status labels.
    private var order: [WorkshopItem] = []
    private var statusLabels: [String: Widget] = [:]
    private var shownKey = ""
    /// Bumped when the grid is rebuilt: preview callbacks for destroyed tiles are dropped.
    private var generation = 0
    private var selected: WorkshopItem?
    private var detailStatus: Widget?
    private var detailKey = ""
    /// Bumped when the detail pane is rebuilt (its preview callback must not touch a destroyed image).
    private var detailGeneration = 0
    private var noticeKey = ""
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var refresh = Debouncer(ms: 80) { [weak self] in self?.modelChanged() }

    init(app: LinuxApp) {
        self.app = app
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "photon Workshop")
        gtk_window_set_default_size(G(window), 1100, 760)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        let root = box(true, spacing: 0)
        gtk_container_add(G(window), root)

        let top = box(false, spacing: 8)
        margins(top, 8)
        entry = gtk_search_entry_new()!
        gtk_entry_set_placeholder_text(G(entry), "Search the Workshop (Enter)")
        pack(top, entry, expand: true)
        pack(root, top)
        notice = box(true, spacing: 4)
        margins(notice, 8)
        pack(root, notice)
        pack(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))

        missingCheck = gtk_check_button_new_with_label("Not downloaded")!
        downloadAll = gtk_button_new_with_label("Download All")!

        let paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        pack(root, paned, expand: true)
        flow = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(G(flow), GTK_SELECTION_SINGLE)
        gtk_flow_box_set_activate_on_single_click(G(flow), 1)
        gtk_flow_box_set_homogeneous(G(flow), 1)
        gtk_flow_box_set_min_children_per_line(G(flow), 2)
        gtk_flow_box_set_max_children_per_line(G(flow), 12)
        gtk_flow_box_set_column_spacing(G(flow), 6)
        gtk_flow_box_set_row_spacing(G(flow), 6)
        gtk_widget_set_valign(flow, GTK_ALIGN_START)
        margins(flow, 8)
        gtk_paned_pack1(G(paned), scrolled(flow), 1, 0)
        detailBox = box(true, spacing: 0)
        gtk_widget_set_size_request(detailBox, 340, -1)
        gtk_paned_pack2(G(paned), detailBox, 0, 0)
        gtk_paned_set_position(G(paned), 740)

        pack(root, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        downloads = label("", css: "photon-caption", wrap: true)
        margins(downloads, 6)
        pack(root, downloads)
        let pager = box(false, spacing: 8)
        margins(pager, 6)
        prev = gtk_button_new_with_label("‹ Previous")
        next = gtk_button_new_with_label("Next ›")
        pageLabel = label("", css: "photon-dim")
        pack(pager, prev)
        pack(pager, pageLabel)
        pack(pager, next)
        packEnd(pager, label(workshop.rating.label + " (Settings)", css: "photon-dim"))
        pack(root, pager)

        let w = workshop
        modeCombo = Combo([("browse", "Browse"), ("subscribed", "Subscribed")], selected: "browse") { [weak self] v in
            self?.setMode(subscribed: v == "subscribed")
        }
        sortCombo = Combo(WorkshopSort.allCases.map { ($0.rawValue, $0.label) }, selected: w.query.sort.rawValue) { [weak self] v in
            guard let self, let s = WorkshopSort(rawValue: v) else { return }
            self.workshop.query.sort = s
            self.workshop.search()
        }
        typeCombo = Combo([("", "All types")] + WorkshopCatalog.types.map { ($0, $0) }, selected: w.query.type ?? "") { [weak self] v in
            guard let self else { return }
            if self.subscribedMode {
                self.workshop.subscribedFilter.type = v.isEmpty ? nil : v
            } else {
                self.workshop.query.type = v.isEmpty ? nil : v
                self.workshop.search()
            }
        }
        tagCombo = Combo([("", "Any tag")] + WorkshopCatalog.filterTags.map { ($0, $0) }, selected: w.query.tags.first ?? "") { [weak self] v in
            self?.workshop.query.tags = v.isEmpty ? [] : [v]
            self?.workshop.search()
        }
        pack(top, sortCombo.widget)
        pack(top, typeCombo.widget)
        pack(top, tagCombo.widget)
        pack(top, missingCheck)
        pack(top, button("Reload") { [weak self] in
            guard let self else { return }
            guard self.subscribedMode else { return self.workshop.search(keepPage: true) }
            // Ask Steam through steamcmd when downloading is set up; otherwise re-read the saved list.
            if self.canAskSteam { self.subscribedMessage = self.workshop.refreshSubscriptionsFromSteam() }
            else { self.workshop.loadSubscribed() }
            self.modelChanged()
        })
        packEnd(pager, downloadAll)
        browseOnly = [sortCombo.widget, tagCombo.widget, prev, next]

        gtk_entry_set_text(G(entry), w.query.searchText)
        on(entry, "activate") { [weak self] in
            guard let self, !self.subscribedMode else { return }
            self.workshop.query.searchText = String(cString: gtk_entry_get_text(G(self.entry)))
            self.workshop.search()
        }
        // The subscriptions are filtered locally, as you type.
        on(entry, "search-changed") { [weak self] in
            guard let self, self.subscribedMode else { return }
            self.workshop.subscribedFilter.searchText = String(cString: gtk_entry_get_text(G(self.entry)))
        }
        on(missingCheck, "toggled") { [weak self] in
            guard let self else { return }
            self.workshop.subscribedFilter.missingOnly = gtk_toggle_button_get_active(G(self.missingCheck)) != 0
        }
        on(downloadAll, "clicked") { [weak self] in
            guard let self else { return }
            self.subscribedMessage = self.workshop.downloadMissingSubscribed().problem
            self.modelChanged()
        }
        on(prev, "clicked") { [weak self] in guard let self else { return }; self.workshop.goToPage(self.workshop.query.page - 1) }
        on(next, "clicked") { [weak self] in guard let self else { return }; self.workshop.goToPage(self.workshop.query.page + 1) }
        on(flow, "selected-children-changed") { [weak self] in self?.selectionChanged() }
        onEvent(window, "delete-event") { [weak self] in
            gtk_widget_hide(self?.window)
            return true
        }
        w.objectWillChange.sink { [weak self] in self?.refresh.poke() }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] in self?.refresh.poke() }.store(in: &subscriptions)
        // A finished download: select it in the library browser (once its grid has the new tile).
        w.$lastInstalled.sink { [weak self] id in
            guard let id else { return }
            after(400) { self?.app.browser?.select(id) }
        }.store(in: &subscriptions)
        gtk_widget_show_all(root)
        pack(top, modeCombo.widget)
        gtk_box_reorder_child(G(top), modeCombo.widget, 0)
        gtk_widget_show(modeCombo.widget)
        applyMode()
        showDetail()
        if w.page == nil && !w.loading { w.search() }
        modelChanged()
    }

    /// Browse ⇄ Subscribed: the search text and type carry over; the browse-only controls hide.
    func setMode(subscribed: Bool) {
        guard subscribed != subscribedMode else { return }
        subscribedMode = subscribed
        if modeCombo.selected != (subscribed ? "subscribed" : "browse") { modeCombo.select(subscribed ? "subscribed" : "browse") }
        let w = workshop
        let text = subscribed ? w.subscribedFilter.searchText : w.query.searchText
        let type = subscribed ? w.subscribedFilter.type : w.query.type
        gtk_entry_set_text(G(entry), text)
        typeCombo.select(type ?? "")
        applyMode()
        if subscribed && w.subscriptionSnapshot == nil && !w.subscribedLoading {
            w.loadSubscribed()
            if w.subscriptionSyncStatus == nil && canAskSteam { w.refreshSubscriptionsFromSteam() }
        }
        modelChanged()
    }

    private var canAskSteam: Bool {
        !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && workshop.steamcmdExecutable != nil
    }

    private func applyMode() {
        for widget in browseOnly { gtk_widget_set_visible(widget, subscribedMode ? 0 : 1) }
        gtk_widget_set_visible(missingCheck, subscribedMode ? 1 : 0)
        gtk_widget_set_visible(downloadAll, subscribedMode ? 1 : 0)
        gtk_entry_set_placeholder_text(G(entry), subscribedMode ? "Search subscriptions" : "Search the Workshop (Enter)")
    }

    func present() {
        gtk_widget_show_all(window)
        gtk_window_present(G(window))
        modelChanged()
    }

    // MARK: model → widgets

    private func modelChanged() {
        let w = workshop
        let items = subscribedMode ? w.visibleSubscribed : w.visibleItems
        let key = (subscribedMode ? "s|" : "\(w.page?.page ?? 0)|") + items.map(\.id).joined(separator: ",")
        if key != shownKey {
            shownKey = key
            buildTiles(items)
        }
        for item in items { if let l = statusLabels[item.id] { gtk_label_set_text(G(l), info(item)) } }
        if subscribedMode {
            gtk_label_set_text(G(pageLabel), subscribedSummary())
            let missing = w.missingSubscribedCount
            gtk_button_set_label(G(downloadAll), missing > 0 ? "Download All (\(missing))" : "Download All")
            gtk_widget_set_sensitive(downloadAll, missing > 0 ? 1 : 0)
        } else if let page = w.page {
            gtk_label_set_text(G(pageLabel), (w.loading ? "Loading… " : "")
                + "Page \(page.page) of \(page.totalPages) · \(page.totalCount) items")
        } else {
            gtk_label_set_text(G(pageLabel), w.loading ? "Loading…" : (w.error ?? ""))
        }
        if let e = w.error, w.page != nil, !subscribedMode { gtk_label_set_text(G(pageLabel), e) }
        gtk_widget_set_sensitive(prev, w.query.page > 1 && !w.loading ? 1 : 0)
        gtk_widget_set_sensitive(next, (w.page.map { $0.page < $0.totalPages } ?? false) && !w.loading ? 1 : 0)
        updateNotice()
        gtk_label_set_text(G(downloads), w.queue.jobs.isEmpty ? "" : "Downloads: " + w.queue.jobs.map { job in
            let pct = job.progress.map { " \(Int($0 * 100))%" } ?? ""
            return "\(job.title) — \(job.phase.label)\(pct)"
        }.joined(separator: "   ·   "))
        gtk_widget_set_visible(downloads, w.queue.jobs.isEmpty ? 0 : 1)
        refreshDetail()
    }

    private func subscribedSummary() -> String {
        let w = workshop
        if w.subscribedLoading && w.subscribed.isEmpty { return "Loading your subscriptions…" }
        if let e = w.subscribedError, w.subscribed.isEmpty { return e }
        guard let snap = w.subscriptionSnapshot else { return "" }
        if snap.files.isEmpty && !w.subscriptionSyncRunning {
            return (w.subscriptionSyncStatus.map { $0 + ". " } ?? "")
                + "No subscription list yet: set your Steam username and steamcmd in Settings, then Reload."
        }
        let downloaded = w.subscribed.filter { if case .installed = w.status(of: $0) { return true } else { return false } }.count
        var parts = ["\(w.subscribed.count) subscribed", "\(downloaded) downloaded"]
        if w.subscribedFilteredOut > 0 { parts.append("\(w.subscribedFilteredOut) hidden by the age filter or blocklist") }
        if w.subscribedUnavailable > 0 { parts.append("\(w.subscribedUnavailable) no longer on the Workshop") }
        if snap.lastUpdated > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(snap.lastUpdated))
            parts.append("list from " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
        }
        if w.subscribedLoading { parts.insert("Loading…", at: 0) }
        if w.subscriptionSyncRunning { parts.insert("Asking Steam…", at: 0) }
        else if let status = w.subscriptionSyncStatus { parts.insert(status, at: 0) }
        if let m = subscribedMessage { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private func info(_ item: WorkshopItem) -> String {
        var parts = [item.type.isEmpty ? "Unknown type" : item.type]
        if item.unsupportedReason != nil { parts.append("not supported") }
        switch workshop.status(of: item) {
        case .installed(let update): parts.append(update ? "update available" : "downloaded")
        case .queued: parts.append("queued")
        case .downloading(let s, let p): parts.append(p.map { "\(Int($0 * 100))%" } ?? s.lowercased())
        case .notInstalled: parts += item.displayTags.prefix(2)
        }
        return parts.joined(separator: " · ")
    }

    private func buildTiles(_ items: [WorkshopItem]) {
        generation += 1
        let gen = generation
        removeChildren(flow)
        statusLabels = [:]
        order = items
        for item in items {
            let tile = box(true, spacing: 4)
            addClass(tile, "photon-tile")
            let image = gtk_image_new_from_icon_name("image-x-generic", GTK_ICON_SIZE_DIALOG)!
            gtk_widget_set_size_request(image, 168, 168)
            pack(tile, image)
            let title = label(item.title, css: "photon-caption", xalign: 0)
            gtk_label_set_ellipsize(G(title), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(G(title), 20)
            pack(tile, title)
            let status = label(info(item), css: "photon-dim", xalign: 0)
            gtk_label_set_ellipsize(G(status), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(G(status), 22)
            pack(tile, status)
            statusLabels[item.id] = status
            if item.unsupportedReason != nil { gtk_widget_set_opacity(image, 0.45) }
            gtk_widget_set_tooltip_text(tile, item.unsupportedReason ?? item.title)
            gtk_flow_box_insert(G(flow), tile, -1)
            WorkshopPreviewCache.shared.preview(item) { [weak self] file in
                guard let self, self.generation == gen, let file else { return }
                Thumbnails.load(file.path, size: (168, 168), into: image)
            }
        }
        gtk_widget_show_all(flow)
        if let s = selected, let idx = order.firstIndex(where: { $0.id == s.id }),
           let child = gtk_flow_box_get_child_at_index(G(flow), Int32(idx)) {
            gtk_flow_box_select_child(G(flow), child)
        }
    }

    private func selectionChanged() {
        guard let list = gtk_flow_box_get_selected_children(G(flow)) else { return }
        defer { g_list_free(list) }
        guard let child = list.pointee.data else { return }
        let idx = Int(gtk_flow_box_child_get_index(child.assumingMemoryBound(to: GtkFlowBoxChild.self)))
        guard order.indices.contains(idx), order[idx].id != selected?.id else { return }
        selected = order[idx]
        showDetail()
    }

    private func updateNotice() {
        let w = workshop
        let user = w.username.trimmingCharacters(in: .whitespaces)
        var lines: [String] = []
        if w.steamcmdExecutable == nil { lines.append("Downloading needs steamcmd (your distribution's steamcmd package, or set its path in Settings).") }
        if user.isEmpty { lines.append("Set your Steam username in Settings to download. Browsing works without it.") }
        let problem = w.queue.loginProblem
        let key = lines.joined() + (problem ?? "")
        guard key != noticeKey else { return }
        noticeKey = key
        removeChildren(notice)
        if let problem {
            pack(notice, label("Steam login needed", css: "photon-section"))
            pack(notice, label(problem, wrap: true))
            let row = box(false, spacing: 8)
            let cmd = label(DownloadQueue.loginCommand(username: user), xalign: 0)
            gtk_label_set_selectable(G(cmd), 1)
            pack(row, cmd, expand: true)
            pack(row, button("Retry") { [weak self] in self?.workshop.queue.retry() })
            pack(notice, row)
        }
        for l in lines { pack(notice, label(l, css: "photon-dim", wrap: true)) }
        gtk_widget_show_all(notice)
        gtk_widget_set_visible(notice, key.isEmpty ? 0 : 1)
    }

    // MARK: details

    private func detailStateKey(_ item: WorkshopItem) -> String {
        "\(item.id)|\(workshop.status(of: item))|\(state.item(item.id) != nil)"
    }

    private func refreshDetail() {
        guard let item = selected else { return }
        if detailStateKey(item) != detailKey { showDetail() }
        if let l = detailStatus {
            gtk_label_set_text(G(l), workshop.queue.job(item.id).map { job in
                job.phase.label + (job.progress.map { " (\(Int($0 * 100))%)" } ?? "")
            } ?? "")
        }
    }

    private func showDetail() {
        removeChildren(detailBox)
        detailStatus = nil
        detailGeneration += 1
        guard let item = selected else {
            detailKey = ""
            let l = label("Select a Workshop item", css: "photon-dim", xalign: 0.5)
            gtk_widget_set_valign(l, GTK_ALIGN_CENTER)
            pack(detailBox, l, expand: true)
            gtk_widget_show_all(detailBox)
            return
        }
        detailKey = detailStateKey(item)
        let content = box(true, spacing: 8)
        margins(content, 14)
        pack(detailBox, scrolled(content), expand: true)
        let image = gtk_image_new_from_icon_name("image-x-generic", GTK_ICON_SIZE_DIALOG)!
        gtk_widget_set_size_request(image, 312, 176)
        pack(content, image)
        let gen = detailGeneration
        let id = item.id
        WorkshopPreviewCache.shared.preview(item, size: 640) { [weak self] file in
            guard let self, self.detailGeneration == gen, let file else { return }
            Thumbnails.load(file.path, size: (312, 176), into: image)
        }
        let title = label(item.title, css: "photon-title", wrap: true)
        gtk_label_set_selectable(G(title), 1)
        pack(content, title)
        var facts = ["\(item.type.isEmpty ? "Unknown type" : item.type) · \(item.rating ?? "Unrated") · \(item.id)"]
        if item.fileSize > 0 { facts.append(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)) }
        facts.append("\(item.subscriptions) subscribers")
        if item.timeUpdated > 0 {
            let f = DateFormatter()
            f.dateStyle = .medium
            facts.append("updated " + f.string(from: Date(timeIntervalSince1970: TimeInterval(item.timeUpdated))))
        }
        pack(content, label(facts.joined(separator: " · "), css: "photon-dim", wrap: true))
        if !item.displayTags.isEmpty { pack(content, label(item.displayTags.joined(separator: ", "), css: "photon-caption", wrap: true)) }
        if let reason = item.unsupportedReason { pack(content, label("⚠ " + reason, css: "photon-warning", wrap: true)) }

        let row = box(false, spacing: 6)
        let w = workshop
        switch w.status(of: item) {
        case .notInstalled:
            pack(row, button("Download") { [weak self] in self?.act { $0.download(item) } })
        case .installed(let update):
            if state.item(item.id) != nil {
                pack(row, button("Show in Library") { [weak self] in
                    self?.app.showBrowser()
                    self?.app.browser?.select(id)
                })
            }
            pack(row, button(update ? "Update" : "Download Again") { [weak self] in self?.act { $0.download(item, update: true) } })
            if w.canRemove(item.id) {
                pack(row, button("Remove…") { [weak self] in self?.confirmRemove(item) })
            }
        case .queued, .downloading:
            pack(row, button("Cancel") { [weak self] in self?.workshop.queue.cancel(id) })
        }
        pack(content, row)
        let status = label("", css: "photon-caption", wrap: true)
        detailStatus = status
        pack(content, status)
        if !item.description.isEmpty {
            pack(content, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            let d = label(item.description, css: "photon-caption", wrap: true)
            gtk_label_set_selectable(G(d), 1)
            pack(content, d)
        }
        gtk_widget_show_all(detailBox)
        refreshDetail()
    }

    /// Runs a download action; a refusal is shown under the buttons.
    private func act(_ f: (WorkshopController) -> String?) {
        if let why = f(workshop), let l = detailStatus { gtk_label_set_text(G(l), why) }
    }

    private func confirmRemove(_ item: WorkshopItem) {
        let d = photon_dialog_new(G(window), "Remove Wallpaper", "Remove")!
        let area = gtk_dialog_get_content_area(G(d))!
        margins(area, 12)
        let shown = state.activeIDs.contains(item.id) ? " It stops showing on the desktop." : ""
        pack(area, label("Delete “\(item.title)” from disk?\(shown) You can download it again later.", wrap: true))
        gtk_widget_show_all(d)
        on1(d, "response") { [weak self] resp in
            let r = Int32(truncatingIfNeeded: Int(bitPattern: resp))
            gtk_widget_destroy(d)
            guard r == 1, let self else { return }
            do { try self.workshop.remove(item.id) } catch {
                if let l = self.detailStatus { gtk_label_set_text(G(l), error.localizedDescription) }
            }
            self.showDetail()
        }
    }
}
#endif
