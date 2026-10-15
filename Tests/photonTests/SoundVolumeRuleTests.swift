import Foundation
import Metal
import PhotonCore
@testable import PhotonRender
import XCTest

/// The sound volume rule (docs/re/06 §4.3, `Sound_VolumeChanged` 0x1401f4c20 and the renderer volume setter
/// 0x1401816d0): a renderer volume of 0 pauses playing tracks (and stops a random / single track whose time ran out), a
/// volume above 0 resumes them, and a loop / random sound that stayed silent at load starts. Voices are fakes; nothing
/// plays.
final class SoundVolumeRuleTests: XCTestCase {
    final class FakeVoice: SoundVoice {
        let duration: TimeInterval
        var isPlaying = false
        let log: (String) -> Void
        init(duration: TimeInterval, log: @escaping (String) -> Void) { self.duration = duration; self.log = log }
        @discardableResult func play() -> Bool { isPlaying = true; log("play"); return true }
        func pause() { isPlaying = false; log("pause") }
        func stop() { isPlaying = false; log("stop") }
    }

    var events: [String] = []
    var resources: SceneResources!
    var dir: URL!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("photon-sound-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("sounds/a.wav"))
        let fs = AssetFileSystem(engineAssets: nil)
        fs.addSearchDirectory(dir)
        resources = SceneResources(device: device, fs: fs)
        events = []
        SoundObject.voiceFactory = { [unowned self] _, _, loops in
            self.events.append("new\(loops ? " loop" : "")")
            return FakeVoice(duration: 1) { self.events.append($0) }
        }
        SoundObject.playbackEnabled = true
    }

    override func tearDown() {
        SoundObject.voiceFactory = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func sound(_ mode: String, startSilent: Bool = false) -> SoundObject {
        SoundObject(json: ["sound": ["sounds/a.wav"], "playbackmode": mode, "volume": 1, "startsilent": startSilent], id: 1,
                    resources: resources)
    }

    func setVolume(_ s: SoundObject, _ v: Float) { resources.volume = v; s.rendererVolumeMaybeChanged() }

    func testMuteAndUnmuteLoop() {
        resources.volume = 0.5
        let s = sound("loop")
        s.update(0.016)
        XCTAssertEqual(events, ["new loop", "play"])
        setVolume(s, 0.2)
        XCTAssertEqual(events, ["new loop", "play"], "a change above 0 resumes nothing that is playing")
        setVolume(s, 0)
        XCTAssertEqual(events.last, "pause", "renderer volume 0 pauses the playing track")
        setVolume(s, 0)
        XCTAssertEqual(events.count, 3, "an equal volume does not run the rule")
        setVolume(s, 0.01)
        XCTAssertEqual(Array(events.suffix(1)), ["play"], "above 0 again: the paused track resumes")
        XCTAssertEqual(events.filter { $0.hasPrefix("new") }.count, 1, "resumed, not restarted")
    }

    func testRandomTrackWhoseTimeRanOutIsStopped() {
        resources.volume = 1
        let s = sound("random")
        s.minTime = 5; s.maxTime = 5
        s.update(0.016)
        XCTAssertEqual(events, ["new", "play"])
        s.update(0.5)
        setVolume(s, 0)
        XCTAssertEqual(Array(events.suffix(1)), ["pause"], "time left: paused only")
        setVolume(s, 1)
        XCTAssertEqual(Array(events.suffix(1)), ["play"])
        s.update(0.6)            // the track's 1 s has run out (the countdown is still running)
        setVolume(s, 0)
        XCTAssertEqual(Array(events.suffix(2)), ["pause", "stop"], "time ran out: paused and stopped")
        let n = events.count
        setVolume(s, 1)
        XCTAssertEqual(events.count, n, "a stopped random track is not resumed; the countdown is still running")
    }

    func testSilentAtLoad() {
        resources.volume = 0
        let loop = sound("loop"), single = sound("single"), silent = sound("loop", startSilent: true)
        for s in [loop, single, silent] { s.update(0.016) }
        XCTAssertEqual(events, [], "gain 0 at load plays nothing")
        for s in [loop, single, silent] { setVolume(s, 0.5) }
        XCTAssertEqual(events, ["new loop", "play"], "only the loop sound starts; single never, startsilent waits for play()")
    }

    func testScriptPausedStaysPaused() {
        resources.volume = 1
        let s = sound("loop")
        s.update(0.016)
        s.scriptPause()
        setVolume(s, 0)
        setVolume(s, 1)
        XCTAssertEqual(events, ["new loop", "play", "pause"], "a script-paused sound is neither paused again nor resumed")
        s.scriptPlay()
        XCTAssertEqual(events.last, "play")
    }
}
