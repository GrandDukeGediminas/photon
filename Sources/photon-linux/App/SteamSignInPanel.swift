#if os(Linux)
import CGtk3
import Combine
import Foundation
import PhotonApp

/// steamcmd setup and Steam sign-in (macOS: SteamSignInView): downloads Valve's steamcmd when none is installed, then
/// answers steamcmd's password and Steam Guard prompts from these entries. Nothing typed here is stored.
final class SteamSignInPanel {
    let widget: Widget
    private let workshop: WorkshopController
    private let message: Widget
    private let entry: Widget
    private let primary: Widget
    private let cancel: Widget
    private var subscriptions: Set<AnyCancellable> = []
    private let signedIn: () -> Void
    private var shownKey = ""

    init(workshop: WorkshopController, signedIn: @escaping () -> Void) {
        self.workshop = workshop
        self.signedIn = signedIn
        widget = box(true, spacing: 8)
        message = label("", wrap: true)
        pack(widget, message)
        entry = gtk_entry_new()!
        pack(widget, entry)
        let row = box(false, spacing: 8)
        cancel = gtk_button_new_with_label("Cancel")!
        primary = gtk_button_new_with_label("")!
        pack(row, cancel)
        packEnd(row, primary)
        pack(widget, row)
        on(primary, "clicked") { [weak self] in self?.act() }
        on(entry, "activate") { [weak self] in self?.act() }
        on(cancel, "clicked") { [weak self] in self?.workshop.signIn.cancel() }
        let refresh = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        workshop.signIn.$state.sink { s in
            refresh()
            if s == .signedIn {
                DispatchQueue.main.async { [weak self] in
                    self?.workshop.queue.retry()
                    self?.signedIn()
                }
            }
        }.store(in: &subscriptions)
        workshop.installer.$state.sink { _ in refresh() }.store(in: &subscriptions)
        workshop.objectWillChange.sink { refresh() }.store(in: &subscriptions)
        refresh()
    }

    private enum Mode { case setup, start, password, code, busy, done }

    private var mode: Mode {
        if workshop.steamcmdExecutable == nil { return .setup }
        switch workshop.signIn.state {
        case .needsPassword: return .password
        case .needsCode: return .code
        case .working: return .busy
        case .signedIn: return .done
        case .idle, .failed: return .start
        }
    }

    func refresh() {
        let login = workshop.signIn
        var text = ""
        var button = ""
        var showEntry = false
        var secret = false
        var placeholder = ""
        var busy = false
        switch mode {
        case .setup:
            text = "photon uses Valve's steamcmd to talk to Steam. It isn't installed yet."
            button = "Set Up steamcmd"
            switch workshop.installer.state {
            case .running(let s): text += "\n" + s; busy = true
            case .failed(let s): text += "\n" + s
            default: break
            }
        case .start:
            if case .failed(let m) = login.state { text = m + "\n\n" }
            text += "steamcmd needs to sign in to Steam once. Your password goes only to steamcmd; photon doesn't keep it."
            button = "Sign In to Steam"
        case .password:
            text = "Sign in to Steam as \(workshop.username)"
            button = "Sign In"; showEntry = true; secret = true; placeholder = "Steam password"
        case .code:
            if case .needsCode(let kind, let retry) = login.state {
                text = (retry ? "That code wasn't accepted. " : "")
                    + (kind == .authenticator ? "Enter the code from the Steam Guard section of the Steam app on your phone."
                       : "Steam emailed you a Steam Guard code. Enter it here.")
            }
            button = "Continue"; showEntry = true; placeholder = "Steam Guard code"
        case .busy:
            if case .working(let s) = login.state { text = s }
            busy = true
        case .done:
            text = "Signed in. steamcmd will remember this login."
        }
        gtk_label_set_text(G(message), text)
        let key = "\(mode)|\(secret)"
        if key != shownKey {
            shownKey = key
            gtk_entry_set_text(G(entry), "")
            gtk_entry_set_visibility(G(entry), secret ? 0 : 1)
            gtk_entry_set_placeholder_text(G(entry), placeholder)
            if showEntry { gtk_widget_grab_focus(entry) }
        }
        gtk_widget_set_visible(entry, showEntry ? 1 : 0)
        gtk_button_set_label(G(primary), button)
        gtk_widget_set_visible(primary, button.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(primary, busy ? 0 : 1)
        gtk_widget_set_visible(cancel, mode == .password || mode == .code ? 1 : 0)
    }

    private func act() {
        let text = String(cString: gtk_entry_get_text(G(entry)))
        switch mode {
        case .setup: workshop.setUpSteamCmd()
        case .start: workshop.signIn.start(username: workshop.username)
        case .password:
            guard !text.isEmpty else { return }
            workshop.signIn.submitPassword(text)
            gtk_entry_set_text(G(entry), "")
        case .code:
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            workshop.signIn.submitCode(text)
            gtk_entry_set_text(G(entry), "")
        default: break
        }
    }
}

/// The sign-in panel in its own window (the Workshop window's login notice, Settings).
final class SteamSignInWindow {
    let window: Widget
    private var panel: SteamSignInPanel!

    init(workshop: WorkshopController) {
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(G(window), "Steam")
        gtk_window_set_default_size(G(window), 440, -1)
        gtk_window_set_wmclass(G(window), "photon2", "photon2")
        let root = box(true, spacing: 10)
        margins(root, 16)
        gtk_container_add(G(window), root)
        let user = gtk_entry_new()!
        gtk_entry_set_placeholder_text(G(user), "Steam username")
        gtk_entry_set_text(G(user), workshop.username)
        on(user, "changed") { workshop.username = String(cString: gtk_entry_get_text(G(user))) }
        pack(root, user)
        panel = SteamSignInPanel(workshop: workshop) { [weak self] in
            after(800) { if let w = self?.window { gtk_widget_hide(w) } }
        }
        pack(root, panel.widget)
        onEvent(window, "delete-event") { [weak self] in
            workshop.signIn.cancel()
            if let w = self?.window { gtk_widget_hide(w) }
            return true
        }
    }

    func present() {
        gtk_widget_show_all(window)
        panel.refresh() // after show_all, which shows the hidden entry and buttons too
        gtk_window_present(G(window))
    }
}
#endif
