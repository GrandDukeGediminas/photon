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

        func shot(_ name: String) {
            let host = NSHostingView(rootView: OwnershipGateView(ownership: o, workshop: w, passed: {}))
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
    }
}
