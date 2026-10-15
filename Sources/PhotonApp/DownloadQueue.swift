import Combine
import Foundation

/// Workshop downloads through steamcmd, one at a time:
///
///     steamcmd +@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +login <username> +workshop_download_item 431960 <id> +quit
///
/// photon never asks for, stores or passes a password. steamcmd logs in with the credentials it cached when the user
/// logged in once in a terminal (`steamcmd +login <username> +quit`, with the Steam Guard code). When there are none
/// steamcmd says so (or prompts, which is caught and stopped) and the queue pauses with `loginProblem` set until
/// `retry()`.
///
/// States of a job: queued → running(stage) → succeeded | failed(reason) | needsLogin(reason) | cancelled.
package final class DownloadQueue: ObservableObject {
    package enum Kind: String { case download, update }

    package enum Phase: Equatable {
        case queued
        case running(String)
        case succeeded
        case failed(String)
        case needsLogin(String)
        case cancelled

        package var isFinished: Bool {
            switch self {
            case .succeeded, .failed, .needsLogin, .cancelled: return true
            case .queued, .running: return false
            }
        }

        package var label: String {
            switch self {
            case .queued: return "Queued"
            case .running(let s): return s
            case .succeeded: return "Done"
            case .failed(let r): return "Failed: \(r)"
            case .needsLogin: return "Steam login needed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    package struct Job: Identifiable, Equatable {
        package let id: String
        package var title: String
        package var kind: Kind
        package var phase: Phase = .queued
        /// 0–1 while the staging folder grows, when the size is known.
        package var progress: Double?
        package var expectedBytes: Int64
        /// Where steamcmd put the item.
        package var installedPath: URL?
        /// Queued because a downloaded preset needs it.
        package var dependencyOf: String?
    }

    @Published package private(set) var jobs: [Job] = []
    /// Set while the queue is paused on a login problem: what to tell the user.
    @Published package private(set) var loginProblem: String?

    /// The Steam account name (no password, ever).
    package var username: () -> String = { "" }
    /// The steamcmd executable, or nil when none is installed.
    package var executable: () -> String? = { nil }
    /// Ids that must not be downloaded (the content filter).
    package var hidden: () -> Set<String> = { [] }
    /// Whether an id is in the library already (dependencies that are present aren't downloaded again).
    package var isInstalled: (String) -> Bool = { _ in false }
    /// Where steamcmd is expected to put items (`…/workshop/content/431960`), for the progress estimate.
    package var contentDirectory: () -> URL? = { nil }
    /// Called on the main queue after an item landed: its id and folder.
    package var onInstalled: ((String, URL) -> Void)?
    /// Every output line, for a log view (on the main queue).
    package var onOutput: ((String) -> Void)?
    /// The process factory (tests pass a fake steamcmd script through `SpawnedSteamCmd`).
    package var makeProcess: () -> SteamCmdProcess = { SpawnedSteamCmd() }
    /// Extra environment for steamcmd.
    package var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Another steamcmd run (the subscription refresh) owns steamcmd: queued jobs wait until it is released.
    package var held = false {
        didSet { if !held && oldValue { startNext() } }
    }

    /// Reports a login problem found by another steamcmd run, so the notice and Retry cover it too.
    package func reportLoginProblem(_ message: String) { loginProblem = message }

    private var process: SteamCmdProcess?
    private var parser = SteamCmdOutputParser()
    private var runningID: String?
    private var progressTimer: Timer?
    /// Set when the running job's outcome is already decided (login problem, cancel) before steamcmd exits.
    private var decided = false
    private var lastError: String?

    package init() {}

    package var current: Job? { runningID.flatMap { id in jobs.first { $0.id == id } } }
    package var isBusy: Bool { runningID != nil }
    package func job(_ id: String) -> Job? { jobs.last { $0.id == id } }

    /// Adds a download; returns why it was refused, or nil.
    @discardableResult
    package func enqueue(id: String, title: String, kind: Kind = .download, expectedBytes: Int64 = 0,
                         dependencyOf: String? = nil) -> String? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return "Not a workshop id" }
        if hidden().contains(id) { return "This item is hidden by the content filter" }
        if let j = job(id), !j.phase.isFinished { return nil }
        jobs.removeAll { $0.id == id && $0.phase.isFinished }
        jobs.append(Job(id: id, title: title, kind: kind, expectedBytes: expectedBytes, dependencyOf: dependencyOf))
        startNext()
        return nil
    }

    /// Removes a queued job, or stops the running one.
    package func cancel(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id && !$0.phase.isFinished }) else { return }
        if runningID == id {
            decided = true
            jobs[i].phase = .cancelled
            process?.terminate()
        } else {
            jobs.remove(at: i)
        }
    }

    /// Forgets finished jobs.
    package func clearFinished() { jobs.removeAll { $0.phase.isFinished } }

    /// After the user logged in in a terminal: the jobs that stopped on the login go back in the queue.
    package func retry() {
        loginProblem = nil
        for i in jobs.indices {
            if case .needsLogin = jobs[i].phase { jobs[i].phase = .queued; jobs[i].progress = nil }
        }
        startNext()
    }

    /// The terminal command that caches the login.
    package static func loginCommand(username: String) -> String {
        "steamcmd +login \(username.isEmpty ? "<username>" : username) +quit"
    }

    package static func loginMessage(username: String, reason: String) -> String {
        "steamcmd has no saved Steam login (\(reason)). Open Terminal and run `\(loginCommand(username: username))` once: "
            + "steamcmd asks for your password and Steam Guard code there and remembers the login. Then press Retry. "
            + "The saved login belongs to the exact name you type, capitals included, so it must match the Steam "
            + "username in Settings. photon never sees or stores your password."
    }

    // MARK: running

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.lastIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func startNext() {
        guard runningID == nil, !held, loginProblem == nil, let job = jobs.first(where: { $0.phase == .queued }) else { return }
        let id = job.id
        if hidden().contains(id) {
            update(id) { $0.phase = .failed("Hidden by the content filter") }
            return startNext()
        }
        let user = username().trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else {
            update(id) { $0.phase = .failed("Set your Steam username in Settings first") }
            return startNext()
        }
        guard let exe = executable() else {
            update(id) { $0.phase = .failed("steamcmd isn't installed (macOS: brew install --cask steamcmd)") }
            return startNext()
        }
        runningID = id
        decided = false
        lastError = nil
        parser = SteamCmdOutputParser()
        update(id) { $0.phase = .running("Starting steamcmd"); $0.progress = nil }
        let p = makeProcess()
        process = p
        let args = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1", "+login", user,
                    "+workshop_download_item", WorkshopPaths.appID, id, "+quit"]
        do {
            try p.start(executable: exe, arguments: args, environment: environment, output: { [weak self] chunk in
                DispatchQueue.main.async { self?.received(chunk, id: id) }
            }, exit: { [weak self] status in
                DispatchQueue.main.async { self?.exited(status, id: id) }
            })
        } catch {
            process = nil
            runningID = nil
            update(id) { $0.phase = .failed(error.localizedDescription) }
            return startNext()
        }
        startProgress(id)
    }

    private func received(_ chunk: String, id: String) {
        guard runningID == id else { return }
        if let onOutput {
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) { onOutput(String(line)) }
        }
        for event in parser.feed(chunk) { handle(event, id: id) }
    }

    private func handle(_ event: SteamCmdEvent, id: String) {
        guard !decided else { return }
        switch event {
        case .stage(let s):
            update(id) { $0.phase = .running(s) }
        case .needsLogin(let reason):
            decided = true
            let message = Self.loginMessage(username: username(), reason: reason)
            update(id) { $0.phase = .needsLogin(message) }
            loginProblem = message
            process?.terminate()
        case .loginFailed(let reason):
            decided = true
            update(id) { $0.phase = .failed(reason) }
            process?.terminate()
        case .downloading(let item) where item == id:
            update(id) { $0.phase = .running("Downloading") }
        case .downloaded(let item, let path, _) where item == id:
            update(id) { $0.installedPath = URL(fileURLWithPath: path); $0.progress = 1; $0.phase = .running("Installing") }
        case .downloadFailed(let item, let reason) where item == id:
            decided = true
            update(id) { $0.phase = .failed(Self.explain(reason)) }
        case .error(let line):
            lastError = line
        default:
            break
        }
    }

    private static func explain(_ reason: String) -> String {
        switch reason.lowercased() {
        case "no subscription", "access denied": return "\(reason): the account must own Wallpaper Engine"
        case "file not found": return "\(reason): the item was removed from the Workshop"
        default: return reason
        }
    }

    private func exited(_ status: Int32, id: String) {
        guard runningID == id else { return }
        for event in parser.finish() { handle(event, id: id) }
        stopProgress()
        process = nil
        runningID = nil
        if let job = job(id), case .running = job.phase {
            if let dir = job.installedPath, FileManager.default.fileExists(atPath: dir.path) {
                update(id) { $0.phase = .succeeded; $0.progress = 1 }
                onInstalled?(id, dir)
                queueDependency(of: id, at: dir)
            } else {
                let why = lastError ?? (status == 0 ? "steamcmd finished without downloading the item" : "steamcmd exited with status \(status)")
                update(id) { $0.phase = .failed(why) }
            }
        }
        startNext()
    }

    /// Presets name the wallpaper they configure in project.json `dependency`; it is downloaded too.
    private func queueDependency(of id: String, at dir: URL) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
              let project = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let dep = (project["dependency"] as? String) ?? (project["dependency"] as? NSNumber).map { "\($0.int64Value)" }
        guard let dep, !dep.isEmpty, dep != id, !isInstalled(dep) else { return }
        if hidden().contains(dep) { return }
        let title = job(id).map { "Wallpaper for \($0.title)" } ?? "Dependency of \(id)"
        enqueue(id: dep, title: title, kind: .download, dependencyOf: id)
    }

    // MARK: progress (steamcmd prints none for workshop items: the staging folder's size is measured instead)

    private func startProgress(_ id: String) {
        stopProgress()
        guard let content = contentDirectory(), let expected = job(id)?.expectedBytes, expected > 0 else { return }
        let staging = WorkshopPaths.stagingDirectory(content: content, id: id)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let bytes = Self.size(of: staging)
                DispatchQueue.main.async {
                    guard let self, self.runningID == id, bytes > 0 else { return }
                    self.update(id) { job in
                        job.progress = min(Double(bytes) / Double(expected), 0.99)
                        if case .running(let s) = job.phase, s != "Downloading", s != "Installing" { job.phase = .running("Downloading") }
                    }
                }
            }
        }
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
