import Foundation
@testable import PhotonRender
import XCTest
@testable import PhotonApp
@testable import photon

/// Settings persistence (the engine's key names in a defaults suite) and the state the renderer reads.
final class AppStateTests: XCTestCase {
    var d: TestDefaults!
    var lib: FakeLibrary!

    override func setUp() {
        d = TestDefaults()
        lib = FakeLibrary()
    }

    override func tearDown() {
        d.remove()
        lib.remove()
    }

    func testDefaultsOnFirstRun() {
        let env = ProcessInfo.processInfo.environment
        let s = makeState(d, library: lib)
        XCTAssertEqual(s.playback, PlaybackSettings())
        XCTAssertTrue(s.rules.isEmpty)
        if env["PHOTON_FPS"] == nil { XCTAssertEqual(s.fps, 15) }
        if env["PHOTON_MSAA"] == nil { XCTAssertEqual(s.msaa, "x2"); XCTAssertEqual(Multisample.setting, "x2") }
        if env["PHOTON_RESOLUTION"] == nil { XCTAssertEqual(s.resolution, "full") }
        XCTAssertEqual(s.layout, 0)
        XCTAssertTrue(s.cloneFlip.isEmpty)
        XCTAssertEqual(s.browseTransition, TransitionSettings(mode: -1, timeMs: 1500), "config default {none, 1500}")
        XCTAssertEqual(s.volume, 1)
        XCTAssertFalse(s.muted)
        XCTAssertFalse(s.paused)
        XCTAssertTrue(s.activeIDs.isEmpty)
        XCTAssertEqual(Set(s.items.map(\.id)), ["s0", "s1", "s2", "s3", "s4", "v0", "w0"])
        XCTAssertEqual(s.item("v0")?.type, "video")
        XCTAssertEqual(s.item("w0")?.type, "web")
        XCTAssertEqual(s.item("s0")?.type, "scene")
        // Nothing was written to the app's real domain by this state.
        XCTAssertNotEqual(d.suite, AppState.defaultsSuite)
    }

    func testRoundTrip() {
        var s: AppState? = makeState(d, library: lib)
        var pb = PlaybackSettings()
        pb.focus = .pauseAll
        pb.maximized = .mute
        pb.fullscreen = .stop
        pb.battery = .pause
        pb.sleep = .run
        pb.audio = .mute
        pb.windowUpdateRate = 250
        pb.pauseOnVRAMExhaustion = true
        s!.playback = pb
        s!.rules = [AppRule(application: "Xcode", condition: .fullscreen, action: .stop)]
        s!.fps = 30
        s!.msaa = "x8"
        s!.resolution = "half"
        s!.layout = 2
        s!.cloneFlip = ["display-a"]
        s!.browseTransition = TransitionSettings(mode: -3, timeMs: 750, pool: [3, 23])
        s!.postProcessing = .ultra
        s!.volume = 0.4
        s!.muted = true
        s!.apply("s1", display: nil)
        s!.apply("s2", display: "display-b")
        s!.setProperty("color", to: "1 0 0", of: "s1")
        s!.setGeneral("volume", to: 20, of: "s1")
        s = nil
        let r = makeState(d, library: lib)
        XCTAssertEqual(r.playback, pb)
        XCTAssertEqual(r.rules.map(\.application), ["Xcode"])
        XCTAssertEqual(r.rules.first?.condition, .fullscreen)
        if ProcessInfo.processInfo.environment["PHOTON_FPS"] == nil { XCTAssertEqual(r.fps, 30) }
        if ProcessInfo.processInfo.environment["PHOTON_MSAA"] == nil { XCTAssertEqual(r.msaa, "x8") }
        if ProcessInfo.processInfo.environment["PHOTON_RESOLUTION"] == nil {
            XCTAssertEqual(r.resolution, "half")
            XCTAssertEqual(SceneRenderer.resolutionSetting, "half")
        }
        XCTAssertEqual(r.layout, 2)
        XCTAssertEqual(r.cloneFlip, ["display-a"])
        XCTAssertEqual(r.browseTransition, TransitionSettings(mode: -3, timeMs: 750, pool: [3, 23]))
        XCTAssertEqual(r.postProcessing, .ultra)
        XCTAssertEqual(r.volume, 0.4)
        XCTAssertTrue(r.muted)
        XCTAssertFalse(r.paused, "the tray pause is not restored")
        XCTAssertEqual(r.wallpaper(forDisplay: "display-b"), "s2")
        XCTAssertEqual(r.wallpaper(forDisplay: "display-c"), "s1", "other displays fall back to the all-displays choice")
        XCTAssertEqual(r.overrides["s1"]?["color"] as? String, "1 0 0")
        XCTAssertEqual((r.generalValues(of: "s1")["volume"] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((r.generalValues(of: "s2")["volume"] as? NSNumber)?.intValue, 50, "UI default volume 50")
        // Stored under the engine's key names.
        XCTAssertEqual(d.defaults.string(forKey: "playbackfocus"), "pauseall")
        XCTAssertEqual(d.defaults.string(forKey: "playbackonbattery"), "pause")
        XCTAssertEqual(d.defaults.integer(forKey: "windowupdaterate"), 250)
        XCTAssertEqual((d.defaults.dictionary(forKey: "browsetransition")?["transition"] as? String), "random")
    }

    func testTransitionSettingRoundTripsEveryMode() {
        for mode in [-1, -2, -3, 0, 18, 23, 26] {
            let s = makeState(d, library: lib)
            s.browseTransition = TransitionSettings(mode: mode, timeMs: 1200)
            XCTAssertEqual(makeState(d, library: lib).browseTransition, TransitionSettings(mode: mode, timeMs: 1200), "mode \(mode)")
        }
    }

    func testLayoutClampAndBadValues() {
        d.defaults.set(7, forKey: "layout")
        d.defaults.set("garbage", forKey: "playbackfocus")
        d.defaults.set(Data("not json".utf8), forKey: "apprules")
        d.defaults.set(Data("{".utf8), forKey: "overrides")
        d.defaults.set("weird", forKey: "browsetransition")
        let s = makeState(d, library: lib)
        XCTAssertEqual(s.layout, 2)
        XCTAssertEqual(s.playback.focus, .run, "unknown string → run, as PlaybackMode_Parse")
        XCTAssertTrue(s.rules.isEmpty)
        XCTAssertTrue(s.overrides.isEmpty)
        XCTAssertEqual(s.browseTransition.mode, -1, "a non-object browsetransition parses to none")
    }

    func testApplyReplacesPlaylistAndTransitionsAreConsumed() {
        let s = makeState(d, library: lib)
        s.browseTransition = TransitionSettings(mode: 5, timeMs: 900)
        s.showFromPlaylist("s3", display: "k", transition: TransitionSettings(mode: 23, timeMs: 400))
        XCTAssertEqual(s.takeTransition(display: "k"), TransitionSettings(mode: 23, timeMs: 400), "the playlist's own transition")
        XCTAssertEqual(s.takeTransition(display: "k"), TransitionSettings(mode: 5, timeMs: 900), "consumed: then browsetransition")
        s.showFromPlaylist("s3", display: "k", transition: nil)
        XCTAssertEqual(s.takeTransition(display: "k").mode, -1, "startup picks have no transition")
        s.showFromPlaylist("s3", display: "k", transition: TransitionSettings(mode: 1, timeMs: 1))
        s.apply("s4", display: "k")
        XCTAssertEqual(s.takeTransition(display: "k"), s.browseTransition, "a browser apply uses browsetransition")
    }

    func testPauseMuteStopState() {
        let s = makeState(d, library: lib)
        XCTAssertFalse(s.isPaused(displayIndex: 0))
        s.decision = PlaybackDecision(pauseMask: 0b10)
        XCTAssertFalse(s.isPaused(displayIndex: 0))
        XCTAssertTrue(s.isPaused(displayIndex: 1))
        XCTAssertFalse(s.isPaused(displayIndex: 40), "no bit past 31")
        s.decision = PlaybackDecision(pauseMask: .max)
        XCTAssertTrue(s.isPaused(displayIndex: 31))
        s.decision = PlaybackDecision()
        s.hostFlags = [.asleep]
        XCTAssertTrue(s.isPaused(displayIndex: 3), "asleep pauses everything (flags & 0x21)")
        s.hostFlags = []
        s.paused = true
        XCTAssertTrue(s.isPaused(displayIndex: 0))
        XCTAssertFalse(s.isMuted)
        s.decision = PlaybackDecision(mute: true)
        XCTAssertTrue(s.isMuted)
        s.decision = PlaybackDecision(stop: true)
        XCTAssertTrue(s.isStopped)
    }

    func testGeneralValuesDefaultsAndColorMapping() {
        let s = makeState(d, library: lib)
        let g = s.generalValues(of: "s0")
        XCTAssertEqual(g["alignment"] as? Int, 0)
        XCTAssertEqual(g["rate"] as? Int, 100)
        XCTAssertEqual(g["volume"] as? Int, 50)
        XCTAssertEqual(g["wec_e"] as? Bool, false)
        XCTAssertEqual(g["wcc_amt"] as? Int, 100)
        s.setGeneral("wec_e", to: true, of: "s0")
        s.setGeneral("wec_hue", to: 75, of: "s0")
        let cc = ColorCorrection()
        cc.apply(s.generalValues(of: "s0"))
        XCTAssertTrue(cc.enabled)
        XCTAssertEqual(cc.hue, 0.25, accuracy: 1e-6)
        XCTAssertTrue(cc.colorActive)
    }

    func testRevisionsBumpOnPropertyChange() {
        let s = makeState(d, library: lib)
        let r0 = s.revision("s0")
        s.setProperty("x", to: 1, of: "s0")
        s.setProperty("x", to: 2, of: "s0")
        XCTAssertEqual(s.revision("s0"), r0, "debounced")
        spin(0.5)
        XCTAssertEqual(s.revision("s0"), r0 + 1, "one reload after the slider settles")
        s.setGeneral("rate", to: 50, of: "s0")
        spin(0.4)
        XCTAssertEqual(s.revision("s0"), r0 + 1, "general properties apply live, no reload")
        s.apply("s0", display: nil)
        let before = s.revision("s0")
        s.postProcessing = s.postProcessing == .ultra ? .enabled : .ultra
        XCTAssertEqual(s.revision("s0"), before + 1, "post-processing reloads the shown wallpapers")
        s.resolution = s.resolution == "half" ? "full" : "half"
        XCTAssertEqual(s.revision("s0"), before + 2, "so does the resolution (read at load)")
        s.resolution = s.resolution
        XCTAssertEqual(s.revision("s0"), before + 2, "no reload without a change")
        XCTAssertEqual(s.revision("s1"), 0, "wallpapers not shown are not touched")
    }
}
