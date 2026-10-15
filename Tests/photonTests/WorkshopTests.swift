import Combine
import Foundation
import XCTest
@testable import PhotonApp

/// Saved Workshop pages and API answers (Tests/fixtures/workshop), fetched from the public pages without an account.
enum WorkshopFixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/workshop")
    static func text(_ name: String) -> String { try! String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    static func data(_ name: String) -> Data { try! Data(contentsOf: dir.appendingPathComponent(name)) }
    static var fakeSteamcmd: String { dir.appendingPathComponent("fake-steamcmd.sh").path }
}

final class WorkshopParserTests: XCTestCase {
    func testBrowsePageFromEmbeddedData() throws {
        let page = try XCTUnwrap(WorkshopParser.browsePage(WorkshopFixtures.text("browse-ssr.html")))
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.totalPages, 1000)
        XCTAssertGreaterThan(page.totalCount, 1_000_000)
        XCTAssertEqual(page.items.count, 10)
        let first = page.items[0]
        XCTAssertEqual(first.id, "3819090543")
        XCTAssertEqual(first.type, "Video")
        XCTAssertEqual(first.rating, "Everyone")
        XCTAssertEqual(first.fileSize, 224_839_817)
        XCTAssertGreaterThan(first.subscriptions, 0)
        XCTAssertEqual(first.timeUpdated, 1_791_896_772)
        XCTAssertEqual(first.previewURL?.host, "images.steamusercontent.com")
        XCTAssertFalse(first.displayTags.contains("Video"))
        XCTAssertFalse(first.displayTags.contains("Everyone"))
        XCTAssertNil(first.unsupportedReason)
        let app = try XCTUnwrap(page.items.first { $0.id == "1000000002" })
        XCTAssertEqual(app.type, "Application")
        XCTAssertNotNil(app.unsupportedReason, "applications can't be rendered")
        XCTAssertEqual(page.items.first { $0.id == "1000000001" }?.rating, "Mature")
    }

    func testOlderPageLayoutGivesIDsAndPageCount() {
        let html = WorkshopFixtures.text("browse-legacy.html")
        XCTAssertNil(WorkshopParser.browsePage(html))
        XCTAssertEqual(WorkshopParser.ids(inBrowsePage: html), ["3819090543", "3819548334", "3818033498", "3814714349"])
        XCTAssertEqual(WorkshopParser.legacyPageCount(html), 89060)
    }

    func testPublishedFileDetails() {
        let items = WorkshopParser.details(WorkshopFixtures.data("details.json"))
        XCTAssertEqual(items.map(\.id), ["3819548334", "3815542599"], "the unknown id (result 9) is dropped")
        XCTAssertEqual(items[1].title, "Dystopic City Port [4K, Ambient]")
        XCTAssertEqual(items[1].timeUpdated, 1_791_491_547)
        XCTAssertEqual(items[1].fileSize, 134_752_600)
        XCTAssertEqual(items[0].type, "Scene")
        XCTAssertFalse(items[0].description.isEmpty)
    }

    func testQueryURL() {
        var q = WorkshopQuery(searchText: "rainy city", sort: .toprated, type: "Scene", tags: ["Anime", "Pixel art"], page: 3)
        let s = q.url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://steamcommunity.com/workshop/browse/?appid=431960"))
        XCTAssertTrue(s.contains("browsesort=toprated"))
        XCTAssertTrue(s.contains("searchtext=rainy%20city"))
        XCTAssertTrue(s.contains("requiredtags%5B%5D=Scene"))
        XCTAssertTrue(s.contains("requiredtags%5B%5D=Pixel%20art"))
        XCTAssertTrue(s.contains("excludedtags%5B%5D=Questionable"))
        XCTAssertTrue(s.contains("excludedtags%5B%5D=Mature"))
        XCTAssertTrue(s.contains("p=3"))
        XCTAssertFalse(s.contains("days="))
        q.rating = .all
        q.sort = .trend
        XCTAssertFalse(q.url.absoluteString.contains("excludedtags"))
        XCTAssertTrue(q.url.absoluteString.contains("days=7"))
    }

    func testRatingFilter() {
        let e = WorkshopItem(id: "1", title: "", tags: ["Scene", "Everyone"])
        let q = WorkshopItem(id: "2", title: "", tags: ["Scene", "Questionable"])
        let m = WorkshopItem(id: "3", title: "", tags: ["Scene", "Mature"])
        let none = WorkshopItem(id: "4", title: "", tags: ["Scene"])
        XCTAssertEqual([e, q, m, none].filter(WorkshopRatingFilter.everyone.allows).map(\.id), ["1", "4"])
        XCTAssertEqual([e, q, m, none].filter(WorkshopRatingFilter.questionable.allows).map(\.id), ["1", "2", "4"])
        XCTAssertEqual([e, q, m, none].filter(WorkshopRatingFilter.all.allows).count, 4)
    }

    func testThumbnailURLUsesResizer() {
        let item = WorkshopItem(id: "1", title: "", previewURL: URL(string: "https://images.steamusercontent.com/ugc/1/ABC/"))
        let url = item.thumbnailURL(size: 320)!.absoluteString
        XCTAssertTrue(url.contains("imw=320") && url.contains("imh=320"))
    }

    func testNoConnectionMeansNoSavedLogin() {
        let events = SteamCmdOutputParser.parse(line: "Logging in user 'someone' [U:1:1] to Steam Public...FAILED (No Connection)")
        guard case .needsLogin = events.first else { return XCTFail("\(events)") }
    }

    func testSteamcmdOutput() {
        var p = SteamCmdOutputParser()
        var events = p.feed("[  0%] Checking for available updates...\nLogging in user 'someone' [U:1:2] to Steam Public...OK\n")
        events += p.feed("Downloading item 123 ...\nSuccess. Downloaded item 123 to \"/x/steamapps/workshop/content/431960/123\" (4567 bytes)\n")
        XCTAssertEqual(events, [.stage("Updating steamcmd"), .stage("Logged in"), .downloading(id: "123"),
                                .downloaded(id: "123", path: "/x/steamapps/workshop/content/431960/123", bytes: 4567)])
        XCTAssertEqual(SteamCmdOutputParser.parse(line: "ERROR! Download item 9 failed (File Not Found)."),
                       [.downloadFailed(id: "9", reason: "File Not Found")])
        XCTAssertEqual(SteamCmdOutputParser.parse(line: "ERROR! Timeout downloading item 9"), [.downloadFailed(id: "9", reason: "Timeout")])
        XCTAssertEqual(SteamCmdOutputParser.parse(line: "Cached credentials not found."), [.needsLogin("Cached credentials not found")])
        if case .needsLogin = SteamCmdOutputParser.parse(line: "Logging in user 'a' to Steam Public...FAILED (Invalid Password)").first {} else {
            XCTFail("an invalid password needs a terminal login")
        }
        if case .loginFailed = SteamCmdOutputParser.parse(line: "Logging in user 'a' to Steam Public...FAILED (Rate Limit Exceeded)").first {} else {
            XCTFail("rate limiting is its own failure")
        }
        XCTAssertEqual(SteamCmdOutputParser.parse(line: "\u{1B}[0mWaiting for user info...OK"), [.stage("Logged in")])
        // Prompts arrive without a newline.
        var q = SteamCmdOutputParser()
        XCTAssertEqual(q.feed("Logging in user 'a' to Steam Public...\npassword: "), [.stage("Logging in"), .needsLogin("Password prompt")])
        var g = SteamCmdOutputParser()
        XCTAssertEqual(g.feed("Steam Guard code:"), [.needsLogin("Steam Guard prompt")])
    }

    func testAcfInstallTime() {
        let acf = """
        "AppWorkshop"
        {
            "appid"		"431960"
            "WorkshopItemsInstalled"
            {
                "111"
                {
                    "size"		"10"
                    "timeupdated"		"1700000000"
                    "manifest"		"1"
                }
                "222"
                {
                    "size"		"20"
                    "timeupdated"		"1750000000"
                }
            }
        }
        """
        XCTAssertEqual(WorkshopPaths.acfTimeUpdated(acf, id: "222"), 1_750_000_000)
        XCTAssertEqual(WorkshopPaths.acfTimeUpdated(acf, id: "111"), 1_700_000_000)
        XCTAssertNil(WorkshopPaths.acfTimeUpdated(acf, id: "333"))
    }
}

/// The library: duplicate ids across workshop folders, and the hidden-items blocklist.
final class LibraryFilterTests: XCTestCase {
    var d: TestDefaults!
    var libs: [FakeLibrary] = []
    var hiddenFile: URL!

    override func setUp() {
        d = TestDefaults()
        hiddenFile = FileManager.default.temporaryDirectory.appendingPathComponent("photon-hidden-\(UUID().uuidString).json")
    }

    override func tearDown() {
        d.remove()
        libs.forEach { $0.remove() }
        try? FileManager.default.removeItem(at: hiddenFile)
    }

    private func library() -> FakeLibrary {
        let l = FakeLibrary(scenes: 0, videos: 0, webs: 0)
        libs.append(l)
        return l
    }

    func testDuplicateIDsComeFromTheFirstFolder() {
        let steamcmd = library(), crossover = library()
        steamcmd.add("100", file: "scene.json")
        crossover.add("100", file: "clip.mp4")
        crossover.add("200", file: "clip.mp4")
        let items = Library.scan(directories: [steamcmd.root, crossover.root])
        XCTAssertEqual(items.map(\.id).sorted(), ["100", "200"])
        XCTAssertEqual(items.first { $0.id == "100" }?.type, "scene")
        XCTAssertEqual(items.first { $0.id == "100" }?.directory.deletingLastPathComponent().standardizedFileURL,
                       steamcmd.root.standardizedFileURL)
        // The same folder twice (a symlinked alias) is scanned once.
        XCTAssertEqual(WorkshopPaths.unique([steamcmd.root, steamcmd.root, crossover.root]).count, 2)
    }

    func testHiddenFileFormats() {
        XCTAssertEqual(HiddenItems.parse(Data(#"["1507593643", "2077454291"]"#.utf8)), ["1507593643", "2077454291"])
        XCTAssertEqual(HiddenItems.parse(Data(#"[123, "456", "abc", null]"#.utf8)), ["123", "456"])
        XCTAssertEqual(HiddenItems.parse(Data(#"{"ids": ["1", "2"]}"#.utf8)), ["1", "2"])
        XCTAssertEqual(HiddenItems.parse(Data(#"{"hidden": [{"id": "7"}, {"publishedfileid": "8"}]}"#.utf8)), ["7", "8"])
        XCTAssertEqual(HiddenItems.parse(Data(#"{"11": true, "12": false, "13": "reason"}"#.utf8)), ["11", "13"])
        XCTAssertEqual(HiddenItems.parse(Data("not json".utf8)), [])
        XCTAssertEqual(HiddenItems.load(URL(fileURLWithPath: "/nonexistent/hidden.json")), [])
    }

    func testHiddenItemsLeaveLibraryPlaylistsAndWorkshop() throws {
        let lib = library()
        for id in ["100", "200", "300"] { lib.add(id, file: "scene.json") }
        // A preset of a hidden wallpaper is hidden with it.
        let preset = lib.root.appendingPathComponent("400")
        try FileManager.default.createDirectory(at: preset, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": "preset", "dependency": "200"]).write(to: preset.appendingPathComponent("project.json"))
        try Data(#"["200", "3819090543"]"#.utf8).write(to: hiddenFile)

        let s = AppState(engineAssets: lib.root.appendingPathComponent("none/assets"), libraryDirectories: [lib.root],
                         defaults: d.defaults, hiddenFile: hiddenFile)
        XCTAssertEqual(s.hiddenIDs, ["200", "3819090543"])
        XCTAssertEqual(Set(s.items.map(\.id)), ["100", "300"])
        XCTAssertNil(s.item("200"))
        XCTAssertNil(s.item("400"))
        XCTAssertNotNil(s.installedItem("200"), "still on disk, only hidden")

        // A playlist naming the hidden item never selects it.
        s.playlists.assign(playlistJSON(["delay": 1, "order": "sorted"], ["200", "100", "300"]), to: AppState.allDisplays)
        for _ in 0..<6 {
            for k in s.wallpaperTargets.map(\.id) { XCTAssertNotEqual(s.wallpaper(forDisplay: k), "200") }
            s.playlists.next()
        }

        // Workshop results drop it too.
        let client = WorkshopClient { _, done in done(WorkshopFixtures.data("browse-ssr.html"), nil) }
        let w = WorkshopController(state: s, defaults: d.defaults, client: client)
        let loaded = expectation(description: "page")
        w.search()
        let sub = w.$page.compactMap { $0 }.sink { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        sub.cancel()
        let ids = w.visibleItems.map(\.id)
        XCTAssertFalse(ids.contains("3819090543"), "hidden")
        XCTAssertFalse(ids.contains("1000000001"), "Mature, hidden by default")
        XCTAssertFalse(ids.contains("1000000002"), "Questionable, hidden by default")
        XCTAssertEqual(ids.count, 7)
        w.rating = .all
        let reloaded = expectation(description: "page again")
        let sub2 = w.$loading.dropFirst().filter { !$0 }.sink { _ in reloaded.fulfill() }
        wait(for: [reloaded], timeout: 5)
        sub2.cancel()
        XCTAssertTrue(w.visibleItems.map(\.id).contains("1000000001"))
        XCTAssertFalse(w.visibleItems.map(\.id).contains("3819090543"), "hidden whatever the rating setting")

        // And it is never downloaded.
        XCTAssertNotNil(w.queue.enqueue(id: "200", title: "x"))
        XCTAssertTrue(w.queue.jobs.isEmpty)
    }

    func testHiddenListIsReReadOnRescan() throws {
        let lib = library()
        lib.add("100", file: "scene.json")
        let s = AppState(engineAssets: lib.root.appendingPathComponent("none/assets"), libraryDirectories: [lib.root],
                         defaults: d.defaults, hiddenFile: hiddenFile)
        XCTAssertNotNil(s.item("100"))
        try Data(#"["100"]"#.utf8).write(to: hiddenFile)
        s.reloadLibrary()
        XCTAssertNil(s.item("100"))
    }
}

/// The download queue against a fake steamcmd (Tests/fixtures/workshop/fake-steamcmd.sh): no Steam login, no network.
final class DownloadQueueTests: XCTestCase {
    var content: URL!
    var argsFile: URL!
    var queue: DownloadQueue!
    var installed: [String] = []
    var hidden: Set<String> = []

    override func setUp() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photon-dl-\(UUID().uuidString)")
        content = root.appendingPathComponent("steamapps/workshop/content/431960")
        try! FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        argsFile = root.appendingPathComponent("args.txt")
        installed = []
        hidden = []
        queue = DownloadQueue()
        queue.username = { "tester" }
        queue.executable = { WorkshopFixtures.fakeSteamcmd }
        queue.hidden = { [unowned self] in self.hidden }
        queue.isInstalled = { [unowned self] id in FileManager.default.fileExists(atPath: self.content.appendingPathComponent(id).path) }
        queue.contentDirectory = { [unowned self] in self.content }
        queue.environment = ["PATH": "/usr/bin:/bin", "FAKE_CONTENT": content.path, "FAKE_ARGS": argsFile.path]
        queue.onInstalled = { [unowned self] id, _ in self.installed.append(id) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: content.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent())
    }

    private func waitUntil(_ timeout: Double = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func phase(_ id: String) -> DownloadQueue.Phase? { queue.job(id)?.phase }

    func testSuccessAndArguments() throws {
        XCTAssertNil(queue.enqueue(id: "101", title: "one", expectedBytes: 1234))
        XCTAssertNil(queue.enqueue(id: "102", title: "two"))
        XCTAssertEqual(phase("102"), .queued, "one steamcmd at a time")
        waitUntil { phase("102") == .succeeded }
        XCTAssertEqual(phase("101"), .succeeded)
        XCTAssertEqual(installed, ["101", "102"])
        XCTAssertEqual(queue.job("101")?.installedPath?.standardizedFileURL, content.appendingPathComponent("101").standardizedFileURL)
        XCTAssertFalse(queue.isBusy)
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(10)), ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1", "+login", "tester",
                                                 "+workshop_download_item", "431960", "101", "+quit"])
        XCTAssertFalse(args.contains { $0.lowercased().contains("password") && $0 != "+@NoPromptForPassword" })
    }

    func testDependencyIsDownloaded() {
        queue.enqueue(id: "401", title: "preset")
        waitUntil { phase("101") == .succeeded }
        XCTAssertEqual(installed, ["401", "101"])
        XCTAssertEqual(queue.job("101")?.dependencyOf, "401")
    }

    func testPresentDependencyIsNotDownloadedAgain() {
        try! FileManager.default.createDirectory(at: content.appendingPathComponent("101"), withIntermediateDirectories: true)
        queue.enqueue(id: "401", title: "preset")
        waitUntil { phase("401") == .succeeded }
        waitUntil(0.5) { false }
        XCTAssertNil(queue.job("101"))
    }

    func testHiddenDependencyIsNotDownloaded() {
        hidden = ["101"]
        queue.enqueue(id: "401", title: "preset")
        waitUntil { phase("401") == .succeeded }
        waitUntil(0.5) { false }
        XCTAssertNil(queue.job("101"))
        XCTAssertNotNil(queue.enqueue(id: "101", title: "x"), "refused")
    }

    func testLoginNeededStopsSteamcmdAndPausesTheQueue() {
        queue.enqueue(id: "201", title: "needs login")
        queue.enqueue(id: "102", title: "next")
        let start = Date()
        waitUntil { if case .needsLogin = phase("201") ?? .queued { return true }; return false }
        guard case .needsLogin(let message) = phase("201") else { return XCTFail("expected needsLogin, got \(String(describing: phase("201")))") }
        XCTAssertTrue(message.contains("steamcmd +login tester +quit"))
        XCTAssertEqual(queue.loginProblem, message)
        // steamcmd was stopped rather than left waiting at the prompt (it sleeps 30 s).
        waitUntil { !queue.isBusy }
        XCTAssertFalse(queue.isBusy)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(phase("102"), .queued, "paused until Retry")
        queue.retry()
        XCTAssertNil(queue.loginProblem)
        waitUntil { if case .needsLogin = phase("201") ?? .queued { return true }; return false }
        waitUntil { !queue.isBusy }
        // Still no login: it stops on the same item again.
        XCTAssertEqual(phase("102"), .queued)
    }

    func testSteamGuardPromptIsCaught() {
        queue.enqueue(id: "501", title: "guard")
        waitUntil { if case .needsLogin = phase("501") ?? .queued { return true }; return false }
        guard case .needsLogin = phase("501") else { return XCTFail() }
        waitUntil { !queue.isBusy }
    }

    func testFailureMovesOn() {
        queue.enqueue(id: "301", title: "gone")
        queue.enqueue(id: "103", title: "fine")
        waitUntil { phase("103") == .succeeded }
        guard case .failed(let reason) = phase("301") else { return XCTFail() }
        XCTAssertTrue(reason.contains("File Not Found"))
        XCTAssertEqual(installed, ["103"])
    }

    func testCancelQueuedAndRunning() {
        queue.enqueue(id: "201", title: "waits at a prompt")
        queue.enqueue(id: "104", title: "queued")
        queue.cancel("104")
        XCTAssertNil(queue.job("104"))
        // Cancelling the running one stops steamcmd.
        queue.loginProblem.map { _ in XCTFail("not yet") }
        queue.cancel("201")
        waitUntil { !queue.isBusy }
        XCTAssertTrue(phase("201") == .cancelled || { if case .needsLogin = phase("201")! { return true }; return false }())
    }

    func testMissingSetupFailsClearly() {
        queue.username = { "" }
        queue.enqueue(id: "105", title: "x")
        guard case .failed(let r) = phase("105") else { return XCTFail() }
        XCTAssertTrue(r.contains("username"))
        queue.username = { "tester" }
        queue.executable = { nil }
        queue.enqueue(id: "106", title: "y")
        guard case .failed(let r2) = phase("106") else { return XCTFail() }
        XCTAssertTrue(r2.contains("steamcmd"))
        XCTAssertNotNil(queue.enqueue(id: "abc", title: "z"))
    }
}
