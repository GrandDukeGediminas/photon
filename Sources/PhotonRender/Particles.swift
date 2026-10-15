import Foundation
import Metal
import PhotonCore
import simd

/// A particle system scene object (docs/re/05 §2, §9). The simulation lives in `ParticleInstance`
/// (ParticleSim.swift / ParticleOps.swift), drawing in ParticleRender.swift.
final class ParticleSystemObject: SceneObject {
    /// Always set: `Scene_CreateObject` 0x14018ff60 ORs 0x100 into obj+0x120 for every particle object (0x14019027b) before
    /// `SceneParticle::load` 0x14022af30, which only clears 0x90 and ORs ParticleDef+4 (0 or 0x80 = json `flags & 4`)
    /// back in (0x14022b418–0x14022b43e). docs/re/05 §1.
    override var isTransparent: Bool { true }
    let resources: SceneResources
    weak var scene: SceneRenderer?
    /// InstanceOverride (obj+0x778), shared with every child system.
    var override: ParticleOverride
    var system: ParticleInstance?
    private var built = false
    private var wasActive = true
    private var firstUpdate = true
    private let fallbackFrame = FrameState()
    /// obj+0x770: layer time, advanced by the rate-scaled dt while active (remapvalue input `layertime`).
    var layerTime: Float = 0
    /// layerimage sampling records, shared per (layer id, mask path) (ctx+0x1b00 list in the engine).
    private var layerImages: [String: PLayerImage] = [:]

    /// `(scene+0x118 >> 10) & 1`: set when the scene has `general.orthogonalprojection` (2D defaults).
    var ortho: Bool { scene?.general["orthogonalprojection"] is [String: Any] }
    /// Renderer HDR flag (`C+0x118 & 0x2000` = `R+0x128`), not the scene's general.hdr (see SceneRenderer.hdr).
    var hdr: Bool { scene?.hdr ?? false }
    /// R+0x120, the fov of the perspective push 0x1401e5b60. The push only changes ortho projections, where the
    /// engine's S+0x148 is `perspectiveoverridefov` (default 95), not `fov` (0x140189278–0x1401892c4).
    var fov: Float {
        guard let s = scene else { return 95 }
        return s.isOrtho ? s.orthoPerspectiveFOV : min(max(EngineValue.float(s.general["fov"], default: 50), 0.1), 179.9)
    }
    var sceneSize: SIMD2<Float> { scene?.orthoSize ?? SIMD2(1920, 1080) }
    /// C+0x150: the previous frame's dt (07 §3.1; read by inheritcontrolpointvelocity), C+0x14c = this frame's.
    private(set) var prevFrameTime: Float = 1.0 / 30
    /// C+0x144: the renderer's frame counter (07 §3.1), incremented once per frame (boids amortisation).
    private(set) var frameCounter = 0
    private var curFrameTime: Float = 0
    /// 2×16 audio bands. There is no audio input yet, so audio-driven emitters see silence.
    var audioBands: [Float] = []
    var frameState: FrameState { scene?.frame ?? fallbackFrame }

    init(json: [String: Any], id: Int, resources: SceneResources) {
        self.resources = resources
        override = ParticleOverride(json: unwrapUserValue(json["instanceoverride"]))
        super.init(json: json, id: id)
    }

    private func build() {
        built = true
        guard let path = json["particle"] as? String,
              let def = ParticleDef.load(path, fs: resources.fs, ortho: ortho) else { return }
        let inst = ParticleInstance(def: def, host: self, parent: nil, childDef: nil)
        inst.linkDependencies()
        inst.mat = world
        inst.updateTop()
        inst.resolveControlPoints()
        inst.start()
        system = inst
    }

    override func update(_ dt: Float) {
        super.update(dt)
        let ft = frameState.frameTime
        frameCounter &+= 1
        for img in layerImages.values { img.frameTick() }
        prevFrameTime = curFrameTime > 0 ? curFrameTime : ft
        curFrameTime = ft
        if !built { build() }
        guard let sys = system else { return }
        let active = effectiveVisible
        if !active {
            if wasActive { sys.clearAll() }
            wasActive = false
            return
        }
        wasActive = true
        // Script pause() only stops automatic emission (emitAndInit); the system keeps simulating.
        let step = dt * max(0.01, override.rate)
        layerTime += step
        sys.mat = world
        if firstUpdate {
            firstUpdate = false
            // Offline renders (photon-tool) start at a late scene time with only a few frames; simulate the
            // missing time at 30 Hz so the system looks as it would after running live. Live playback starts
            // at time ≈ 0, where this does nothing.
            let behind = min(frameState.time - dt, 120)
            if behind > 0.5 {
                var t: Float = 0
                while t < behind {
                    sys.update(min(1 / 30, behind - t) * max(0.01, override.rate), active: true)
                    t += 1 / 30
                }
            }
        }
        sys.update(step, active: true)
    }

    /// obj+0x93d bit 0: the frame buffer was copied for a refracting system during this render (0x140236610 clears it).
    var frameBufferCopied = false

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        frameBufferCopied = false
        guard effectiveVisible, let sys = system else { return }
        for img in layerImages.values { img.encodeCapture(ctx) }
        sys.render(ctx, frame, scene)
    }

    /// The shared sampling record for a layer and mask; the layer becomes a dependency (dedicated composite).
    func layerImage(_ layer: ImageLayer, mask: String) -> PLayerImage {
        let key = "\(layer.id)|\(mask)"
        if let r = layerImages[key] { return r }
        layer.markDependency()
        let r = PLayerImage(layer: layer, mask: mask.isEmpty ? nil : resources.textures.texture(named: mask))
        layerImages[key] = r
        return r
    }

    // MARK: - SceneScript (docs/re/05 §10, registration 0x14024cb00)

    /// `play()` 0x14024c5b0: clear the paused bit; when nothing is alive or emitting, re-enable the emitters (0x14022f5b0).
    func scriptPlay() {
        guard let sys = system else { return }
        sys.paused = false
        if !sys.staticChildren.contains(where: { $0.isAlive }) && !sys.eventChildren.contains(where: { $0.active.contains { $0.isAlive } })
            && sys.activeEmitters == 0 && sys.alive == 0 {
            sys.enableEmittersRecursive()
        }
    }

    /// `pause()` 0x14024c670: sets the paused bit, which stops automatic emission only.
    func scriptPause() { system?.paused = true }

    /// `stop()` 0x14024c680: disable every emitter (children too), layer time 0, reset time and emitters, clear
    /// the particles and the children's, drop the event children.
    func scriptStop() {
        layerTime = 0
        guard let sys = system else { return }
        sys.disableEmitters()
        sys.resetEmitters()
        sys.clearParticles()
    }

    /// `emitParticles(n)` 0x14024cac0: emitAndInit(inst, 0, n) on the system right away; 0 means 1, negative nothing.
    func scriptEmit(_ n: Int) {
        guard n >= 0, let sys = system else { return }
        let before = PDump.want("emit\(sys.def.path)") ? sys.alive : nil
        sys.emitAndInit(0, extra: n == 0 ? 1 : n)
        if let before { PDump.write(["kind": "emit", "def": sys.def.path, "n": n, "before": before, "after": sys.alive,
                                     "max": sys.maxCount, "emitters": sys.emitters.count, "paused": sys.paused]) }
    }
}
