import Foundation
import XCTest
@testable import PhotonApp
@testable import photon

/// The evaluator (`0x14006cea0`, docs/re/09 §1.3) and app rules (§1.5). Ported from scratchpad r7/host/test plus the
/// layout, rule-precedence and flag cases.
final class PlaybackRulesTests: XCTestCase {
    let d = PlaybackSettings()

    func eval(_ s: SystemSnapshot, _ settings: PlaybackSettings? = nil, rules: [AppRule] = [], flags: HostFlags = [],
              layout: Int = 0) -> PlaybackDecision {
        PlaybackEvaluator.evaluate(s, settings: settings ?? d, rules: rules, flags: flags, layout: layout)
    }

    func testDefaults() {
        XCTAssertEqual(d.focus, .run)
        XCTAssertEqual(d.maximized, .pause)
        XCTAssertEqual(d.fullscreen, .pause)
        XCTAssertEqual(d.battery, .run)
        XCTAssertEqual(d.sleep, .stop)
        XCTAssertEqual(d.audio, .run)
        XCTAssertEqual(d.windowUpdateRate, 1000)
        XCTAssertFalse(d.pauseOnVRAMExhaustion)
    }

    func testModeParse() {
        XCTAssertEqual(["stop", "pauseall", "pause", "mute", "run", "xyz", ""].map { PlaybackAction(engineString: $0) },
                       [.stop, .pauseAll, .pause, .mute, .run, .run, .run])
        for a in PlaybackAction.allCases { XCTAssertEqual(PlaybackAction(engineString: a.engineString), a) }
    }

    func testWindowRules() {
        var s = SystemSnapshot()
        s.allMask = 0b11
        XCTAssertEqual(eval(s), PlaybackDecision(), "idle")
        s.maximizedMask = 0b10
        XCTAssertEqual(eval(s), PlaybackDecision(pauseMask: 0b10), "maximized pause per display")
        XCTAssertEqual(eval(s, layout: 1), PlaybackDecision(), "span: one display covered → run")
        s.fullscreenMask = 0b01
        XCTAssertEqual(eval(s, layout: 1), PlaybackDecision(pauseMask: .max), "span: fullscreen + maximized cover all")
        XCTAssertEqual(eval(s, layout: 2), PlaybackDecision(pauseMask: .max), "clone: same rule")
        var pa = d
        pa.maximized = .pauseAll
        s.fullscreenMask = 0
        XCTAssertEqual(eval(s, pa), PlaybackDecision(pauseMask: .max), "maximized pauseall")
        var st = d
        st.fullscreen = .stop
        s.fullscreenMask = 1
        s.maximizedMask = 0
        XCTAssertEqual(eval(s, st), PlaybackDecision(stop: true), "fullscreen stop")
        var mu = d
        mu.fullscreen = .mute
        XCTAssertEqual(eval(s, mu), PlaybackDecision(mute: true), "fullscreen mute")
        var all = SystemSnapshot(allMask: 0b11)
        all.fullscreenMask = 0b11
        XCTAssertEqual(eval(all, layout: 1), PlaybackDecision(pauseMask: .max), "span: fullscreen on both")
        var mx = d
        mx.maximized = .stop
        XCTAssertEqual(eval(SystemSnapshot(fullscreenMask: 1, allMask: 1), mx, layout: 1), PlaybackDecision(pauseMask: .max, stop: true),
                       "layout ≠ 0: fullscreen counts as maximized")
        XCTAssertEqual(eval(SystemSnapshot(fullscreenMask: 1, allMask: 1), mx, layout: 0), PlaybackDecision(pauseMask: 1),
                       "layout 0: it does not")
    }

    func testFocusRule() {
        var fm = d
        fm.focus = .mute
        var s = SystemSnapshot(allMask: 0b11)
        s.focusMask = 0b10
        XCTAssertEqual(eval(s, fm), PlaybackDecision(mute: true))
        fm.focus = .pause
        XCTAssertEqual(eval(s, fm), PlaybackDecision(pauseMask: 0b10), "focus pause on its display")
        XCTAssertEqual(eval(s, fm, layout: 2), PlaybackDecision(pauseMask: .max), "focus pause with a shared layout: all")
        fm.focus = .pauseAll
        XCTAssertEqual(eval(s, fm), PlaybackDecision(pauseMask: .max))
        fm.focus = .stop
        XCTAssertEqual(eval(s, fm), PlaybackDecision(), "focus has no stop")
    }

    func testFlags() {
        XCTAssertEqual(eval(SystemSnapshot(maximizedMask: 1, allMask: 1), flags: [.peek]), PlaybackDecision(), "peek forces run")
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), flags: [.screensaver]), PlaybackDecision(pauseMask: .max), "screensaver")
        XCTAssertEqual(eval(SystemSnapshot(maximizedMask: 1, allMask: 1), flags: [.peek, .screensaver]), PlaybackDecision(pauseMask: .max),
                       "screensaver after peek")
        var bat = d
        bat.battery = .stop
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), bat, flags: [.onBattery]), PlaybackDecision(stop: true))
        bat.battery = .pause
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), bat, flags: [.onBattery]), PlaybackDecision(pauseMask: .max))
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), bat, flags: []), PlaybackDecision(), "battery rule only on battery")
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), flags: [.onBattery]), PlaybackDecision(), "battery default run")
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), flags: [.vramExhausted]), PlaybackDecision(stop: true))
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), flags: [.userStop]), PlaybackDecision(stop: true))
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1), flags: [.userPause, .userMute, .asleep]), PlaybackDecision(),
                       "tray pause/mute and sleep act in apply, not in the decision")
    }

    func testOtherAudio() {
        var au = d
        au.audio = .pause
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1, otherAudio: true), au), PlaybackDecision(pauseMask: .max))
        au.audio = .mute
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1, otherAudio: true), au), PlaybackDecision(mute: true))
        XCTAssertEqual(eval(SystemSnapshot(allMask: 1, otherAudio: false), au), PlaybackDecision())
    }

    func testAppRules() {
        let me = AppIdentity(pid: 1, name: "Safari", bundleID: "com.apple.Safari", executable: "Safari")
        var rs = SystemSnapshot(allMask: 3)
        rs.windows = [(me, 1, .focused)]
        XCTAssertEqual(eval(rs, rules: [AppRule(application: "Safari", condition: .focused, action: .pause)]),
                       PlaybackDecision(pauseMask: 0b10), "focused pause on display 1")
        XCTAssertEqual(eval(rs, rules: [AppRule(application: "Safari", condition: .maximized, action: .pause)]),
                       PlaybackDecision(), "condition must match the window state")
        XCTAssertEqual(eval(rs, rules: [AppRule(application: "Safari", condition: .focused, action: .pauseAll)]),
                       PlaybackDecision(pauseMask: .max))
        XCTAssertEqual(eval(rs, rules: [AppRule(application: "Safari", condition: .focused, action: .stop)]),
                       PlaybackDecision(stop: true))
        var far = SystemSnapshot(allMask: 3)
        far.windows = [(me, 40, .fullscreen)]
        XCTAssertEqual(eval(far, rules: [AppRule(application: "Safari", condition: .fullscreen, action: .pause)]), PlaybackDecision(),
                       "a display index past 31 has no bit (no crash)")
        var rr = SystemSnapshot(allMask: 3)
        rr.running = [me]
        XCTAssertEqual(eval(rr, rules: [AppRule(application: "Safari", condition: .running, action: .mute)]), PlaybackDecision(mute: true))
        XCTAssertEqual(eval(rr, rules: [AppRule(application: "Safari", condition: .running, action: .pause)]),
                       PlaybackDecision(pauseMask: .max), "running pause = every display")
        var aa = SystemSnapshot(allMask: 3)
        aa.audioApps = [me]
        XCTAssertEqual(eval(aa, rules: [AppRule(application: "safari", condition: .playingAudio, action: .mute)]),
                       PlaybackDecision(mute: true))
        // Rules add to the global rules; a run rule does nothing.
        var both = rs
        both.maximizedMask = 0b01
        XCTAssertEqual(eval(both, rules: [AppRule(application: "Safari", condition: .focused, action: .pause)]),
                       PlaybackDecision(pauseMask: 0b11))
        XCTAssertEqual(eval(rs, rules: [AppRule(application: "Safari", condition: .focused, action: .run)]), PlaybackDecision())
    }

    func testAppRuleMatching() {
        let me = AppIdentity(pid: 1, name: "Safari", bundleID: "com.apple.Safari", executable: "Safari")
        XCTAssertTrue(AppRule(application: "com.apple.safari", condition: .running, action: .mute).matches(me))
        XCTAssertTrue(AppRule(application: "Safari.app", condition: .running, action: .mute).matches(me))
        XCTAssertTrue(AppRule(application: "  safari ", condition: .running, action: .mute).matches(me))
        XCTAssertFalse(AppRule(application: "Chrome", condition: .running, action: .mute).matches(me))
        XCTAssertFalse(AppRule(application: "", condition: .running, action: .mute).matches(AppIdentity(pid: 2, name: "")),
                       "an empty rule matches nothing")
        let rules = [AppRule(application: "X", condition: .fullscreen, action: .stop)]
        let back = try! JSONDecoder().decode([AppRule].self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(back, rules, "rules persist as JSON")
    }
}
