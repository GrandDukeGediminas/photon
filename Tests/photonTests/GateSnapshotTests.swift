import AppKit
import SwiftUI
import XCTest
@testable import photon
@testable import PhotonApp

/// PHOTON_SNAPSHOT_DIR=<dir>: renders the ownership window in its states to PNGs (offscreen, fake steamcmd).
final class GateSnapshotTests: XCTestCase {
    func testSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["PHOTON_SNAPSHOT_DIR"] else { throw XCTSkip("set PHOTON_SNAPSHOT_DIR") }
        let d = TestDefaults()
        defer { d.remove() }
        let lib = FakeLibrary(scenes: 0, videos: 0, webs: 0)
        defer { lib.remove() }
        let state = AppState(engineAssets: lib.root.appendingPathComponent("none/assets"), libraryDirectories: [lib.root],
                             defaults: d.defaults, hiddenFile: lib.root.appendingPathComponent("hidden.json"))
        let w = state.workshop!
        let o = OwnershipCheck(workshop: w, defaults: d.defaults)
        o.environment = ["PATH": "/usr/bin:/bin"]
        w.signIn.environment = o.environment
        // Never this Mac's own subscription files.
        w.subscriptionSource = { SteamSubscriptions.load(files: []) }
        w.subscribedCacheFile = nil

        func shot(_ name: String, owned: Bool = false) {
            render(name, OwnershipGateView(ownership: o, workshop: w, owned: owned, start: {}, close: {}))
        }
        func render<V: View>(_ name: String, _ view: V) {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 440)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        func spin(_ cond: () -> Bool) {
            let end = Date().addingTimeInterval(10)
            while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        w.steamcmdPath = "/nonexistent/steamcmd"
        shot("1-setup.png")
        w.steamcmdPath = WorkshopFixtures.fakeSteamcmd
        w.username = "nologin"
        o.check(); spin { o.status != .checking }
        shot("2-signin.png")
        w.signIn.start(username: "email"); spin { w.signIn.state == .needsPassword }
        shot("3-password.png")
        w.signIn.submitPassword("right"); spin { if case .needsCode = w.signIn.state { return true }; return false }
        shot("4-code.png")
        w.signIn.cancel(); spin { !w.signIn.isRunning }
        w.username = "someone"
        o.check(); spin { o.status != .checking }
        shot("5-owned.png")
        w.username = "noowner"
        o.check(); spin { o.status != .checking }
        shot("6-notowned.png")

        // Wallpaper Engine's files: downloading (the fake pauses at 25%), failed, then the subscriptions.
        w.username = "someone"
        w.engine.environment = ["PATH": "/usr/bin:/bin", "FAKE_APP_DELAY": "3"]
        w.downloadEngineFiles()
        spin { if case .running(_, _?, _) = w.engine.state { return true }; return false }
        render("7-engine.png", VStack(alignment: .leading, spacing: 12) { EngineFilesView(engine: w.engine, retry: {}); Spacer() }
            .padding(20).frame(width: 520, height: 440, alignment: .topLeading))
        spin { !w.engine.isRunning }
        w.username = "nospace"
        w.downloadEngineFiles()
        spin { !w.engine.isRunning }
        render("8-engine-failed.png", VStack(alignment: .leading, spacing: 12) { EngineFilesView(engine: w.engine, retry: {}); Spacer() }
            .padding(20).frame(width: 520, height: 440, alignment: .topLeading))
        w.username = "someone"
        shot("9-subscriptions.png", owned: true)
        spin { !w.syncing }
    }
}
