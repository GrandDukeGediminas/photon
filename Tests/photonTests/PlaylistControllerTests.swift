import Foundation
import PhotonRender
import XCTest
@testable import PhotonApp
@testable import photon

/// `PlaylistController` end to end: assignment, the windowupdaterate tick, video ends, next / previous, stretch / clone,
/// the panel's draft and the saved state across a restart.
final class PlaylistControllerTests: XCTestCase {
    var d: TestDefaults!
    var lib: FakeLibrary!

    override func setUp() {
        d = TestDefaults()
        lib = FakeLibrary(scenes: 6, videos: 2, webs: 1)
    }

    override func tearDown() {
        d.remove()
        lib.remove()
    }

    func displays(_ s: AppState) -> [String] { s.displays.map(\.id) }

    func testOneItemIsADraftNotAPlaylist() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        pl.assign(playlistJSON(["delay": 1], ["s0"]), to: AppState.allDisplays)
        XCTAssertNil(pl.assigned[AppState.allDisplays], "fewer than two items: no playlist (SelectPlaylist)")
        XCTAssertEqual((pl.drafts[AppState.allDisplays]?["items"] as? [Any])?.count, 1, "the panel keeps the item it added")
        pl.assign(playlistJSON(["delay": 1], ["s0", "s1"]), to: AppState.allDisplays)
        XCTAssertNotNil(pl.assigned[AppState.allDisplays])
        XCTAssertNil(pl.drafts[AppState.allDisplays])
        pl.assign(playlistJSON(["delay": 1], []), to: AppState.allDisplays)
        XCTAssertNil(pl.assigned[AppState.allDisplays])
        XCTAssertNil(pl.drafts[AppState.allDisplays], "Clear removes the draft too")
    }

    func testAssignPicksForDisplaysWithoutWallpaperAndKeepsShownOnes() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.isEmpty, "no displays")
        pl.assign(playlistJSON(["delay": 1, "order": "sorted"], ["s0", "s1", "s2"]), to: AppState.allDisplays)
        for k in displays(s) {
            XCTAssertNotNil(pl.runners[k], "a node per display")
            XCTAssertTrue(["s0", "s1", "s2"].contains(s.wallpaper(forDisplay: k) ?? ""), "display without a wallpaper picks now")
        }
        // A display that shows a wallpaper keeps it when another playlist is selected.
        let shown = s.wallpaper(forDisplay: displays(s)[0])
        pl.assign(playlistJSON(["delay": 1, "order": "sorted"], ["s3", "s4"]), to: AppState.allDisplays)
        XCTAssertEqual(s.wallpaper(forDisplay: displays(s)[0]), shown)
        XCTAssertEqual(pl.runners[displays(s)[0]]?.elapsed, 0, "every node's timer restarts")
    }

    func testNeverModeStillShowsSomethingOnAnEmptyDisplay() throws {
        let s = makeState(d, library: lib)
        try XCTSkipIf(s.displays.isEmpty)
        s.playlists.assign(playlistJSON(["mode": "never"], ["s0", "s1"]), to: AppState.allDisplays)
        for k in displays(s) { XCTAssertNotNil(s.wallpaper(forDisplay: k)) }
    }

    func testTimerTickSwitchesWithThePlaylistTransition() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.isEmpty)
        let k = displays(s)[0]
        pl.assign(playlistJSON(["delay": 1, "order": "sorted", "transition": "23", "transitiontime": 800], ["s0", "s1", "s2"]),
                  to: AppState.allDisplays)
        let first = s.wallpaper(forDisplay: k)
        _ = s.takeTransition(display: k)
        for _ in 0..<11 { pl.tick(dt: 5) }
        XCTAssertEqual(s.wallpaper(forDisplay: k), first, "55 s < 1 min")
        pl.tick(dt: 5)
        XCTAssertNotEqual(s.wallpaper(forDisplay: k), first, "60 s: next item")
        XCTAssertEqual(s.takeTransition(display: k), TransitionSettings(mode: 23, timeMs: 800), "the playlist's transition")
        // Paused (tray) → the timer stops; updateonpause keeps it going.
        let now = s.wallpaper(forDisplay: k)
        s.paused = true
        for _ in 0..<30 { pl.tick(dt: 5) }
        XCTAssertEqual(s.wallpaper(forDisplay: k), now)
        s.paused = false
        // The display's bit in the rule pause mask pauses it too.
        s.decision = PlaybackDecision(pauseMask: 1)
        for _ in 0..<30 { pl.tick(dt: 5) }
        XCTAssertEqual(s.wallpaper(forDisplay: k), now)
        s.decision = PlaybackDecision(stop: true)
        for _ in 0..<30 { pl.tick(dt: 5) }
        XCTAssertEqual(s.wallpaper(forDisplay: k), now, "stopped: no ticks")
        s.decision = PlaybackDecision()
        for _ in 0..<12 { pl.tick(dt: 5) }
        XCTAssertNotEqual(s.wallpaper(forDisplay: k), now, "runs again once unpaused")
    }

    func testPlaylistWithoutSettingsUsesTheCtorTransition() throws {
        let s = makeState(d, library: lib)
        try XCTSkipIf(s.displays.isEmpty)
        let k = displays(s)[0]
        s.playlists.assign(playlistJSON(nil, ["s0", "s1"]), to: AppState.allDisplays)
        _ = s.takeTransition(display: k)
        s.playlists.next(display: k)
        XCTAssertEqual(s.takeTransition(display: k), TransitionSettings(mode: -2, timeMs: 0), "ctor: −2, 0 ms")
        XCTAssertEqual(s.playlists.assigned[AppState.allDisplays]?.delay, 60)
    }

    func testVideoSequence() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.isEmpty)
        let k = displays(s)[0]
        pl.assign(playlistJSON(["delay": 1, "order": "sorted", "videosequence": true], ["v0", "v1"]), to: AppState.allDisplays)
        let first = s.wallpaper(forDisplay: k)
        XCTAssertEqual(pl.runners[k]?.currentIsVideo, true)
        for _ in 0..<60 { pl.tick(dt: 5) }
        XCTAssertEqual(s.wallpaper(forDisplay: k), first, "a video with videosequence waits for its end")
        pl.videoEnded(display: k)
        XCTAssertNotEqual(s.wallpaper(forDisplay: k), first, "its end advances")
    }

    func testNextPreviousAndOffers() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.isEmpty)
        let k = displays(s)[0]
        XCTAssertFalse(pl.offersNext)
        pl.assign(playlistJSON(["delay": 10, "order": "sorted"], ["s0", "s1", "s2"]), to: AppState.allDisplays)
        XCTAssertTrue(pl.offersNext)
        XCTAssertFalse(pl.offersPrevious)
        let a = s.wallpaper(forDisplay: k)
        pl.next()
        let b = s.wallpaper(forDisplay: k)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(pl.offersPrevious)
        pl.previous()
        XCTAssertEqual(s.wallpaper(forDisplay: k), a)
        pl.assign(playlistJSON(["mode": "daytime"], ["s0", "s1"]), to: AppState.allDisplays)
        XCTAssertFalse(pl.offersNext, "no Next for daytime")
    }

    func testDaytimeFollowsTheClockOnlyWithTheUIClosed() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.isEmpty)
        let k = displays(s)[0]
        pl.now = { localDate("2026-10-13 08:00") }
        pl.assign(playlistJSON(["mode": "daytime"], ["s0", "s1"]), to: AppState.allDisplays)
        pl.tick(dt: 1)
        XCTAssertEqual(s.wallpaper(forDisplay: k), "s0")
        pl.now = { localDate("2026-10-13 13:00") }
        pl.uiOpen = true
        pl.tick(dt: 1)
        XCTAssertEqual(s.wallpaper(forDisplay: k), "s0", "browser open: no re-evaluation")
        pl.uiOpen = false
        pl.tick(dt: 1)
        XCTAssertEqual(s.wallpaper(forDisplay: k), "s1")
    }

    func testDayOfWeekCutTo7() {
        let s = makeState(d, library: lib)
        s.playlists.assign(playlistJSON(["mode": "dayofweek"], (0..<6).map { "s\($0)" } + ["v0", "v1", "w0"]), to: "x")
        XCTAssertEqual(s.playlists.assigned["x"]?.items.count, 7)
    }

    func testClearOneDisplayKeepsTheOthers() throws {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        try XCTSkipIf(s.displays.count < 2, "needs two displays")
        let k = displays(s)
        pl.assign(playlistJSON(["delay": 1], ["s0", "s1"]), to: AppState.allDisplays)
        s.apply("s5", display: k[0])
        XCTAssertNil(pl.playlist(forDisplay: k[0]))
        XCTAssertNotNil(pl.playlist(forDisplay: k[1]), "the others keep the all-displays playlist")
        XCTAssertNil(pl.runners[k[0]])
        XCTAssertEqual(s.wallpaper(forDisplay: k[0]), "s5")
        s.apply("s5", display: nil)
        XCTAssertTrue(pl.assigned.isEmpty)
        XCTAssertTrue(pl.runners.isEmpty)
    }

    func testStretchAndCloneRunOneNode() throws {
        let s = makeState(d, library: lib)
        try XCTSkipIf(s.displays.count < 2, "needs two displays")
        s.layout = 1
        s.playlists.start()
        s.playlists.assign(playlistJSON(["delay": 1], ["s0", "s1"]), to: AppState.allDisplays)
        XCTAssertEqual(Array(s.playlists.runners.keys), [displays(s)[0]], "only the source display runs a node")
        s.layout = 0
        spin(0.2)
        XCTAssertEqual(Set(s.playlists.runners.keys), Set(displays(s)), "back to a node per display")
        s.layout = 2
        spin(0.2)
        XCTAssertEqual(Array(s.playlists.runners.keys), [displays(s)[0]])
    }

    func testStartupResumeAcrossRestart() throws {
        var s: AppState? = makeState(d, library: lib)
        try XCTSkipIf(s!.displays.isEmpty)
        let k = displays(s!)[0]
        s!.playlists.assign(playlistJSON(["delay": 10, "order": "sorted"], ["s0", "s1", "s2", "s3"]), to: AppState.allDisplays)
        s!.playlists.next()
        let shown = s!.wallpaper(forDisplay: k)
        for _ in 0..<24 { s!.playlists.tick(dt: 5) } // 2 minutes into the 10
        s!.playlists.saveState()
        s = nil
        let r = makeState(d, library: lib)
        r.playlists.start()
        XCTAssertEqual(r.wallpaper(forDisplay: k), shown, "resumes the wallpaper shown before")
        XCTAssertEqual(r.playlists.runners[k]?.elapsed, 0, "the startup pick restarts the timer (no wallpaper object yet)")
        for _ in 0..<(10 * 12) { r.playlists.tick(dt: 5) }
        XCTAssertNotEqual(r.wallpaper(forDisplay: k), shown, "a full delay later: the next one")
        // Without the saved assignment the resume item is picked itself.
        d.defaults.removeObject(forKey: "assignments")
        let q = makeState(d, library: lib)
        q.playlists.start()
        XCTAssertNotNil(q.wallpaper(forDisplay: k))
        XCTAssertEqual(q.takeTransition(display: k).mode, -1, "no transition at startup")
    }

    func testLogonPicksANewWallpaperEveryStart() throws {
        var s: AppState? = makeState(d, library: lib)
        try XCTSkipIf(s!.displays.isEmpty)
        let k = displays(s!)[0]
        s!.playlists.assign(playlistJSON(["mode": "logon", "order": "sorted"], ["s0", "s1", "s2"]), to: AppState.allDisplays)
        let shown = s!.wallpaper(forDisplay: k)
        for _ in 0..<100 { s!.playlists.tick(dt: 5) }
        XCTAssertEqual(s!.wallpaper(forDisplay: k), shown, "logon: no change while running")
        s!.playlists.saveState()
        s = nil
        let r = makeState(d, library: lib)
        r.playlists.start()
        XCTAssertNotEqual(r.wallpaper(forDisplay: k), shown, "a new one at start")
    }

    func testBeginFirstAtStartup() throws {
        var s: AppState? = makeState(d, library: lib)
        try XCTSkipIf(s!.displays.isEmpty)
        let k = displays(s!)[0]
        s!.playlists.assign(playlistJSON(["delay": 10, "beginfirst": true, "playintro": true], ["s4", "s1", "s2"]),
                            to: AppState.allDisplays)
        s!.playlists.next()
        s!.playlists.next()
        s!.playlists.saveState()
        s = nil
        let r = makeState(d, library: lib)
        r.playlists.start()
        XCTAssertEqual(r.wallpaper(forDisplay: k), "s4", "beginfirst: the first wallpaper at startup")
        XCTAssertEqual(r.playlists.runners[k]?.introPlaying, true)
        for _ in 0..<20 { r.playlists.next() }
        XCTAssertNotEqual(r.wallpaper(forDisplay: k), "s4")
    }

    func testSavedPlaylists() {
        let s = makeState(d, library: lib)
        s.playlists.save(playlistJSON(["delay": 5], ["s0", "s1"], name: "A"))
        s.playlists.save(playlistJSON(["delay": 7], ["s0", "s2"], name: "A"))
        s.playlists.save(playlistJSON(["delay": 7], ["s0", "s2"], name: ""))
        XCTAssertEqual(s.playlists.saved.map(\.name), ["A"], "save overwrites by name; unnamed ignored")
        XCTAssertEqual(makeState(d, library: lib).playlists.saved.first?.delay, 7, "persisted")
        s.playlists.delete(named: "A")
        XCTAssertTrue(makeState(d, library: lib).playlists.saved.isEmpty)
    }

    /// The panel's edit cycle: items as the panel reads them back (`assigned.json` or the draft), cleaned like the UI's
    /// `y()`, sent with `assign`.
    func testPanelEditCycle() {
        let s = makeState(d, library: lib)
        let pl = s.playlists!
        let key = "panel"
        func items() -> [[String: Any]] {
            let json = pl.assigned[key]?.json ?? pl.drafts[key] ?? ["items": [Any]()]
            return (json["items"] as? [Any] ?? []).map { ($0 as? String).map { ["file": $0] } ?? ($0 as? [String: Any] ?? [:]) }
        }
        func commit(_ list: [[String: Any]], mode: String = "daytime") {
            pl.assign(["name": "", "settings": ["mode": mode], "items": PlaylistPanel.cleanItems(list, mode: mode)], to: key)
        }
        commit(items() + [["file": "s0"]])
        XCTAssertEqual(items().count, 1, "the first wallpaper stays in the panel")
        commit(items() + [["file": "s1"]])
        commit(items() + [["file": "s2"]])
        XCTAssertEqual(pl.assigned[key]?.items.map(\.daytimeEnd), [1.0 / 3, 2.0 / 3, 1], "evenly filled")
        var l = items()
        l[0]["daytimeend"] = 0.5
        commit(l)
        XCTAssertEqual(pl.assigned[key]?.items.map(\.daytimeEnd), [0.5, 0.75, 1])
        commit(items() + [["file": "s3"]])
        for (a, b) in zip(pl.assigned[key]?.items.map(\.daytimeEnd) ?? [], [0.5, 2.0 / 3, 5.0 / 6, 1] as [Float]) {
            XCTAssertEqual(a, b, accuracy: 1e-6, "a new last item: the filled ends are recomputed, not frozen")
        }
        l = items()
        l[1]["daytimeend"] = 0.25
        commit(l)
        XCTAssertEqual(pl.assigned[key]?.items[1].daytimeEnd ?? 0, 2.0 / 3, accuracy: 1e-6, "a decreasing end is dropped")
        commit(items(), mode: "timer")
        XCTAssertTrue(items().allSatisfy { $0["daytimeend"] == nil }, "ends go outside time of day")
        XCTAssertEqual(PlaylistPanel.cleanItems([["file": "a", "daytimeend": Float(0.5)], ["file": "b"]], mode: "timer").compactMap { $0 as? String },
                       ["a", "b"], "Float ends (built in code) are handled too")
    }
}
