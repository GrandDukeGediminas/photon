#if os(Linux)
import CGtk3
import Combine
import Foundation
import PhotonApp

/// Shown at launch until photon can run (macOS: OwnershipGateView): the Steam account passes the Wallpaper Engine
/// ownership check (`OwnershipCheck`), then Wallpaper Engine's files are downloaded when no install has them
/// (`EngineDownloader`). photon starts once they are there, and the window stays to show the subscribed wallpapers
/// downloading (`WorkshopController.syncSubscriptions`), closing itself when they are done. Closing it before photon
/// started quits.
final class OwnershipWindow {
    private enum Phase { case ownership, engine, subscriptions }

    unowned let app: LinuxApp
    let window: Widget
    private let ownershipBox: Widget
    private let entry: Widget
    private let statusLabel: Widget
    private let checkButton: Widget
    private let quitButton: Widget
    private let closeButton: Widget
    // The download phases: a heading, a note, a spinner or a progress bar, and Try Again after a failure.
    private let progressBox: Widget
    private let heading: Widget
    private let note: Widget
    private let spinnerRow: Widget
    private let spinner: Widget
    private let spinnerLabel: Widget
    private let bar: Widget
    private let retryButton: Widget
    private let owned: Bool
    private let start: () -> Void
    private let finished: () -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var phase = Phase.ownership
    private var started = false
    private var closed = false
    private var panel: SteamSignInPanel!
    private let panelBox: Widget

    /// `owned`: the account passed recently (`OwnershipCheck.mayStart`), so the files come next. `start` starts photon;
    /// `finished` runs when the window has closed.
    init(app: LinuxApp, owned: Bool, start: @escaping () -> Void, finished: @escaping () -> Void) {
        self.app = app
        self.owned = owned
        self.start = start
        self.finished = finished
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "photon")
        gtk_window_set_default_size(G(window), 520, -1)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        let root = box(true, spacing: 10)
        margins(root, 18)
        gtk_container_add(G(window), root)

        ownershipBox = box(true, spacing: 10)
        pack(root, ownershipBox)
        pack(ownershipBox, label("photon requires Wallpaper Engine", css: "photon-section"))
        pack(ownershipBox, label("photon requires a Steam account that owns Wallpaper Engine. Its wallpapers come from "
                                 + "Wallpaper Engine's Steam Workshop, and owning it supports the original developers. "
                                 + "photon asks Steam through steamcmd, using the login steamcmd saved; photon never sees "
                                 + "your password.", wrap: true))
        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(G(entry), "Steam username")
        gtk_entry_set_text(G(entry), app.state.workshop.username)
        pack(ownershipBox, entry)
        statusLabel = label("", wrap: true)
        gtk_label_set_selectable(G(statusLabel), 1)
        pack(ownershipBox, statusLabel)
        panelBox = box(true, spacing: 8)
        pack(ownershipBox, panelBox)

        progressBox = box(true, spacing: 10)
        pack(root, progressBox)
        heading = label("", css: "photon-section")
        note = label("", wrap: true)
        pack(progressBox, heading)
        pack(progressBox, note)
        spinnerRow = box(false, spacing: 8)
        spinner = gtk_spinner_new()!
        spinnerLabel = label("", wrap: true)
        gtk_label_set_selectable(G(spinnerLabel), 1)
        pack(spinnerRow, spinner)
        pack(spinnerRow, spinnerLabel, expand: true)
        pack(progressBox, spinnerRow)
        bar = gtk_progress_bar_new()!
        gtk_progress_bar_set_show_text(G(bar), 1)
        gtk_progress_bar_set_ellipsize(G(bar), PANGO_ELLIPSIZE_END)
        pack(progressBox, bar)
        retryButton = gtk_button_new_with_label("Try Again")!
        gtk_widget_set_halign(retryButton, GTK_ALIGN_START)
        pack(progressBox, retryButton)

        let row = box(false, spacing: 8)
        quitButton = button("Quit") { [weak app] in app?.quit() }
        pack(row, quitButton)
        checkButton = gtk_button_new_with_label("Check Ownership")!
        packEnd(row, checkButton)
        closeButton = gtk_button_new_with_label("Close")!
        packEnd(row, closeButton)
        pack(root, row)

        on(entry, "changed") { [weak self] in
            guard let self else { return }
            self.app.state.workshop.username = String(cString: gtk_entry_get_text(G(self.entry)))
            self.refresh()
        }
        on(entry, "activate") { [weak self] in self?.check() }
        on(checkButton, "clicked") { [weak self] in self?.check() }
        on(retryButton, "clicked") { [weak self] in self?.proceed() }
        on(closeButton, "clicked") { [weak self] in self?.close() }
        onEvent(window, "delete-event") { [weak self] in
            guard let self else { return false }
            if !self.started { self.app.quit() }
            self.closed = true
            DispatchQueue.main.async { self.finished() }
            return false
        }
        panel = SteamSignInPanel(workshop: app.state.workshop) { [weak self] in self?.check() }
        pack(panelBox, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        pack(panelBox, panel.widget)
        let workshop: WorkshopController = app.state.workshop
        let refresh = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        app.ownership.$status.sink { _ in refresh() }.store(in: &subscriptions)
        workshop.signIn.$state.sink { _ in refresh() }.store(in: &subscriptions)
        workshop.engine.$state.sink { _ in refresh() }.store(in: &subscriptions)
        workshop.objectWillChange.sink { refresh() }.store(in: &subscriptions)
        // Once photon has set up steamcmd, ask Steam straight away.
        workshop.installer.$state.sink { [weak self] s in
            if case .done = s { DispatchQueue.main.async { self?.check() } }
        }.store(in: &subscriptions)
        gtk_widget_show_all(window)
        refresh()
        gtk_window_present(G(window))
        if owned {
            proceed()
        } else if !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && workshop.steamcmdExecutable != nil {
            // Already set up (an account whose check lapsed, or a new install of a configured one): ask Steam right away.
            check()
        }
    }

    private func check() {
        guard phase == .ownership, app.state.workshop.steamcmdExecutable != nil else { return }
        app.ownership.check { [weak self] status in
            guard status == .owned else { return }
            after(600) { self?.proceed() }
        }
    }

    /// Owned: fetch Wallpaper Engine's files when they are missing, then start.
    private func proceed() {
        let workshop: WorkshopController = app.state.workshop
        guard !workshop.engineFilesInstalled else { return begin() }
        phase = .engine
        refresh()
        workshop.downloadEngineFiles { [weak self] problem in
            if problem == nil { self?.begin() } else { self?.refresh() }
        }
    }

    private func begin() {
        guard !started else { return }
        started = true
        phase = .subscriptions
        start()
        app.state.workshop.syncSubscriptions()
        refresh()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        gtk_widget_destroy(window)
        finished()
    }

    private func refresh() {
        guard !closed else { return }
        let w: WorkshopController = app.state.workshop
        gtk_widget_set_visible(ownershipBox, phase == .ownership ? 1 : 0)
        gtk_widget_set_visible(progressBox, phase == .ownership ? 0 : 1)
        gtk_widget_set_visible(quitButton, phase == .subscriptions ? 0 : 1)
        gtk_widget_set_visible(closeButton, phase == .subscriptions ? 1 : 0)
        switch phase {
        case .ownership: refreshOwnership(w)
        case .engine: refreshEngine(w.engine.state)
        case .subscriptions: refreshSubscriptions(w)
        }
    }

    private func refreshOwnership(_ w: WorkshopController) {
        var text: String
        switch app.ownership.status {
        case .unchecked: text = ""
        case .checking: text = "Asking Steam…"
        case .owned: text = "Wallpaper Engine is owned."
        case .notOwned: text = "This Steam account doesn't own Wallpaper Engine."
        case .needsLogin: text = ""
        case .failed(let m): text = m
        }
        gtk_label_set_text(G(statusLabel), text)
        gtk_widget_set_visible(statusLabel, text.isEmpty ? 0 : 1)
        // steamcmd missing or not signed in: the setup / sign-in panel takes over from the Check button.
        var signIn = w.steamcmdExecutable == nil || w.signIn.isRunning
        if case .needsLogin = app.ownership.status { signIn = true }
        gtk_widget_set_visible(panelBox, signIn ? 1 : 0)
        if signIn { panel.refresh() }
        gtk_widget_set_visible(checkButton, signIn ? 0 : 1)
        gtk_widget_set_sensitive(entry, w.signIn.isRunning ? 0 : 1)
        let ready = !w.username.trimmingCharacters(in: .whitespaces).isEmpty && w.steamcmdExecutable != nil
            && app.ownership.status != .checking
        gtk_widget_set_sensitive(checkButton, ready ? 1 : 0)
    }

    private func refreshEngine(_ state: EngineDownloader.State) {
        gtk_widget_set_visible(checkButton, 0)
        gtk_label_set_text(G(heading), "Downloading Wallpaper Engine's files")
        gtk_label_set_text(G(note), "photon builds wallpapers from Wallpaper Engine's own shaders, materials and effects. "
                           + "They come from your Steam account (about 800 MB) and stay in photon's folder.")
        var failed = false
        switch state {
        case .idle: showSpinner("Starting…")
        case let .running(stage, progress, bytes):
            if let progress {
                let size = bytes.map { " \(Self.size($0.done)) of \(Self.size($0.total))" } ?? " \(Int(progress * 100))%"
                showBar(progress, stage + size)
            } else {
                showSpinner(stage)
            }
        case .done: showSpinner("Wallpaper Engine's files are ready.", spinning: false)
        case .failed(let m): showSpinner(m, spinning: false); failed = true
        }
        gtk_widget_set_visible(retryButton, failed ? 1 : 0)
    }

    private func refreshSubscriptions(_ w: WorkshopController) {
        gtk_widget_set_visible(checkButton, 0)
        gtk_widget_set_visible(retryButton, 0)
        gtk_label_set_text(G(heading), "Downloading your wallpapers")
        gtk_label_set_text(G(note), "photon is running. Each wallpaper appears in the library when it has downloaded. You "
                           + "can close this window: the downloads continue in the background, and new subscriptions "
                           + "download whenever photon starts.")
        if let p = w.syncProgress {
            showBar(Double(p.done) / Double(max(p.total, 1)),
                    "Subscribed wallpapers: \(p.done) of \(p.total)" + (p.current.map { " — \($0)" } ?? ""))
        } else {
            showSpinner(w.subscriptionSyncStatus ?? "Asking Steam for your subscriptions…")
        }
        if !w.syncing { after(1000) { [weak self] in self?.close() } }
    }

    private func showSpinner(_ text: String, spinning: Bool = true) {
        gtk_widget_set_visible(bar, 0)
        gtk_widget_set_visible(spinnerRow, 1)
        gtk_widget_set_visible(spinner, spinning ? 1 : 0)
        if spinning { gtk_spinner_start(G(spinner)) } else { gtk_spinner_stop(G(spinner)) }
        gtk_label_set_text(G(spinnerLabel), text)
    }

    private func showBar(_ fraction: Double, _ text: String) {
        gtk_widget_set_visible(spinnerRow, 0)
        gtk_widget_set_visible(bar, 1)
        gtk_progress_bar_set_fraction(G(bar), min(max(fraction, 0), 1))
        gtk_progress_bar_set_text(G(bar), text)
    }

    static func size(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }
}
#endif
