import Combine
import Foundation
import XCTest
@testable import PhotonApp

final class SubscriptionTests: XCTestCase {
    var d: TestDefaults!
    var root: URL!
    var libs: [FakeLibrary] = []

    override func setUp() {
        d = TestDefaults()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photon-steam-\(UUID().uuidString)")
    }

    override func tearDown() {
        d.remove()
        libs.forEach { $0.remove() }
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, appID: String, updated: Int, _ items: [(String, Int)], account: String = "12345678") throws {
        let dir = root.appendingPathComponent("userdata/\(account)/ugc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = "\"subscribedfiles\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"time_last_updated\"\t\t\"\(updated)\"\n"
        for (n, item) in items.enumerated() {
            text += "\t\"\(n)\"\n\t{\n\t\t\"publishedfileid\"\t\t\"\(item.0)\"\n\t\t\"time_subscribed\"\t\t\"\(item.1)\"\n"
            text += "\t\t\"disabled_locally\"\t\t\"0\"\n\t}\n"
        }
        try Data((text + "}\n").utf8).write(to: dir.appendingPathComponent(name))
    }

    /// 431960_subscriptions.vdf ids are Wallpaper Engine's; 0_subscriptions.vdf mixes every app.
    private func writeFixture() throws {
        try write("431960_subscriptions.vdf", appID: "431960", updated: 100, [("11", 10), ("22", 30)])
        try write("0_subscriptions.vdf", appID: "0", updated: 200, [("11", 5), ("33", 20), ("44", 40)])
    }

    func testKeyValues() {
        let kv = KeyValues.parse("// comment\n\"a\" { \"b\" \"x \\\"q\\\"\" \"c\" { } }")
        XCTAssertEqual(kv, [KeyValues.Pair(key: "a", value: .object([KeyValues.Pair(key: "b", value: .string("x \"q\"")),
                                                                         KeyValues.Pair(key: "c", value: .object([]))]))])
        XCTAssertNil(KeyValues.parse("\"a\" { \"b\" \"c\""))
        XCTAssertNil(KeyValues.parse("\"a\" }"))
    }

    func testFilesAreMergedNewestFirst() throws {
        try writeFixture()
        // Not an account folder: ignored.
        try write("431960_subscriptions.vdf", appID: "431960", updated: 999, [("99", 99)], account: "anonymous")
        let files = SteamSubscriptions.files(roots: [root])
        XCTAssertEqual(files.map(\.lastPathComponent), ["431960_subscriptions.vdf", "0_subscriptions.vdf"])
        let snap = SteamSubscriptions.load(files: files)
        XCTAssertEqual(snap.entries.map(\.id), ["44", "22", "33", "11"])
        XCTAssertEqual(snap.entries.map(\.mixed), [true, false, true, false])
        XCTAssertEqual(snap.entries.last?.timeSubscribed, 10)
        XCTAssertEqual(snap.lastUpdated, 200)
        XCTAssertEqual(SteamSubscriptions.load(files: []), .empty)
    }

    func testControllerResolvesCachesAndDownloads() throws {
        try writeFixture()
        let lib = FakeLibrary(scenes: 0, videos: 0, webs: 0)
        libs.append(lib)
        lib.add("11", file: "scene.json")
        let s = AppState(engineAssets: lib.root.appendingPathComponent("none/assets"), libraryDirectories: [lib.root],
                         defaults: d.defaults, hiddenFile: root.appendingPathComponent("hidden.json"))

        var asked: [[String]] = []
        func detail(_ id: String) -> [String: Any] {
            switch id {
            case "22": return ["publishedfileid": id, "result": 9]
            case "33": return ["publishedfileid": id, "result": 1, "title": "a mod", "consumer_app_id": 4000]
            default: return ["publishedfileid": id, "result": 1, "title": "wallpaper \(id)", "consumer_app_id": 431960,
                             "tags": [["tag": "Scene"], ["tag": "Everyone"]]]
            }
        }
        let client = WorkshopClient { request, done in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let ids = body.split(separator: "&").filter { $0.hasPrefix("publishedfileids") }.map { String($0.split(separator: "=")[1]) }
            asked.append(ids)
            let reply: [String: Any] = ["response": ["publishedfiledetails": ids.map(detail)]]
            done(try? JSONSerialization.data(withJSONObject: reply), nil)
        }
        let w = WorkshopController(state: s, defaults: d.defaults, client: client)
        let rootDir = root!
        w.subscriptionSource = { SteamSubscriptions.load(files: SteamSubscriptions.files(roots: [rootDir])) }
        w.subscribedCacheFile = root.appendingPathComponent("subscribed.json")

        func load() {
            let done = expectation(description: "loaded")
            let sub = w.$subscribedLoading.dropFirst().filter { !$0 }.sink { _ in done.fulfill() }
            w.loadSubscribed()
            wait(for: [done], timeout: 5)
            sub.cancel()
        }
        load()
        XCTAssertEqual(asked, [["44", "22", "33", "11"]])
        XCTAssertEqual(w.subscribed.map(\.id), ["44", "11"], "33 is another app's; 22 no longer resolves")
        XCTAssertEqual(w.subscribedUnavailable, 1)
        XCTAssertNil(w.subscribedError)
        XCTAssertEqual(w.status(of: w.subscribed[1]), .installed(updateAvailable: false))
        XCTAssertEqual(w.missingSubscribedCount, 1)
        w.subscribedFilter.missingOnly = true
        XCTAssertEqual(w.visibleSubscribed.map(\.id), ["44"])
        w.subscribedFilter = .init()
        w.subscribedFilter.searchText = "WALLPAPER 1"
        XCTAssertEqual(w.visibleSubscribed.map(\.id), ["11"])
        w.subscribedFilter = .init()

        // A reload shows the cached list at once and doesn't ask about the other app's item again.
        asked = []
        let w2 = WorkshopController(state: s, defaults: d.defaults, client: client)
        w2.subscriptionSource = w.subscriptionSource
        w2.subscribedCacheFile = w.subscribedCacheFile
        w2.loadSubscribed()
        XCTAssertEqual(w2.subscribed.map(\.id), ["44", "11"], "from the cache, before Steam answers")
        let done = expectation(description: "reloaded")
        let sub = w2.$subscribedLoading.filter { !$0 }.sink { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        sub.cancel()
        XCTAssertEqual(asked, [["44", "22", "11"]])

        // Download All needs the setup first, then queues only what's missing.
        XCTAssertEqual(w.downloadMissingSubscribed().queued, 0)
        XCTAssertNotNil(w.downloadMissingSubscribed().problem)
        // The fake steamcmd writes into a temporary content folder, never Steam's.
        let content = root.appendingPathComponent("steamapps/workshop/content/431960")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        w.username = "someone"
        w.steamcmdPath = WorkshopFixtures.fakeSteamcmd
        w.queue.contentDirectory = { content }
        w.queue.environment = ["PATH": "/usr/bin:/bin", "FAKE_CONTENT": content.path,
                               "FAKE_ARGS": root.appendingPathComponent("args.txt").path]
        let r = w.downloadMissingSubscribed()
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.queued, 1)
        XCTAssertEqual(w.queue.jobs.map(\.id), ["44"])
        let end = Date().addingTimeInterval(10)
        while w.queue.job("44")?.phase != .succeeded && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(w.queue.job("44")?.phase, .succeeded)
        XCTAssertEqual(w.missingSubscribedCount, 0, "downloaded now")
    }

    func testStatusOutput() {
        let out = """
        Logging in user 'x' [U:1:1] to Steam Public...OK
        [AppID 431960] Subscribed items changed. Number of items: 135 (update time: 1757631788)
        Workshop item 764162681 installed (17251881 bytes)
        Loading Steam API...OK 1234567
        """
        let r = WorkshopController.subscriptionStatusOutput(out)
        XCTAssertEqual(r.count, 135)
        XCTAssertEqual(r.ids, ["764162681", "17251881"], "ids from item lines only; their app is checked later")
        XCTAssertNil(WorkshopController.subscriptionStatusOutput("[AppID 4000] Subscribed items changed. Number of items: 3").count)
    }

    func testRefreshThroughSteamcmd() throws {
        let lib = FakeLibrary(scenes: 0, videos: 0, webs: 0)
        libs.append(lib)
        let s = AppState(engineAssets: lib.root.appendingPathComponent("none/assets"), libraryDirectories: [lib.root],
                         defaults: d.defaults, hiddenFile: root.appendingPathComponent("hidden.json"))
        let client = WorkshopClient { request, done in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let ids = body.split(separator: "&").filter { $0.hasPrefix("publishedfileids") }.map { String($0.split(separator: "=")[1]) }
            let list = ids.map { ["publishedfileid": $0, "result": 1, "title": "w\($0)", "consumer_app_id": 431960] as [String: Any] }
            done(try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": list]]), nil)
        }
        let w = WorkshopController(state: s, defaults: d.defaults, client: client)
        let rootDir = root!
        w.subscriptionSource = { SteamSubscriptions.load(files: SteamSubscriptions.files(roots: [rootDir])) }
        w.subscribedCacheFile = nil
        w.steamcmdPath = WorkshopFixtures.fakeSteamcmd
        w.queue.environment = ["PATH": "/usr/bin:/bin",
                               "FAKE_SUBS": root.appendingPathComponent("userdata/7/ugc/431960_subscriptions.vdf").path]
        XCTAssertNotNil(w.refreshSubscriptionsFromSteam(), "no username")

        func run() {
            XCTAssertNil(w.refreshSubscriptionsFromSteam())
            XCTAssertTrue(w.queue.held, "downloads wait for it")
            let end = Date().addingTimeInterval(10)
            while (w.subscriptionSyncRunning || w.subscribedLoading) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertFalse(w.queue.held)
        }
        w.username = "nologin"
        run()
        XCTAssertNotNil(w.queue.loginProblem, "the login notice covers it")
        XCTAssertTrue(w.subscribed.isEmpty)
        w.queue.retry()

        w.username = "someone"
        run()
        XCTAssertEqual(w.subscriptionSyncStatus, "Steam lists 1 subscription")
        XCTAssertEqual(w.subscribed.map(\.id), ["55"], "the file steamcmd rewrote was read again")
    }
}
