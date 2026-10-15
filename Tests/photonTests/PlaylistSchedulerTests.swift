import Foundation
import XCTest
@testable import PhotonApp
@testable import photon

/// `Playlist.swift` against docs/re/09 §9.2–9.4 with a simulated clock (ported from scratchpad r7/playlist/test).
final class PlaylistSchedulerTests: XCTestCase {
    var rng = PlaylistRandom(seed: 1)
    let five = ["a", "b", "c", "d", "e"]

    func parse(_ s: [String: Any]?, _ items: [Any]) -> EnginePlaylist { EnginePlaylist.parse(playlistJSON(s, items), random: &rng) }

    // MARK: §9.2 parse

    func testParseDelayAndMode() {
        var p = parse(["mode": "timer"], five)
        XCTAssertEqual(p.delay, 0, "settings without delay → delay 0")
        XCTAssertTrue(p.mode == .timer && !p.sorted, "default mode timer, order random")
        p = parse(nil, five)
        XCTAssertEqual(p.delay, 60, "no settings object → delay 60 (ctor)")
        p = parse(["delay": 15, "mode": "logon", "order": "sorted"], five)
        XCTAssertTrue(p.mode == .logon && p.delay == 15 && p.sorted, "logon keeps delay; sorted")
        p = parse(["delay": 15, "mode": "daytime"], five)
        XCTAssertTrue(p.mode == .daytime && p.delay == 0, "daytime zeroes delay")
        p = parse(["delay": 15, "mode": "dayofweek"], five)
        XCTAssertTrue(p.mode == .dayOfWeek && p.delay == 0)
        p = parse(["delay": 15, "mode": "never"], five)
        XCTAssertTrue(p.mode == .never && p.delay == 0)
        p = parse(["delay": 15, "mode": "bogus"], five)
        XCTAssertTrue(p.mode == .timer && p.delay == 15, "unknown mode → timer")
        p = parse(["delay": true], five)
        XCTAssertEqual(p.delay, 0, "a bool is not a number")
        p = parse(["delay": 2.5], five)
        XCTAssertEqual(p.delay, 2.5)
    }

    func testParseFlags() {
        var p = parse(["mode": "logon", "beginfirst": true, "playintro": true, "videosequence": true, "updateonpause": true], five)
        XCTAssertEqual(p.flags, [.videoSequence, .updateOnPause], "beginfirst only in timer mode; playintro needs beginfirst")
        p = parse(["mode": "timer", "beginfirst": true, "playintro": true], five)
        XCTAssertTrue(p.flags == [.beginFirst, .playIntro] && p.index == 0, "timer beginfirst+playintro, start index 0")
        XCTAssertEqual(p.pool.map(\.file), ["b", "c", "d", "e"], "intro left out of the pool")
        p = parse(["videosequence": 1], five)
        XCTAssertFalse(p.flags.contains(.videoSequence), "non-bool videosequence ignored")
        p = parse(["playintro": true], five)
        XCTAssertFalse(p.flags.contains(.playIntro), "playintro without beginfirst")
    }

    func testParseItems() {
        var p = parse(["delay": 1], ["only"])
        XCTAssertTrue(p.items.isEmpty, "one item → no playlist")
        p = parse(["delay": 1], ["x", ["file": "y", "preset": "p1"], ["file": ""], 5])
        XCTAssertEqual(p.items.map(\.key), ["x", "yp1"], "string/object items, empty file and non-items skipped")
        let back = EnginePlaylist.parse(p.json, random: &rng)
        XCTAssertTrue(back.items == p.items && back.delay == 1, "json round trip")
        for _ in 0..<50 {
            let q = parse(["delay": 1], five)
            XCTAssertTrue((0..<5).contains(q.index), "random start index in range")
        }
    }

    /// The stored JSON is the UI's: no settings object stays absent (ctor delay 60, transition −2), and the ends the
    /// parse fills in are not written back.
    func testJSONKeepsWhatWasRead() {
        let none = parse(nil, five)
        XCTAssertNil(none.json["settings"], "no settings object → none written")
        XCTAssertEqual(EnginePlaylist.parse(none.json, random: &rng).delay, 60, "round trip keeps the ctor delay")
        let d = parse(["mode": "daytime"], ["a", ["file": "b", "daytimeend": 0.5], "c", "d"])
        let items = d.json["items"] as! [Any]
        XCTAssertEqual(items[0] as? String, "a", "filled end not persisted")
        XCTAssertEqual(((items[1] as? [String: Any])?["daytimeend"] as? NSNumber)?.doubleValue, 0.5)
        let w = parse(["mode": "dayofweek"], ["a", "b", "c"])
        XCTAssertEqual((w.json["items"] as! [Any]).compactMap { $0 as? String }, ["a", "b", "c"], "day shares not persisted")
        // Items built in code (no raw entries) still serialise; ends as JSON numbers.
        var built = EnginePlaylist()
        built.items = [.init(file: "a", daytimeEnd: 0.25), .init(file: "b")]
        let data = try! JSONSerialization.data(withJSONObject: built.json)
        let re = EnginePlaylist.parse(try! JSONSerialization.jsonObject(with: data) as! [String: Any], random: &rng)
        XCTAssertEqual(re.items.map(\.file), ["a", "b"])
    }

    // MARK: day of week / time of day fill

    func testDayOfWeekShares() {
        func ends(_ n: Int) -> [Float] { parse(["mode": "dayofweek"], (0..<n).map { "w\($0)" }).items.map(\.daytimeEnd) }
        XCTAssertEqual(ends(2), [3, 7], "2 items: 3+4 days")
        XCTAssertEqual(ends(3), [2, 4, 7], "3 items: 2+2+3 days")
        XCTAssertEqual(ends(7), [1, 2, 3, 4, 5, 6, 7], "7 items: a day each")
        XCTAssertEqual(Array(ends(9).prefix(7)), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertGreaterThan(ends(9)[7], 7, "items past the 7th never chosen")
    }

    func testDaytimeFill() {
        let p = parse(["mode": "daytime"], ["a", ["file": "b", "daytimeend": 0.5], "c", "d"])
        XCTAssertEqual(p.items.map(\.daytimeEnd), [0.25, 0.5, 0.75, 1], "ends filled evenly")
    }

    // MARK: §9.3 selection

    func testDaytimeSelection() {
        var r = PlaylistRunner(playlist: parse(["mode": "daytime"], ["a", ["file": "b", "daytimeend": 0.5], "c", "d"]))
        var ctx = PlaylistRunner.Context()
        ctx.now = localDate("2026-10-13 05:59")
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "a")
        ctx.now = localDate("2026-10-13 06:00")
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "b", "06:00 (0.25) → b (end must be > now)")
        XCTAssertNil(r.select(force: false, context: ctx, random: &rng), "same item → no change")
        ctx.now = localDate("2026-10-13 23:59")
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "d")
    }

    func testDayOfWeekSelection() {
        var w = PlaylistRunner(playlist: parse(["mode": "dayofweek"], ["mon-tue", "wed-thu", "fri-sun"]))
        var c = PlaylistRunner.Context()
        c.firstDayOfWeek = 0
        c.now = localDate("2026-10-12 12:00") // Monday
        XCTAssertEqual(w.select(force: false, context: c, random: &rng)?.file, "mon-tue")
        c.now = localDate("2026-10-14 12:00") // Wednesday → day 2
        XCTAssertEqual(w.select(force: false, context: c, random: &rng)?.file, "wed-thu")
        c.now = localDate("2026-10-18 12:00") // Sunday → day 6
        XCTAssertEqual(w.select(force: false, context: c, random: &rng)?.file, "fri-sun")
        c.firstDayOfWeek = 6 // Sunday first
        XCTAssertEqual(w.select(force: false, context: c, random: &rng)?.file, "mon-tue")
    }

    func testRandomPoolNeverRepeats() {
        var r = PlaylistRunner(playlist: parse(["delay": 1], five))
        let ctx = PlaylistRunner.Context()
        var seq: [String] = []
        _ = r.select(force: true, context: ctx, random: &rng)
        seq.append(r.current!.file)
        for _ in 0..<99 { seq.append(r.select(force: true, context: ctx, random: &rng)?.file ?? "=") }
        for i in 1..<seq.count { XCTAssertNotEqual(seq[i], seq[i - 1], "repeat at \(i): \(seq.joined())") }
        XCTAssertFalse(seq.contains("="))
        XCTAssertEqual(Set(seq.prefix(5)).count, 5, "first draws cover the pool")
        // Later refills leave out the running wallpaper: cycles of 4 distinct draws (a shuffle bag).
        XCTAssertEqual(Set(seq[5..<9]).count, 4)
        XCTAssertEqual(Set(seq[9..<13]).count, 4)
    }

    func testSortedIntroAndInvalidSkip() {
        var r = PlaylistRunner(playlist: parse(["delay": 1, "order": "sorted", "beginfirst": true, "playintro": true], five))
        r.restore(nil)
        let ctx = PlaylistRunner.Context()
        var seq: [String] = []
        for _ in 0..<10 { if let x = r.select(force: true, context: ctx, random: &rng) { seq.append(x.file) } }
        XCTAssertEqual(seq, ["a", "b", "c", "d", "e", "b", "c", "d", "e", "b"], "intro first, then never again")
        var q = PlaylistRunner(playlist: parse(["delay": 1, "order": "sorted"], five))
        var vctx = ctx
        vctx.isValid = { $0.file != "c" }
        q.playlist.index = 1
        _ = q.select(force: true, context: vctx, random: &rng)
        XCTAssertEqual(q.select(force: true, context: vctx, random: &rng)?.file, "d", "invalid (missing) item skipped")
        // Every item invalid: the sorted walk gives up after n tries instead of looping forever.
        var all = PlaylistRunner(playlist: parse(["delay": 1, "order": "sorted"], five))
        var none = ctx
        none.isValid = { _ in false }
        _ = all.select(force: true, context: none, random: &rng)
        var rnd = PlaylistRunner(playlist: parse(["delay": 1], five))
        _ = rnd.select(force: true, context: none, random: &rng)
    }

    func testBeginFirstSkipsInvalidFirst() {
        var r = PlaylistRunner(playlist: parse(["delay": 1, "order": "sorted", "beginfirst": true], five))
        r.restore(nil)
        var ctx = PlaylistRunner.Context()
        ctx.isValid = { $0.file != "a" }
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "b")
    }

    // MARK: §9.4 timer

    func testTimerTick() {
        var r = PlaylistRunner(playlist: parse(["delay": 2, "order": "sorted"], five))
        r.playlist.index = 0
        let ctx = PlaylistRunner.Context()
        _ = r.select(force: true, context: ctx, random: &rng)
        XCTAssertEqual(r.current?.file, "a")
        var switched = 0
        for _ in 0..<(4 * 60) where r.tick(dt: 1, paused: false, uiOpen: false) {
            if r.select(force: false, context: ctx, random: &rng) != nil { switched += 1 }
        }
        XCTAssertTrue(switched == 2 && r.current?.file == "c", "2-minute delay: 2 changes in 4 minutes")
        for _ in 0..<600 { _ = r.tick(dt: 1, paused: true, uiOpen: false) }
        XCTAssertEqual(r.elapsed, 0, "paused: the timer stops")
        r.playlist.flags.insert(.updateOnPause)
        _ = r.tick(dt: 1, paused: true, uiOpen: false)
        XCTAssertEqual(r.elapsed, 1, "updateonpause: runs while paused")
        _ = r.tick(dt: 3600, paused: false, uiOpen: false)
        XCTAssertEqual(r.elapsed, 6, "dt clamped to 5 s per tick")
        r.currentIsVideo = true
        r.playlist.flags.insert(.videoSequence)
        r.elapsed = 1e6
        XCTAssertFalse(r.tick(dt: 1, paused: false, uiOpen: false), "video with videosequence: timer does not change it")
        XCTAssertTrue(r.videoEndedShouldAdvance(), "video end advances with videosequence")
        var z = PlaylistRunner(playlist: parse(["delay": 0.005], five))
        z.elapsed = 1e6
        XCTAssertFalse(z.tick(dt: 1, paused: false, uiOpen: false), "delay < 0.01 min never fires")
        var d = PlaylistRunner(playlist: parse(["mode": "daytime"], five))
        XCTAssertTrue(d.tick(dt: 1, paused: false, uiOpen: false))
        XCTAssertFalse(d.tick(dt: 1, paused: false, uiOpen: true), "daytime re-evaluates each tick unless the UI is open")
        XCTAssertFalse(d.tick(dt: 1, paused: true, uiOpen: false), "daytime also waits while paused")
    }

    func testIntroVideoPlaysToItsEnd() {
        var r = PlaylistRunner(playlist: parse(["delay": 1, "order": "sorted", "beginfirst": true, "playintro": true], five))
        r.restore(nil)
        let ctx = PlaylistRunner.Context()
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "a")
        XCTAssertTrue(r.introPlaying)
        r.currentIsVideo = true
        r.elapsed = 1e6
        XCTAssertFalse(r.tick(dt: 1, paused: false, uiOpen: false), "intro video waits for its end")
        XCTAssertTrue(r.videoEndedShouldAdvance(), "intro end advances")
        XCTAssertEqual(r.select(force: false, context: ctx, random: &rng)?.file, "b")
        XCTAssertFalse(r.introPlaying)
        XCTAssertFalse(r.videoEndedShouldAdvance(), "timer mode without videosequence: a video end does nothing")
    }

    func testVideoSequenceOnlyInTimerMode() {
        var r = PlaylistRunner(playlist: parse(["mode": "logon", "videosequence": true], five))
        XCTAssertFalse(r.videoEndedShouldAdvance())
        r = PlaylistRunner(playlist: parse(["mode": "timer", "videosequence": true], five))
        XCTAssertTrue(r.videoEndedShouldAdvance())
        XCTAssertFalse(PlaylistRunner(playlist: parse(["videosequence": true], ["one"])).videoEndedShouldAdvance(), "no items")
    }

    // MARK: restart (playliststate)

    func testRestore() {
        let ctx = PlaylistRunner.Context()
        var r = PlaylistRunner(playlist: parse(["delay": 10, "order": "sorted"], five))
        r.playlist.index = 2
        _ = r.select(force: true, context: ctx, random: &rng) // c
        r.elapsed = 120
        var s = r.saved
        s.savedAt = 1000
        var a = PlaylistRunner(playlist: parse(["delay": 10, "order": "sorted"], five))
        a.restore(s, now: 1000 + 60)
        XCTAssertTrue(a.elapsed == 180 && a.playlist.index == 3, "timer gains offline time; index restored")
        XCTAssertEqual(a.select(force: false, context: ctx, random: &rng)?.file, "c", "resumes the saved wallpaper")
        var b = PlaylistRunner(playlist: parse(["delay": 10, "order": "sorted"], five))
        b.restore(s, now: 1000 + 3600)
        XCTAssertEqual(b.select(force: false, context: ctx, random: &rng)?.file, "d", "delay ran out while closed → next one")
        XCTAssertEqual(b.elapsed, 0, "and the timer restarts")
        var l = PlaylistRunner(playlist: parse(["mode": "logon", "order": "sorted"], five))
        l.restore(s, now: 1001)
        XCTAssertEqual(l.select(force: false, context: ctx, random: &rng)?.file, "d", "logon: a new wallpaper at every start")
        XCTAssertNil(l.select(force: false, context: ctx, random: &rng), "logon: no change while running")
        XCTAssertEqual(l.select(force: true, context: ctx, random: &rng)?.file, "e", "logon: next wallpaper still works")
        var n = PlaylistRunner(playlist: parse(["mode": "never"], five))
        n.restore(s, now: 1001)
        XCTAssertNil(n.select(force: false, context: ctx, random: &rng), "never: keeps the configured wallpaper")
        XCTAssertTrue(n.offersNext, "never offers Next Wallpaper")
        XCTAssertFalse(PlaylistRunner(playlist: parse(["mode": "daytime"], five)).offersNext)
        var bf = PlaylistRunner(playlist: parse(["delay": 10, "order": "sorted", "beginfirst": true], five))
        bf.restore(s, now: 1001)
        XCTAssertEqual(bf.select(force: false, context: ctx, random: &rng)?.file, "a", "beginfirst drops the resume item")
        // A saved random pool keeps only items still in the playlist.
        var t = s
        t.pool = [["a", ""], ["zz", ""], ["b", ""], ["bad"]]
        var p = PlaylistRunner(playlist: parse(["delay": 10], five))
        p.restore(t, now: 1001)
        XCTAssertEqual(p.playlist.pool.map(\.file), ["a", "b"])
        // Saved state survives Codable.
        let data = try! JSONEncoder().encode(["k": s])
        XCTAssertEqual(try! JSONDecoder().decode([String: PlaylistRunner.Saved].self, from: data)["k"]?.file, "c")
    }

    func testRandomDeterministic() {
        var a = PlaylistRandom(seed: 42), b = PlaylistRandom(seed: 42)
        XCTAssertEqual((0..<10).map { _ in a.rand() }, (0..<10).map { _ in b.rand() })
        var c = PlaylistRandom(seed: 0)
        XCTAssertEqual(c.rand(), 38, "MSVC rand() with seed 0")
        for _ in 0..<1000 { XCTAssertTrue((0...32767).contains(c.rand())) }
        XCTAssertEqual(c.uniform(1), 0)
    }
}
