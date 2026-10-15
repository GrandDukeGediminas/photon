import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Finding steamcmd. It's never bundled: the user installs it (Homebrew cask `steamcmd` on macOS, the distribution's
/// `steamcmd` package or Valve's tarball on Linux), or photon downloads Valve's tarball into its own folder
/// (`SteamCmdInstaller`).
package enum SteamCmdLocator {
    package static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd", "/usr/games/steamcmd", "/usr/bin/steamcmd",
                    home + "/steamcmd/steamcmd.sh", home + "/.steam/steamcmd/steamcmd.sh", home + "/Steam/steamcmd.sh"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            list.append(String(dir) + "/steamcmd")
        }
        list.append(SteamCmdInstaller.directory.appendingPathComponent("steamcmd.sh").path)
        return list
    }

    /// The configured path when it is executable, else the first candidate that is.
    package static func find(override: String?) -> String? {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let path = (o as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// What steamcmd's console output says, line by line.
package enum SteamCmdEvent: Equatable {
    /// A step worth showing ("Updating steamcmd", "Logging in", "Logged in", "Downloading").
    case stage(String)
    /// No cached login (or a password / Steam Guard prompt): the user must log in once in a terminal.
    case needsLogin(String)
    /// The login was refused for another reason (e.g. rate limiting).
    case loginFailed(String)
    case downloading(id: String)
    case downloaded(id: String, path: String, bytes: Int64?)
    case downloadFailed(id: String, reason: String)
    case error(String)
}

/// Incremental parser of steamcmd output. steamcmd writes progress dots and prompts without a newline, so the
/// unterminated tail is checked for prompts too.
package struct SteamCmdOutputParser {
    private var buffer = ""
    private var promptReported = false

    package init() {}

    package mutating func feed(_ chunk: String) -> [SteamCmdEvent] {
        buffer += chunk
        var events: [SteamCmdEvent] = []
        while let r = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) {
            let line = String(buffer[..<r.lowerBound])
            buffer.removeSubrange(..<r.upperBound)
            events += Self.parse(line: line)
        }
        if !promptReported, let prompt = Self.prompt(in: buffer) {
            promptReported = true
            events.append(.needsLogin(prompt))
        }
        return events
    }

    /// The rest of the output at exit.
    package mutating func finish() -> [SteamCmdEvent] {
        let rest = buffer
        buffer = ""
        return rest.isEmpty ? [] : Self.parse(line: rest)
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    private static let success = try! NSRegularExpression(pattern: #"Success\. Downloaded item ([0-9]+) to "(.*)"(?: \(([0-9]+) bytes\))?"#)
    private static let failure = try! NSRegularExpression(pattern: #"ERROR! Download item ([0-9]+) failed \((.*)\)"#)
    private static let timeout = try! NSRegularExpression(pattern: #"ERROR! Timeout downloading item ([0-9]+)"#)
    private static let downloading = try! NSRegularExpression(pattern: #"Downloading item ([0-9]+)"#)
    private static let failedReason = try! NSRegularExpression(pattern: #"(?:FAILED|ERROR) \(([^)]*)\)"#)

    /// Login refusals that a terminal login fixes (as opposed to rate limiting or a Steam outage).
    private static let loginReasons = ["password", "two-factor", "two factor", "steam guard", "logon denied", "login denied",
                                       "authcode", "auth code", "expired", "invalid login", "account"]

    static func clean(_ line: String) -> String {
        let ns = line as NSString
        return ansi.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func parse(line raw: String) -> [SteamCmdEvent] {
        let line = clean(raw)
        guard !line.isEmpty else { return [] }
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        if let m = success.firstMatch(in: line, range: all), let id = group(m, 1), let path = group(m, 2) {
            return [.downloaded(id: id, path: path, bytes: group(m, 3).flatMap { Int64($0) })]
        }
        if let m = failure.firstMatch(in: line, range: all), let id = group(m, 1) {
            return [.downloadFailed(id: id, reason: group(m, 2) ?? "Failure")]
        }
        if let m = timeout.firstMatch(in: line, range: all), let id = group(m, 1) {
            return [.downloadFailed(id: id, reason: "Timeout")]
        }
        let lower = line.lowercased()
        if lower.contains("cached credentials not found") || lower.contains("no cached credentials") {
            return [.needsLogin("Cached credentials not found")]
        }
        if let p = prompt(in: line) { return [.needsLogin(p)] }
        if lower.hasPrefix("logging in user") || lower.contains("logging in using") {
            if let m = failedReason.firstMatch(in: line, range: all) { return [loginFailure(group(m, 1) ?? "")] }
            if lower.contains("failed") { return [loginFailure("")] }
            return [lower.hasSuffix("ok") ? .stage("Logged in") : .stage("Logging in")]
        }
        if lower.hasPrefix("failed") || lower.contains("failed login") {
            let reason = failedReason.firstMatch(in: line, range: all).flatMap { group($0, 1) } ?? line
            return [loginFailure(reason)]
        }
        if lower.contains("waiting for user info") && lower.hasSuffix("ok") { return [.stage("Logged in")] }
        if let m = downloading.firstMatch(in: line, range: all), let id = group(m, 1) { return [.downloading(id: id)] }
        if lower.contains("checking for available update") || lower.contains("downloading update")
            || lower.contains("verifying installation") || lower.contains("extracting package") || lower.contains("installing update") {
            return [.stage("Updating steamcmd")]
        }
        if line.hasPrefix("ERROR!") || lower.hasPrefix("error:") { return [.error(line)] }
        return []
    }

    private static func loginFailure(_ reason: String) -> SteamCmdEvent {
        let r = reason.lowercased()
        if r.contains("rate limit") { return .loginFailed("Steam is rate-limiting logins (\(reason)); wait a while and retry") }
        if loginReasons.contains(where: r.contains) || r.isEmpty { return .needsLogin(reason.isEmpty ? "Login failed" : reason) }
        // With no saved login for the account name steamcmd doesn't contact Steam at all and reports "FAILED (No
        // Connection)" (its connection log: "cached creds not available"), so this is a missing login, not the network.
        if r.contains("no connection") { return .needsLogin("no saved login for this account name") }
        return .loginFailed(reason)
    }

    /// An interactive prompt steamcmd waits on (it must never get one from photon).
    static func prompt(in text: String) -> String? {
        let t = clean(text).lowercased()
        if t.hasSuffix("password:") || t.contains("password: ") && t.hasSuffix(":") { return "Password prompt" }
        if t.contains("steam guard code:") || t.contains("two-factor code:") || t.contains("two factor code:")
            || t.contains("enter the current code") || t.contains("auth code:") {
            return "Steam Guard prompt"
        }
        return nil
    }
}

/// A running steamcmd (or a test stand-in).
package protocol SteamCmdProcess: AnyObject {
    /// Starts `executable args`; `output` gets stdout+stderr chunks and `exit` the status, both on a background queue.
    func start(executable: String, arguments: [String], environment: [String: String],
               output: @escaping (String) -> Void, exit: @escaping (Int32) -> Void) throws
    /// Stops it and everything it started.
    func terminate()
    /// Writes to its standard input (interactive runs only: the sign-in answers steamcmd's prompts this way).
    func write(_ text: String)
}

extension SteamCmdProcess {
    package func write(_ text: String) {}
}

package enum SteamCmdProcessError: LocalizedError {
    case spawn(Int32)
    package var errorDescription: String? {
        if case .spawn(let e) = self { return "Couldn't start steamcmd: \(String(cString: strerror(e)))" }
        return nil
    }
}

/// posix_spawn in a process group of its own, so that `terminate` also stops the steamcmd binary its launcher script
/// runs (the script waits on it rather than exec'ing it). stdin is /dev/null: steamcmd never gets typed input.
package final class SpawnedSteamCmd: SteamCmdProcess {
    /// Give steamcmd a pipe as standard input (`write`) instead of /dev/null.
    private let interactive: Bool
    private var stdinFD: Int32 = -1
    private var pid: pid_t = 0
    private let lock = NSLock()
    private var exited = false

    package init(interactive: Bool = false) { self.interactive = interactive }

    package func write(_ text: String) {
        lock.lock(); let fd = stdinFD; lock.unlock()
        guard fd >= 0 else { return }
        var bytes = Array(text.utf8)
        _ = bytes.withUnsafeMutableBytes { buf -> Int in
            #if canImport(Darwin)
            return Darwin.write(fd, buf.baseAddress, buf.count)
            #else
            return Glibc.write(fd, buf.baseAddress, buf.count)
            #endif
        }
        // The password passes through this buffer only; overwrite it before it is freed.
        for i in bytes.indices { bytes[i] = 0 }
    }

    package func start(executable: String, arguments: [String], environment: [String: String],
                       output: @escaping (String) -> Void, exit: @escaping (Int32) -> Void) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SteamCmdProcessError.spawn(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        var input: [Int32] = [-1, -1]
        if interactive {
            guard pipe(&input) == 0 else { close(readFD); close(writeFD); throw SteamCmdProcessError.spawn(errno) }
            posix_spawn_file_actions_adddup2(&actions, input[0], 0)
            posix_spawn_file_actions_addclose(&actions, input[0])
            posix_spawn_file_actions_addclose(&actions, input[1])
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        // Own process group; default signal handling and an empty mask (the parent may ignore or block SIGTERM/SIGPIPE).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigdelset(&all, SIGKILL)
        sigdelset(&all, SIGSTOP)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, envp)
        close(writeFD)
        if input[0] >= 0 { close(input[0]) }
        guard rc == 0 else {
            close(readFD)
            if input[1] >= 0 { close(input[1]) }
            throw SteamCmdProcessError.spawn(rc)
        }
        lock.lock(); pid = child; stdinFD = input[1]; lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            var pending = Data()
            while true {
                let n = read(readFD, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
                // Only whole UTF-8 sequences go out.
                if let s = String(data: pending, encoding: .utf8) {
                    output(s); pending.removeAll()
                } else if pending.count > 16 {
                    output(String(decoding: pending, as: UTF8.self)); pending.removeAll()
                }
            }
            if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
            close(readFD)
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self?.lock.lock()
            self?.exited = true
            if let fd = self?.stdinFD, fd >= 0 { close(fd); self?.stdinFD = -1 }
            self?.lock.unlock()
            // WIFEXITED / WEXITSTATUS; a signal gives 128 + signal, as shells report it.
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            exit(code)
        }
    }

    package func terminate() {
        lock.lock()
        let (p, done) = (pid, exited)
        lock.unlock()
        guard p > 0, !done else { return }
        kill(-p, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let done = self.exited; self.lock.unlock()
            if !done { kill(-p, SIGKILL) }
        }
    }
}
