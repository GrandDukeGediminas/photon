import Combine
import Foundation

/// photon only runs for a Steam account that owns Wallpaper Engine (app 431960). The account is asked through steamcmd
/// with the login it saved (`+login <user> +licenses_for_app 431960`); photon never sees a password. An active licence
/// whose apps include 431960 counts:
///
///     License packageID 1:
///      - State   : Active (flags 0x200) - Purchased : … in "XX", Split
///      - Apps : 431960, 1790230,  (2 in total)
///
/// A successful check is remembered for the account. It is repeated after `recheckAfter`; when Steam can't be reached the
/// last success counts until `offlineGrace` has passed.
package final class OwnershipCheck: ObservableObject {
    package enum Status: Equatable {
        case unchecked
        case checking
        case owned
        case notOwned
        /// steamcmd has no saved login for the account (the message says how to make one).
        case needsLogin(String)
        case failed(String)
    }

    package static let verifiedKey = "ownershipverified"
    package static let accountKey = "ownershipaccount"
    package static let recheckAfter: TimeInterval = 7 * 86400
    package static let offlineGrace: TimeInterval = 30 * 86400

    @Published package private(set) var status: Status = .unchecked

    private let defaults: UserDefaults
    package var username: () -> String = { "" }
    package var executable: () -> String? = { nil }
    package var environment: [String: String] = ProcessInfo.processInfo.environment
    package var makeProcess: () -> SteamCmdProcess = { SpawnedSteamCmd() }
    /// The download queue, held while the check runs (one steamcmd at a time).
    package weak var queue: DownloadQueue?
    package var now: () -> Date = Date.init
    private var process: SteamCmdProcess?

    package init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The check owned by the app's Workshop settings (username, steamcmd path, download queue).
    package convenience init(workshop: WorkshopController, defaults: UserDefaults) {
        self.init(defaults: defaults)
        username = { [weak workshop] in workshop?.username ?? "" }
        executable = { [weak workshop] in workshop?.steamcmdExecutable }
        queue = workshop.queue
        environment = workshop.queue.environment
    }

    private var account: String { username().trimmingCharacters(in: .whitespaces).lowercased() }

    /// When the current account last passed the check, if it did.
    package var lastVerified: Date? {
        guard !account.isEmpty, defaults.string(forKey: Self.accountKey) == account else { return nil }
        let t = defaults.double(forKey: Self.verifiedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The app may start without asking Steam: the account passed within the offline grace period.
    package var mayStart: Bool {
        guard let t = lastVerified else { return false }
        let age = now().timeIntervalSince(t)
        return age >= 0 && age < Self.offlineGrace
    }

    /// The last success is old enough to ask Steam again.
    package var dueForRecheck: Bool {
        guard let t = lastVerified else { return true }
        let age = now().timeIntervalSince(t)
        return age < 0 || age >= Self.recheckAfter
    }

    /// Asks Steam. `completion` gets the result on the main queue.
    package func check(completion: ((Status) -> Void)? = nil) {
        if status == .checking { return }
        let user = username().trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return finish(.failed("Enter the Steam account that owns Wallpaper Engine"), completion) }
        guard let exe = executable() else {
            return finish(.failed("steamcmd wasn't found. Install it (macOS: brew install --cask steamcmd) or set its path in Settings."), completion)
        }
        if queue?.isBusy == true { return finish(.failed("Wait for the current download to finish"), completion) }
        status = .checking
        queue?.held = true
        var parser = SteamCmdOutputParser()
        var text = ""
        var problem: Status?
        let p = makeProcess()
        process = p
        let args = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1", "+login", user,
                    "+licenses_for_app", WorkshopPaths.appID, "+quit"]
        func handle(_ events: [SteamCmdEvent]) {
            for e in events where problem == nil {
                switch e {
                case .needsLogin(let reason):
                    problem = .needsLogin(DownloadQueue.loginMessage(username: user, reason: reason))
                    p.terminate()
                case .loginFailed(let reason):
                    problem = .failed(reason)
                    p.terminate()
                default: break
                }
            }
        }
        do {
            try p.start(executable: exe, arguments: args, environment: environment, output: { chunk in
                DispatchQueue.main.async {
                    text += chunk
                    handle(parser.feed(chunk))
                }
            }, exit: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    handle(parser.finish())
                    self.process = nil
                    self.queue?.held = false
                    if let problem { return self.finish(problem, completion) }
                    switch Self.owns(text) {
                    case true?:
                        self.defaults.set(self.account, forKey: Self.accountKey)
                        self.defaults.set(self.now().timeIntervalSince1970, forKey: Self.verifiedKey)
                        self.finish(.owned, completion)
                    case false?:
                        self.defaults.removeObject(forKey: Self.verifiedKey)
                        self.finish(.notOwned, completion)
                    case nil:
                        self.finish(.failed("Steam didn't answer (steamcmd status \(status)). Check the connection and try again."), completion)
                    }
                }
            })
        } catch {
            queue?.held = false
            finish(.failed(error.localizedDescription), completion)
        }
    }

    package func cancel() { process?.terminate() }

    private func finish(_ s: Status, _ completion: ((Status) -> Void)?) {
        status = s
        completion?(s)
    }

    /// `licenses_for_app` output: true when an active licence lists app 431960, false when the login completed without
    /// one, nil when the login never completed (no answer to judge).
    package static func owns(_ text: String) -> Bool? {
        var loggedIn = false, active = false, owned = false
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("logging in user") && lower.hasSuffix("ok") { loggedIn = true }
            if lower.hasPrefix("waiting for user info") && lower.hasSuffix("ok") { loggedIn = true }
            if lower.hasPrefix("license packageid") { active = false; loggedIn = true }
            if lower.hasPrefix("- state") {
                let value = lower.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                active = value.hasPrefix("active")
            }
            if lower.hasPrefix("- apps"), active {
                let list = lower.split(separator: ":", maxSplits: 1).last ?? ""
                let apps = list.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "(" }).map(String.init)
                if apps.contains(WorkshopPaths.appID) { owned = true }
            }
        }
        if owned { return true }
        return loggedIn ? false : nil
    }
}
