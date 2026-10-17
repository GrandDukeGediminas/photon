#if os(Linux)
import CGtk3
import Combine
import Foundation
import PhotonApp

/// Shown at launch until the Steam account passes the Wallpaper Engine ownership check (`OwnershipCheck`; macOS:
/// OwnershipGateView). Closing it quits.
final class OwnershipWindow {
    unowned let app: LinuxApp
    let window: Widget
    private let entry: Widget
    private let statusLabel: Widget
    private let checkButton: Widget
    private let passed: () -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var done = false
    private var panel: SteamSignInPanel!
    private let panelBox: Widget

    init(app: LinuxApp, passed: @escaping () -> Void) {
        self.app = app
        self.passed = passed
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "photon")
        gtk_window_set_default_size(G(window), 520, -1)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        let root = box(true, spacing: 10)
        margins(root, 18)
        gtk_container_add(G(window), root)
        pack(root, label("photon requires Wallpaper Engine", css: "photon-section"))
        pack(root, label("photon requires a Steam account that owns Wallpaper Engine. Its wallpapers come from Wallpaper "
                         + "Engine's Steam Workshop, and owning it supports the original developers. photon asks Steam "
                         + "through steamcmd, using the login steamcmd saved; photon never sees your password.", wrap: true))
        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(G(entry), "Steam username")
        gtk_entry_set_text(G(entry), app.state.workshop.username)
        pack(root, entry)
        statusLabel = label("", wrap: true)
        gtk_label_set_selectable(G(statusLabel), 1)
        pack(root, statusLabel)
        panelBox = box(true, spacing: 8)
        pack(root, panelBox)
        let row = box(false, spacing: 8)
        pack(row, button("Quit") { [weak app] in app?.quit() })
        checkButton = gtk_button_new_with_label("Check Ownership")!
        packEnd(row, checkButton)
        pack(root, row)

        on(entry, "changed") { [weak self] in
            guard let self else { return }
            self.app.state.workshop.username = String(cString: gtk_entry_get_text(G(self.entry)))
            self.refresh()
        }
        on(entry, "activate") { [weak self] in self?.check() }
        on(checkButton, "clicked") { [weak self] in self?.check() }
        onEvent(window, "delete-event") { [weak self] in
            if self?.done != true { self?.app.quit() }
            return false
        }
        panel = SteamSignInPanel(workshop: app.state.workshop) { [weak self] in self?.check() }
        pack(panelBox, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        pack(panelBox, panel.widget)
        app.ownership.$status.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        app.state.workshop.signIn.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        // Once photon has set up steamcmd, ask Steam straight away.
        app.state.workshop.installer.$state.sink { [weak self] s in
            if case .done = s { DispatchQueue.main.async { self?.check() } }
        }.store(in: &subscriptions)
        gtk_widget_show_all(window)
        refresh()
        gtk_window_present(G(window))
        // Already set up (an account whose check lapsed, or a new install of a configured one): ask Steam right away.
        if !app.state.workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && app.state.workshop.steamcmdExecutable != nil {
            check()
        }
    }

    private func check() {
        guard app.state.workshop.steamcmdExecutable != nil else { return }
        app.ownership.check { [weak self] status in
            guard let self, status == .owned else { return }
            after(600) {
                self.done = true
                gtk_widget_destroy(self.window)
                self.passed()
            }
        }
    }

    private func refresh() {
        let w: WorkshopController = app.state.workshop
        var text: String
        switch app.ownership.status {
        case .unchecked: text = ""
        case .checking: text = "Asking Steam…"
        case .owned: text = "Wallpaper Engine is owned. Starting…"
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
}
#endif
