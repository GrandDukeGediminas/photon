import Combine
import Foundation

/// The Workshop tab's model, shared by the macOS and Linux browsers: the browse query and its results, the content
/// filters, the settings (Steam username, steamcmd path, age ratings) and the download queue, wired to the library.
package final class WorkshopController: ObservableObject {
    package enum ItemStatus: Equatable {
        case notInstalled
        case installed(updateAvailable: Bool)
        case queued
        case downloading(String, Double?)
    }

    package static let usernameKey = "steamusername"
    package static let steamcmdKey = "steamcmdpath"
    package static let ratingKey = "workshoprating"

    private weak var state: AppState?
    private let defaults: UserDefaults
    package let client: WorkshopClient
    package let queue = DownloadQueue()

    @Published package var query = WorkshopQuery()
    @Published package private(set) var page: WorkshopPage?
    @Published package private(set) var loading = false
    @Published package private(set) var error: String?
    /// The last item a download put in the library (the browser selects it).
    @Published package private(set) var lastInstalled: String?
    /// Recent steamcmd output lines.
    @Published package private(set) var log: [String] = []

    /// The Steam account name steamcmd logs in with. Never a password.
    @Published package var username: String {
        didSet { defaults.set(username.trimmingCharacters(in: .whitespaces), forKey: Self.usernameKey) }
    }
    /// steamcmd's path ("" = look in the usual places).
    @Published package var steamcmdPath: String { didSet { defaults.set(steamcmdPath, forKey: Self.steamcmdKey) } }
    /// Age ratings shown (default: Everyone only).
    @Published package var rating: WorkshopRatingFilter {
        didSet {
            defaults.set(rating.rawValue, forKey: Self.ratingKey)
            query.rating = rating
            if rating != oldValue && page != nil { search() }
        }
    }

    /// The Subscribed tab: the account's subscriptions as the Steam client last recorded them, newest first.
    @Published package private(set) var subscribed: [WorkshopItem] = []
    @Published package private(set) var subscribedLoading = false
    @Published package private(set) var subscribedError: String?
    /// What the subscription files said (nil before the first load).
    @Published package private(set) var subscriptionSnapshot: SteamSubscriptions.Snapshot?
    /// Subscribed Wallpaper Engine ids Steam no longer resolves (deleted, or made private by their author).
    @Published package private(set) var subscribedUnavailable = 0
    @Published package var subscribedFilter = SubscribedFilter()

    package struct SubscribedFilter: Equatable {
        package var searchText = ""
        /// "Scene", "Video", "Web", "Application", or nil for every type.
        package var type: String?
        package var missingOnly = false
        package init() {}
    }

    /// The steamcmd subscription refresh is running.
    @Published package private(set) var subscriptionSyncRunning = false
    /// The last refresh's outcome ("Steam lists 135 subscriptions", or why it failed), nil before one ran.
    @Published package private(set) var subscriptionSyncStatus: String?
    /// Ids the last refresh printed itself (its subscription file is read too); their app is checked like `0_` ids.
    private var steamcmdSubscriptionIDs: [String] = []

    /// Reads the subscription files; replaceable for tests.
    package var subscriptionSource: () -> SteamSubscriptions.Snapshot = { SteamSubscriptions.load() }
    /// Resolved items and the ids known not to be Wallpaper Engine items, so a reload shows the list at once and only
    /// asks Steam about each id once. nil keeps nothing on disk.
    package var subscribedCacheFile: URL? = WorkshopPreviewCache.shared.directory.appendingPathComponent("subscribed.json")

    private var requestSerial = 0
    private var subscribedSerial = 0
    private var installedTimes: [String: Int] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    package init(state: AppState, defaults: UserDefaults, client: WorkshopClient = WorkshopClient()) {
        self.state = state
        self.defaults = defaults
        self.client = client
        username = defaults.string(forKey: Self.usernameKey) ?? ""
        steamcmdPath = defaults.string(forKey: Self.steamcmdKey) ?? ""
        let r = defaults.string(forKey: Self.ratingKey).flatMap(WorkshopRatingFilter.init(rawValue:)) ?? .everyone
        rating = r
        query.rating = r
        queue.username = { [weak self] in self?.username ?? "" }
        queue.executable = { [weak self] in SteamCmdLocator.find(override: self?.steamcmdPath) }
        queue.hidden = { [weak self] in self?.state?.hiddenIDs ?? [] }
        queue.isInstalled = { [weak self] id in self?.state?.installedItem(id) != nil }
        queue.contentDirectory = { [weak self] in self?.downloadDirectory }
        queue.onInstalled = { [weak self] id, dir in self?.installed(id, at: dir) }
        queue.onOutput = { [weak self] line in
            guard let self else { return }
            self.log.append(line)
            if self.log.count > 400 { self.log.removeFirst(self.log.count - 400) }
        }
        queue.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    package var steamcmdExecutable: String? { SteamCmdLocator.find(override: steamcmdPath) }

    /// Where steamcmd puts items: the folder an earlier download reported, else its default.
    package var downloadDirectory: URL {
        if let p = defaults.string(forKey: "steamcmdcontent"), !p.isEmpty { return URL(fileURLWithPath: p) }
        #if os(macOS)
        return WorkshopPaths.steamcmdContent
        #else
        return WorkshopPaths.workshopLibraries.first ?? WorkshopPaths.steamcmdContent
        #endif
    }

    // MARK: browsing

    /// The current page without hidden items or ratings the filter excludes.
    package var visibleItems: [WorkshopItem] {
        let hidden = state?.hiddenIDs ?? []
        return (page?.items ?? []).filter { !hidden.contains($0.id) && rating.allows($0) }
    }

    /// Fetches `query` (page 1 unless `keepPage`).
    package func search(keepPage: Bool = false) {
        if !keepPage { query.page = 1 }
        query.rating = rating
        requestSerial += 1
        let serial = requestSerial
        loading = true
        error = nil
        client.browse(query) { [weak self] result in
            guard let self, serial == self.requestSerial else { return }
            self.loading = false
            switch result {
            case .success(let p):
                self.page = p
                self.refreshInstalledTimes()
            case .failure(let e):
                self.error = e.localizedDescription
            }
        }
    }

    package func goToPage(_ n: Int) {
        let last = page?.totalPages ?? n
        query.page = min(max(n, 1), max(last, 1))
        search(keepPage: true)
    }

    // MARK: subscribed

    private struct SubscribedCache: Codable {
        var items: [WorkshopItem]
        var otherApps: [String]
    }

    /// The subscribed items the Subscribed tab shows: without hidden items, ratings the filter excludes, and items
    /// outside `subscribedFilter`.
    package var visibleSubscribed: [WorkshopItem] {
        let hidden = state?.hiddenIDs ?? []
        let f = subscribedFilter
        let text = f.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return subscribed.filter { item in
            !hidden.contains(item.id) && rating.allows(item)
                && (f.type == nil || item.type == f.type)
                && (!f.missingOnly || status(of: item) == .notInstalled)
                && (text.isEmpty || item.id == text || item.title.localizedCaseInsensitiveContains(text)
                    || item.tags.contains { $0.localizedCaseInsensitiveContains(text) })
        }
    }

    /// Subscribed items the blocklist or the age-rating setting keeps out of the tab.
    package var subscribedFilteredOut: Int {
        let hidden = state?.hiddenIDs ?? []
        return subscribed.filter { hidden.contains($0.id) || !rating.allows($0) }.count
    }

    /// Re-reads the subscription files and asks Steam for the details of their ids (100 per request). Cached items
    /// show at once; ids already known to belong to other apps aren't asked about again.
    package func loadSubscribed() {
        subscribedSerial += 1
        let serial = subscribedSerial
        var snapshot = subscriptionSource()
        let known = Set(snapshot.entries.map(\.id))
        snapshot.entries += steamcmdSubscriptionIDs.filter { !known.contains($0) }
            .map { SteamSubscriptions.Entry(id: $0, timeSubscribed: 0, mixed: true) }
        subscriptionSnapshot = snapshot
        subscribedError = nil
        let cache = subscribedCacheFile.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(SubscribedCache.self, from: $0) } ?? SubscribedCache(items: [], otherApps: [])
        let other = Set(cache.otherApps)
        let cached = Dictionary(cache.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = snapshot.entries.filter { !other.contains($0.id) }
        subscribed = entries.compactMap { cached[$0.id] }
        refreshInstalledTimes(subscribed)
        guard !entries.isEmpty else {
            subscribedLoading = false
            subscribedUnavailable = 0
            return
        }
        subscribedLoading = true
        let ids = entries.map(\.id)
        let mixed = Set(entries.filter(\.mixed).map(\.id))
        var found: [String: WorkshopItem] = [:], otherApps = other, unavailable = 0
        func step(_ start: Int) {
            guard serial == subscribedSerial else { return }
            guard start < ids.count else {
                subscribedLoading = false
                subscribed = ids.compactMap { found[$0] }
                subscribedUnavailable = unavailable
                refreshInstalledTimes(subscribed)
                if let file = subscribedCacheFile,
                   let data = try? JSONEncoder().encode(SubscribedCache(items: subscribed, otherApps: otherApps.sorted())) {
                    try? data.write(to: file, options: .atomic)
                }
                return
            }
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            client.detailsWithMissing(chunk) { [weak self] result in
                guard let self, serial == self.subscribedSerial else { return }
                switch result {
                case .success(let r):
                    for item in r.items {
                        // Items from 431960_subscriptions.vdf are Wallpaper Engine items whatever the reply says.
                        if !mixed.contains(item.id) || item.appID.map(String.init) == WorkshopPaths.appID {
                            found[item.id] = item
                        } else {
                            otherApps.insert(item.id)
                        }
                    }
                    for id in r.missing {
                        // An unresolved id from the mixed list may belong to any app.
                        if mixed.contains(id) { otherApps.insert(id) } else { unavailable += 1 }
                    }
                    step(start + 100)
                case .failure(let e):
                    self.subscribedLoading = false
                    self.subscribedError = e.localizedDescription
                }
            }
        }
        step(0)
    }

    /// Asks Steam for the current subscription list through steamcmd with the saved login
    /// (`+login <user> +workshop_status 431960`): steamcmd's client updates the account's subscription file
    /// (`userdata/<account>/ugc/…_subscriptions.vdf`, "Subscribed items changed. Number of items: N"), which is then
    /// read again. Downloads wait while it runs (one steamcmd at a time). Returns why it can't start, or nil.
    @discardableResult
    package func refreshSubscriptionsFromSteam() -> String? {
        let user = username.trimmingCharacters(in: .whitespaces)
        if user.isEmpty { return "Set your Steam username in Settings first" }
        guard let exe = steamcmdExecutable else { return "steamcmd wasn't found. Install it or set its path in Settings." }
        if subscriptionSyncRunning { return nil }
        if queue.isBusy { return "Wait for the current download to finish" }
        subscriptionSyncRunning = true
        subscriptionSyncStatus = "Asking Steam for your subscriptions…"
        queue.held = true
        var parser = SteamCmdOutputParser()
        var text = ""
        var problem: String?
        let p = queue.makeProcess()
        let args = ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1", "+login", user,
                    "+workshop_status", WorkshopPaths.appID, "+quit"]
        func handle(_ events: [SteamCmdEvent]) {
            for e in events {
                switch e {
                case .needsLogin(let reason):
                    guard problem == nil else { continue }
                    problem = DownloadQueue.loginMessage(username: user, reason: reason)
                    queue.reportLoginProblem(problem!)
                    p.terminate()
                case .loginFailed(let reason):
                    guard problem == nil else { continue }
                    problem = reason
                    p.terminate()
                default: break
                }
            }
        }
        do {
            try p.start(executable: exe, arguments: args, environment: queue.environment, output: { [weak self] chunk in
                DispatchQueue.main.async {
                    guard self != nil else { return }
                    text += chunk
                    self?.queue.onOutput.map { out in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).forEach { out(String($0)) } }
                    handle(parser.feed(chunk))
                }
            }, exit: { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    handle(parser.finish())
                    let result = Self.subscriptionStatusOutput(text)
                    self.steamcmdSubscriptionIDs = result.ids
                    self.subscriptionSyncRunning = false
                    self.queue.held = false
                    if let problem {
                        self.subscriptionSyncStatus = problem
                    } else if let count = result.count {
                        self.subscriptionSyncStatus = "Steam lists \(count) subscription\(count == 1 ? "" : "s")"
                    } else if status != 0 {
                        self.subscriptionSyncStatus = "steamcmd stopped (status \(status)) without the list; showing the saved one"
                    } else {
                        self.subscriptionSyncStatus = "Updated from Steam"
                    }
                    self.loadSubscribed()
                }
            })
        } catch {
            subscriptionSyncRunning = false
            queue.held = false
            subscriptionSyncStatus = error.localizedDescription
            return error.localizedDescription
        }
        return nil
    }

    /// `workshop_status 431960` output: the item count steamclient prints when it updates the list
    /// ("[AppID 431960] Subscribed items changed. Number of items: N (update time: T)", or "… did not change …"), and the
    /// item ids in lines that name an item. The ids' app is checked against Steam before they are shown.
    package static func subscriptionStatusOutput(_ text: String) -> (count: Int?, ids: [String]) {
        var count: Int?
        var ids: [String] = [], seen = Set<String>()
        let countPattern = try! NSRegularExpression(pattern: #"\[AppID \#(WorkshopPaths.appID)\] Subscribed items (?:changed|did not change)\. Number of items: ([0-9]+)"#)
        let idPattern = try! NSRegularExpression(pattern: #"(?<![0-9])([0-9]{6,12})(?![0-9])"#)
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            let ns = line as NSString
            if let m = countPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                count = Int(ns.substring(with: m.range(at: 1)))
                continue
            }
            let lower = line.lowercased()
            guard lower.contains("item") || lower.contains("publishedfile") else { continue }
            for m in idPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                if id != WorkshopPaths.appID, seen.insert(id).inserted { ids.append(id) }
            }
        }
        return (count, ids)
    }

    /// Queues every subscribed item the tab shows that isn't downloaded and photon can show. Returns how many were
    /// queued, or why nothing could be.
    package func downloadMissingSubscribed() -> (queued: Int, problem: String?) {
        var queued = 0
        for item in visibleSubscribed where status(of: item) == .notInstalled && item.unsupportedReason == nil {
            if let problem = download(item) { return (queued, problem) }
            queued += 1
        }
        return (queued, nil)
    }

    /// Subscribed items the tab shows that aren't downloaded and photon can show.
    package var missingSubscribedCount: Int {
        visibleSubscribed.filter { status(of: $0) == .notInstalled && $0.unsupportedReason == nil }.count
    }

    // MARK: status

    package func status(of item: WorkshopItem) -> ItemStatus {
        if let job = queue.job(item.id) {
            switch job.phase {
            case .queued: return .queued
            case .running(let s): return .downloading(s, job.progress)
            default: break
            }
        }
        guard state?.installedItem(item.id) != nil else { return .notInstalled }
        let local = installedTimes[item.id] ?? 0
        return .installed(updateAvailable: item.timeUpdated > 0 && local > 0 && item.timeUpdated > local + 60)
    }

    private func refreshInstalledTimes() { refreshInstalledTimes(page?.items ?? []) }

    private func refreshInstalledTimes(_ items: [WorkshopItem]) {
        guard let state else { return }
        for item in items {
            if let local = state.installedItem(item.id) {
                installedTimes[item.id] = WorkshopPaths.installedTime(id: item.id, directory: local.directory)
            }
        }
    }

    // MARK: actions

    /// Queues a download (or an update); returns why it can't, or nil.
    @discardableResult
    package func download(_ item: WorkshopItem, update: Bool = false) -> String? {
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Set your Steam username in Settings first" }
        if steamcmdExecutable == nil { return "steamcmd wasn't found. Install it (brew install --cask steamcmd) or set its path in Settings." }
        return queue.enqueue(id: item.id, title: item.title, kind: update ? .update : .download, expectedBytes: item.fileSize)
    }

    /// Whether `id` can be removed: it is in a workshop folder steamcmd manages (not the engine's default or own
    /// projects, and not CrossOver Steam's folder, where the Steam client would download a subscribed item again).
    package func canRemove(_ id: String) -> Bool {
        guard let item = state?.installedItem(id) else { return false }
        let parent = item.directory.deletingLastPathComponent()
        #if os(macOS)
        if parent.standardizedFileURL.path == WorkshopPaths.crossOverContent.standardizedFileURL.path { return false }
        #endif
        return parent.lastPathComponent == WorkshopPaths.appID
    }

    /// Deletes a downloaded item's folder and rescans. The caller confirms first.
    package func remove(_ id: String) throws {
        guard let state, let item = state.installedItem(id), canRemove(id) else { return }
        try FileManager.default.removeItem(at: item.directory)
        installedTimes[id] = nil
        state.reloadLibrary()
    }

    private func installed(_ id: String, at dir: URL) {
        let parent = dir.deletingLastPathComponent()
        if parent.standardizedFileURL != downloadDirectory.standardizedFileURL {
            defaults.set(parent.path, forKey: "steamcmdcontent")
        }
        state?.addLibraryDirectory(parent)
        state?.reloadLibrary()
        installedTimes[id] = WorkshopPaths.installedTime(id: id, directory: dir) ?? Int(Date().timeIntervalSince1970)
        lastInstalled = id
    }
}
