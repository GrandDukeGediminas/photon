import AppKit
import JavaScriptCore
import PhotonRender
import XCTest
@testable import PhotonApp

/// photon's energy controls (Energy.swift) and the web frame-rate cap (WebPageScripts.frameLimiter).
final class EnergyTests: XCTestCase {
    private func evaluate(_ fps: Int, _ settings: EnergySettings, _ inputs: EnergyInputs) -> EnergyState {
        EnergyPolicy.evaluate(fps: fps, settings: settings, inputs: inputs)
    }
    private func evaluate(_ fps: Int, _ inputs: EnergyInputs) -> EnergyState { evaluate(fps, EnergySettings(), inputs) }

    func testOnACTheSettingIsUnchanged() {
        XCTAssertEqual(evaluate(60, EnergyInputs()), EnergyState(fps: 60))
        XCTAssertEqual(evaluate(0, EnergyInputs()).fps, 0, "unlimited stays unlimited")
        XCTAssertEqual(evaluate(60, EnergyInputs(thermal: .fair)).fps, 60, "fair thermal pressure is ignored")
    }

    func testBatteryFrameRate() {
        let e = evaluate(60, EnergyInputs(onBattery: true))
        XCTAssertEqual(e.fps, 30)
        XCTAssertTrue(e.saving)
        XCTAssertEqual(e.summary, "30 fps: on battery")
        XCTAssertEqual(evaluate(0, EnergyInputs(onBattery: true)).fps, 30, "unlimited is capped too")
        XCTAssertEqual(evaluate(15, EnergyInputs(onBattery: true)).fps, 15, "never raised above the setting")
        XCTAssertEqual(evaluate(15, EnergyInputs(onBattery: true)).reasons, [])
        let keep = EnergySettings(batteryFPS: 0)
        XCTAssertEqual(evaluate(60, keep, EnergyInputs(onBattery: true)).fps, 60, "battery fps 0 keeps the setting")
        XCTAssertTrue(evaluate(60, keep, EnergyInputs(onBattery: true)).saving, "the battery rule still applies")
    }

    func testLowPowerMode() {
        let e = evaluate(60, EnergyInputs(lowPower: true))
        XCTAssertEqual(e.fps, 30)
        XCTAssertTrue(e.saving, "Low Power Mode counts as battery for the battery rule")
        XCTAssertEqual(e.summary, "30 fps: Low Power Mode")
        let ignore = EnergySettings(followLowPower: false)
        XCTAssertEqual(evaluate(60, ignore, EnergyInputs(lowPower: true)), EnergyState(fps: 60))
        XCTAssertEqual(evaluate(60, EnergyInputs(onBattery: true, lowPower: true)).reasons, ["on battery", "Low Power Mode"])
    }

    func testHeat() {
        let hot = evaluate(60, EnergyInputs(thermal: .serious))
        XCTAssertEqual(hot.fps, 30)
        XCTAssertFalse(hot.overheated)
        XCTAssertEqual(evaluate(0, EnergyInputs(thermal: .serious)).fps, 30, "unlimited halves from 60")
        XCTAssertEqual(evaluate(60, EnergyInputs(onBattery: true, thermal: .serious)).fps, 15, "battery, then heat")
        XCTAssertEqual(evaluate(6, EnergyInputs(thermal: .serious)).fps, EnergyPolicy.minimumFPS)
        let critical = evaluate(60, EnergyInputs(thermal: .critical))
        XCTAssertTrue(critical.overheated)
        XCTAssertEqual(critical.summary, "Paused: the computer is very hot")
        let off = EnergySettings(thermalBackoff: false)
        XCTAssertEqual(evaluate(60, off, EnergyInputs(thermal: .critical)), EnergyState(fps: 60))
    }

    func testWebPages() {
        XCTAssertEqual(evaluate(60, EnergyInputs()).webFPS, 60, "capped to the limit by default")
        let engine = EnergySettings(capWebPages: false)
        XCTAssertEqual(evaluate(60, engine, EnergyInputs()).webFPS, 0, "off: the refresh rate, as in the engine")
        XCTAssertEqual(evaluate(60, engine, EnergyInputs(onBattery: true)).webFPS, 30, "battery still caps them")
        XCTAssertEqual(evaluate(60, engine, EnergyInputs(thermal: .serious)).webFPS, 30, "heat still caps them")
    }

    func testOverheatedPausesEveryDisplay() {
        let d = PlaybackEvaluator.evaluate(SystemSnapshot(allMask: 0b11), settings: PlaybackSettings(), rules: [], flags: [.overheated])
        XCTAssertEqual(d.pauseMask, UInt32.max)
    }

    func testSettingsPersistAndDriveTheFrameRate() {
        let suite = "photon2-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(60, forKey: "fps")
        let state = AppState(engineAssets: URL(fileURLWithPath: "/nonexistent"), libraryDirectories: [], defaults: defaults)
        XCTAssertEqual(state.energy.fps, 60, "set up in init")
        state.energyInputs = EnergyInputs(onBattery: true)
        XCTAssertEqual(state.energy.fps, 30)
        XCTAssertEqual(SceneRenderer.fpsSetting, 30, "the renderer follows the rate in use")
        XCTAssertEqual(state.generalSettingsForWeb["fps"] as? Int, 30)
        state.energySettings.batteryFPS = 20
        XCTAssertEqual(state.energy.fps, 20)
        XCTAssertEqual(EnergySettings(defaults: defaults).batteryFPS, 20, "saved")
        state.energyInputs = EnergyInputs()
        XCTAssertEqual(state.energy.fps, 60)
        XCTAssertEqual(SceneRenderer.fpsSetting, 60)
    }

    /// The web limiter in JavaScriptCore against a simulated 120 Hz display: a page asking for a frame every frame gets
    /// `fps` of them a second, with even spacing, and wakes far less often than the display refreshes. (WebKit runs no
    /// animation frames for a test process's windows, which it treats as hidden.)
    func testWebFrameLimiter() throws {
        func simulate(fps: Int, refresh: Double = 120, seconds: Double = 2) -> (frames: Int, wakes: Int, maxGap: Double) {
            let js = JSContext()!
            js.evaluateScript("""
            var window = this, now = 0, rafQueue = [], timers = [], wakes = 0, pageFrames = [];
            window.requestAnimationFrame = function(fn) { rafQueue.push(fn); return rafQueue.length; };
            window.cancelAnimationFrame = function() {};
            window.setTimeout = function(fn, ms) { timers.push({at: now + (ms || 0), fn: fn}); return timers.length; };
            """)
            js.evaluateScript(WebPageScripts.frameLimiter + WebPageScripts.setFrameRate(fps))
            js.evaluateScript("function tick(t) { pageFrames.push(t); requestAnimationFrame(tick); } requestAnimationFrame(tick);")
            // Advance in 0.5 ms steps: due timers fire, and each display refresh runs the queued animation callbacks.
            js.evaluateScript("""
            var period = 1000 / \(refresh), nextVsync = period;
            for (now = 0; now < \(seconds * 1000); now += 0.5) {
              var due = timers.filter(function(x) { return x.at <= now; });
              timers = timers.filter(function(x) { return x.at > now; });
              due.forEach(function(x) { wakes++; x.fn(); });
              if (now >= nextVsync) {
                nextVsync += period;
                var q = rafQueue; rafQueue = [];
                if (q.length) wakes++;
                q.forEach(function(fn) { fn(now); });
              }
            }
            """)
            let frames = Int(js.evaluateScript("pageFrames.length").toInt32())
            let wakes = Int(js.evaluateScript("wakes").toInt32())
            let gap = js.evaluateScript("pageFrames.slice(5).reduce(function(m, t, i, a) { return i ? Math.max(m, t - a[i-1]) : m; }, 0)").toDouble()
            return (frames, wakes, gap)
        }
        let capped = simulate(fps: 30)
        XCTAssertEqual(Double(capped.frames), 60, accuracy: 3, "30 fps over 2 s")
        XCTAssertLessThan(capped.maxGap, 1000 / 30 + 9, "evenly spaced")
        XCTAssertLessThan(capped.wakes, 3 * 60, "sleeps between frames instead of waking on all 240 refreshes")
        let sixty = simulate(fps: 60)
        XCTAssertEqual(Double(sixty.frames), 120, accuracy: 3, "60 fps on 120 Hz is every other refresh")
        let free = simulate(fps: 0)
        XCTAssertEqual(Double(free.frames), 240, accuracy: 3, "uncapped runs at the refresh rate")
        let above = simulate(fps: 240)
        XCTAssertEqual(Double(above.frames), 240, accuracy: 3, "a cap above the refresh rate changes nothing")
    }
}
