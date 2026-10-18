import AppKit
import PhotonApp
import SwiftUI

/// Shown at launch until photon can run: the Steam account passes the Wallpaper Engine ownership check
/// (`OwnershipCheck`; steamcmd is set up and signed in here when needed), then Wallpaper Engine's files are downloaded
/// when no install has them (`EngineDownloader`). photon starts once they are there, and the window stays to show the
/// subscribed wallpapers downloading (`WorkshopController.syncSubscriptions`), closing itself when they are done.
struct OwnershipGateView: View {
    enum Phase { case ownership, engine, subscriptions }

    @ObservedObject var ownership: OwnershipCheck
    @ObservedObject var workshop: WorkshopController
    /// The account passed recently (`OwnershipCheck.mayStart`): no need to ask Steam before the files.
    let owned: Bool
    /// Starts photon (the files are there).
    let start: () -> Void
    let close: () -> Void
    @State private var phase = Phase.ownership

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .ownership: ownershipBody
            case .engine: EngineFilesView(engine: workshop.engine, retry: proceed)
            case .subscriptions: subscriptionsBody
            }
            Spacer(minLength: 0)
            HStack {
                if phase == .subscriptions {
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Quit") { NSApp.terminate(nil) }
                    Spacer()
                    if phase == .ownership {
                        if ownership.status == .checking { ProgressView().controlSize(.small) }
                        if !needsSignIn {
                            Button("Check Ownership", action: check)
                                .keyboardShortcut(.defaultAction)
                                .disabled(ownership.status == .checking || workshop.username.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440, alignment: .topLeading)
        .onReceive(workshop.installer.$state) { s in
            if case .done = s { check() }
        }
        .onChange(of: workshop.syncing) { _, syncing in
            if phase == .subscriptions && !syncing { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: close) }
        }
        .onAppear {
            if owned {
                proceed()
            } else if !workshop.username.trimmingCharacters(in: .whitespaces).isEmpty && workshop.steamcmdExecutable != nil {
                // Already set up (an account whose check lapsed): ask Steam right away.
                check()
            }
        }
    }

    @ViewBuilder private var ownershipBody: some View {
        Text("photon requires Wallpaper Engine").font(.title2.bold())
        Text("photon requires a Steam account that owns Wallpaper Engine. Its wallpapers come from Wallpaper Engine's "
             + "Steam Workshop, and owning it supports the original developers. Enter your Steam username and photon "
             + "will ask Steam.")
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
    }

    @ViewBuilder private var subscriptionsBody: some View {
        Text("Downloading your wallpapers").font(.title2.bold())
        Label("photon is running.", systemImage: "checkmark.circle").foregroundStyle(.green)
        if let p = workshop.syncProgress {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                Text("Subscribed wallpapers: \(p.done) of \(p.total)")
            } currentValueLabel: {
                Text(p.current ?? " ").lineLimit(1)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(workshop.subscriptionSyncStatus ?? "Asking Steam for your subscriptions…")
            }
        }
        Text("Each wallpaper appears in the library when it has downloaded. You can close this window: the downloads "
             + "continue in the background, and new subscriptions download whenever photon starts.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
            Label("Wallpaper Engine is owned.", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .notOwned:
            Label("This Steam account doesn't own Wallpaper Engine.", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check() {
        guard workshop.steamcmdExecutable != nil else { return }
        ownership.check { status in
            if status == .owned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: proceed) }
        }
    }

    /// Owned: fetch Wallpaper Engine's files when they are missing, then start.
    private func proceed() {
        guard !workshop.engineFilesInstalled else { return begin() }
        phase = .engine
        workshop.downloadEngineFiles { problem in
            if problem == nil { begin() }
        }
    }

    private func begin() {
        start()
        phase = .subscriptions
        workshop.syncSubscriptions()
    }
}

/// Wallpaper Engine's files downloading: a progress bar with the size when steamcmd reports it, else a spinner.
struct EngineFilesView: View {
    @ObservedObject var engine: EngineDownloader
    let retry: () -> Void

    var body: some View {
        Text("Downloading Wallpaper Engine's files").font(.title2.bold())
        Text("photon builds wallpapers from Wallpaper Engine's own shaders, materials and effects. They come from your "
             + "Steam account (about 800 MB) and stay in photon's folder.")
            .fixedSize(horizontal: false, vertical: true)
        switch engine.state {
        case .idle:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting…") }
        case let .running(stage, progress, bytes):
            if let progress {
                ProgressView(value: progress) {
                    Text(stage)
                } currentValueLabel: {
                    Text(bytes.map { "\(Self.size($0.done)) of \(Self.size($0.total))" } ?? "\(Int(progress * 100))%")
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(stage) }
            }
        case .done:
            Label("Wallpaper Engine's files are ready.", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry)
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
