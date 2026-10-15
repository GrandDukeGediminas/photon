import Foundation
import XCTest
@testable import PhotonApp

/// The multi-monitor layout model (docs/re/09 §8.3): the wallpaperconfig `profile` as `Layout_Compute` 0x1400740d0 reads
/// it, the clone source rule, groups (0x140061b50), splits (0x140061280), the UI's edit rules (scripts.js) and what each
/// display shows.
final class MonitorLayoutTests: XCTestCase {
    typealias M = LayoutPlan.Monitor

    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func plan(_ layout: Int, _ p: MonitorProfile, _ ms: [M]) -> LayoutPlan { LayoutPlan.compute(layout: layout, profile: p, monitors: ms) }

    // MARK: profile JSON

    func testProfileJSONFollowsTheEngineTypeRules() throws {
        let text = """
        {"source": "B", "monitorconfig": {"A": {"flip": true}, "B": {"flip": 1}, "C": {"flip": false}, "D": true},
         "groups": {"g1": {"monitors": ["A", "B", 3], "layout": 2, "source": "B", "monitorconfig": {"A": {"flip": true}}},
                    "g2": {"monitors": ["C", "D"]}, "g3": {"monitors": ["C", "D"], "layout": true}, "g4": {"monitors": "C"},
                    "g5": {"monitors": ["E"], "layout": 2.0}},
         "splits": {"A": {"direction": 1, "position": 0.25}, "B": {"direction": "1", "position": 0.5},
                    "C": {"direction": 0, "position": "0.5"}, "D": {"direction": 0.0, "position": 2}}}
        """
        let p = MonitorProfile(json: try JSONSerialization.jsonObject(with: Data(text.utf8)))
        XCTAssertEqual(p.source, "B")
        XCTAssertEqual(p.flip, ["A"], "flip must be a JSON boolean true in an object (0x140061a10)")
        XCTAssertEqual(p.groups["g1"], MonitorProfile.Group(monitors: ["A", "B"], layout: 2, source: "B", flip: ["A"]))
        XCTAssertEqual(p.groups["g2"]?.layout, 1, "missing layout: 1 (0x140061dbe)")
        XCTAssertEqual(p.groups["g3"]?.layout, 1, "a boolean is not an int")
        XCTAssertNil(p.groups["g4"], "monitors must be an array (0x140061d4e)")
        XCTAssertEqual(p.groups["g5"]?.layout, 2, "an integral real is an int (jsoncpp isInt)")
        XCTAssertEqual(p.splits["A"], MonitorProfile.Split(direction: 1, position: 0.25))
        XCTAssertNil(p.splits["B"], "direction must be an int")
        XCTAssertNil(p.splits["C"], "position must be a number")
        XCTAssertEqual(p.splits["D"]?.direction, 0, "kept here; position 2 is rejected when the split is applied")
        // Written back with the engine's key names; read again it is the same profile.
        let again = MonitorProfile(json: try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: p.json)))
        XCTAssertEqual(again, p)
        let j = p.json
        XCTAssertEqual(((j["monitorconfig"] as? [String: Any])?["A"] as? [String: Any])?["flip"] as? Bool, true)
        XCTAssertEqual(((j["groups"] as? [String: Any])?["g1"] as? [String: Any])?["source"] as? String, "B")
        XCTAssertTrue(MonitorProfile(json: nil).isEmpty)
        XCTAssertTrue(MonitorProfile().json.isEmpty)
    }

    // MARK: UI edit rules (scripts.js)

    func testHashCodeIsTheUIStringHash() {
        XCTAssertEqual(MonitorProfile.hashCode("ab"), 3105)
        XCTAssertEqual(MonitorProfile.hashCode("display-adisplay-b"), -1708885823, "int32 wrap like `e &= e`")
        XCTAssertEqual(MonitorProfile.hashCode(""), 0)
    }

    func testCreateMergeAndRemoveGroups() {
        var p = MonitorProfile(splits: ["A": .init(direction: 0, position: 0.5), "A/L": .init(direction: 1, position: 0.5),
                                        "AB": .init(direction: 0, position: 0.5)])
        XCTAssertNil(p.createGroup(["A"], layout: 1), "at least two entries")
        let g = p.createGroup(["A", "B"], layout: 1)
        XCTAssertEqual(g, "group_\(MonitorProfile.hashCode("AB"))")
        XCTAssertEqual(p.groups[g!], MonitorProfile.Group(monitors: ["A", "B"], layout: 1))
        XCTAssertEqual(Set(p.splits.keys), ["AB"], "a stretch group removes its monitors' splits (Tt: only `/`, L, R follow)")
        // A selection touching a group merges into it and takes the new layout.
        let merged = p.createGroup(["C", "B"], layout: 2)
        XCTAssertEqual(merged, g)
        XCTAssertEqual(p.groups[g!], MonitorProfile.Group(monitors: ["A", "B", "C"], layout: 2))
        // Another group selected together with it is folded in and removed.
        let other = p.createGroup(["D", "E"], layout: 1)!
        XCTAssertEqual(p.createGroup([g!, other], layout: 1), g)
        XCTAssertNil(p.groups[other])
        XCTAssertEqual(p.groups[g!]?.monitors, ["A", "B", "C", "D", "E"])
        // Same name again: a random one.
        var q = MonitorProfile()
        let a = q.createGroup(["X", "Y"], layout: 2)!
        q.groups[a]!.monitors = ["Z"]
        let b = q.createGroup(["X", "Y"], layout: 2)!
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.hasPrefix("group_") && b.count == 12)
        p.removeGroup("C")
        XCTAssertTrue(p.groups.isEmpty, "removing by a member removes its group")
    }

    func testCloneSourceAndFlipRules() {
        var p = MonitorProfile()
        p.toggleFlip("B", among: ["A", "B", "C"])
        p.setSource("B")
        XCTAssertEqual(p.source, "B")
        XCTAssertTrue(p.flip.isEmpty, "locking a source unflips it")
        p.toggleFlip("B", among: ["A", "B", "C"])
        XCTAssertEqual(p.source, "", "flipping the locked source unlocks it")
        XCTAssertFalse(p.toggleFlip("A", among: ["A", "B", "C"]))
        XCTAssertTrue(p.toggleFlip("C", among: ["A", "B", "C"]), "every monitor flipped: the limitation")
        XCTAssertEqual(p.flip, ["B", "C"], "the first other monitor is unflipped again")
        p.setSource(nil)
        XCTAssertEqual(p.source, "")
        // Groups: the same rules on the group's own source and monitorconfig.
        p.groups["g"] = .init(monitors: ["A", "B"], layout: 2)
        p.setGroupSource("g", "A")
        XCTAssertFalse(p.toggleGroupFlip("g", "B"))
        XCTAssertTrue(p.toggleGroupFlip("g", "A"))
        XCTAssertEqual(p.groups["g"]?.source, "")
        XCTAssertEqual(p.groups["g"]?.flip, ["A"])
    }

    // MARK: layout 1 and 2

    func testStretchIsTheUnionOnMonitorZero() {
        let ms = [M(key: "A", rect: r(0, 0, 1920, 1080)), M(key: "B", rect: r(1920, 200, 1280, 1024), scale: 2)]
        let pl = plan(1, MonitorProfile(), ms)
        XCTAssertEqual(pl.records.map(\.skipped), [false, true])
        XCTAssertEqual(pl.records[0].rect, r(0, 0, 3200, 1224))
        XCTAssertEqual(pl.instances.count, 1)
        XCTAssertEqual(pl.instances[0].key, "A")
        XCTAssertEqual(pl.instances[0].kind, .span)
        XCTAssertEqual(pl.instances[0].pixelSize, CGSize(width: 3200, height: 1224), "the box at the smallest scale")
        XCTAssertEqual(pl.tiles(for: "B").first?.source, r(1920.0 / 3200, 200.0 / 1224, 1280.0 / 3200, 1024.0 / 1224))
        XCTAssertEqual(pl.role("A"), .shared(instance: pl.instances[0], tile: pl.tiles(for: "A")[0], isHost: true))
    }

    /// 0x14007466f–0x14007494a: the largest landscape monitor that is not flipped, starting from monitor 0.
    func testCloneSourceRule() {
        let A = M(key: "A", rect: r(0, 0, 1920, 1080)), B = M(key: "B", rect: r(1920, 0, 2560, 1440))
        let C = M(key: "C", rect: r(-1080, 0, 1080, 1920)), P = M(key: "P", rect: r(0, 0, 1080, 1920))
        let small = M(key: "S", rect: r(1080, 0, 1280, 720))
        func source(_ ms: [M], _ p: MonitorProfile = MonitorProfile()) -> String { plan(2, p, ms).instances[0].host }
        XCTAssertEqual(source([A, B, C]), "B", "largest landscape")
        XCTAssertEqual(source([A, C]), "A", "a bigger portrait monitor loses once a landscape one was seen")
        XCTAssertEqual(source([P, small]), "S", "the first landscape monitor after portrait ones wins whatever its area")
        XCTAssertEqual(source([P, M(key: "Q", rect: r(1080, 0, 1440, 2560))]), "Q", "only portraits: by area")
        XCTAssertEqual(source([A, B], MonitorProfile(flip: ["B"])), "A", "flipped monitors are never picked")
        XCTAssertEqual(source([A, small], MonitorProfile(flip: ["A"])), "S", "a flipped monitor 0 is replaced by any other")
        XCTAssertEqual(source([A, B, C], MonitorProfile(source: "C")), "C", "`source` locks")
        XCTAssertEqual(source([A, B, C], MonitorProfile(source: "gone")), "B", "an absent source does not lock")
        XCTAssertEqual(source([A, M(key: "R", rect: r(1920, 0, 960, 540), scale: 2)]), "A", "equal pixel areas: the first stays")
        XCTAssertEqual(source([A, M(key: "R", rect: r(1920, 0, 1280, 720), scale: 2)]), "R", "areas in pixels (2560×1440)")
    }

    func testCloneRecordsSwapAndTiles() {
        let A = M(key: "A", rect: r(0, 0, 1920, 1080)), B = M(key: "B", rect: r(1920, 0, 2560, 1440))
        let C = M(key: "C", rect: r(-1080, 0, 1080, 1920))
        let pl = plan(2, MonitorProfile(flip: ["A", "C"]), [A, B, C])
        // Monitor 0's record renders at the source's rectangle; the source's record is a clone target at monitor 0's.
        XCTAssertEqual(pl.records.map(\.key), ["A", "B", "C"])
        XCTAssertEqual(pl.records.map(\.skipped), [false, true, true])
        XCTAssertEqual(pl.records[0].rect, B.rect)
        XCTAssertEqual(pl.records[1].rect, A.rect)
        XCTAssertEqual(pl.records.map(\.flip), [false, true, true], "flips follow the rectangles")
        let inst = pl.instances[0]
        XCTAssertEqual(inst.key, "A", "the wallpaper is monitor 0's (selectedwallpapers.A)")
        XCTAssertEqual(inst.host, "B")
        XCTAssertEqual(inst.pixelSize, CGSize(width: 2560, height: 1440))
        XCTAssertEqual(pl.tiles(for: "B"), [LayoutPlan.Tile(display: "B", instance: "A", source: unit, target: unit, flip: false, isClone: false)])
        XCTAssertEqual(pl.tiles(for: "A").first?.flip, true)
        let c = pl.tiles(for: "C")[0]
        XCTAssertTrue(c.isClone && c.flip)
        XCTAssertEqual(c.source, LayoutGeometry.coverUV(source: 2560.0 / 1440, target: 1080.0 / 1920), "cover fit")
        XCTAssertEqual(pl.role("B"), .shared(instance: inst, tile: pl.tiles(for: "B")[0], isHost: true))
        XCTAssertEqual(pl.hostGroups(displays: ["A", "B", "C"]),
                       [LayoutPlan.HostGroup(key: "A", outputs: ["A", "B", "C"], layout: 2, cloneSource: "B", flips: ["A", "C"])])
        // One display: nothing to share.
        XCTAssertEqual(plan(2, MonitorProfile(), [A]).role("A"), .own(key: "A"))
    }

    // MARK: layout 0: groups and splits

    func testCloneAndStretchGroups() {
        let ms = [M(key: "A", rect: r(0, 0, 1920, 1080)), M(key: "B", rect: r(1920, 0, 1920, 1080)),
                  M(key: "C", rect: r(3840, 0, 1280, 1024)), M(key: "D", rect: r(5120, 0, 1080, 1920))]
        var p = MonitorProfile()
        p.groups["zclone"] = .init(monitors: ["C", "B", "A"], layout: 2, flip: ["C"])
        p.groups["astretch"] = .init(monitors: ["C", "D"], layout: 1)
        let pl = plan(0, p, ms)
        // Key order: "astretch" first takes C and D; "zclone" only gets B and A.
        let span = pl.records.first { $0.key == "astretch" }!, clone = pl.records.first { $0.key == "zclone" }!
        XCTAssertEqual(span.group, 0)
        XCTAssertEqual(clone.group, 1)
        XCTAssertEqual(span.index, 2, "index = the lowest member index")
        XCTAssertEqual(clone.index, 0)
        XCTAssertEqual(span.rect, r(3840, 0, 2360, 1920), "stretch: the union")
        XCTAssertEqual(clone.rect, r(0, 0, 1920, 1080), "equal areas: the member with the lowest index so far (A over B)")
        XCTAssertEqual(pl.records.filter { !$0.virtual }.map(\.skipped), [true, true, true, true])
        XCTAssertFalse(pl.records.first { $0.key == "C" }!.flip, "C is in the stretch group: the clone group's flip is not applied")
        XCTAssertEqual(pl.instances.map(\.key), ["zclone", "astretch"])
        let ci = pl.instance("zclone")!
        XCTAssertEqual(ci.host, "A")
        XCTAssertEqual(ci.members, ["A", "B"])
        XCTAssertEqual(pl.tiles(for: "B").first?.isClone, true, "members whose rectangle differs are clone targets")
        XCTAssertEqual(pl.tiles(for: "A").first?.isClone, false)
        XCTAssertEqual(pl.tiles(for: "D").first?.source, r(1280.0 / 2360, 0, 1080.0 / 2360, 1), "D's part of the box")
        XCTAssertEqual(pl.instance("astretch")?.host, "C")
        XCTAssertEqual(pl.hostGroups(displays: ["A", "B", "C", "D"]), [
            LayoutPlan.HostGroup(key: "zclone", outputs: ["A", "B"], layout: 2, cloneSource: "A", flips: []),
            LayoutPlan.HostGroup(key: "astretch", outputs: ["C", "D"], layout: 1, cloneSource: nil, flips: []),
        ])
    }

    func testGroupCloneSourceRule() {
        let A = M(key: "A", rect: r(0, 0, 1080, 1920)), B = M(key: "B", rect: r(1080, 0, 1280, 720))
        let C = M(key: "C", rect: r(2360, 0, 2560, 1440)), E = M(key: "E", rect: r(4920, 0, 800, 600))
        func source(_ g: MonitorProfile.Group, _ ms: [M] = []) -> CGRect {
            plan(0, MonitorProfile(groups: ["g": g]), ms.isEmpty ? [A, B, C, E] : ms).records.first { $0.key == "g" }!.rect
        }
        XCTAssertEqual(source(.init(monitors: ["A", "B", "C"], layout: 2)), C.rect, "largest landscape")
        XCTAssertEqual(source(.init(monitors: ["A", "B"], layout: 2)), B.rect, "first landscape after a portrait")
        XCTAssertEqual(source(.init(monitors: ["C", "A"], layout: 2)), C.rect, "portrait after a landscape is not taken")
        XCTAssertEqual(source(.init(monitors: ["B", "C"], layout: 2, flip: ["C"])), B.rect, "flipped members are skipped")
        XCTAssertEqual(source(.init(monitors: ["C", "B", "E"], layout: 2, source: "E")), E.rect, "`source` locks")
        XCTAssertEqual(source(.init(monitors: ["B", "C"], layout: 2, flip: ["B", "C"])), B.rect,
                       "all flipped (the engine's off-screen rectangle): photon2 takes the first member")
        // A group whose monitors are all missing is not created; a missing one is ignored.
        let pl = plan(0, MonitorProfile(groups: ["g": .init(monitors: ["X", "Y"], layout: 2), "h": .init(monitors: ["X", "B"], layout: 2)]), [A, B])
        XCTAssertNil(pl.records.first { $0.key == "g" })
        XCTAssertEqual(pl.instance("h")?.members, ["B"])
        XCTAssertEqual(pl.role("B"), .own(key: "h"), "a one-display group draws like a display")
    }

    func testSplits() {
        let A = M(key: "A", rect: r(0, 0, 1366, 768), scale: 2), B = M(key: "B", rect: r(1366, 0, 1920, 1080))
        var p = MonitorProfile()
        p.splits["A"] = .init(direction: 0, position: 1.0 / 3)
        p.splits["A/R"] = .init(direction: 1, position: 0.25)
        p.splits["B"] = .init(direction: 0, position: 1)
        let pl = plan(0, p, [A, B])
        let keys = pl.records.filter { !$0.skipped }.map(\.key)
        XCTAssertEqual(keys, ["B", "A/L", "A/R/L", "A/R/R"], "B's split is rejected (position 1); A/R is split again, not added")
        let rec = Dictionary(uniqueKeysWithValues: pl.records.map { ($0.key, $0) })
        // d = int(float(1/3) · 2732 px) = 910 px = 455 points.
        XCTAssertEqual(rec["A/L"]!.rect, r(0, 0, 455, 768))
        // A/R is 911 × 768 points; d = int(0.25 · 1536 px) = 384 px = 192 points.
        XCTAssertEqual(rec["A/R/L"]!.rect, r(455, 0, 911, 192))
        XCTAssertEqual(rec["A/R/R"]!.rect, r(455, 192, 911, 576))
        XCTAssertEqual([rec["A/L"]!.splitID, rec["A/R/L"]!.splitID, rec["A/R/R"]!.splitID], [1, 3, 4])
        XCTAssertTrue(rec["A"]!.skipped)
        XCTAssertEqual(pl.instance("A/L")?.kind, .split)
        XCTAssertEqual(pl.tiles(for: "A").count, 3)
        XCTAssertEqual(pl.role("A"), .composite(tiles: pl.tiles(for: "A")), "each region drawn in its rectangle")
        XCTAssertEqual(pl.tiles(for: "A").map(\.target), [r(0, 0, 455.0 / 1366, 1), r(455.0 / 1366, 0, 911.0 / 1366, 0.25),
                                                           r(455.0 / 1366, 0.25, 911.0 / 1366, 0.75)])
        XCTAssertEqual(pl.instance("A/R/R")?.pixelSize, CGSize(width: 1822, height: 1152), "the region at the display's scale")
        XCTAssertEqual(pl.instance("A/R/L")?.name, "A Split 3")
        // One host per region (Linux), with the region's rectangle on its output.
        XCTAssertEqual(pl.hostGroups(displays: ["A", "B"]), [
            LayoutPlan.HostGroup(key: "A/L", outputs: ["A"], layout: 0, cloneSource: nil, flips: [], regions: ["A": r(0, 0, 455, 768)]),
            LayoutPlan.HostGroup(key: "A/R/L", outputs: ["A"], layout: 0, cloneSource: nil, flips: [], regions: ["A": r(455, 0, 911, 192)]),
            LayoutPlan.HostGroup(key: "A/R/R", outputs: ["A"], layout: 0, cloneSource: nil, flips: [], regions: ["A": r(455, 192, 911, 576)]),
            LayoutPlan.HostGroup(key: "B", outputs: ["B"], layout: 0, cloneSource: nil, flips: []),
        ])
        // Groups can take split regions as members.
        var q = p
        q.splits["B"] = nil
        q.groups["g"] = .init(monitors: ["A/L", "B"], layout: 2)
        let pg = plan(0, q, [A, B])
        XCTAssertEqual(pg.instance("g")?.members, ["A", "B"])
        XCTAssertTrue(pg.records.first { $0.key == "A/L" }!.skipped)
        // The group's source is the larger B; A/L shows the cover-fitted clone in its rectangle, A/R its own split.
        XCTAssertEqual(pg.instance("g")?.host, "B")
        guard case .composite(let ta) = pg.role("A") else { return XCTFail("A is a composite") }
        XCTAssertEqual(Set(ta.map(\.instance)), ["A/R/L", "A/R/R", "g"])
        XCTAssertEqual(ta.first { $0.instance == "g" }?.isClone, true)
        XCTAssertEqual(pg.hostGroups(displays: ["A", "B"]).first { $0.key == "g" },
                       LayoutPlan.HostGroup(key: "g", outputs: ["A", "B"], layout: 2, cloneSource: "B", flips: [], regions: ["A": r(0, 0, 455, 768)]))
    }

    /// The UI's split edits (scripts.js): the dialog's pixel position, `Rt` keeping a same-direction `/R` split in place,
    /// edit with another direction, remove (`callbackRemoveSplit` → `Tt` of the parent), remove all (`Tt(rootLocation)`).
    func testSplitEdits() {
        XCTAssertEqual(MonitorProfile.splitFraction(pixels: nil, size: 1921), 960.0 / 1921, "default: floor(size / 2)")
        XCTAssertEqual(MonitorProfile.splitFraction(pixels: 0, size: 1920), 1.0 / 1920, "clamped to [1, size − 1]")
        XCTAssertEqual(MonitorProfile.splitFraction(pixels: 5000, size: 1920), 1919.0 / 1920)
        XCTAssertEqual(MonitorProfile.splitFraction(pixels: 480.9, size: 1920), 0.25, "floored")
        XCTAssertEqual(MonitorProfile.splitPixels(0.25, size: 1080), 270)
        var p = MonitorProfile()
        p.addSplit("A")
        XCTAssertEqual(p.splits["A"], .init(direction: 0, position: 0.5), "add_split: {direction: 0, position: 0.5}")
        p.addSplit("A/R", direction: 0, position: 0.5)
        p.addSplit("A/L", direction: 1, position: 0.5)
        // A/R's divider sits at 0.5 + 0.5 · 0.5 = 0.75 of A; moving A's to 0.25 keeps it there: (0.75 − 0.25) / 0.75.
        XCTAssertTrue(p.moveSplit("A", to: 0.25))
        XCTAssertEqual(p.splits["A"]?.position, 0.25)
        XCTAssertEqual(p.splits["A/R"]!.position, 2.0 / 3, accuracy: 1e-12)
        XCTAssertFalse(p.moveSplit("B", to: 0.5))
        p.editSplit("A/L", direction: 1, position: 0.3)
        XCTAssertEqual(p.splits["A/L"], .init(direction: 1, position: 0.3))
        p.editSplit("A", direction: 1, position: 0.6)
        XCTAssertEqual(p.splits["A"], .init(direction: 1, position: 0.6), "another direction replaces direction and position")
        XCTAssertEqual(p.splits["A/R"]!.position, 2.0 / 3, accuracy: 1e-12, "and leaves the /R split alone")
        XCTAssertEqual(MonitorProfile.splitParent("A/R/L"), "A/R")
        XCTAssertNil(MonitorProfile.splitParent("A"))
        XCTAssertEqual(MonitorProfile.splitRoot("A/R/L"), "A")
        XCTAssertEqual(p.removeSplit(region: "A/R/L"), "A/R")
        XCTAssertEqual(Set(p.splits.keys), ["A", "A/L"])
        p.addSplit("AB")
        p.removeAllSplits(region: "A/L/R")
        XCTAssertEqual(Set(p.splits.keys), ["AB"], "remove all: every split of the monitor, not of another monitor sharing the prefix")
    }

    /// Adding a split moves the region's wallpaper to its left part (the UI re-applies it there).
    func testAddSplitMovesTheWallpaperToTheLeftRegion() {
        let d = TestDefaults(), lib = FakeLibrary()
        defer { d.remove(); lib.remove() }
        let s = makeState(d, library: lib)
        s.layout = 0
        s.apply("s1", display: "A")
        s.addSplit("A", direction: 1, position: 0.5)
        XCTAssertEqual(s.profile.splits["A"], .init(direction: 1, position: 0.5))
        XCTAssertEqual(s.wallpaper(forDisplay: "A/L"), "s1")
        let r = makeState(d, library: lib)
        XCTAssertEqual(r.profile.splits["A"], .init(direction: 1, position: 0.5), "persisted")
        XCTAssertEqual(r.assignments["A/L"], "s1")
    }

    func testAppStatePersistsTheProfileUnderTheEngineKey() throws {
        let d = TestDefaults(), lib = FakeLibrary()
        defer { d.remove(); lib.remove() }
        d.defaults.set(["X"], forKey: "cloneflip")
        var s: AppState? = makeState(d, library: lib)
        XCTAssertEqual(s!.cloneFlip, ["X"], "the old clone flip list carries over")
        s!.profile.createGroup(["A", "B"], layout: 2)
        s!.profile.setSource("A")
        s = nil
        let r = makeState(d, library: lib)
        XCTAssertEqual(r.profile.groups.values.first?.monitors, ["A", "B"])
        XCTAssertEqual(r.profile.source, "A")
        let stored = try JSONSerialization.jsonObject(with: XCTUnwrap(d.defaults.data(forKey: "profile"))) as? [String: Any]
        XCTAssertNotNil(stored?["groups"])
        XCTAssertEqual(stored?["source"] as? String, "A")
        // The state's plan uses its layout and profile.
        r.layout = 0
        let pl = r.layoutPlan([M(key: "A", rect: CGRect(x: 0, y: 0, width: 100, height: 100)), M(key: "B", rect: CGRect(x: 100, y: 0, width: 100, height: 100))])
        XCTAssertEqual(pl.instances.map(\.kind), [.clone])
    }
}
