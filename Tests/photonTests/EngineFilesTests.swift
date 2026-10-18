import Combine
import Foundation
import XCTest
@testable import PhotonApp

/// Wallpaper Engine's files downloaded with steamcmd (EngineFiles.swift) and the automatic subscription downloads
/// (WorkshopController.syncSubscriptions), against the fake steamcmd.
final class EngineFilesTests: XCTestCase {
    var d: TestDefaults!
    var root: URL!
    var libs: [FakeLibrary] = []
    /// The controllers' states (WorkshopController holds its AppState weakly).
    var states: [AppState] = []

    override func setUp() {
        d = TestDefaults()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photon-engine-\(UUID().uuidString)")
    }

    override func tearDown() {
        d.remove()
        libs.forEach { $0.remove() }
        try? FileManager.default.removeItem(at: root)
    }

    private func controller(client: WorkshopClient = WorkshopClient { _, done in done(nil, nil) }) -> WorkshopController {
        let lib = FakeLibrary(scenes: 0, videos: 0, webs: 0)
        libs.append(lib)
        let install = root.appendingPathComponent("wallpaper_engine")
        let s = AppState(engineAssets: install.appendingPathComponent("assets"),
                         libraryDirectories: [lib.root, install.appendingPathComponent("projects/defaultprojects")],
                         defaults: d.defaults, hiddenFile: root.appendingPathComponent("hidden.json"))
        states.append(s)
        let w = WorkshopController(state: s, defaults: d.defaults, client: client)
        w.steamcmdPath = WorkshopFixtures.fakeSteamcmd
        w.subscribedCacheFile = nil
        w.queue.environment = ["PATH": "/usr/bin:/bin", "FAKE_ARGS": root.appendingPathComponent("args.txt").path]
        w.engine.environment = w.queue.environment
        return w
    }

    private func spin(until done: () -> Bool, timeout: Double = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testParse() {
        XCTAssertEqual(EngineDownloader.parse(line: "Update state (0x61) downloading, progress: 12.50 (125 / 1000)"),
                       .progress("Downloading", fraction: 0.125, done: 125, total: 1000))
        XCTAssertEqual(EngineDownloader.parse(line: "Update state (0x81) verifying update, progress: 99.00 (990 / 1000)"),
                       .progress("Verifying", fraction: 0.99, done: 990, total: 1000))
        XCTAssertEqual(EngineDownloader.parse(line: "Success! App '431960' fully installed."), .installed)
        XCTAssertEqual(EngineDownloader.parse(line: "ERROR! Failed to install app '431960' (No subscription)"),
                       .failed("This Steam account doesn't own Wallpaper Engine (No subscription)"))
        guard case .failed(let full)? = EngineDownloader.parse(line: "Error! App '431960' state is 0x202 after update job.") else {
            return XCTFail("state error")
        }
        XCTAssertTrue(full.contains("disk space"), full)
        XCTAssertNil(EngineDownloader.parse(line: "Loading Steam API...OK"))
    }

    func testDownloadsTheFilesAndReloads() throws {
        let w = controller()
        XCTAssertFalse(w.engineFilesInstalled)
        w.username = "someone"
        var progress: [Double] = []
        let sub = w.engine.$state.sink { s in if case let .running(_, p?, _) = s { progress.append(p) } }
        var result: String?? = .none
        w.downloadEngineFiles { result = .some($0) }
        XCTAssertTrue(w.queue.held, "Workshop downloads wait for it")
        spin { result != nil }
        sub.cancel()
        XCTAssertEqual(result, .some(nil))
        XCTAssertEqual(w.engine.state, .done)
        XCTAssertTrue(w.engineFilesInstalled)
        XCTAssertFalse(w.queue.held)
        XCTAssertEqual(progress, [0.25, 0.75, 0.9], "steamcmd's progress is shown")
        let args = try String(contentsOf: root.appendingPathComponent("args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let install = root.appendingPathComponent("wallpaper_engine").path
        XCTAssertEqual(Array(args.drop { $0 != "+@sSteamCmdForcePlatformType" }.prefix(6)),
                       ["+@sSteamCmdForcePlatformType", "windows", "+force_install_dir", install, "+login", "someone"],
                       "the Windows build, into photon's folder, the folder before the login")
        XCTAssertTrue(args.contains("+app_update") && args.contains("+@NoPromptForPassword"))
    }

    func testFailures() {
        for (user, expected) in [("nospace", "disk space"), ("noowner", "doesn't own Wallpaper Engine")] {
            let w = controller()
            w.username = user
            var result: String??
            w.downloadEngineFiles { result = .some($0) }
            spin { result != nil }
            guard case .failed(let message) = w.engine.state else { return XCTFail("\(user): \(w.engine.state)") }
            XCTAssertTrue(message.contains(expected), "\(user): \(message)")
            XCTAssertEqual(result, .some(message))
            XCTAssertFalse(w.engineFilesInstalled)
        }
        let w = controller()
        w.username = ""
        var result: String??
        w.downloadEngineFiles { result = .some($0) }
        XCTAssertEqual(result, .some("Enter your Steam username first"))
    }

    /// Steam's list (rewritten by `workshop_status`), then every subscribed item that isn't in the library is downloaded.
    func testSyncSubscriptionsDownloadsWhatIsMissing() throws {
        let client = WorkshopClient { request, done in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let ids = body.split(separator: "&").filter { $0.hasPrefix("publishedfileids") }.map { String($0.split(separator: "=")[1]) }
            let list = ids.map { ["publishedfileid": $0, "result": 1, "title": "w\($0)", "consumer_app_id": 431960,
                                  "tags": [["tag": "Scene"], ["tag": "Everyone"]]] as [String: Any] }
            done(try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": list]]), nil)
        }
        let w = controller(client: client)
        let rootDir = root!
        w.subscriptionSource = { SteamSubscriptions.load(files: SteamSubscriptions.files(roots: [rootDir])) }
        let content = root.appendingPathComponent("steamapps/workshop/content/431960")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        w.queue.contentDirectory = { content }
        // The account's subscription file (the fake steamcmd's ids starting with 5 prompt for a code, so not its own).
        let ugc = root.appendingPathComponent("userdata/7/ugc")
        try FileManager.default.createDirectory(at: ugc, withIntermediateDirectories: true)
        try Data("\"subscribedfiles\"\n{\n\t\"appid\"\t\t\"431960\"\n\t\"time_last_updated\"\t\t\"300\"\n\t\"0\"\n\t{\n\t\t\"publishedfileid\"\t\t\"123\"\n\t\t\"time_subscribed\"\t\t\"50\"\n\t}\n}\n".utf8)
            .write(to: ugc.appendingPathComponent("431960_subscriptions.vdf"))
        w.queue.environment = ["PATH": "/usr/bin:/bin", "FAKE_CONTENT": content.path]
        w.username = "someone"
        w.syncSubscriptions()
        XCTAssertTrue(w.syncing)
        spin { !w.syncing }
        XCTAssertEqual(w.syncQueued, ["123"])
        XCTAssertEqual(w.queue.job("123")?.phase, .succeeded)
        XCTAssertEqual(w.syncProgress?.done, 1)
        XCTAssertEqual(w.syncProgress?.total, 1)
        XCTAssertTrue(w.missingSubscribed.isEmpty)

        // Nothing new: nothing is queued.
        w.syncSubscriptions()
        spin { !w.syncing }
        XCTAssertEqual(w.syncQueued, [])
        XCTAssertNil(w.syncProgress)
    }
}
