import AppKit
import SwiftUI

/// Shown at launch until the Steam account passes the Wallpaper Engine ownership check (`OwnershipCheck`): sets up
/// steamcmd, signs it in when it has no saved login, and checks, all in this window.
struct OwnershipGateView: View {
    @ObservedObject var ownership: OwnershipCheck
    @ObservedObject var workshop: WorkshopController
    let passed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("photon needs Wallpaper Engine").font(.title2.bold())
            Text("photon runs only for a Steam account that owns Wallpaper Engine. Enter your Steam username and photon will "
                 + "ask Steam.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Steam username", text: $workshop.username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(check)
                .disabled(workshop.signIn.isRunning)
            statusView
            if needsSignIn {
                Divider()
                SteamSignInView(workshop: workshop) { check() }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                if ownership.status == .checking { ProgressView().controlSize(.small) }
                if !needsSignIn {
                    Button("Check Ownership", action: check)
                        .keyboardShortcut(.defaultAction)
                        .disabled(ownership.status == .checking || workshop.username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440, alignment: .topLeading)
        .onReceive(workshop.installer.$state) { s in
            if case .done = s { check() }
        }
        .onAppear {
            // Already set up (an account whose check lapsed): ask Steam right away.
            if !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && workshop.steamcmdExecutable != nil { check() }
        }
    }

    /// steamcmd is missing or has no saved login: the setup / sign-in panel takes over.
    private var needsSignIn: Bool {
        if workshop.steamcmdExecutable == nil { return true }
        if case .needsLogin = ownership.status { return true }
        if workshop.signIn.isRunning { return true }
        return false
    }

    @ViewBuilder private var statusView: some View {
        switch ownership.status {
        case .unchecked, .needsLogin:
            EmptyView()
        case .checking:
            Text("Asking Steam…").foregroundStyle(.secondary)
        case .owned:
            Label("Wallpaper Engine is owned. Starting…", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .notOwned:
            Label("This Steam account doesn't own Wallpaper Engine.", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func check() {
        guard workshop.steamcmdExecutable != nil else { return }
        ownership.check { status in
            if status == .owned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: passed) }
        }
    }
}
