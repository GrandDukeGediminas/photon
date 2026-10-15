import AppKit
import Metal
import MetalKit
import PhotonRender
import WebKit
import XCTest
@testable import PhotonApp
@testable import photon

/// Headless runs of `WallpaperRenderer` (the app's per-display draw, switch transitions, stretch / clone, web pages)
/// against offscreen `MTKView`s: no desktop windows are created and nothing is shown. Each view is driven through
/// `MTKView.draw()` like the host's display link, with a simulated clock, on the real display ids (the renderer reads
/// `NSScreen` for layouts and pause bits).
///
/// Needs the engine assets and real wallpapers, so it runs only with `PHOTON_TEST_INTEGRATION=1`; run it with
/// `MTL_DEBUG_LAYER=1` to have Metal validation abort on errors. Wallpapers: `PHOTON_TEST_WALLPAPERS` (a colon-separated
/// list of wallpaper folders) or the defaults below; missing ones are skipped. Sound stays off (muted, master volume 0,
/// no audio capture).
final class HeadlessRendererTests: XCTestCase {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let engineAssets = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTON_WE_ASSETS"]
        ?? home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets").path)
    static var workshop: URL { home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960") }
    static var defaults: URL { engineAssets.deletingLastPathComponent().appendingPathComponent("projects/defaultprojects") }

    /// Role → candidate folders (first that exists wins).
    static var candidates: [String: [URL]] {
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTON_TEST_SCRATCH"] ?? "/nonexistent")
        return [
            "sceneA": [defaults.appendingPathComponent("beach")],
            "sceneB": [defaults.appendingPathComponent("retro")],
            "sceneC": [workshop.appendingPathComponent("1139304621"), defaults.appendingPathComponent("deep_space")],
            "hdr": [workshop.appendingPathComponent("2927802976")],
            "model": [scratch.appendingPathComponent("r7/mdl/scenes/cbm"), workshop.appendingPathComponent("3509243656")],
            "video": [workshop.appendingPathComponent("3611879823"), workshop.appendingPathComponent("3642408184")],
            "web": [defaults.appendingPathComponent("corsair_o_tron"), scratch.appendingPathComponent("r7/host/synth/web1")],
        ]
    }

    var d: TestDefaults!
    var lib: URL!
    var state: AppState!
    var renderer: WallpaperRenderer!
    var device: MTLDevice!
    var views: [CGDirectDisplayID: MTKView] = [:]
    var screens: [CGDirectDisplayID] = []
    var time: Double = 1
    var ids: [String: String] = [:]
    private var shim: Shim!

    /// Forwards `MTKView.draw()` to the renderer with the display id and the simulated time, like DesktopHost.
    final class Shim: NSObject, MTKViewDelegate {
        weak var test: HeadlessRendererTests?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        /// The texture of the last drawable each display drew into.
        var last: [CGDirectDisplayID: MTLTexture] = [:]
        func draw(in view: MTKView) {
            guard let t = test, let screen = t.views.first(where: { $0.value === view })?.key else { return }
            let tex = view.currentDrawable?.texture
            t.renderer.draw(in: view, screen: screen, time: t.time)
            last[screen] = tex
        }
    }

    /// Mean brightness (0–255) of what a display drew last, read back through a blit.
    func brightness(_ screen: CGDirectDisplayID) -> Double? {
        guard let tex = shim.last[screen], tex.pixelFormat == .bgra8Unorm || tex.pixelFormat == .rgba16Float else { return nil }
        spin(0.1)
        let bpp = tex.pixelFormat == .bgra8Unorm ? 4 : 8
        let row = tex.width * bpp
        guard let q = device.makeCommandQueue(), let buf = device.makeBuffer(length: row * tex.height, options: .storageModeShared),
              let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * tex.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var sum = 0.0
        if bpp == 4 {
            let p = buf.contents().assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: row * tex.height, by: 4) { sum += Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2]) }
        } else {
            let p = buf.contents().assumingMemoryBound(to: Float16.self)
            for i in stride(from: 0, to: tex.width * tex.height * 4, by: 4) {
                sum += (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) * 255
            }
        }
        return sum / Double(tex.width * tex.height * 3)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOTON_TEST_INTEGRATION"] == "1", "set PHOTON_TEST_INTEGRATION=1")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.engineAssets.path), "engine assets not found")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        SceneRenderer.audioCaptureEnabled = false
        d = TestDefaults()
        lib = FileManager.default.temporaryDirectory.appendingPathComponent("photon-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment["PHOTON_TEST_WALLPAPERS"]?.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        if let env {
            for (i, u) in env.enumerated() { try link(u, as: "w\(i)") }
        } else {
            for (role, urls) in Self.candidates {
                guard let u = urls.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }) else { continue }
                try link(u, as: role)
            }
        }
        state = AppState(engineAssets: Self.engineAssets, libraryDirectories: [lib], defaults: d.defaults, hiddenFile: nil)
        print("photon-tests: wallpapers \(state.items.map { "\($0.id) (\($0.type))" }.sorted())")
        state.muted = true
        state.volume = 0
        renderer = WallpaperRenderer(device: device, state: state)
        shim = Shim()
        shim.test = self
        screens = NSScreen.screens.map(\.displayID)
        try XCTSkipIf(screens.isEmpty, "no displays")
        for s in screens.prefix(2) {
            let v = MTKView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), device: device)
            v.colorPixelFormat = .bgra8Unorm
            v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            v.framebufferOnly = false
            v.autoResizeDrawable = false
            v.drawableSize = CGSize(width: 480, height: 270)
            v.isPaused = true
            v.enableSetNeedsDisplay = false
            v.delegate = shim
            views[s] = v
        }
    }

    override func tearDown() {
        renderer?.releaseAll()
        views.removeAll()
        renderer = nil
        state = nil
        d?.remove()
        if let lib { try? FileManager.default.removeItem(at: lib) }
        spin(0.05)
    }

    private func link(_ source: URL, as id: String) throws {
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent(id), withDestinationURL: source)
        ids[id] = id
    }

    func require(_ roles: String...) throws {
        for r in roles { try XCTSkipUnless(state.item(r) != nil, "wallpaper for '\(r)' not available") }
    }

    var driven: [CGDirectDisplayID] { Array(views.keys).sorted { screens.firstIndex(of: $0)! < screens.firstIndex(of: $1)! } }

    /// One display-link tick on every driven view, then the main queue (scene loads land there).
    func frame(_ dt: Double = 1.0 / 60) {
        for s in driven { views[s]!.draw() }
        time += dt
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }

    /// Runs frames until `done` or the wall-clock timeout; returns whether it got there.
    @discardableResult
    func run(until done: () -> Bool, timeout: Double = 60, dt: Double = 1.0 / 60) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            frame(dt)
        }
        return done()
    }

    func shows(_ id: String, on screens: [CGDirectDisplayID]? = nil) -> Bool {
        (screens ?? driven).allSatisfy { renderer.debugShown($0)?.id == id }
    }

    func noSwitches() -> Bool { driven.allSatisfy { renderer.debugSwitch($0) == nil } }

    /// With stretch / clone only the host display (stretch: the first screen; clone: the source the size / orientation
    /// rule picks, LayoutPlan) has a wallpaper of its own.
    var wallpaperScreens: [CGDirectDisplayID] { state.layout == 0 ? driven : [host] }

    /// The display that renders the shared instance (docs/re/09 §8.3).
    var host: CGDirectDisplayID {
        let key = state.layoutPlan(LayoutCompositor.monitors()).instances.first?.host
        return driven.first { DisplayInfo.key(for: $0) == key } ?? driven[0]
    }

    func load(_ id: String) {
        state.apply(id, display: nil)
        XCTAssertTrue(run(until: { shows(id, on: wallpaperScreens) && noSwitches() }), "\(id) loaded")
        frame()
    }

    // MARK: tests

    func testOffscreenViewsGiveDrawables() throws {
        let v = try XCTUnwrap(views.values.first)
        XCTAssertNotNil(v.currentDrawable, "an MTKView without a window still vends drawables")
    }

    /// Every transition kind between two scenes: −1 freezes the old frame, −2 holds it until the new one is ready,
    /// effects animate (including the shatter mesh and the bricks GS), random picks one; each ends and frees itself.
    func testSceneToSceneTransitions() throws {
        try require("sceneA", "sceneB")
        load("sceneA")
        let s0 = driven[0]
        var next = "sceneB"
        for (mode, kind) in [(-1, "frozen"), (-2, "noFlicker"), (0, "transition"), (23, "transition"), (16, "transition"),
                             (18, "transition"), (-3, "transition")] {
            state.browseTransition = TransitionSettings(mode: mode, timeMs: 300)
            state.apply(next, display: nil)
            frame()
            let sw = renderer.debugSwitch(s0)
            XCTAssertEqual(sw?.kind, kind, "mode \(mode)")
            if mode >= 0 { XCTAssertEqual(sw?.effect, mode) }
            XCTAssertTrue(run(until: { shows(next) && noSwitches() }, timeout: 30), "mode \(mode) finishes")
            XCTAssertFalse(renderer.fullRate, "display-rate frames end with the overlay")
            next = next == "sceneA" ? "sceneB" : "sceneA"
        }
        XCTAssertEqual(renderer.debugCounts["slots"], driven.count)
        XCTAssertEqual(renderer.debugCounts["overlays"], 0)
    }

    /// −1 across types (scene → video): nothing to hold, the old wallpaper goes at once.
    func testTypeChangesAndVideo() throws {
        try require("sceneA", "video")
        load("sceneA")
        state.browseTransition = TransitionSettings(mode: -1, timeMs: 300)
        state.apply("video", display: nil)
        frame()
        XCTAssertNil(renderer.debugSwitch(driven[0]), "−1 between types: no frozen frame")
        XCTAssertTrue(run(until: { shows("video") }, timeout: 30))
        let c0 = renderer.debugShown(driven[0])!.clock
        run(until: { false }, timeout: 0.5)
        XCTAssertGreaterThan(renderer.debugShown(driven[0])!.clock, c0, "video plays")
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 300)
        state.apply("sceneA", display: nil)
        frame()
        XCTAssertEqual(renderer.debugSwitch(driven[0])?.kind, "transition", "video → scene with a fade")
        XCTAssertTrue(run(until: { shows("sceneA") && noSwitches() }, timeout: 30))
    }

    /// Pause stops the clock after the 6/s fade; a switch started while paused still animates to its end.
    func testPauseResumeAndSwitchWhilePaused() throws {
        try require("sceneA", "sceneB")
        load("sceneA")
        state.paused = true
        run(until: { false }, timeout: 1.5)
        let c = renderer.debugShown(driven[0])!.clock
        run(until: { false }, timeout: 0.5)
        XCTAssertEqual(renderer.debugShown(driven[0])!.clock, c, accuracy: 0.01, "paused: the clock stops")
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 1500)
        state.apply("sceneB", display: nil)
        XCTAssertTrue(run(until: { shows("sceneB") && noSwitches() }, timeout: 30), "the overlay finishes while paused")
        XCTAssertFalse(renderer.fullRate)
        state.paused = false
        let c1 = renderer.debugShown(driven[0])!.clock
        run(until: { false }, timeout: 0.5)
        XCTAssertGreaterThan(renderer.debugShown(driven[0])!.clock, c1 + 0.1, "resumes")
    }

    /// A stop rule frees everything (AppController calls releaseAll and the host hides the windows); it reloads after.
    func testStopAndResume() throws {
        try require("sceneA")
        load("sceneA")
        state.decision = PlaybackDecision(stop: true)
        renderer.releaseAll()
        frame()
        XCTAssertEqual(renderer.debugCounts["slots"], 0)
        XCTAssertEqual(renderer.debugCounts["loading"], 0)
        state.decision = PlaybackDecision()
        XCTAssertTrue(run(until: { shows("sceneA") }, timeout: 30), "reloads when the stop ends")
    }

    /// Playlist switches use the playlist's transition; the timer path and Next both end on the new wallpaper.
    func testPlaylistAdvance() throws {
        try require("sceneA", "sceneB", "sceneC")
        load("sceneA")
        state.playlists.assign(playlistJSON(["delay": 1, "order": "sorted", "transition": "9", "transitiontime": 200],
                                            ["sceneA", "sceneB", "sceneC"]), to: AppState.allDisplays)
        let key0 = DisplayInfo.key(for: driven[0])
        for _ in 0..<3 {
            let before = renderer.debugShown(driven[0])?.id
            XCTAssertEqual(state.wallpaper(forDisplay: key0), before)
            // Sorted order starts at a random index (docs/re/09 §9.2 +0x40), so Next can pick the wallpaper that is
            // already running, which changes nothing (§9.3); the index has moved on and Next again picks the next one.
            state.playlists.next()
            if state.wallpaper(forDisplay: key0) == before {
                XCTAssertNil(renderer.debugSwitch(driven[0]), "same wallpaper: no switch")
                state.playlists.next()
            }
            XCTAssertNotEqual(state.wallpaper(forDisplay: key0), before, "Next changes the wallpaper")
            frame()
            XCTAssertEqual(renderer.debugSwitch(driven[0])?.effect, 9, "the playlist's transition (circular)")
            XCTAssertTrue(run(until: { noSwitches() && renderer.debugShown(driven[0])?.id != before && renderer.debugShown(driven[0]) != nil },
                              timeout: 30))
            // The new scene presents a frame before the next switch reads it back (a scene that never drew has no
            // frame to hand to the overlay).
            frame()
        }
        let before = renderer.debugShown(driven[0])?.id
        for _ in 0..<12 { state.playlists.tick(dt: 5) }
        XCTAssertTrue(run(until: { noSwitches() && renderer.debugShown(driven[0])?.id != before && renderer.debugShown(driven[0]) != nil },
                          timeout: 30), "timer advance")
    }

    /// Stretch and clone: the source display renders into the shared frame, the others show their part; a switch runs
    /// one overlay over the shared frame; clone flip; back to per display.
    func testStretchAndCloneLayouts() throws {
        try require("sceneA", "sceneB")
        try XCTSkipIf(driven.count < 2, "needs two displays")
        for layout in [1, 2] {
            state.layout = layout
            state.cloneFlip = layout == 2 ? [DisplayInfo.key(for: driven[1])] : []
            // With a third, larger display the size rule would pick it, and only the first two displays have views here.
            if layout == 2, NSScreen.screens.count > driven.count { state.profile.setSource(DisplayInfo.key(for: driven[0])) }
            load("sceneA")
            let h = host, other = driven.first { $0 != h }!
            XCTAssertNotNil(renderer.debugShown(h))
            XCTAssertNil(renderer.debugShown(other), "layout \(layout): no wallpaper of its own on the other display")
            state.browseTransition = TransitionSettings(mode: 2, timeMs: 300)
            state.apply("sceneB", display: nil)
            frame()
            XCTAssertEqual(renderer.debugSwitch(h)?.kind, "transition")
            XCTAssertTrue(run(until: { shows("sceneB", on: [h]) && noSwitches() }, timeout: 30))
            for _ in 0..<10 { frame() }
        }
        XCTAssertEqual(renderer.debugCounts["sharedFrame"], 1)
        state.layout = 0
        XCTAssertTrue(run(until: { shows("sceneB") }, timeout: 30), "per display again")
        XCTAssertEqual(renderer.debugCounts["sharedFrame"], 0, "the shared frame is freed")
    }

    /// A clone group of two displays (profile `groups`, docs/re/09 §8.3): the group's wallpaper renders on the group's
    /// source display only; the other member shows the clone; a display outside the group keeps its own wallpaper.
    func testCloneGroup() throws {
        try require("sceneA", "sceneB")
        try XCTSkipIf(driven.count < 2, "needs two displays")
        state.layout = 0
        state.profile = MonitorProfile()
        let a = DisplayInfo.key(for: driven[0]), b = DisplayInfo.key(for: driven[1])
        let group = try XCTUnwrap(state.profile.createGroup([a, b], layout: 2))
        state.profile.setGroupSource(group, b)
        state.apply("sceneA", display: nil)
        state.apply("sceneB", display: group)
        XCTAssertTrue(state.wallpaperTargets.contains { $0.id == group }, "the group is a wallpaper target")
        XCTAssertTrue(run(until: { self.renderer.debugShown(self.driven[1])?.id == "sceneB" && self.renderer.debugShown(self.driven[0]) == nil },
                          timeout: 30), "the locked source renders the group's wallpaper, the other member none")
        for _ in 0..<5 { frame() }
        XCTAssertEqual(renderer.debugCounts["sharedFrame"], 1)
        if driven.count > 2 { XCTAssertEqual(renderer.debugShown(driven[2])?.id, "sceneA", "outside the group: its own") }
        state.profile.removeGroup(group)
        XCTAssertTrue(run(until: { self.shows("sceneA") }, timeout: 30), "per display again")
        XCTAssertEqual(renderer.debugCounts["sharedFrame"], 0)
    }

    /// BGRA8 bytes of a texture (tightly packed rows).
    func pixels(_ tex: MTLTexture) -> [UInt8]? {
        guard tex.pixelFormat == .bgra8Unorm else { return nil }
        let row = tex.width * 4
        guard let q = device.makeCommandQueue(), let buf = device.makeBuffer(length: row * tex.height, options: .storageModeShared),
              let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * tex.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: row * tex.height))
    }

    /// A wallpaper rendered on its own (a fresh scene) at `size` and scene time `clock`, as BGRA8.
    func standalone(_ id: String, size: (Int, Int), clock: Double) throws -> [UInt8] {
        let scene = try SceneRenderer(device: device, wallpaperDirectory: try XCTUnwrap(state.item(id)).directory,
                                      engineAssets: Self.engineAssets, propertyOverrides: [:])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let tex = try XCTUnwrap(device.makeTexture(descriptor: d))
        // A few frames up to the clock, as the region's scene stepped there.
        for t in stride(from: max(clock - 0.1, 0), through: clock, by: 1.0 / 30) + [clock] {
            let cb = try XCTUnwrap(scene.render(into: tex, time: t, outputSize: CGSize(width: size.0, height: size.1), pointer: nil))
            cb.commit()
            cb.waitUntilCompleted()
        }
        return try XCTUnwrap(pixels(tex))
    }

    /// Mean absolute difference of a region of a BGRA8 image (`width` wide) against a `w`×`h` image.
    func meanDiff(_ img: [UInt8], width: Int, x0: Int, y0: Int, _ other: [UInt8], w: Int, h: Int) -> Double {
        var sum = 0.0
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            sum += abs(Double(img[((y0 + y) * width + x0 + x) * 4 + c]) - Double(other[(y * w + x) * 4 + c]))
        } } }
        return sum / Double(w * h * 3)
    }

    /// Split regions (profile `splits`, `Layout_ApplySplit` 0x140061280, docs/re/09 §8.3): each region is a wallpaper
    /// instance keyed `<display>/L`, `/R` with its own scene sized to the region; the display composes them (each half is
    /// its wallpaper rendered at the half size); a nested split; the display's pause bit pauses its regions; a web page
    /// sits over its region; removing the split goes back to one wallpaper.
    func testSplitRegions() throws {
        try require("sceneA", "sceneB")
        // The right half: a scene whose frame depends only on its clock (sceneB animates by script from its own history).
        let right = ProcessInfo.processInfo.environment["PHOTON_TEST_SPLIT_RIGHT"] ?? "sceneC"
        try require(right)
        state.layout = 0
        state.profile = MonitorProfile()
        let s0 = driven[0], key = DisplayInfo.key(for: s0)
        state.apply("sceneA", display: nil)
        state.addSplit(key, direction: 0, position: 0.5)
        state.apply(right, display: key + "/R")
        XCTAssertEqual(Set(state.wallpaperTargets.map(\.id)).intersection([key, key + "/L", key + "/R"]), [key + "/L", key + "/R"])
        XCTAssertTrue(run(until: { self.renderer.debugRegion(s0, key + "/L")?.id == "sceneA" && self.renderer.debugRegion(s0, key + "/R")?.id == right
            && self.renderer.debugShown(s0) == nil && self.noSwitches()
            && (self.driven.count < 2 || self.renderer.debugShown(self.driven[1])?.id == "sceneA") }, timeout: 60), "each region loads its own wallpaper")
        XCTAssertEqual(renderer.debugRegions(s0), [key + "/L", key + "/R"])
        if driven.count > 1 { XCTAssertEqual(renderer.debugShown(driven[1])?.id, "sceneA", "another display keeps its own") }
        // Pixels: pause (the clocks stop after the fade), then each half against its wallpaper rendered alone at the half size.
        state.paused = true
        run(until: { false }, timeout: 1.5)
        frame()
        let tile = try XCTUnwrap(state.layoutPlan(LayoutCompositor.monitors()).tiles(for: key).first { $0.instance == key + "/L" })
        let view = try XCTUnwrap(views[s0])
        let W = Int(view.drawableSize.width), H = Int(view.drawableSize.height)
        let lw = Int((tile.target.width * CGFloat(W)).rounded()), rw = W - lw
        let shot = try XCTUnwrap(shim.last[s0].flatMap(pixels))
        let a = try standalone("sceneA", size: (lw, H), clock: try XCTUnwrap(renderer.debugRegion(s0, key + "/L")).clock)
        let b = try standalone(right, size: (rw, H), clock: try XCTUnwrap(renderer.debugRegion(s0, key + "/R")).clock)
        let ba = try standalone("sceneB", size: (lw, H), clock: 1)
        let ab = try standalone("sceneA", size: (rw, H), clock: 1)
        let dl = meanDiff(shot, width: W, x0: 0, y0: 0, a, w: lw, h: H), dlx = meanDiff(shot, width: W, x0: 0, y0: 0, ba, w: lw, h: H)
        let dr = meanDiff(shot, width: W, x0: lw, y0: 0, b, w: rw, h: H), drx = meanDiff(shot, width: W, x0: lw, y0: 0, ab, w: rw, h: H)
        if let dir = ProcessInfo.processInfo.environment["PHOTON_TEST_DUMP"] {
            for (name, px, w) in [("shot", shot, W), ("a", a, lw), ("b", b, rw)] {
                try Data(px).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(w)x\(H).bgra"))
            }
        }
        print("photon-tests: split halves \(lw)+\(rw)x\(H): left vs sceneA \(dl) (vs sceneB \(dlx)), right vs \(right) \(dr) (vs sceneA \(drx))")
        XCTAssertLessThan(dl, 12, "left half is sceneA at \(lw)x\(H)")
        XCTAssertLessThan(dr, 12, "right half is \(right) at \(rw)x\(H)")
        XCTAssertLessThan(dl * 2, dlx)
        XCTAssertLessThan(dr * 2, drx)
        state.paused = false
        // The display's pause bit (a rule pausing that monitor) pauses its regions.
        let idx = NSScreen.screens.firstIndex { $0.displayID == s0 } ?? 0
        state.decision = PlaybackDecision(pauseMask: 1 << UInt32(idx))
        run(until: { false }, timeout: 1.5)
        let c0 = try XCTUnwrap(renderer.debugRegion(s0, key + "/R")).clock
        run(until: { false }, timeout: 0.5)
        XCTAssertEqual(try XCTUnwrap(renderer.debugRegion(s0, key + "/R")).clock, c0, accuracy: 0.01, "paused with its display")
        state.decision = PlaybackDecision()
        run(until: { false }, timeout: 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(renderer.debugRegion(s0, key + "/R")).clock, c0 + 0.1, "resumes")
        // Nested: /R cut top / bottom; /R/L takes /R's wallpaper, /R/R falls back to all displays'.
        state.addSplit(key + "/R", direction: 1, position: 0.5)
        XCTAssertTrue(run(until: { self.renderer.debugRegions(s0) == [key + "/L", key + "/R/L", key + "/R/R"]
            && self.renderer.debugRegion(s0, key + "/R/L")?.id == right && self.renderer.debugRegion(s0, key + "/R/R")?.id == "sceneA" }, timeout: 60),
                      "nested split: \(renderer.debugRegions(s0))")
        // A switch in one region runs its own transition, the others are untouched.
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 300)
        state.apply("sceneB", display: key + "/L")
        frame()
        XCTAssertEqual(renderer.debugRegionSwitch(s0, key + "/L")?.kind, "transition")
        XCTAssertNil(renderer.debugRegionSwitch(s0, key + "/R/R"))
        XCTAssertTrue(run(until: { self.renderer.debugRegion(s0, key + "/L")?.id == "sceneB" && self.renderer.debugRegionSwitch(s0, key + "/L") == nil },
                          timeout: 30))
        if state.item("web") != nil {
            state.apply("web", display: key + "/R/R")
            XCTAssertTrue(run(until: { self.renderer.debugRegion(s0, key + "/R/R")?.id == "web" && self.renderer.debugRegionSwitch(s0, key + "/R/R") == nil },
                              timeout: 30))
            let pages = view.subviews.filter { $0 is WKWebView }
            XCTAssertEqual(pages.count, 1)
            let f = try XCTUnwrap(pages.first).frame, b = view.bounds
            XCTAssertEqual(f.minX, b.width * tile.target.width, accuracy: 1, "the page covers its region: \(f)")
            XCTAssertEqual(f.maxY, b.height / 2, accuracy: 1, "the bottom half of /R (view coordinates: y up)")
        }
        // Remove: back to one wallpaper on the display.
        state.profile.removeSplit(region: key + "/L")
        XCTAssertTrue(run(until: { self.renderer.debugShown(s0)?.id == "sceneA" && self.renderer.debugRegions(s0).isEmpty }, timeout: 60))
        for _ in 0..<3 { frame() }
        XCTAssertEqual(renderer.debugCounts["sharedFrame"], 0, "region frames freed")
        XCTAssertEqual(renderer.debugCounts["webSlots"], 0)
        XCTAssertTrue(view.subviews.isEmpty, "no web view left")
    }

    /// Colour correction × MSAA × post-processing on a model scene and an HDR scene.
    func testColorMSAAHDRCombos() throws {
        try require("sceneA")
        let targets = ["model", "hdr", "sceneA"].filter { state.item($0) != nil }
        for id in targets {
            for pp in [SceneRenderer.PostProcessing.enabled, .ultra, .displayhdr] {
                for msaa in ["none", "x4", "x8"] {
                    state.postProcessing = pp
                    state.msaa = msaa
                    for (k, v) in ["wec_e": true, "wec_con": 70, "wec_brs": 40, "wec_sa": 0, "wec_hue": 80] as [String: Any] {
                        state.setGeneral(k, to: v, of: id)
                    }
                    state.setGeneral("wcc_v", to: Library.lutFilterFiles.first ?? "", of: id)
                    state.apply(id, display: nil)
                    XCTAssertTrue(run(until: { shows(id) && noSwitches() }, timeout: 60), "\(id) \(pp) \(msaa)")
                    for _ in 0..<5 { frame() }
                    XCTAssertNil(state.errors[id], "\(id) \(pp) \(msaa): \(state.errors[id] ?? "")")
                }
            }
        }
        state.msaa = "x2"
        state.postProcessing = .enabled
    }

    /// Web wallpapers in offscreen WKWebViews: scene → web (overlay view above the page), web → scene (snapshot of the
    /// page or the 3 s wait), web → web with "none" (the old page stays until the new one loaded).
    func testWebWallpaperSwitches() throws {
        try require("sceneA", "web")
        load("sceneA")
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 300)
        state.apply("web", display: nil)
        XCTAssertTrue(run(until: { shows("web") && noSwitches() }, timeout: 30), "scene → web")
        XCTAssertEqual(renderer.debugCounts["webSlots"], driven.count)
        XCTAssertEqual(renderer.debugCounts["overlays"], 0, "overlay views removed")
        run(until: { false }, timeout: 1)
        state.apply("sceneA", display: nil)
        XCTAssertTrue(run(until: { shows("sceneA") && noSwitches() }, timeout: 30), "web → scene")
        XCTAssertEqual(renderer.debugCounts["webSlots"], 0)
        XCTAssertEqual(renderer.debugCounts["pendingWeb"], 0)
        for v in views.values { XCTAssertTrue(v.subviews.isEmpty, "no web view or overlay left in the view") }
        spin(0.5)
        XCTAssertEqual(WebWallpaper.liveInstances, 0, "removed pages are freed (no retain cycle keeps them running)")
    }

    /// Many switches: the renderer's objects and the device's allocations stay flat.
    func testNoLeaksOverManySwitches() throws {
        try require("sceneA", "sceneB")
        let modes = [0, -1, -2, 23, 5]
        load("sceneA")
        func cycle(_ n: Int) {
            for i in 0..<n {
                state.browseTransition = TransitionSettings(mode: modes[i % modes.count], timeMs: 100)
                let id = i % 2 == 0 ? "sceneB" : "sceneA"
                state.apply(id, display: nil)
                XCTAssertTrue(run(until: { shows(id) && noSwitches() }, timeout: 30))
                for _ in 0..<3 { frame() }
            }
        }
        cycle(6)
        spin(0.5)
        let base = device.currentAllocatedSize
        cycle(20)
        spin(0.5)
        for _ in 0..<5 { frame() }
        let growth = Double(device.currentAllocatedSize) - Double(base)
        print("photon-tests: allocated \(base / 1_048_576) MB → \(device.currentAllocatedSize / 1_048_576) MB after 20 switches")
        XCTAssertLessThan(growth, 64 * 1_048_576, "GPU allocations grow by \(Int(growth / 1_048_576)) MB over 20 switches")
        XCTAssertEqual(renderer.debugCounts, ["slots": driven.count, "loading": 0, "switches": 0, "webSlots": 0, "overlays": 0,
                                              "pendingWeb": 0, "retiringWeb": 0, "sharedFrame": 0])
    }

    /// No frame takes long on the main thread (scene loads are off it).
    func testNoStallsWhileSwitching() throws {
        try require("sceneA", "sceneB")
        load("sceneA")
        var worst = 0.0
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 300)
        for id in ["sceneB", "sceneA", "sceneB"] {
            state.apply(id, display: nil)
            let end = Date().addingTimeInterval(30)
            while Date() < end, !(shows(id) && noSwitches()) {
                let t0 = CACurrentMediaTime()
                for s in driven { views[s]!.draw() }
                worst = max(worst, CACurrentMediaTime() - t0)
                time += 1.0 / 60
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }
        print("photon-tests: worst frame \(Int(worst * 1000)) ms")
        XCTAssertLessThan(worst, 0.5, "a frame blocked the main thread for \(Int(worst * 1000)) ms")
    }

    /// Loaded wallpapers draw something (not the black clear).
    func testFramesAreNotBlack() throws {
        try require("sceneA")
        load("sceneA")
        for _ in 0..<5 { frame() }
        for sc in driven {
            let b = try XCTUnwrap(brightness(sc))
            XCTAssertGreaterThan(b, 2, "display \(sc) drew a picture (mean \(b))")
        }
        if state.item("video") != nil {
            load("video")
            run(until: { false }, timeout: 2) // decoding runs on its own clock
            XCTAssertGreaterThan(try XCTUnwrap(brightness(driven[0])), 2, "video frame")
        }
    }

    /// Switching again while a switch is still loading or animating, stopping mid-switch, changing layout mid-switch.
    func testRapidAndInterruptedSwitches() throws {
        try require("sceneA", "sceneB", "sceneC")
        load("sceneA")
        state.browseTransition = TransitionSettings(mode: 0, timeMs: 2000)
        for id in ["sceneB", "sceneC", "sceneA", "sceneB"] {
            state.apply(id, display: nil)
            for _ in 0..<4 { frame() }
        }
        XCTAssertTrue(run(until: { shows("sceneB") && noSwitches() }, timeout: 60), "settles on the last choice")
        state.apply("sceneC", display: nil)
        for _ in 0..<3 { frame() }
        state.decision = PlaybackDecision(stop: true)
        renderer.releaseAll()
        for _ in 0..<3 { frame() }
        XCTAssertEqual(renderer.debugCounts["switches"], 0)
        XCTAssertFalse(renderer.fullRate)
        state.decision = PlaybackDecision()
        XCTAssertTrue(run(until: { shows("sceneC") }, timeout: 60))
        if driven.count > 1 {
            state.apply("sceneA", display: nil)
            for _ in 0..<3 { frame() }
            state.layout = 1
            XCTAssertTrue(run(until: { shows("sceneA", on: [driven[0]]) && noSwitches() }, timeout: 60), "layout change mid-switch")
            state.layout = 0
            XCTAssertTrue(run(until: { shows("sceneA") }, timeout: 60))
        }
    }

    /// Display HDR with stretch: the other display presents the shared fp16 frame in the same (EDR) format.
    func testDisplayHDRWithStretch() throws {
        try require("hdr")
        try XCTSkipIf(driven.count < 2, "needs two displays")
        state.postProcessing = .displayhdr
        state.layout = 1
        load("hdr")
        for _ in 0..<5 { frame() }
        let src = views[driven[0]]!, other = views[driven[1]]!
        XCTAssertEqual(other.colorPixelFormat, src.colorPixelFormat, "same output format as the source")
        state.layout = 0
        state.postProcessing = .enabled
        XCTAssertTrue(run(until: { shows("hdr") }, timeout: 60))
    }

    /// Web page to web page with "none": the old page stays until the new one has loaded, then goes.
    func testWebToWebNone() throws {
        try require("web")
        // A second web wallpaper: the same page under another id.
        let src = try FileManager.default.destinationOfSymbolicLink(atPath: lib.appendingPathComponent("web").path)
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("web2"), withDestinationURL: URL(fileURLWithPath: src))
        state.reloadLibrary()
        load("web")
        run(until: { false }, timeout: 1)
        state.browseTransition = TransitionSettings(mode: -1, timeMs: 0)
        state.apply("web2", display: nil)
        frame()
        XCTAssertTrue(run(until: { shows("web2") && renderer.debugCounts["retiringWeb"] == 0 }, timeout: 10), "the old page retires")
        for v in views.values { XCTAssertEqual(v.subviews.count, 1, "one page left in the view") }
    }

    /// A video in a playlist with "videosequence" moves on when it ends (the renderer counts the loops).
    func testVideoEndAdvancesPlaylist() throws {
        try require("video", "sceneA")
        load("video")
        state.playlists.assign(playlistJSON(["delay": 600, "order": "sorted", "videosequence": true, "transition": "none"],
                                            ["video", "sceneA"]), to: AppState.allDisplays)
        XCTAssertEqual(renderer.debugShown(driven[0])?.id, "video")
        let duration = WallpaperRenderer.videoDuration(state.item("video")!.directory)
        try XCTSkipIf(duration <= 0 || duration > 600, "video duration \(duration)")
        XCTAssertTrue(run(until: { renderer.debugShown(driven[0])?.id == "sceneA" }, timeout: 120, dt: 0.25),
                      "after \(duration) s of video the playlist changes")
    }
}
