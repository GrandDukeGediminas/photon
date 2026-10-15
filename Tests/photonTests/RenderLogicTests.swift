import Foundation
import Metal
@testable import PhotonRender
import XCTest
@testable import PhotonApp
@testable import photon

/// Pure parts of the host features: transition settings (frame-graph §T1/T2), colour-correction parameters (09 §5.1),
/// the MSAA rule (09 §8.1), the resolution setting, stretch / clone geometry (09 §8.2) and the pause / mute fades (09 §2).
final class RenderLogicTests: XCTestCase {
    // MARK: transitions

    func testTransitionParse() {
        func p(_ o: Any?) -> TransitionSettings { TransitionSettings.parse(o) }
        XCTAssertEqual(p(nil), TransitionSettings(mode: -1, timeMs: 0), "only an object is parsed")
        XCTAssertEqual(p("fade"), TransitionSettings(mode: -1, timeMs: 0))
        XCTAssertEqual(p([String: Any]()), TransitionSettings(mode: -1, timeMs: 500), "absent time → 500")
        XCTAssertEqual(p(["transition": true]).mode, 0, "true → fade")
        XCTAssertEqual(p(["transition": false]).mode, -2, "false → −2")
        XCTAssertEqual(p(["transition": "none"]).mode, -1)
        XCTAssertEqual(p(["transition": "-2"]).mode, -2)
        XCTAssertEqual(p(["transition": "23"]).mode, 23)
        XCTAssertEqual(p(["transition": "99"]).mode, 99, "kept; the pick clamps")
        XCTAssertEqual(p(["transition": "x"]).mode, 0, "atoi of garbage is 0")
        XCTAssertEqual(p(["transition": 5]).mode, -1, "a number is not a string or a bool")
        XCTAssertEqual(p(["transition": "random"]), TransitionSettings(mode: -3, timeMs: 500))
        XCTAssertEqual(p(["transition": "random", "transitionpool": ["3", 4, "23x", true]]).pool, [3, 23], "string members only")
        XCTAssertEqual(p(["transition": "0", "transitiontime": 1500]).timeMs, 1500)
        XCTAssertEqual(p(["transition": "0", "transitiontime": 1234.9]).timeMs, 1234)
        XCTAssertEqual(p(["transition": "0", "transitiontime": "100"]).timeMs, 500)
        XCTAssertEqual(p(["transition": "0", "transitiontime": true]).timeMs, 500)
        XCTAssertEqual(TransitionSettings.atoi("  -12abc"), -12)
        XCTAssertEqual(TransitionSettings.atoi("+7"), 7)
        XCTAssertEqual(TransitionSettings.atoi(""), 0)
    }

    func testTransitionJSONRoundTrip() {
        for s in [TransitionSettings(mode: -1, timeMs: 1500), TransitionSettings(mode: -2, timeMs: 0),
                  TransitionSettings(mode: -3, timeMs: 700), TransitionSettings(mode: -3, timeMs: 700, pool: [1, 26]),
                  TransitionSettings(mode: 0, timeMs: 3000), TransitionSettings(mode: 26, timeMs: 50)] {
            XCTAssertEqual(TransitionSettings.parse(s.jsonObject), s)
        }
    }

    func testEffectPick() {
        XCTAssertNil(TransitionSettings(mode: -1, timeMs: 1).pickEffect(), "none: no overlay")
        XCTAssertNil(TransitionSettings(mode: -2, timeMs: 1).pickEffect(), "no flicker: hold, no effect")
        XCTAssertEqual(TransitionSettings(mode: 99, timeMs: 1).pickEffect(), 26)
        XCTAssertEqual(TransitionSettings(mode: -7, timeMs: 1).pickEffect(), 0, "other numbers clamp to 0…26")
        XCTAssertEqual(TransitionSettings(mode: 11, timeMs: 1).pickEffect(), 11)
        var seen = Set<Int>()
        for _ in 0..<5000 { seen.insert(TransitionSettings(mode: -3, timeMs: 1).pickEffect()!) }
        XCTAssertTrue(seen.isSubset(of: Set(0...26)))
        XCTAssertGreaterThan(seen.count, 20)
        let pool = TransitionSettings(mode: -3, timeMs: 1, pool: [4, 40])
        for _ in 0..<200 { XCTAssertTrue([4, 40].contains(pool.pickEffect()!), "pool values unclamped") }
    }

    // MARK: colour correction

    func testColorCorrectionMapping() {
        let c = ColorCorrection()
        XCTAssertFalse(c.isActive, "ctor (false, 1, 1, 1, 0, \"\", 1)")
        c.apply(["wec_e": true, "wec_con": 25, "wec_brs": 100, "wec_sa": 0, "wec_hue": 100])
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.contrast, 0.5)
        XCTAssertEqual(c.brightness, 2)
        XCTAssertEqual(c.saturation, 0)
        XCTAssertEqual(c.hue, 0.5)
        XCTAssertTrue(c.colorActive)
        XCTAssertFalse(c.lutActive)
        c.apply(["wec_con": ["value": 50], "wec_brs": "50", "wec_sa": 50, "wec_hue": 50])
        XCTAssertEqual(c.contrast, 1, "{value:} objects")
        XCTAssertEqual(c.brightness, 1, "numeric strings")
        XCTAssertFalse(c.colorActive, "all neutral → no COL pass")
        XCTAssertTrue(c.enabled, "a missing key keeps the previous value")
        c.apply(["wec_e": false, "wec_hue": 0])
        XCTAssertFalse(c.colorActive, "wec_e off disables COL whatever the values")
        c.apply(["wcc_v": "neutral", "wcc_amt": 0])
        XCTAssertFalse(c.lutActive, "amount 0 → no LUT")
        c.apply(["wcc_amt": 50])
        XCTAssertEqual(c.lutAmount, 1)
        XCTAssertTrue(c.lutActive)
        XCTAssertTrue(c.isActive)
        c.apply(["wcc_v": ""])
        XCTAssertFalse(c.isActive)
    }

    // MARK: MSAA

    func testMSAARule() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertEqual(Multisample.sampleCount(setting: "none", device: device), 1)
        XCTAssertEqual(Multisample.sampleCount(setting: "disabled", device: device), 1)
        XCTAssertEqual(Multisample.sampleCount(setting: "x2", device: device), 2)
        XCTAssertEqual(Multisample.sampleCount(setting: "x4", device: device), 4)
        XCTAssertEqual(Multisample.sampleCount(setting: "x8", device: device), device.supportsTextureSampleCount(8) ? 8 : 1)
        XCTAssertEqual(Multisample.sampleCount(setting: "x16", device: device), 1, "only x2/x4/x8 parse")
        XCTAssertTrue(Multisample.sceneHasModel(["objects": [["image": "a"], ["model": "m.json"]]]))
        XCTAssertFalse(Multisample.sceneHasModel(["objects": [["model": NSNull()], ["image": "a"]]]), "null model: not multisampled")
        XCTAssertFalse(Multisample.sceneHasModel(["objects": [["sound": ["a.mp3"]]]]))
        XCTAssertFalse(Multisample.sceneHasModel([:]))
    }

    /// The resolve scratch cache must not keep textures of freed MSAA targets, nor hand one of another format.
    func testMSAAResolveScratchDoesNotLeak() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func ms(_ f: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: 64, height: 32, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = 4
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let dst = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return d
        }())!
        for i in 0..<40 {
            autoreleasepool {
                let src = ms(i % 2 == 0 ? .bgra8Unorm : .rgba16Float)
                let cb = queue.makeCommandBuffer()!
                if src.pixelFormat == dst.pixelFormat {
                    Multisample.resolve(src, into: dst, commandBuffer: cb, device: device)
                } else {
                    let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 32, height: 32, mipmapped: false)
                    d2.usage = [.renderTarget, .shaderRead]
                    d2.storageMode = .private
                    Multisample.resolve(src, into: device.makeTexture(descriptor: d2)!, commandBuffer: cb, device: device)
                }
                cb.commit()
                cb.waitUntilCompleted()
                XCTAssertNil(cb.error)
            }
        }
        XCTAssertLessThanOrEqual(Multisample.scratchCount, 2, "entries of freed MSAA targets are dropped")
    }

    // MARK: resolution

    func testResolutionSetting() {
        XCTAssertEqual(SceneRenderer.textureReduction(setting: "full", screen: SIMD2(800, 600)), 1)
        XCTAssertEqual(SceneRenderer.textureReduction(setting: "half", screen: SIMD2(5120, 2880)), 2)
        XCTAssertEqual(SceneRenderer.textureReduction(setting: "auto", screen: SIMD2(1920, 1080)), 1, "2073600 ≥ 1969920")
        XCTAssertEqual(SceneRenderer.textureReduction(setting: "auto", screen: SIMD2(1600, 1200)), 2, "1920000 < 1969920")
        XCTAssertEqual(SceneRenderer.textureReduction(setting: "anything", screen: SIMD2(1280, 720)), 2, "other strings = auto")
    }

    // MARK: stretch / clone geometry

    func testSpanAndCoverGeometry() {
        let rects: [(id: CGDirectDisplayID, rect: CGRect, scale: CGFloat)] = [
            (1, CGRect(x: 0, y: 0, width: 1920, height: 1080), 1), (2, CGRect(x: 1920, y: 0, width: 1920, height: 1080), 1),
            (3, CGRect(x: 3840, y: -420, width: 1080, height: 1920), 1)]
        let (box, uv) = LayoutCompositor.spanRegions(rects)
        XCTAssertEqual(box, CGRect(x: 0, y: -420, width: 4920, height: 1920))
        XCTAssertEqual(uv[1]!.minX, 0)
        XCTAssertEqual(uv[2]!.minX, 1920.0 / 4920, accuracy: 1e-9)
        XCTAssertEqual(uv[3]!.minY, 0)
        XCTAssertEqual(uv[1]!.minY, 420.0 / 1920, accuracy: 1e-9)
        XCTAssertEqual(uv[3]!.height, 1)
        // Every display's region lies inside the box, and the regions don't overlap.
        for r in uv.values { XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-9, dy: -1e-9).contains(r)) }
        XCTAssertTrue(uv[1]!.intersection(uv[2]!).width < 1e-9)
        XCTAssertEqual(LayoutCompositor.spanRegions([]).box, .zero)
        let wide = LayoutCompositor.coverUV(source: 16.0 / 9, target: 21.0 / 9)
        XCTAssertEqual(wide.width, 1)
        XCTAssertEqual(wide.height, (16.0 / 9) / (21.0 / 9), accuracy: 1e-9)
        XCTAssertEqual(wide.midY, 0.5, accuracy: 1e-9)
        let tall = LayoutCompositor.coverUV(source: 16.0 / 9, target: 9.0 / 16)
        XCTAssertEqual(tall.height, 1)
        XCTAssertEqual(tall.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(LayoutCompositor.coverUV(source: 0, target: 1), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(LayoutCompositor.coverUV(source: 1.5, target: 1.5), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: fades

    func testPauseAndMuteFades() {
        var v: Float = 1
        var frames = 0
        while v > 0, frames < 1000 { v = WallpaperRenderer.fade(v, toward: 0, dt: 1.0 / 60); frames += 1 }
        XCTAssertEqual(v, 0, "snaps to the target")
        XCTAssertTrue((40...60).contains(frames), "6/s at 60 fps: ~0.8 s (\(frames) frames)")
        XCTAssertEqual(WallpaperRenderer.fade(0.5, toward: 1, dt: 1), 1, "min(6·dt, 1) caps the step")
        XCTAssertEqual(WallpaperRenderer.fade(0.995, toward: 1, dt: 0.001), 1, "within 0.01 → snap")
        XCTAssertEqual(WallpaperRenderer.fade(0.5, toward: 1, dt: 0.1), 0.8, accuracy: 1e-6)
    }
}
