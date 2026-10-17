import Combine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads Valve's steamcmd into photon's own folder (`~/Library/Application Support/photon2/steamcmd`,
/// `~/.local/share/photon2/steamcmd`) and runs it once so it updates itself. steamcmd keeps its login and downloads
/// under that folder.
package final class SteamCmdInstaller: ObservableObject {
    package enum State: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    @Published package private(set) var state: State = .idle

    package static var directory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/photon2/steamcmd")
        #else
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return data.appendingPathComponent("photon2/steamcmd")
        #endif
    }

    /// Valve's download.
    package static var tarball: URL {
        #if os(macOS)
        return URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
        #else
        return URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz")!
        #endif
    }

    package var directory: URL = SteamCmdInstaller.directory
    package var makeProcess: () -> SteamCmdProcess = { SpawnedSteamCmd() }
    /// Fetches the tarball to a local file; replaceable for tests.
    package var download: (URL, @escaping (URL?, Error?) -> Void) -> Void = { url, done in
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        URLSession(configuration: config).downloadTask(with: url) { file, response, error in
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return done(nil, WorkshopError.http(http.statusCode))
            }
            // The temporary file goes away when this returns: keep it.
            guard let file else { return done(nil, error) }
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("photon-steamcmd-\(UUID().uuidString).tar.gz")
            do { try FileManager.default.moveItem(at: file, to: keep); done(keep, nil) } catch { done(nil, error) }
        }.resume()
    }

    package init() {}

    package var script: URL { directory.appendingPathComponent("steamcmd.sh") }

    /// Downloads, unpacks and bootstraps steamcmd; `completion` gets steamcmd's path or nil, on the main queue.
    package func install(completion: ((String?) -> Void)? = nil) {
        if case .running = state { return }
        state = .running("Downloading steamcmd from Valve…")
        download(Self.tarball) { [weak self] file, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let file else { return self.fail("Couldn't download steamcmd: \(error?.localizedDescription ?? "no data")", completion) }
                self.unpack(file, completion: completion)
            }
        }
    }

    private func unpack(_ file: URL, completion: ((String?) -> Void)?) {
        state = .running("Unpacking steamcmd…")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar")
            tar.arguments = ["-xzf", file.path, "-C", directory.path]
            try tar.run()
            tar.waitUntilExit()
            try? FileManager.default.removeItem(at: file)
            guard tar.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: script.path) else {
                return fail("Couldn't unpack steamcmd (tar status \(tar.terminationStatus))", completion)
            }
        } catch {
            return fail("Couldn't unpack steamcmd: \(error.localizedDescription)", completion)
        }
        bootstrap(completion: completion)
    }

    /// The first run downloads the rest of steamcmd (`+quit`, no login).
    private func bootstrap(completion: ((String?) -> Void)?) {
        state = .running("Setting up steamcmd (first run downloads about 40 MB)…")
        var parser = SteamCmdOutputParser()
        var text = ""
        let p = makeProcess()
        do {
            try p.start(executable: script.path, arguments: ["+quit"], environment: ProcessInfo.processInfo.environment, output: { chunk in
                DispatchQueue.main.async {
                    text += chunk
                    for e in parser.feed(chunk) {
                        if case .stage(let s) = e { self.state = .running(s == "Updating steamcmd" ? "Updating steamcmd…" : s) }
                    }
                }
            }, exit: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == 0 || text.contains("Loading Steam API...OK") {
                        self.state = .done("steamcmd is ready")
                        completion?(self.script.path)
                    } else {
                        #if os(Linux)
                        let hint = " Valve's steamcmd is a 32-bit program; install your distribution's steamcmd package (or its 32-bit C library) instead."
                        #else
                        let hint = ""
                        #endif
                        self.fail("steamcmd's first run failed (status \(status)).\(hint)", completion)
                    }
                }
            })
        } catch {
            fail("Couldn't start steamcmd: \(error.localizedDescription)", completion)
        }
    }

    private func fail(_ message: String, _ completion: ((String?) -> Void)?) {
        state = .failed(message)
        completion?(nil)
    }
}

/// Signs steamcmd in to a Steam account from photon's own window: photon starts `steamcmd +login <user>` and answers its
/// prompts (`password:`, `Steam Guard code:` for an emailed code, `Two-factor code:` for the authenticator app) with
/// what the user types. The password and codes go straight to steamcmd's input and are never stored or logged;
/// steamcmd then remembers the login itself, as after a terminal login.
package final class SteamLogin: ObservableObject {
    package enum CodeKind: Equatable {
        /// Steam Guard by email.
        case email
        /// The Steam Guard mobile authenticator.
        case authenticator
    }

    package enum State: Equatable {
        case idle
        case working(String)
        case needsPassword
        /// A code is needed; `retry` when the previous one was refused.
        case needsCode(CodeKind, retry: Bool)
        case signedIn
        case failed(String)
    }

    @Published package private(set) var state: State = .idle

    package var executable: () -> String? = { nil }
    package var environment: [String: String] = ProcessInfo.processInfo.environment
    package var makeProcess: () -> SteamCmdProcess = { SpawnedSteamCmd(interactive: true) }
    /// The download queue, held while steamcmd is signing in (one steamcmd at a time).
    package weak var queue: DownloadQueue?
    private var process: SteamCmdProcess?
    private var buffer = ""
    /// steamcmd's last non-empty line, quoted when it stops for a reason photon doesn't recognise.
    private var lastLine: String?

    /// While steamcmd waits for the sign-in to be approved in the Steam Mobile app (Steam Guard mobile authenticator).
    package static let approveMessage = "Approve the sign-in in the Steam Mobile app on your phone…"
    /// steamcmd gave up waiting for that approval (about a minute) and stopped.
    package static let approvalTimedOut = "The sign-in wasn't approved in the Steam Mobile app in time. Try again and approve it on your phone."

    package init() {}

    package var isRunning: Bool { process != nil }

    /// Starts `steamcmd +login <user> +quit`; the state then asks for the password and any code.
    package func start(username: String) {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard process == nil else { return }
        guard !user.isEmpty else { return state = .failed("Enter your Steam username") }
        guard let exe = executable() else { return state = .failed("steamcmd isn't set up yet") }
        if queue?.isBusy == true { return state = .failed("Wait for the current download to finish") }
        buffer = ""
        lastLine = nil
        codeRefused = false
        state = .working("Starting steamcmd…")
        queue?.held = true
        let p = makeProcess()
        process = p
        do {
            try p.start(executable: exe, arguments: ["+@ShutdownOnFailedCommand", "1", "+login", user, "+quit"],
                        environment: environment, output: { [weak self] chunk in
                DispatchQueue.main.async { self?.received(chunk) }
            }, exit: { [weak self] status in
                DispatchQueue.main.async { self?.exited(status) }
            })
        } catch {
            process = nil
            queue?.held = false
            state = .failed(error.localizedDescription)
        }
    }

    package func submitPassword(_ password: String) {
        guard state == .needsPassword, let p = process else { return }
        state = .working("Signing in…")
        p.write(password + "\n")
    }

    package func submitCode(_ code: String) {
        guard case .needsCode = state, let p = process else { return }
        state = .working("Checking the code…")
        p.write(code.trimmingCharacters(in: .whitespaces) + "\n")
    }

    package func cancel() {
        process?.terminate()
    }

    private func received(_ chunk: String) {
        buffer += chunk
        // Whole lines first, then the unterminated tail, where steamcmd leaves its prompts.
        while let r = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) {
            let line = String(buffer[..<r.lowerBound])
            buffer.removeSubrange(..<r.upperBound)
            handle(line: line, complete: true)
        }
        if !buffer.isEmpty { handle(line: buffer, complete: false) }
    }

    private var codeRefused = false

    private func handle(line raw: String, complete: Bool) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        // steamcmd doesn't end a prompt's line after reading the answer: "Two-factor code:Logging in user …".
        if complete, let r = line.range(of: "Logging in user", options: .caseInsensitive), r.lowerBound != line.startIndex {
            line = String(line[r.lowerBound...])
        }
        let lower = line.lowercased()
        if complete, !line.isEmpty { lastLine = line }
        if lower.contains("timed out waiting for confirmation") {
            state = .failed(Self.approvalTimedOut)
            return
        }
        // "Please confirm the login in the Steam Mobile app on your phone." then "Waiting for confirmation..." with no
        // line end until it is approved.
        if lower.contains("confirm the login in the steam mobile app") || lower.hasPrefix("waiting for confirmation") {
            if lower.hasSuffix("ok") { state = .working("Signing in…") } else if state != .signedIn { state = .working(Self.approveMessage) }
            return
        }
        if lower.hasSuffix("password:") {
            if !complete { buffer = "" }
            // A second password prompt means the first was wrong.
            state = .needsPassword
            return
        }
        if lower.hasSuffix("steam guard code:") || lower.hasSuffix("two-factor code:") {
            if !complete { buffer = "" }
            state = .needsCode(lower.hasSuffix("two-factor code:") ? .authenticator : .email, retry: codeRefused)
            codeRefused = false
            return
        }
        guard complete else { return }
        if lower.contains("that steam guard code was invalid") || lower.contains("two-factor code mismatch") {
            codeRefused = true
            return
        }
        if lower.contains("this computer has not been authenticated") || lower.contains("please check your email") {
            state = .working("Steam emailed you a Steam Guard code…")
            return
        }
        if lower.hasPrefix("logging in user") {
            if lower.hasSuffix("ok") { state = .signedIn; return }
            if let open = line.range(of: "(", options: .backwards), let close = line.range(of: ")", options: .backwards),
               open.upperBound <= close.lowerBound, lower.contains("error (") || lower.contains("failed (") {
                state = .failed(Self.explain(String(line[open.upperBound..<close.lowerBound])))
                return
            }
            state = .working("Signing in…")
            return
        }
        if lower.hasPrefix("waiting for user info") && lower.hasSuffix("ok") { state = .signedIn }
    }

    private func exited(_ status: Int32) {
        process = nil
        queue?.held = false
        switch state {
        case .signedIn, .failed: break
        case .needsPassword, .needsCode: state = .failed("steamcmd stopped before signing in")
        case .working(Self.approveMessage): state = .failed(Self.approvalTimedOut)
        default: state = .failed(Self.stopped(status: status, lastLine: lastLine))
        }
    }

    /// Why sign-in failed when steamcmd stopped without a reason photon recognises: its status and last line.
    package static func stopped(status: Int32, lastLine: String?) -> String {
        if status == 0 { return "steamcmd stopped without signing in" }
        return "steamcmd stopped (status \(status))" + (lastLine.map { ": \($0.prefix(200))" } ?? "")
    }

    /// steamcmd's refusal reasons in words.
    package static func explain(_ reason: String) -> String {
        switch reason.lowercased() {
        case "invalid password": return "Wrong username or password"
        case "rate limit exceeded": return "Steam is limiting sign-in attempts. Wait a while and try again."
        case "two-factor code mismatch", "invalid login auth code": return "That code wasn't accepted"
        case "no connection": return "Couldn't reach Steam"
        case "account logon denied": return "Steam refused the sign-in (Steam Guard)"
        default: return "Steam refused the sign-in (\(reason))"
        }
    }
}
