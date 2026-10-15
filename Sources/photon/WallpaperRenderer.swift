import AppKit
import AVFoundation
import Metal
import MetalKit
import WebKit
import PhotonApp
import PhotonHost
import PhotonRender

/// Draws each display's chosen wallpaper. One scene per display (each has its own resolution and
/// targets); only the first display showing a wallpaper plays its sound.
final class WallpaperRenderer: DesktopRenderer {
    private struct Slot {
        let id: String
        let revision: Int
        let scene: SceneRenderer?
        /// Playback clock: advances only while not paused, so pausing doesn't skip animation.
        var clock: Double = 0
        var lastHostTime: Double?
        /// Time-scale fade (`+0x170` of the scene wallpaper loop, 0x14011137f–0x1401113d7): moves toward 0 while paused and 1
        /// otherwise by min(6·dt, 1) of the gap per frame, snapping when within 0.01.
        var speed: Float = 1
        /// Volume-scale fade (`+0x174`, 0x1401113e0–0x14011144d): toward 0 while muted, 1 otherwise, same 6/s rule.
        var volumeFade: Float = 1
        var hasFrame = false
        /// Video wallpapers: the file's audio track (the engine's Media Foundation player, `videoaudiooutput` on).
        var videoAudio: VideoAudio?
        /// `spritesheetrefreshsync` pacing (host loop 0x140113510–0x1401136a1): host time before which the next frame
        /// does not start, and whether the scene asked for it on its last frame.
        var nextFrameAt: Double = 0
        var spriteSync = false
        /// Video wallpapers: the file's duration and the number of completed loops, for the playlist's "change when a
        /// video ends" (`Playlist_OnVideoEnded` 0x140067720).
        var videoDuration: Double = 0
        var videoLoops = 0
    }

    let device: MTLDevice
    let state: AppState
    private let queue: MTLCommandQueue
    private var slots: [CGDirectDisplayID: Slot] = [:]
    let desktopPointer = DesktopPointer()

    init(device: MTLDevice, state: AppState) {
        self.device = device
        self.state = state
        queue = device.makeCommandQueue()!
    }

    /// Index of a display in `NSScreen.screens` order: its bit in the playback-rule masks.
    private func displayIndex(_ screen: CGDirectDisplayID) -> Int {
        let display = slotPhysical[screen] ?? screen
        return NSScreen.screens.firstIndex { $0.displayID == display } ?? 0
    }

    /// Stretch / clone layouts and groups (DisplayLayout.swift, docs/re/09 §8.2, §8.3).
    private lazy var compositor = LayoutCompositor(device: device)
    /// Each shared frame's host renders an EDR (fp16 extended-linear) output, by instance key.
    private var sharedEDR: [String: Bool] = [:]
    /// The monitor records for the current layout, profile and displays (`Layout_Compute` 0x1400740d0).
    private var planCache: (layout: Int, profile: MonitorProfile, monitors: [LayoutPlan.Monitor], plan: LayoutPlan)?
    /// The wallpaper key each display draws (its own, a group's on the group's host, the first display's with layouts 1
    /// and 2): the key of its assignment, preset and transition.
    private var drawKeys: [CGDirectDisplayID: String] = [:]

    private func currentPlan() -> LayoutPlan {
        let ms = LayoutCompositor.monitors()
        if let c = planCache, c.layout == state.layout, c.profile == state.profile, c.monitors == ms { return c.plan }
        let p = state.layoutPlan(ms)
        planCache = (state.layout, state.profile, ms, p)
        return p
    }

    /// What a display draws. A shared instance showing a web page, or stopped, is drawn per display.
    private func role(_ screen: CGDirectDisplayID, plan: LayoutPlan) -> LayoutPlan.Role {
        let r = plan.role(DisplayInfo.key(for: screen))
        if case .shared(let inst, _, _) = r, drawnPerDisplay(inst.key) { return .own(key: inst.key) }
        return r
    }

    /// A shared instance whose wallpaper is a web page (web wallpapers stay per display), or every instance while a rule
    /// stops the wallpapers.
    private func drawnPerDisplay(_ key: String) -> Bool {
        state.isStopped || state.wallpaper(forDisplay: key).flatMap({ state.item($0) })?.type == "web"
    }

    /// Displays then their region slots, in `NSScreen` order: the order in which wallpapers claim their sound.
    private var drawOrder: [CGDirectDisplayID] { NSScreen.screens.map(\.displayID).flatMap { [$0] + (regionOrder[$0] ?? []) } }

    /// The first display or region that draws a wallpaper (`NSScreen` order, then the display's regions): it plays the
    /// sound.
    private func soundOwner(_ id: String) -> CGDirectDisplayID? {
        drawOrder.first { s in drawKeys[s].flatMap { state.wallpaper(forDisplay: $0) } == id }
    }

    // MARK: split regions (docs/re/09 §8.3)

    /// Where an instance is drawn: the display's drawable, a shared frame shown by every member display (stretch / clone
    /// host), or a region's frame that the display composes with its other regions (`Layout_ApplySplit` 0x140061280
    /// records: each region is a wallpaper instance with its own window in the engine).
    private enum Output {
        case drawable
        case shared(inst: LayoutPlan.Instance, tile: LayoutPlan.Tile)
        case region(inst: LayoutPlan.Instance, tile: LayoutPlan.Tile)

        var instance: LayoutPlan.Instance? {
            switch self {
            case .drawable: return nil
            case .shared(let i, _), .region(let i, _): return i
            }
        }
        var isRegion: Bool { if case .region = self { return true }; return false }
    }

    /// Region instances have slots of their own under synthetic ids ("display|instance key" → id), mapped to their display.
    private var regionSlotIDs: [String: CGDirectDisplayID] = [:]
    private var slotPhysical: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    /// Each composite display's region slots in tile order (sound order).
    private var regionOrder: [CGDirectDisplayID: [CGDirectDisplayID]] = [:]
    /// A region slot's rectangle in its display view's coordinates (web views and switch overlays).
    private var regionFrames: [CGDirectDisplayID: NSRect] = [:]
    private var nextRegionSlot: CGDirectDisplayID = 0xF000_0000

    private func regionSlot(_ screen: CGDirectDisplayID, _ key: String) -> CGDirectDisplayID {
        let k = "\(screen)|\(key)"
        if let s = regionSlotIDs[k] { return s }
        nextRegionSlot += 1
        regionSlotIDs[k] = nextRegionSlot
        slotPhysical[nextRegionSlot] = screen
        return nextRegionSlot
    }

    /// Frees the region slots of a display that it no longer draws.
    private func dropRegions(_ screen: CGDirectDisplayID, keeping: Set<CGDirectDisplayID>) {
        for (k, slot) in Array(regionSlotIDs) where slotPhysical[slot] == screen && !keeping.contains(slot) {
            dropSlot(slot)
            regionFrames[slot] = nil
            regionSlotIDs[k] = nil
            slotPhysical[slot] = nil
        }
        if keeping.isEmpty { regionOrder[screen] = nil }
    }

    private func dropSlot(_ slot: CGDirectDisplayID) {
        drawKeys[slot] = nil
        slots[slot] = nil
        loading[slot] = nil
        if switches[slot] != nil { endSwitch(slot) }
        removeWeb(slot)
        dropWebSwitchState(slot)
    }

    /// A tile's target in the view's (bottom-left) coordinates.
    private static func frame(of t: LayoutPlan.Tile, in view: NSView) -> NSRect {
        let b = view.bounds
        return NSRect(x: b.minX + t.target.minX * b.width, y: b.minY + (1 - t.target.maxY) * b.height,
                      width: t.target.width * b.width, height: t.target.height * b.height)
    }

    /// The pixel size an instance renders at: a stretch frame is its box, a display's clone source its drawable, a region
    /// its part of the display's drawable.
    private func frameSize(_ output: Output, _ view: MTKView) -> CGSize {
        switch output {
        case .drawable: return view.drawableSize
        case .shared(let inst, _): return compositor.targetSize(inst, sourceDrawable: view.drawableSize)
        case .region(let inst, let t):
            if inst.kind == .span { return inst.pixelSize }
            return CGSize(width: max((t.target.width * view.drawableSize.width).rounded(), 2),
                          height: max((t.target.height * view.drawableSize.height).rounded(), 2))
        }
    }

    /// A display cut in regions (splits, and split regions in groups): every region instance this display hosts renders
    /// into its own frame, sized to the region, with its own slot (wallpaper, playlist, properties and transitions keyed
    /// by the region's key, sound by the first-drawn rule, pause by the display); then the display composes all its
    /// tiles, shared frames rendered elsewhere included.
    private func drawComposite(_ view: MTKView, screen: CGDirectDisplayID, tiles: [LayoutPlan.Tile], plan: LayoutPlan, time: Double) {
        dropSlot(screen) // the display's own wallpaper is not shown while it has regions
        let me = DisplayInfo.key(for: screen)
        var used: [CGDirectDisplayID] = []
        var drawn: Set<String> = []
        for t in tiles {
            guard let inst = plan.instance(t.instance), !drawn.contains(inst.key) else { continue }
            // A stretch / clone frame hosted by another display is only sampled here.
            guard !plan.isShared(inst) || inst.host == me || drawnPerDisplay(inst.key) else { continue }
            drawn.insert(inst.key)
            let slot = regionSlot(screen, inst.key)
            used.append(slot)
            regionFrames[slot] = Self.frame(of: t, in: view)
            drawInstance(view, slot: slot, physical: screen, key: inst.key, output: .region(inst: inst, tile: t), time: time)
        }
        dropRegions(screen, keeping: Set(used))
        regionOrder[screen] = used
        configureOutput(view, edr: tiles.contains { compositor.frameFormat($0.instance) == .rgba16Float })
        guard let cb = queue.makeCommandBuffer() else { return }
        compositor.compose(view, tiles: tiles, commandBuffer: cb)
        cb.commit()
    }

    func draw(in view: MTKView, screen: CGDirectDisplayID, time: TimeInterval) {
        defer { updateFullRate() }
        // Layouts 1 and 2 and stretch / clone groups: the instance's host display runs the wallpaper into a shared frame,
        // the other member displays show their tile of it (stretch: their part of the box; clone: the cover fit,
        // mirrored when flipped). Web wallpapers stay per display. Split regions: each region its own instance.
        let plan = currentPlan()
        let live = Set(plan.instances.filter { $0.kind != .display }.map(\.key))
        if !compositor.frameKeys.isSubset(of: live) { compositor.release(keeping: live) } // up to 16384² fp16 each
        switch role(screen, plan: plan) {
        case .own(let k):
            dropRegions(screen, keeping: [])
            // Drawn per display now (a web page on a shared instance): its shared frame is not needed.
            if compositor.hasFrame(k) { compositor.release(keeping: compositor.frameKeys.subtracting([k])) }
            drawInstance(view, slot: screen, physical: screen, key: k, output: .drawable, time: time)
        case .shared(let inst, let tile, let isHost):
            dropRegions(screen, keeping: [])
            guard isHost else {
                dropSlot(screen)
                // The shared frame is in the host's output format (fp16 linear for display HDR): present it the same way.
                configureOutput(view, edr: sharedEDR[inst.key] ?? false)
                if compositor.hasFrame(inst.key), let cb = queue.makeCommandBuffer() {
                    compositor.present(view, tile: tile, commandBuffer: cb)
                    cb.commit()
                } else {
                    clear(view)
                }
                return
            }
            drawInstance(view, slot: screen, physical: screen, key: inst.key, output: .shared(inst: inst, tile: tile), time: time)
        case .composite(let tiles):
            drawComposite(view, screen: screen, tiles: tiles, plan: plan, time: time)
        }
    }

    /// One wallpaper instance: a display's own, a shared frame on its host, or a region. `slot` keys its scene, switch and
    /// web page (the display id, or a region's synthetic id); `physical` is the display (pause bit, EDR headroom).
    private func drawInstance(_ view: MTKView, slot screen: CGDirectDisplayID, physical: CGDirectDisplayID, key: String,
                              output: Output, time: Double) {
        let frameInst = output.instance
        let region = output.isRegion
        // Regions are composed afterwards: they never present or clear the view themselves.
        func blank() { if !region { clear(view) } }
        drawKeys[screen] = key
        // A "stop" rule destroys the wallpapers (0x140073ac0); they load again when it ends.
        if state.isStopped {
            compositor.releaseAll()
            dropSlot(screen)
            drawKeys[screen] = key
            blank()
            return
        }
        guard let id = state.wallpaper(forDisplay: key), let item = state.item(id), item.unsupportedReason == nil else {
            if frameInst != nil { compositor.release(keeping: compositor.frameKeys.subtracting([key])) }
            dropSlot(screen)
            drawKeys[screen] = key
            blank()
            return
        }
        let revision = state.revision(id)
        // The display's content changes: `Transition_Begin` (0x140068fc0) reads the old frame and starts the overlay
        // before the new wallpaper is loaded.
        if let shown = shownContent(screen), shown.id != id {
            if let pending = pendingWeb[screen], pending.id == id {
                // Waiting for the old web page's frame; it stays on screen meanwhile (the engine waits up to 3 s).
                if time - pending.requested < 3 { blank(); return }
                pendingWeb[screen] = nil
                removeWeb(screen)
            } else {
                if switches[screen] != nil { endSwitch(screen) }
                beginSwitch(to: item, display: key, screen: screen, view: view, size: frameSize(output, view), time: time)
                if pendingWeb[screen] != nil { blank(); return }
            }
        }
        if item.type == "web" {
            slots[screen] = nil
            loading[screen] = nil
            // A region's last scene frame would show under the page.
            if region, compositor.hasFrame(key) { compositor.release(keeping: compositor.frameKeys.subtracting([key])) }
            drawWeb(item, in: view, screen: screen, time: time)
            blank()
            drawWebSwitch(view, screen: screen, time: time)
            return
        }
        removeWeb(screen)
        retireOldWeb(screen, force: true)
        if slots[screen].map({ $0.id != id || $0.revision != revision }) ?? true {
            startLoad(item, revision: revision, for: screen)
        }
        // Keep showing the previous wallpaper until the new one has loaded (or, with a `browsetransition`, its last
        // frame under the transition overlay).
        guard var slot = slots[screen], let scene = slot.scene else {
            if frameInst != nil {
                if !drawSwitchWhileLoadingFrame(view, screen: screen, output: output, time: time) { blank() }
            } else if !drawSwitchWhileLoading(view, screen: screen, time: time) {
                clear(view)
            }
            return
        }
        // `spritesheetrefreshsync`: the engine sleeps after a frame (see `paceSpriteSync`); here a display-link tick
        // before the end of that sleep is skipped. 2 ms of slack absorbs display-link jitter.
        // While the link runs at display rate the `fps` cap is applied the same way.
        if slot.spriteSync || fullRate, switches[screen] == nil, time < slot.nextFrameAt - 0.002 {
            // A composite display still needs its region frames composed; they keep their last frame.
            return
        }
        let frameStart = CACurrentMediaTime()

        // Pause rules are per monitor: a region follows its display's bit (split records copy the monitor index, +0x51).
        let paused = state.isPaused(displayIndex: displayIndex(physical))
        let general = state.generalValues(of: id, display: key)
        scene.applyGeneralProperties(general)
        scene.audioProcessing = (general["audioprocessing"] as? Bool) ?? true

        // Scene wallpaper loop 0x140110c95–0x14011151f: dt is clamped to [0.0001, 0.25], the time scale fades toward the
        // paused state, and the scene step is clamp(rate · speed · dt, 0.0001, 0.25) (rate = the per-wallpaper `rate`
        // setting: `Wallpaper_ApplySettings` 0x140115280 stores W+0x190 = max(rate.value / 100, 0.1), default 100 → 1).
        // Fully paused, the engine stops stepping and sleeps 250 ms per loop.
        let raw = slot.lastHostTime.map { Float(time - $0) } ?? 0
        let dt = min(max(raw, 0.0001), 0.25)
        slot.lastHostTime = time
        slot.speed = Self.fade(slot.speed, toward: paused ? 0 : 1, dt: dt)
        slot.volumeFade = Self.fade(slot.volumeFade, toward: state.isMuted ? 0 : 1, dt: dt)
        // The renderer's master volume is the wallpaper `volume` / 100 × the fade (0x14011533f–0x140115361); sound
        // objects square their own volume on top (Sound_Update 0x1401f5991). Only the first display or region showing a
        // wallpaper plays its sound.
        let soundOwner = soundOwner(id) == screen
        let wallpaperVolume = Float(Self.number(general["volume"]) ?? 50) / 100
        let gain = wallpaperVolume * slot.volumeFade * Float(state.volume)
        scene.setSound(enabled: soundOwner, volume: gain, paused: paused)
        let rateValue = Float(Self.number(general["rate"]) ?? 100)
        let rate = max(rateValue / 100, 0.1)
        if item.type == "video", soundOwner {
            if slot.videoAudio == nil { slot.videoAudio = VideoAudio(project: item.directory) }
            // VideoWallpaper (0x1400ffdb5–0x1400ffe77): volume and rate are value / 100 (no 0.1 floor for the rate).
            slot.videoAudio?.sync(clock: slot.clock, rate: rateValue / 100, volume: gain, paused: paused || slot.speed <= 0)
        } else if slot.videoAudio != nil {
            slot.videoAudio = nil
        }
        // Fully paused: no new frame. A switch overlay still animates over the still scene (the engine draws it on its
        // own thread, whatever the wallpaper's pause state).
        if paused && slot.speed <= 0 && slot.hasFrame && switches[screen] == nil {
            slots[screen] = slot
            return
        }
        if slot.hasFrame { slot.clock += Double(min(max(rate * slot.speed * dt, 0.0001), 0.25)) }
        if slot.videoDuration > 0 {
            let loops = Int(slot.clock / slot.videoDuration)
            if loops > slot.videoLoops {
                slot.videoLoops = loops
                DispatchQueue.main.async { [state] in state.playlists?.videoEnded(display: key) }
            }
        }
        scene.resources.timeScale = rate * slot.speed // C+0x154 (docs/re/09 §3)
        slot.hasFrame = true
        slots[screen] = slot
        defer { paceSpriteSync(scene, screen: screen, time: time, frameStart: frameStart, rate: rate) }

        if !region { configureOutput(view, edr: scene.wantsEDROutput) }
        if let frameInst { sharedEDR[frameInst.key] = scene.wantsEDROutput }
        if scene.wantsEDROutput {
            scene.edrHeadroom = Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        }
        scene.pointerDown = desktopPointer.down
        if let frameInst {
            let size = frameSize(output, view)
            // A region's frame is in its scene's own output format; the display converts when it composes.
            let format: MTLPixelFormat = region ? (scene.wantsEDROutput ? .rgba16Float : .bgra8Unorm) : view.colorPixelFormat
            guard let target = compositor.target(frameInst.key, size: size, format: format),
                  let cb = scene.render(into: target, time: slot.clock, outputSize: size, pointer: compositor.pointer(frameInst))
            else { return }
            // Stretch / clone / a region: one wallpaper window, so one overlay over the whole frame (its client size is
            // the overlay size); every display shows its part of it.
            if var sw = switches[screen] {
                sw.transition?.start(at: time)
                switches[screen] = sw
                if let tr = sw.transition, tr.width == target.width, tr.height == target.height {
                    tr.encode(over: target, commandBuffer: cb, time: time)
                    if tr.isFinished(at: time) { endSwitch(screen) }
                } else {
                    endSwitch(screen)
                }
            }
            if case .shared(_, let tile) = output { compositor.present(view, tile: tile, commandBuffer: cb) }
            cb.commit()
            return
        }
        guard let drawable = view.currentDrawable else { return }
        if var sw = switches[screen] {
            // The new wallpaper is ready: the transition starts now (`Transition_StartTick` 0x14006a030); a "no flicker"
            // hold (-2) ends with a cut.
            sw.transition?.start(at: time)
            switches[screen] = sw
            guard let cb = scene.render(into: drawable.texture, time: slot.clock, outputSize: view.drawableSize, pointer: pointer(in: view))
            else { return }
            if let tr = sw.transition {
                tr.encode(over: drawable.texture, commandBuffer: cb, time: time)
                if tr.isFinished(at: time) { endSwitch(screen) } // removed after the frame drawn at progress ≥ 1
            } else {
                endSwitch(screen)
            }
            cb.present(drawable)
            cb.commit()
            return
        }
        scene.render(to: drawable, time: slot.clock, outputSize: view.drawableSize, pointer: pointer(in: view))
    }

    /// The pause / mute fades of the scene loop (0x14011137f–0x14011144d): `cur += (target − cur) · min(6·dt, 1)`, snapping
    /// to the target within 0.01.
    static func fade(_ value: Float, toward target: Float, dt: Float) -> Float {
        abs(value - target) < 0.01 ? target : value + (target - value) * min(dt * 6, 1)
    }

    /// Live object counts, for the headless tests (leaks over many switches).
    var debugCounts: [String: Int] {
        ["slots": slots.count, "loading": loading.count, "switches": switches.count, "webSlots": webSlots.count,
         "overlays": overlayViews.count, "pendingWeb": pendingWeb.count, "retiringWeb": retiringWeb.count,
         "sharedFrame": compositor.frameKeys.count]
    }

    /// What a split region (or a group drawn in a region) of a display shows, for the headless tests.
    func debugRegion(_ screen: CGDirectDisplayID, _ key: String) -> (id: String, clock: Double)? {
        regionSlotIDs["\(screen)|\(key)"].flatMap(debugShown)
    }

    /// The switch on a display's region, for the headless tests.
    func debugRegionSwitch(_ screen: CGDirectDisplayID, _ key: String) -> (kind: String, effect: Int?, started: Bool)? {
        regionSlotIDs["\(screen)|\(key)"].flatMap(debugSwitch)
    }

    /// Region slots and web views by display (headless tests): the region keys and the web views' frames.
    func debugRegions(_ screen: CGDirectDisplayID) -> [String] {
        regionSlotIDs.filter { slotPhysical[$0.value] == screen }.keys.map { String($0.split(separator: "|", maxSplits: 1).last ?? "") }.sorted()
    }

    /// What a display shows (a loaded scene's or web page's id) and its playback clock, for the headless tests.
    func debugShown(_ screen: CGDirectDisplayID) -> (id: String, clock: Double)? {
        if let s = slots[screen], s.scene != nil { return (s.id, s.clock) }
        if let w = webSlots[screen] { return (w.id, 0) }
        return nil
    }

    /// The switch on a display, for the headless tests: kind ("transition", "noFlicker", "frozen") and effect.
    func debugSwitch(_ screen: CGDirectDisplayID) -> (kind: String, effect: Int?, started: Bool)? {
        guard let sw = switches[screen] else { return nil }
        return ("\(sw.kind)", sw.transition?.effect, sw.transition?.startTime != nil)
    }

    /// Host loop after Present (0x140113510–0x1401136a1): with `spritesheetrefreshsync` (W+0x1b8 bit 2) it sleeps
    /// `Sleep((int)(min(remaining / rate, 0.25) · 1000))` ms, remaining = what is left of the first image layer's current
    /// sprite frame (`SceneRenderer.spriteSheetRefreshDelay`), rate = W+0x190 (divided only when > 0.001). The `fps` cap
    /// then reads QueryPerformanceCounter after that sleep (0x140113608), so the frame period is max(fps period, render
    /// time + sprite sleep). photon2 records the earliest start of the next frame; while any scene uses the flag the
    /// display link runs at display rate (`fullRateChanged`) and the `fps` period is enforced here instead.
    private func paceSpriteSync(_ scene: SceneRenderer, screen: CGDirectDisplayID, time: Double, frameStart: Double, rate: Float) {
        guard slots[screen]?.scene === scene else { return }
        let fpsNext = state.fps > 0 ? time + 1 / Double(state.fps) : 0
        guard let delay = scene.spriteSheetRefreshDelay(rate: rate) else {
            slots[screen]?.spriteSync = false
            slots[screen]?.nextFrameAt = fpsNext
            return
        }
        let sleep = Double(Int(Float(delay) * 1000)) / 1000 // cvttss2si of seconds × 1000 → Sleep(ms)
        let renderEnd = time + (CACurrentMediaTime() - frameStart)
        slots[screen]?.spriteSync = true
        slots[screen]?.nextFrameAt = max(renderEnd + sleep, fpsNext)
    }

    /// Display-rate frames while a transition overlay runs or a scene paces itself (`spritesheetrefreshsync`).
    private(set) var fullRate = false
    private func updateFullRate() {
        let want = switches.values.contains { $0.transition != nil } || slots.values.contains { $0.spriteSync }
        guard want != fullRate else { return }
        fullRate = want
        fullRateChanged?(want)
    }

    // MARK: - Wallpaper switch transitions (`browsetransition`, playlists; docs/re/frame-graph.md §T)

    private struct Switch {
        enum Kind {
            /// An effect (`Transition_Start` 0x140058430): the overlay animates the old frame away.
            case transition
            /// "none (no flicker)" (-2, `Transition_HoldWindow` 0x14005aaf0): a layered window with the old frame
            /// below the wallpaper window, destroyed after 3 s (WM_TIMER 1, 0x1400579ff); it shows until the new
            /// wallpaper draws over it.
            case noFlicker
            /// "none" (-1) between wallpapers of the same type: the engine reuses the wallpaper object (vt+0x20 equal,
            /// 0x14007325c) and its Load (scene vt+8 0x14010df40 → message 0x465 → `Renderer_UnloadScene` 0x14017eb50,
            /// then the synchronous load) frees the old scene without presenting again, so the last presented frame
            /// stays on screen until the new scene presents.
            case frozen
        }
        var kind: Kind
        var transition: WallpaperTransition?
        let snapshot: MTLTexture
        let begun: Double
        /// The new wallpaper is a web page (type 2): `Transition_StartTick` (0x14006a17f) never sees it ready (vt+0x78
        /// 0x1400a36d0 returns false) and starts after 0.5 s instead of 3 s.
        var targetIsWeb = false
    }
    private var switches: [CGDirectDisplayID: Switch] = [:]
    /// Called with true while a transition runs: the engine draws the overlay on its own thread at ~60 fps
    /// (Sleep(15) per frame, 0x14005a790) whatever the wallpaper's `fps` cap.
    var fullRateChanged: ((Bool) -> Void)?

    /// A switch away from a web page waits for the page's frame (web vt+0x60 0x1401194a0 asks the web host for it and
    /// waits up to 300 × 10 ms).
    private struct PendingWeb { let id: String; let requested: Double }
    private var pendingWeb: [CGDirectDisplayID: PendingWeb] = [:]
    /// "none" from one web page to another: the browser is reused, so the old page stays until the new one has loaded.
    private var retiringWeb: [CGDirectDisplayID: (web: WebWallpaper, since: Double)] = [:]
    /// The overlay window over a web wallpaper (the engine's transition child window): a transparent Metal view above
    /// the WKWebView, composited premultiplied by the window server like DWM composes the overlay swap chain.
    private var overlayViews: [CGDirectDisplayID: MTKView] = [:]

    private func shownContent(_ screen: CGDirectDisplayID) -> (id: String, type: String)? {
        if let s = slots[screen] { return (s.id, state.item(s.id)?.type ?? "scene") }
        if let w = webSlots[screen] { return (w.id, "web") }
        return nil
    }

    /// `Transition_Begin` 0x140068fc0: settings from the playlist that changed the wallpaper or `browsetransition`;
    /// −1 shows nothing; otherwise the old wallpaper's frame is read back (vt+0x60) and the overlay starts with an
    /// effect picked from the settings (or the −2 hold). Then the old wallpaper is replaced (`App_LoadWallpaper`
    /// 0x140072a70): a wallpaper of another type is destroyed at once (vt+0x18, 0x140073402), one of the same type
    /// loads the new file itself.
    private func beginSwitch(to item: WallpaperItem, display key: String, screen: CGDirectDisplayID, view: MTKView,
                             size: CGSize, time: Double) {
        let settings = state.takeTransition(display: key)
        let newType = item.type
        if let old = slots[screen], old.id != item.id {
            let oldType = state.item(old.id)?.type ?? "scene"
            defer { slots[screen] = nil }
            guard old.hasFrame, let scene = old.scene else { return }
            if settings.mode == -1 {
                // Same type: the old frame stays frozen until the new one presents; another type: gone at once.
                if oldType == newType, let snap = captureScene(scene, clock: old.clock, size: size) {
                    switches[screen] = Switch(kind: .frozen, transition: nil, snapshot: snap, begun: time)
                }
                return
            }
            guard let snap = captureScene(scene, clock: old.clock, size: size) else { return }
            startSwitch(settings, snapshot: snap, screen: screen, time: time, targetIsWeb: newType == "web")
        } else if let w = webSlots[screen], w.id != item.id {
            if settings.mode == -1 {
                if newType == "web" {
                    webSlots[screen] = nil
                    retireOldWeb(screen, force: true)
                    retiringWeb[screen] = (w.web, time)
                } else {
                    removeWeb(screen)
                }
                return
            }
            pendingWeb[screen] = PendingWeb(id: item.id, requested: time)
            snapshotWeb(w.web, size: size) { [weak self] tex in
                guard let self, self.pendingWeb[screen]?.id == item.id else { return }
                self.pendingWeb[screen] = nil
                self.removeWeb(screen)
                if let tex {
                    self.startSwitch(settings, snapshot: tex, screen: screen, time: CACurrentMediaTime(), targetIsWeb: newType == "web")
                }
            }
        }
    }

    private func startSwitch(_ settings: TransitionSettings, snapshot: MTLTexture, screen: CGDirectDisplayID, time: Double,
                             targetIsWeb: Bool) {
        var transition: WallpaperTransition?
        if let effect = settings.pickEffect() {
            do {
                transition = try WallpaperTransition(device: device, engineAssets: state.engineAssets, effect: effect,
                                                     timeMs: settings.timeMs, snapshot: snapshot, commandQueue: queue)
            } catch {
                NSLog("photon: transition %d failed: %@", effect, "\(error)")
                return
            }
        }
        // The overlay covers the display until the new wallpaper is ready.
        switches[screen] = Switch(kind: transition == nil ? .noFlicker : .transition, transition: transition, snapshot: snapshot,
                                  begun: time, targetIsWeb: targetIsWeb)
        if transition != nil { updateFullRate() }
    }

    /// The old scene's frame as the engine reads it back: rendered at the output size in the output's format (fp16
    /// for display HDR), then resolved to opaque BGRA8 (`R_ReadBackbuffer` 0x14009b7b0: passthroughlinear for an fp16
    /// back buffer, alpha forced to 0xff).
    private func captureScene(_ scene: SceneRenderer, clock: Double, size: CGSize) -> MTLTexture? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let edr = scene.wantsEDROutput
        func tex(_ f: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let frame = tex(edr ? .rgba16Float : .bgra8Unorm), let snap = tex(.bgra8Unorm),
              let cb = scene.render(into: frame, time: clock, outputSize: size, pointer: nil) else { return nil }
        WallpaperTransition.resolveSnapshot(frame, into: snap, hdrScale: 1, commandBuffer: cb)
        cb.commit()
        return snap
    }

    /// The web page's current frame (`WKWebView.takeSnapshot`, the counterpart of the web host's frame message 0x16),
    /// at the output's pixel size.
    private func snapshotWeb(_ web: WebWallpaper, size: CGSize, done: @escaping (MTLTexture?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        web.webView.takeSnapshot(with: config) { [device] image, _ in
            let w = Int(size.width), h = Int(size.height)
            guard let image, w > 0, h > 0, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { done(nil); return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { done(nil); return }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            guard let tex = device.makeTexture(descriptor: d) else { done(nil); return }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
            done(tex)
        }
    }

    private func endSwitch(_ screen: CGDirectDisplayID) {
        switches[screen] = nil
        removeOverlay(screen)
        updateFullRate()
    }

    private func dropWebSwitchState(_ screen: CGDirectDisplayID) {
        pendingWeb[screen] = nil
        retireOldWeb(screen, force: true)
        removeOverlay(screen)
    }

    /// While the new wallpaper loads: the held / frozen frame, or the overlay at progress 0 over black. A scene that is
    /// not ready after 3 s starts the transition anyway (0x14006a17f) and ends a −2 hold; a frozen frame stays until the
    /// new scene presents.
    private func drawSwitchWhileLoading(_ view: MTKView, screen: CGDirectDisplayID, time: Double) -> Bool {
        guard let sw = switchWhileLoading(screen, time: time) else { return false }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return true }
        encodeLoading(sw, screen: screen, target: drawable.texture, pass: pass, commandBuffer: cb, time: time)
        cb.present(drawable)
        cb.commit()
        return true
    }

    /// Stretch / clone / a region: the same into the instance's frame, which the displays then show.
    private func drawSwitchWhileLoadingFrame(_ view: MTKView, screen: CGDirectDisplayID, output: Output, time: Double) -> Bool {
        guard let sw = switchWhileLoading(screen, time: time), let inst = output.instance else { return false }
        let size = frameSize(output, view)
        let format = output.isRegion ? (compositor.frameFormat(inst.key) ?? .bgra8Unorm) : view.colorPixelFormat
        guard let target = compositor.target(inst.key, size: size, format: format), let cb = queue.makeCommandBuffer()
        else { return true }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        encodeLoading(sw, screen: screen, target: target, pass: pass, commandBuffer: cb, time: time)
        if case .shared(_, let tile) = output { compositor.present(view, tile: tile, commandBuffer: cb) }
        cb.commit()
        return true
    }

    private func switchWhileLoading(_ screen: CGDirectDisplayID, time: Double) -> Switch? {
        guard var sw = switches[screen] else { return nil }
        if sw.kind != .frozen, time - sw.begun >= 3 {
            if sw.transition == nil { endSwitch(screen); return nil }
            sw.transition?.start(at: time)
            switches[screen] = sw
        }
        return sw
    }

    private func encodeLoading(_ sw: Switch, screen: CGDirectDisplayID, target: MTLTexture, pass: MTLRenderPassDescriptor,
                               commandBuffer cb: MTLCommandBuffer, time: Double) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let tr = sw.transition {
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            if tr.width == target.width, tr.height == target.height {
                tr.encode(over: target, commandBuffer: cb, time: time)
                if tr.isFinished(at: time) { endSwitch(screen) }
            } else {
                endSwitch(screen) // the output was resized: drop the overlay
            }
        } else if sw.snapshot.width == target.width, sw.snapshot.height == target.height {
            // The held frame (BGRA8, sRGB-encoded) through the composite: over an fp16 EDR target it is decoded first.
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            WallpaperTransition.drawHeld(sw.snapshot, over: target, commandBuffer: cb)
        } else {
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    /// A web page is the new wallpaper: the overlay (or the held frame) is drawn in a transparent view above the page.
    /// The page never reports ready, so a transition starts 0.5 s after the switch (0x14006a184). The −2 hold window
    /// sits below the wallpaper window (its WM_TIMER 0 keeps it at HWND_BOTTOM, 0x140057a0a) and is destroyed by timer 1
    /// after 3 s (0x1400579ff): here the held frame stays until the new page has loaded, at most 3 s.
    private func drawWebSwitch(_ view: MTKView, screen: CGDirectDisplayID, time: Double) {
        retireOldWeb(screen, force: false)
        guard var sw = switches[screen] else { removeOverlay(screen); return }
        if sw.kind == .frozen { endSwitch(screen); return } // a frozen scene frame only between scenes
        if sw.transition == nil {
            let loaded = webSlots[screen].map { !$0.web.webView.isLoading } ?? false
            if loaded || time - sw.begun >= 3 { endSwitch(screen); return }
        } else if time - sw.begun >= 0.5 {
            sw.transition?.start(at: time)
            switches[screen] = sw
        }
        let overlay = overlayView(over: view, screen: screen)
        guard let drawable = overlay.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        if let tr = sw.transition {
            if tr.width == drawable.texture.width, tr.height == drawable.texture.height {
                tr.encode(over: drawable.texture, commandBuffer: cb, time: time)
                if tr.isFinished(at: time) { DispatchQueue.main.async { [weak self] in self?.endSwitch(screen) } }
            } else {
                DispatchQueue.main.async { [weak self] in self?.endSwitch(screen) }
            }
        } else if sw.snapshot.width == drawable.texture.width, sw.snapshot.height == drawable.texture.height {
            WallpaperTransition.drawHeld(sw.snapshot, over: drawable.texture, commandBuffer: cb)
        }
        cb.present(drawable)
        cb.commit()
    }

    private func overlayView(over view: MTKView, screen: CGDirectDisplayID) -> MTKView {
        let overlay: MTKView
        let region = regionFrames[screen]
        if let v = overlayViews[screen], v.superview === view {
            overlay = v
        } else {
            overlay = MTKView(frame: region ?? view.bounds, device: device)
            overlay.colorPixelFormat = .bgra8Unorm
            overlay.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            overlay.isPaused = true
            overlay.enableSetNeedsDisplay = false
            overlay.framebufferOnly = false
            overlay.layer?.isOpaque = false
            overlay.autoresizingMask = region == nil ? [.width, .height] : []
            overlayViews[screen] = overlay
        }
        if view.subviews.last !== overlay { view.addSubview(overlay, positioned: .above, relativeTo: nil) }
        if let region {
            // A region's overlay covers the region, at the display's backing scale.
            let k = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 1
            if overlay.frame != region { overlay.frame = region }
            overlay.drawableSize = CGSize(width: max((region.width * k).rounded(), 2), height: max((region.height * k).rounded(), 2))
        } else {
            overlay.drawableSize = view.drawableSize
        }
        return overlay
    }

    private func removeOverlay(_ screen: CGDirectDisplayID) {
        overlayViews.removeValue(forKey: screen)?.removeFromSuperview()
    }

    /// The previous page of a reused browser goes once the new page has loaded (3 s at most).
    private func retireOldWeb(_ screen: CGDirectDisplayID, force: Bool) {
        guard let r = retiringWeb[screen] else { return }
        let newLoaded = webSlots[screen].map { !$0.web.webView.isLoading } ?? false
        if force || newLoaded || CACurrentMediaTime() - r.since > 3 {
            r.web.webView.removeFromSuperview()
            retiringWeb[screen] = nil
        } else if let newView = webSlots[screen]?.web.webView, let parent = newView.superview,
                  parent.subviews.firstIndex(of: r.web.webView).map({ $0 < (parent.subviews.firstIndex(of: newView) ?? 0) }) == true {
            parent.addSubview(r.web.webView, positioned: .above, relativeTo: newView)
        }
    }

    // MARK: - Web wallpapers (docs/re/04 §1.2): a WKWebView over the display's Metal view.

    private struct WebSlot {
        let id: String
        let revision: Int
        let web: WebWallpaper
        var lastAudio: Double = 0
        /// `general.supportsaudioprocessing` of the project (0x14010d100).
        let audioAllowed: Bool
    }
    private var webSlots: [CGDirectDisplayID: WebSlot] = [:]

    private func drawWeb(_ item: WallpaperItem, in view: MTKView, screen: CGDirectDisplayID, time: TimeInterval) {
        let revision = state.revision(item.id)
        if webSlots[screen].map({ $0.id != item.id || $0.revision != revision }) ?? true {
            removeWeb(screen)
            let project = SceneRenderer.readProject(item.directory)
            let props = WebWallpaper.typedProperties(project: project, overrides: state.effectiveOverrides(item.id, display: drawKey(screen)))
            do {
                // A split region's page covers its region of the display.
                let web = try WebWallpaper(directory: item.directory, file: (project["file"] as? String) ?? "", properties: props,
                                           engineInstall: state.engineAssets.deletingLastPathComponent(), frame: regionFrames[screen] ?? view.bounds)
                web.generalSettings = state.generalSettingsForWeb
                web.webView.autoresizingMask = regionFrames[screen] == nil ? [.width, .height] : []
                view.addSubview(web.webView)
                web.load()
                state.errors[item.id] = nil
                let supports = ((project["general"] as? [String: Any])?["supportsaudioprocessing"] as? Bool) ?? false
                webSlots[screen] = WebSlot(id: item.id, revision: revision, web: web, audioAllowed: supports)
            } catch {
                NSLog("photon: failed to load %@: %@", item.directory.path, "\(error)")
                state.errors[item.id] = "\(error)"
                return
            }
        }
        guard var slot = webSlots[screen] else { return }
        if let f = regionFrames[screen], slot.web.webView.frame != f { slot.web.webView.frame = f }
        slot.web.setPaused(state.isPaused(displayIndex: displayIndex(screen)))
        slot.web.setMuted(state.isMuted)
        // CEFWallpaper audio thread (0x14011af50): every Sleep(33) it fetches the analyzer's raw 128 floats
        // (Audio_GetSpectrum, no per-frame smoothing) and sends them as message 8 (0x200 bytes), but only once the page
        // registered a listener (`AudioContextRegistered`) and the project allows it (+0x439, 0x140119640:
        // general.supportsaudioprocessing and the `audioprocessing` property, true when absent).
        let general = state.generalValues(of: item.id, display: drawKey(screen))
        slot.web.applyWallpaperGeneral(general) // wec_* CSS filter and flip (docs/re/09 §6.2)
        if slot.web.audioRequested, slot.audioAllowed, (general["audioprocessing"] as? Bool) ?? true {
            if !AudioSystem.shared.isRunning, SceneRenderer.audioCaptureEnabled { AudioSystem.shared.start() }
            if time - slot.lastAudio >= 0.033 {
                slot.web.sendAudio(AudioSystem.shared.latestSpectrum())
                slot.lastAudio = time
            }
        }
        webSlots[screen] = slot
    }

    private func removeWeb(_ screen: CGDirectDisplayID) {
        guard let slot = webSlots.removeValue(forKey: screen) else { return }
        slot.web.webView.removeFromSuperview()
    }

    /// Scenes load on one serial queue (first loads compile shaders, which takes seconds); the main thread
    /// keeps drawing. Loads are serial because loading sets the process-wide `UserProperties.current`.
    private let loadQueue = DispatchQueue(label: "photon.sceneload", qos: .userInitiated)
    private var loading: [CGDirectDisplayID: (id: String, revision: Int)] = [:]

    private func startLoad(_ item: WallpaperItem, revision: Int, for screen: CGDirectDisplayID) {
        if let l = loading[screen], l.id == item.id, l.revision == revision { return }
        loading[screen] = (item.id, revision)
        let overrides = state.effectiveOverrides(item.id, display: drawKey(screen))
        let device = device, assets = state.engineAssets
        loadQueue.async { [weak self] in
            let result = Result { try SceneRenderer(device: device, wallpaperDirectory: item.directory, engineAssets: assets,
                                                    propertyOverrides: overrides) }
            let videoDuration = item.type == "video" ? Self.videoDuration(item.directory) : 0
            DispatchQueue.main.async {
                guard let self, let l = self.loading[screen], l.id == item.id, l.revision == revision else { return }
                self.loading[screen] = nil
                switch result {
                case .success(let scene):
                    self.state.errors[item.id] = nil
                    var slot = Slot(id: item.id, revision: revision, scene: scene)
                    slot.videoDuration = videoDuration
                    self.slots[screen] = slot
                case .failure(let error):
                    NSLog("photon: failed to load %@: %@", item.directory.path, "\(error)")
                    self.state.errors[item.id] = "\(error)"
                    self.slots[screen] = Slot(id: item.id, revision: revision, scene: nil)
                }
            }
        }
    }

    /// Display HDR (`postprocessing` = displayhdr on an HDR scene): the engine presents through an fp16 scRGB swap
    /// chain (docs/re/04 §6.7); here that is an extended-linear-sRGB fp16 EDR drawable. Everything else uses 8-bit sRGB.
    private func configureOutput(_ view: MTKView, edr: Bool) {
        let format: MTLPixelFormat = edr ? .rgba16Float : .bgra8Unorm
        guard view.colorPixelFormat != format else { return }
        view.colorPixelFormat = format
        view.colorspace = CGColorSpace(name: edr ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = edr
    }

    /// A "stop" rule: free every scene and web view (the engine destroys its wallpapers, 0x140073ac0).
    func releaseAll() {
        compositor.releaseAll()
        slots.removeAll()
        switches.removeAll()
        updateFullRate()
        loading.removeAll()
        for screen in Array(webSlots.keys) { removeWeb(screen) }
        for screen in Array(Set(overlayViews.keys).union(retiringWeb.keys).union(pendingWeb.keys)) { dropWebSwitchState(screen) }
    }

    /// Duration of a video wallpaper's file (project.json `file`).
    static func videoDuration(_ directory: URL) -> Double {
        let project = SceneRenderer.readProject(directory)
        guard let file = project["file"] as? String else { return 0 }
        let d = CMTimeGetSeconds(AVURLAsset(url: directory.appendingPathComponent(file)).duration)
        return d.isFinite && d > 0 ? d : 0
    }

    static func number(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private func clear(_ view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func drawKey(_ screen: CGDirectDisplayID) -> String { drawKeys[screen] ?? DisplayInfo.key(for: screen) }

    /// Cursor position in the window as 0–1 UV with y down (the engine divides client pixels by size).
    func pointer(in view: MTKView) -> CGPoint? {
        guard let window = view.window else { return nil }
        let p = NSEvent.mouseLocation, f = window.frame
        guard f.width > 0, f.height > 0 else { return nil }
        return CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
    }
}

/// Mouse buttons on the desktop. The windows ignore the mouse (so Finder keeps the icons), so buttons are
/// observed globally and only count while the desktop (Finder) is frontmost, i.e. the click hit the desktop.
final class DesktopPointer {
    private(set) var down = false
    private var monitors: [Any] = []

    init() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            let onDesktop = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
            switch e.type {
            case .leftMouseDown: self?.down = onDesktop
            case .leftMouseUp: self?.down = false
            default: break
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: handler) { monitors.append(m) }
    }
}
