import Combine
import Foundation

/// Wallpaper Engine's own files: the base assets scenes are built from (shaders, materials, effects, fonts), the
/// default projects, the locale strings and the web host whose runtime script web wallpapers get. They are the engine's,
/// so photon never ships them; it reads an existing install, or downloads the account's copy with steamcmd:
///
///     steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir <dir> +login <user> +app_update 431960 +quit
///
/// (about 800 MB installed) into photon's own folder, next to its steamcmd.
package enum EngineFiles {
    /// photon's copy: `~/Library/Application Support/photon2/wallpaper_engine`, `~/.local/share/photon2/wallpaper_engine`.
    package static var installDirectory: URL {
        SteamCmdInstaller.directory.deletingLastPathComponent().appendingPathComponent("wallpaper_engine")
    }

    /// Whether `assets` holds the engine's base assets. steamcmd stages a download and moves it into place when it is
    /// complete, so the folders are there only after a whole install (the test scenes' cut-down assets have these two).
    package static func isInstalled(assets: URL) -> Bool {
        var dir: ObjCBool = false
        return ["shaders", "materials"].allSatisfy {
            FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path, isDirectory: &dir) && dir.boolValue
        }
    }
}

/// Downloads Wallpaper Engine's files with steamcmd and the saved login. One steamcmd at a time: the download queue
/// waits while this runs.
package final class EngineDownloader: ObservableObject {
    package enum State: Equatable {
        case idle
        /// A step ("Starting steamcmd", "Downloading", "Verifying") and, when steamcmd reports it, the fraction done
        /// with the bytes.
        case running(String, progress: Double?, bytes: (done: Int64, total: Int64)?)
        case done
        case failed(String)

        package static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.done, .done): return true
            case let (.failed(x), .failed(y)): return x == y
            case let (.running(s, p, b1), .running(t, q, b2)): return s == t && p == q && b1?.done == b2?.done && b1?.total == b2?.total
            default: return false
            }
        }
    }

    /// What steamcmd's `app_update` output says.
    package enum Event: Equatable {
        case stage(String)
        /// "Update state (0x61) downloading, progress: 12.34 (1234 / 10000)".
        case progress(String, fraction: Double, done: Int64, total: Int64)
        case installed
        case failed(String)
    }

    @Published package private(set) var state: State = .idle

    package var username: () -> String = { "" }
    package var executable: () -> String? = { nil }
    package var environment: [String: String] = ProcessInfo.processInfo.environment
    package var makeProcess: () -> SteamCmdProcess = { SpawnedSteamCmd() }
    /// The download queue, held while this runs.
    package weak var queue: DownloadQueue?
    private var process: SteamCmdProcess?

    package init() {}

    package var isRunning: Bool { process != nil }

    /// Downloads (or completes) the install in `directory`; `completion` gets nil on success or why it failed, on the
    /// main queue.
    package func download(into directory: URL, completion: ((String?) -> Void)? = nil) {
        guard process == nil else { return }
        let user = username().trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return fail("Enter your Steam username first", completion) }
        guard let exe = executable() else { return fail("steamcmd isn't set up yet", completion) }
        if queue?.isBusy == true { return fail("Wait for the current download to finish", completion) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return fail("Couldn't create \(directory.path): \(error.localizedDescription)", completion)
        }
        state = .running("Starting steamcmd…", progress: nil, bytes: nil)
        queue?.held = true
        var login = SteamCmdOutputParser()
        var buffer = ""
        var problem: String?
        var installed = false
        var lastLine: String?
        let p = makeProcess()
        process = p
        // The install directory goes before the login (steamcmd refuses it after); the platform makes the Windows
        // depots download on macOS and Linux.
        let args = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1", "+@sSteamCmdForcePlatformType", "windows",
                    "+force_install_dir", directory.path, "+login", user, "+app_update", WorkshopPaths.appID, "+quit"]
        func handle(line: String) {
            let clean = SteamCmdOutputParser.clean(line)
            if !clean.isEmpty { lastLine = clean }
            for e in login.feed(line + "\n") where problem == nil {
                switch e {
                case .needsLogin(let reason): problem = DownloadQueue.loginMessage(username: user, reason: reason); p.terminate()
                case .loginFailed(let reason): problem = reason; p.terminate()
                case .stage("Logged in"): state = .running("Signed in. Starting the download…", progress: nil, bytes: nil)
                case .stage(let s) where s == "Updating steamcmd": state = .running("Updating steamcmd…", progress: nil, bytes: nil)
                default: break
                }
            }
            guard problem == nil, let event = Self.parse(line: clean) else { return }
            switch event {
            case .stage(let s): state = .running(s, progress: nil, bytes: nil)
            case let .progress(s, f, done, total): state = .running(s, progress: f, bytes: total > 0 ? (done, total) : nil)
            case .installed: installed = true
            case .failed(let reason): problem = reason
            }
        }
        do {
            try p.start(executable: exe, arguments: args, environment: environment, output: { chunk in
                DispatchQueue.main.async {
                    buffer += chunk
                    while let r = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) {
                        let line = String(buffer[..<r.lowerBound])
                        buffer.removeSubrange(..<r.upperBound)
                        handle(line: line)
                    }
                }
            }, exit: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !buffer.isEmpty { handle(line: buffer); buffer = "" }
                    self.process = nil
                    self.queue?.held = false
                    let assets = directory.appendingPathComponent("assets")
                    if problem == nil, installed || status == 0, EngineFiles.isInstalled(assets: assets) {
                        self.state = .done
                        completion?(nil)
                    } else {
                        let why = problem ?? lastLine.map { "steamcmd stopped (status \(status)): \($0)" }
                            ?? "steamcmd stopped (status \(status))"
                        self.fail(why, completion)
                    }
                }
            })
        } catch {
            process = nil
            queue?.held = false
            fail(error.localizedDescription, completion)
        }
    }

    package func cancel() { process?.terminate() }

    private func fail(_ message: String, _ completion: ((String?) -> Void)?) {
        state = .failed(message)
        completion?(message)
    }

    private static let progressPattern = try! NSRegularExpression(
        pattern: #"Update state \(0x[0-9a-fA-F]+\) ([^,]+), progress: ([0-9.]+) \(([0-9]+) / ([0-9]+)\)"#)
    private static let failurePattern = try! NSRegularExpression(pattern: #"ERROR! Failed to install app '[0-9]+' \(([^)]*)\)"#)
    private static let statePattern = try! NSRegularExpression(pattern: #"Error! App '[0-9]+' state is (0x[0-9a-fA-F]+) after update job"#)

    /// One line of `app_update` output (colour codes already removed).
    package static func parse(line: String) -> Event? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = progressPattern.firstMatch(in: line, range: all) {
            let what = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            let fraction = (Double(ns.substring(with: m.range(at: 2))) ?? 0) / 100
            let done = Int64(ns.substring(with: m.range(at: 3))) ?? 0, total = Int64(ns.substring(with: m.range(at: 4))) ?? 0
            // "progress: 0.00 (0 / 0)" while it prepares: no size to show yet.
            guard total > 0 else { return .stage(stageName(what)) }
            return .progress(stageName(what), fraction: min(max(fraction, 0), 1), done: done, total: total)
        }
        if line.hasPrefix("Success! App"), line.contains("fully installed") { return .installed }
        if let m = failurePattern.firstMatch(in: line, range: all) { return .failed(explain(ns.substring(with: m.range(at: 1)))) }
        if let m = statePattern.firstMatch(in: line, range: all) { return .failed(explainState(ns.substring(with: m.range(at: 1)))) }
        return nil
    }

    /// steamcmd's update states in words.
    static func stageName(_ s: String) -> String {
        if s.contains("download") { return "Downloading" }
        if s.contains("verifying") { return "Verifying" }
        if s.contains("preallocat") { return "Preparing" }
        if s.contains("commit") { return "Installing" }
        if s.contains("reconfigur") { return "Preparing" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func explain(_ reason: String) -> String {
        switch reason.lowercased() {
        case "no subscription": return "This Steam account doesn't own Wallpaper Engine (No subscription)"
        case "disk write failure": return "Couldn't write the files (Disk write failure). Check the free space."
        default: return "Steam couldn't install Wallpaper Engine's files (\(reason))"
        }
    }

    /// `state is 0x…` flags: 0x200 disk space, 0x400 no connection / content server, 0x2 the update failed.
    static func explainState(_ hex: String) -> String {
        let v = Int(hex.dropFirst(2), radix: 16) ?? 0
        if v & 0x200 != 0 { return "Not enough free disk space for Wallpaper Engine's files (state \(hex))" }
        if v & 0x400 != 0 { return "Couldn't reach Steam's content servers (state \(hex)). Check the connection and try again." }
        return "Steam couldn't finish downloading Wallpaper Engine's files (state \(hex)). Try again."
    }
}
