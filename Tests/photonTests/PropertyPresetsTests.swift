import Foundation
import XCTest
@testable import PhotonApp
@testable import photon

/// Saved property presets (PropertyPresets.swift): `Preset_Find` 0x140063f00, the UI save/load, and the per-display
/// preset applied to the load values only (0x140073d00).
final class PropertyPresetsTests: XCTestCase {
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

    func testPresetFindRules() {
        let s = makeState(d, library: lib)
        // Stored as the engine's general.wpresets JSON, including entries Preset_Find must skip.
        s.savedPresets = ["s0": ["presets": [
            ["name": 5, "properties": ["a": 0]],                 // name not a string: skipped
            ["name": "p", "properties": ["a": 1]],               // first match decides
            ["name": "p", "properties": ["a": 2]],
            ["name": "bad", "properties": [1, 2]],               // properties not an object: nothing
        ] as [Any]], "s1": ["presets": "x"]]
        XCTAssertEqual(s.presetProperties(file: "s0", name: "p")?["a"] as? Int, 1)
        XCTAssertNil(s.presetProperties(file: "s0", name: ""), "empty name finds nothing")
        XCTAssertNil(s.presetProperties(file: "s0", name: "missing"))
        XCTAssertNil(s.presetProperties(file: "s0", name: "bad"))
        XCTAssertNil(s.presetProperties(file: "s1", name: "p"), "presets must be an array")
        XCTAssertNil(s.presetProperties(file: "s2", name: "p"))
        XCTAssertEqual(s.presets(of: "s0").map(\.name), ["p", "p", "bad"])
    }

    func testSaveMergesByNameAndPersists() {
        var s: AppState? = makeState(d, library: lib)
        s!.savePreset(named: "warm", of: "s0", values: ["color": "1 0 0", "volume": 20])
        s!.savePreset(named: "cold", of: "s0", values: ["color": "0 0 1"])
        s!.savePreset(named: "warm", of: "s0", values: ["speed": 3, "volume": 40])
        s!.savePreset(named: "", of: "s0", values: ["x": 1])
        s = nil
        let s2 = makeState(d, library: lib)
        XCTAssertEqual(s2.presets(of: "s0").map(\.name), ["warm", "cold"], "same name merges in place, order kept")
        let warm = s2.presetProperties(file: "s0", name: "warm")!
        XCTAssertEqual(warm["color"] as? String, "1 0 0")
        XCTAssertEqual(warm["speed"] as? Int, 3)
        XCTAssertEqual(warm["volume"] as? Int, 40)
        s2.deletePreset(named: "warm", of: "s0")
        XCTAssertEqual(s2.presets(of: "s0").map(\.name), ["cold"])
    }

    func testDisplayPresetAppliesToLoadOnly() {
        let s = makeState(d, library: lib)
        s.setProperty("color", to: "0 1 0", of: "s0")
        s.setGeneral("volume", to: 70, of: "s0")
        s.savePreset(named: "p", of: "s0", values: ["color": "1 0 0", "volume": 10, "rate": 50])
        let rev = s.revision("s0")
        s.showFromPlaylist("s0", display: "D1", transition: nil, preset: "p")
        XCTAssertEqual(s.displayPresets["D1"], "p")
        XCTAssertEqual(s.revision("s0"), rev + 1, "a changed preset reloads the wallpaper")
        s.showFromPlaylist("s0", display: "D1", transition: nil, preset: "p")
        XCTAssertEqual(s.revision("s0"), rev + 1, "same file and preset: no reload")

        XCTAssertEqual(s.effectiveOverrides("s0", display: "D1")["color"] as? String, "1 0 0")
        XCTAssertEqual(s.generalValues(of: "s0", display: "D1")["volume"] as? Int, 10)
        XCTAssertEqual(s.generalValues(of: "s0", display: "D1")["rate"] as? Int, 50)
        // Other displays and the stored values are unchanged.
        XCTAssertEqual(s.effectiveOverrides("s0", display: "D2")["color"] as? String, "0 1 0")
        XCTAssertEqual(s.overrides["s0"]?["color"] as? String, "0 1 0")
        XCTAssertEqual(s.generalValues(of: "s0")["volume"] as? Int, 70)

        // An unknown preset name changes nothing; a manual selection clears the display's preset.
        s.showFromPlaylist("s0", display: "D1", transition: nil, preset: "gone")
        XCTAssertEqual(s.effectiveOverrides("s0", display: "D1")["color"] as? String, "0 1 0")
        s.apply("s0", display: "D1")
        XCTAssertNil(s.displayPresets["D1"])
    }

    func testLoadPresetWritesStoredValues() {
        let s = makeState(d, library: lib)
        s.savePreset(named: "p", of: "s0", values: ["color": "1 0 0", "volume": 10])
        s.loadPreset(named: "p", of: "s0")
        XCTAssertEqual(s.overrides["s0"]?["color"] as? String, "1 0 0")
        XCTAssertEqual(s.generalValues(of: "s0")["volume"] as? Int, 10)
    }
}
