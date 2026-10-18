import AppKit
import SwiftUI

/// steamcmd setup and Steam sign-in inside photon: downloads Valve's steamcmd when none is installed, then answers
/// steamcmd's password and Steam Guard prompts from these fields. Nothing typed here is stored; steamcmd keeps the
/// login it makes.
struct SteamSignInView: View {
    @ObservedObject var workshop: WorkshopController
    @ObservedObject var installer: SteamCmdInstaller
    @ObservedObject var login: SteamLogin
    /// Called once steamcmd is signed in.
    var signedIn: () -> Void = {}
    @State private var password = ""
    @State private var code = ""

    init(workshop: WorkshopController, signedIn: @escaping () -> Void = {}) {
        self.workshop = workshop
        installer = workshop.installer
        login = workshop.signIn
        self.signedIn = signedIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workshop.steamcmdExecutable == nil {
                setup
            } else {
                signInForm
            }
        }
        .onChange(of: login.state) { _, s in
            if s == .signedIn {
                password = ""
                code = ""
                workshop.queue.retry()
                signedIn()
            }
        }
    }

    @ViewBuilder private var setup: some View {
        Text("photon uses Valve's steamcmd to talk to Steam. It isn't installed yet.")
        HStack {
            Button("Set Up steamcmd") { workshop.setUpSteamCmd() }
                .disabled({ if case .running = installer.state { return true } else { return false } }())
            switch installer.state {
            case .running(let s): ProgressView().controlSize(.small); Text(s).font(.caption).foregroundStyle(.secondary)
            case .failed(let s): Text(s).font(.caption).foregroundStyle(.red)
            case .done(let s): Text(s).font(.caption).foregroundStyle(.green)
            case .idle: EmptyView()
            }
        }
    }

    @ViewBuilder private var signInForm: some View {
        switch login.state {
        case .needsPassword:
            Text("Sign in to Steam as \(workshop.username)").font(.headline)
            SecureField("Steam password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendPassword)
            HStack {
                Button("Cancel") { login.cancel() }
                Spacer()
                Button("Sign In", action: sendPassword).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        case .needsCode(let kind, let retry):
            Text(kind == .authenticator ? "Enter the code from the Steam Guard section of the Steam app on your phone."
                 : "Steam emailed you a Steam Guard code. Enter it here.")
            if retry { Text("That code wasn't accepted. Try again.").font(.caption).foregroundStyle(.red) }
            TextField("Steam Guard code", text: $code)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(sendCode)
            HStack {
                Button("Cancel") { login.cancel() }
                Spacer()
                Button("Continue", action: sendCode).keyboardShortcut(.defaultAction).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .working(let s):
            HStack(alignment: .firstTextBaseline) { ProgressView().controlSize(.small); Text(s).fixedSize(horizontal: false, vertical: true) }
        case .signedIn:
            Label("Signed in. steamcmd will remember this login.", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .idle, .failed:
            if case .failed(let message) = login.state {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("steamcmd needs to sign in to Steam once. Your password goes only to steamcmd; photon doesn't keep it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Sign In to Steam…") { login.start(username: workshop.username) }
                    .disabled(workshop.username.trimmingCharacters(in: .whitespaces).isEmpty || login.isRunning)
            }
        }
    }

    private func sendPassword() {
        guard !password.isEmpty else { return }
        login.submitPassword(password)
        password = ""
    }

    private func sendCode() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        login.submitCode(c)
        code = ""
    }
}

/// The sign-in as a sheet (Workshop tab, Settings).
struct SteamSignInSheet: View {
    @ObservedObject var workshop: WorkshopController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steam").font(.title3.bold())
            TextField("Steam username", text: $workshop.username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SteamSignInView(workshop: workshop) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
            HStack {
                Spacer()
                Button("Close") { workshop.signIn.cancel(); dismiss() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
