import Foundation
import PhotonCore
import simd

/// Instance overrides (docs/re/05 §5.1), shared by a scene object and all of its child systems.
struct ParticleOverride {
    var alpha: Float = 1, size: Float = 1, count: Float = 1, speed: Float = 1, lifetime: Float = 1, rate: Float = 1
    var brightness: Float = 1
    var colorn: SIMD3<Float>? = nil
    var cp = [SIMD3<Float>?](repeating: nil, count: 8)
    var cpAngle = [SIMD3<Float>?](repeating: nil, count: 8)

    init() {}

    init(json: Any?) {
        guard let o = json as? [String: Any] else { return }
        let j = PJ(o)
        alpha = j.f("alpha", 1); size = j.f("size", 1); count = j.f("count", 1); speed = j.f("speed", 1)
        lifetime = j.f("lifetime", 1); rate = max(0.01, j.f("rate", 1)); brightness = j.f("brightness", 1)
        if j.has("colorn") { colorn = j.v3("colorn", SIMD3(1, 1, 1)) }
        // Legacy `color` (0–255) becomes colorn and is removed (cap:14022b44b).
        if j.has("color") { colorn = j.v3("color", SIMD3(255, 255, 255)) / 255 }
        for i in 0..<8 {
            if j.has("controlpoint\(i)") { cp[i] = j.v3("controlpoint\(i)", .zero) }
            if j.has("controlpointangle\(i)") { cpAngle[i] = j.v3("controlpointangle\(i)", .zero) }
        }
    }
}

/// Values the override-binding records (§5.3) multiply into op constants, resolved per instance.
struct PScales {
    var count: Float = 1, speed: Float = 1, lifetime: Float = 1, size: Float = 1, rate: Float = 1
    var colorActive = false
    var hsvShift = SIMD3<Float>(0, 0, 0)
    var ovHSV = SIMD3<Float>(0, 0, 0)

    init() {}

    init(_ ov: ParticleOverride, def: ParticleDef, colorActive: Bool) {
        let f = def.flags
        count = f & ParticleDef.Flags.noCountOverride != 0 ? 1 : ov.count
        speed = f & ParticleDef.Flags.noSpeedOverride != 0 ? 1 : ov.speed
        lifetime = f & ParticleDef.Flags.noLifetimeOverride != 0 ? 1 : ov.lifetime
        size = f & ParticleDef.Flags.noSizeOverride != 0 ? 1 : ov.size
        rate = ov.rate
        self.colorActive = colorActive
        if colorActive, let c = ov.colorn {
            ovHSV = HSV.fromRGB(c)
            hsvShift = ovHSV - HSV.fromRGB(def.colorn)
        }
    }

    /// Record types 11/12: shift a colour's HSV by (ovHSV − refHSV), hue wrapped, s/v clamped.
    func shift(_ c: SIMD3<Float>) -> SIMD3<Float> {
        guard colorActive else { return c }
        var h = HSV.fromRGB(c) + hsvShift
        h.x -= floorf(h.x)
        h.y = clamp01(h.y); h.z = clamp01(h.z)
        return HSV.toRGB(h)
    }
}

/// Runtime control point (0xd0): world, previous world, local (§6.2).
struct PControlPoint {
    var world = matrix_identity_float4x4
    var prev = matrix_identity_float4x4
    var local = matrix_identity_float4x4
    var flags = 0
    var parent = 0
}

/// Emitter record runtime state (payload fields of §3.1).
struct PEmitterState {
    let def: PEmitterDef
    var rate: Float = 0, maxPerPeriod = 0, speedMin: Float = 0, speedMax: Float = 0
    var duration: Float, delay: Float, acc: Float = 0, timer: Float = 0
    var emittedThisPeriod = 0, pending: Int
    var flags: UInt32
    /// layerimage: P+0xa8 previous layer world (identity at parse), P+0x7c re-capture timer, the linked sampling record.
    var prevLayerWorld = matrix_identity_float4x4
    var captureTimer: Float = 0
    var image: PLayerImage?

    init(_ d: PEmitterDef) {
        def = d
        duration = d.duration; delay = d.delay; pending = d.instantaneous; flags = d.flags
    }

    var disabled: Bool { flags & 0x8000_0000 != 0 }
}

/// A particle-system instance (docs/re/05 §3): the SoA particle arrays plus emitters, control points,
/// children and render state.
final class ParticleInstance {
    let def: ParticleDef
    unowned let host: ParticleSystemObject
    weak var parent: ParticleInstance?
    let childDef: PChildDef?
    var depth = 0
    var flags: UInt32

    // SoA arrays (§8). Capacity = maxcount rounded up to 4.
    let maxCount: Int
    let cap: Int
    var age, life, phase, size, size0, rnd: [Float]
    var rot, angVel, pos, vel, prevPos: [SIMD3<Float>]
    var color, color0: [SIMD4<Float>]
    var highWater = 0, alive = 0, deaths = 0

    var emitters: [PEmitterState] = []
    var activeEmitters = 0
    /// inst+0x3f7 bit 0: script `pause()` (event children copy it from their parent). Stops automatic emission only.
    var paused = false
    /// collisionmodel operators' linked scene objects, by operator index (object `dependencies`, type collisionmodel).
    var collisionModels: [Int: SceneObject] = [:]
    /// Frame counter for the collisionmodel amortisation (groups of 4 visited every S-th frame, S = highwater/10000 + 1).
    var modelFrame = 0
    /// mapsequence state (t, step) by initializer index.
    var seqState: [Int: (t: Float, step: Float)] = [:]
    var cps = [PControlPoint](repeating: PControlPoint(), count: 8)
    var cpStart = 8
    var cpDrivenByParent = false
    /// inst+0x3a0: object world matrix (top level) or the child placement matrix.
    var mat = matrix_identity_float4x4
    /// The pushed matrix ("Top", 0x140229760).
    var top = matrix_identity_float4x4
    var tint = SIMD4<Float>(1, 1, 1, 1)
    var scales = PScales()
    var time: Float = 0
    var followIndex = -1

    var keepOrder = false
    var order: [Int] = []
    var born: [Int] = []
    var died: [Int] = []
    var followRefs: [Int: Int] = [:]
    var childMaskOverride: UInt8? = nil

    var staticChildren: [ParticleInstance] = []
    struct EventSlot { let def: PChildDef; var active: [ParticleInstance] = []; var pool: [ParticleInstance] = [] }
    var eventChildren: [EventSlot] = []

    // Ropetrail history (Part 4 §5.4).
    var histSegments = 0
    var hist: [SIMD3<Float>] = []
    var histCount: [UInt16] = []
    var histScroll: [UInt16] = []
    var histTimer: Float = 0
    var histInterval: Float = 1

    // Render state (ParticleRender.swift).
    var renderMaterials: [Material?] = []
    var baseMaterial: Material?

    var worldSpace: Bool { flags & ParticleDef.Flags.worldSpace != 0 }
    var frame: FrameState { host.frameState }

    init(def: ParticleDef, host: ParticleSystemObject, parent: ParticleInstance?, childDef: PChildDef?) {
        self.def = def
        self.host = host
        self.parent = parent
        self.childDef = childDef
        flags = def.flags
        maxCount = def.maxCount
        cap = (def.maxCount + 3) & ~3
        age = [Float](repeating: 0, count: cap); life = age; phase = age; size = age; size0 = age; rnd = age
        rot = [SIMD3<Float>](repeating: .zero, count: cap); angVel = rot; pos = rot; vel = rot; prevPos = rot
        color = [SIMD4<Float>](repeating: .zero, count: cap); color0 = color
        emitters = def.emitters.map { PEmitterState($0) }
        activeEmitters = emitters.count
        for (k, c) in def.controlPoints.enumerated() {
            cps[k].flags = c.flags
            cps[k].parent = c.parent
            cps[k].local.columns.3 = SIMD4(c.offset, 1)
        }
        if let c = childDef, c.flags & 1 != 0 {
            cpDrivenByParent = true
            cpStart = c.cpStart
        }
        // The spawn-order list (+0x218) only matters to the rope fill; deaths are recorded for it (0x140236d27: rope VB).
        keepOrder = def.renderers.contains { $0.kind == .rope }
        for (k, i) in def.initializers.enumerated() {
            switch i {
            case .mapAround, .mapBetween: seqState[k] = (0, 0)
            default: break
            }
        }
        // 0x1401d29ba: every ropetrail renderer overwrites the render state's segments / interval; the history buffers are
        // allocated after the loop (0x1401d32e3), so the last ropetrail renderer wins.
        if let rt = def.renderers.last(where: { $0.kind == .ropeTrail }) {
            histSegments = rt.segments
            histInterval = rt.length / Float(rt.segments)
            hist = [SIMD3<Float>](repeating: .zero, count: cap * histSegments)
            histCount = [UInt16](repeating: 0, count: cap)
            if flags & ParticleDef.Flags.ropeTrailUVScroll != 0 { histScroll = histCount }
        }
        setupRenderers()
        applyOverrides(force: true)
    }

    // MARK: - Overrides (§5.2)

    func applyOverrides(force: Bool) {
        let ov = host.override
        let C = ov.colorn ?? def.colorn
        var colorActive = false
        if C.x >= 0, def.flags & ParticleDef.Flags.noColorOverride == 0 {
            let d = simd_abs(C - def.colorn)
            // 0x14022bdd8: 0x3b674db4 (0.9/255 rounded), `!(thr > |d|)`.
            let thr = Float(bitPattern: 0x3b67_4db4)
            colorActive = !(thr > d.x) || !(thr > d.y) || !(thr > d.z)
        }
        // ctx flag 0x2000 gates brightness; inferred to be the scene's HDR flag.
        let b = (host.hdr && def.flags & ParticleDef.Flags.noColorOverride == 0) ? ov.brightness : 1
        if flags & ParticleDef.Flags.noColor != 0 && colorActive {
            tint = SIMD4(C * b, ov.alpha)
        } else {
            tint = SIMD4(b, b, b, ov.alpha)
        }
        scales = PScales(ov, def: def, colorActive: colorActive)
        for k in emitters.indices {
            let d = emitters[k].def
            emitters[k].rate = d.rate * scales.count
            emitters[k].maxPerPeriod = Int(Float(d.maxPerPeriod) * scales.count)
            emitters[k].speedMin = d.speedMin * scales.speed
            emitters[k].speedMax = d.speedMax * scales.speed
        }
        for (k, i) in def.initializers.enumerated() {
            switch i {
            case .mapAround(let m):
                let c = m.countOverride ? scales.count : 1
                seqState[k] = (seqState[k]?.t ?? 0, 1 / max(m.count * c, 1e-4))
            case .mapBetween(let m):
                let c = m.countOverride ? scales.count : 1
                seqState[k] = (seqState[k]?.t ?? 0, 1 / max(m.count * c - 1, 1e-4))
            default: break
            }
        }
        for i in 0..<8 where cps[i].flags & 0x10005 == 0 {
            if let a = ov.cpAngle[i] {
                let r = particleEulerMatrix(a)
                cps[i].local.columns.0 = SIMD4(r.columns.0, 0)
                cps[i].local.columns.1 = SIMD4(r.columns.1, 0)
                cps[i].local.columns.2 = SIMD4(r.columns.2, 0)
            }
            if let t = ov.cp[i] { cps[i].local.columns.3 = SIMD4(t, 1) }
            // 0x14022c0b6: the override pass also sets the world matrix; the cases the per-frame resolve never rewrites
            // (local system without flags & 2, worldspace system with flags & 2 on CP ≥ 1) keep this copy of local.
            let flag2 = cps[i].flags & 2 != 0
            if (!worldSpace && !flag2) || (worldSpace && flag2 && i != 0) { cps[i].world = cps[i].local }
        }
        // 0x14022c1d0: static children get the same force flag, event children (active and pooled) none; then, when
        // forced, a disabled emitter with rate > 0 is re-enabled by clearing bit 31 only. The active-emitter byte +0x3f4
        // is not incremented here (it is a u8 that the emitter disable path decrements, see `disable`).
        for c in staticChildren { c.applyOverrides(force: force) }
        for s in eventChildren { for c in s.active + s.pool { c.applyOverrides(force: false) } }
        if force {
            for k in emitters.indices where emitters[k].disabled && emitters[k].rate > 0 {
                emitters[k].flags &= ~0x8000_0000
            }
        }
    }

    // MARK: - Lifecycle

    /// `start` 0x14022ebe0: static children, event slots, prewarm.
    func start() {
        if depth < 10 {
            for c in def.children {
                guard let cd = ParticleDef.load(c.name, fs: host.resources.fs, ortho: host.ortho) else { continue }
                if c.kind == .staticChild {
                    let inst = ParticleInstance(def: cd, host: host, parent: self, childDef: c)
                    inst.depth = depth + 1
                    inst.paused = paused
                    inst.linkDependencies()
                    inst.mat = c.transform
                    // The child's own start pushes 0x140229760 (worldspace → mat), unlike the per-frame push 0x140229810.
                    inst.updateTop()
                    inst.start()
                    staticChildren.append(inst)
                } else {
                    eventChildren.append(EventSlot(def: c))
                }
            }
        }
        // 0x14022f231: active emitters = emitter count, control points resolved and their previous matrices set to the
        // current ones before the prewarm (so inheritcontrolpointvelocity sees no motion on the first prewarm step).
        activeEmitters = emitters.count
        resolveControlPoints()
        for i in 0..<8 { cps[i].prev = cps[i].world }
        prewarm()
    }

    func prewarm() {
        guard def.startTime > 0 else { return }
        let step: Float = maxCount < 500 ? 0.05 : 0.2
        childMaskOverride = 0
        var t: Float = 0
        repeat {
            simulate(step, emit: true)
            t += step
        } while def.startTime > t
        childMaskOverride = nil
        // 0x14022f49d: every slot below the high-water mark (live or not) is seeded, then the scroll counters are cleared.
        if histSegments > 0 {
            for i in 0..<highWater {
                for s in 0..<histSegments { hist[i * histSegments + s] = pos[i] }
                histCount[i] = 1
            }
            for i in 0..<min(highWater, histScroll.count) { histScroll[i] = 0 }
        }
    }

    /// `resetEmitters` 0x14022f6c0: time and emitters only; particles are left alone. `+0x3c` (emitted this period)
    /// and `+0x40` (periodic timer) are cleared by one qword store.
    func resetEmitters() {
        time = 0
        for k in emitters.indices {
            emitters[k].duration = emitters[k].def.duration
            emitters[k].delay = emitters[k].def.delay
            emitters[k].pending = emitters[k].def.instantaneous
            emitters[k].acc = 0
            emitters[k].emittedThisPeriod = 0
            emitters[k].timer = 0
        }
        for k in seqState.keys { seqState[k]!.t = 0 }
        for c in staticChildren { c.resetEmitters() }
    }

    func enableEmitters() {
        for k in emitters.indices where emitters[k].disabled {
            emitters[k].flags &= ~0x8000_0000
        }
        activeEmitters = emitters.count
    }

    /// `0x14022f5b0`: re-enable every emitter (active count = emitter count), recursively into the static children.
    func enableEmittersRecursive() {
        enableEmitters()
        for c in staticChildren { c.enableEmittersRecursive() }
    }

    /// Periodic phase-start callback `0x14022f790` (#48): each static child whose ChildDef flags & 2 is reset (recursive
    /// 0x14022f6c0) and re-enabled (recursive 0x14022f5b0); then this instance's mapsequencebetweencontrolpoints counters
    /// with JSON flags & 0x20 restart (mapsequencearound tests a field the parser never writes).
    func periodicPhaseStart() {
        for c in staticChildren where (c.childDef?.flags ?? 0) & 2 != 0 {
            c.resetEmitters()
            c.enableEmittersRecursive()
        }
        for (k, i) in def.initializers.enumerated() {
            if case .mapBetween(let m) = i, m.periodicReset { seqState[k]?.t = 0 }
        }
    }

    func disableEmitters() {
        for k in emitters.indices { emitters[k].flags |= 0x8000_0000 }
        activeEmitters = 0
        for c in staticChildren { c.disableEmitters() }
    }

    /// Particles of this instance and its static children cleared, event children dropped (script stop).
    func clearParticles() {
        for i in 0..<cap { life[i] = 0 }
        alive = 0; highWater = 0
        order.removeAll()
        for c in staticChildren { c.clearParticles() }
        for k in eventChildren.indices { eventChildren[k].active.removeAll(); eventChildren[k].pool.removeAll() }
    }

    /// Visibility-off reset (§9 step 1).
    func clearAll() {
        resetEmitters()
        enableEmitters()
        for i in 0..<cap { life[i] = 0 }
        alive = 0; highWater = 0
        order.removeAll()
        for c in staticChildren { c.clearAll() }
        for k in eventChildren.indices { eventChildren[k].active.removeAll(); eventChildren[k].pool.removeAll() }
    }

    /// `0x14022c310`: alive particles, active emitters (+0x3f4), or any static / active event child alive (recursive).
    /// Unlike the script `isPlaying` (0x14024ca10) it ignores the paused flag.
    var isAlive: Bool {
        activeEmitters > 0 || alive > 0 || staticChildren.contains { $0.isAlive }
            || eventChildren.contains { $0.active.contains { $0.isAlive } }
    }

    var isPlaying: Bool {
        !paused && (activeEmitters > 0 || alive > 0 || staticChildren.contains { $0.isPlaying }
            || eventChildren.contains { !$0.active.isEmpty })
    }

    /// The matrix push `0x140229760`: worldspace → mat, else parentTop·mat (engine-exact product). The root takes the
    /// object world. Static children inside the parent's update use `0x140229810` instead (always parentTop·mat).
    func updateTop() {
        if let p = parent {
            top = worldSpace ? mat : PMat.mul(p.top, mat)
        } else {
            top = mat
        }
    }

    // MARK: - Per frame

    /// `0x1402308a0` minus the vertex fill: simulate, ropetrail history, then children.
    func update(_ dt: Float, active: Bool) {
        if parent == nil { updateTop() } // children: the parent pushes their matrix before calling update
        time += dt
        if dt > 0 { simulate(dt, emit: active) }
        // 0x1402308f2: everything after simulate up to the children (rope, ropetrail history + VB, sprites) is skipped
        // while nothing is alive; the history step itself does not test dt (0x140232cad).
        let fillDump = PDump.want("fill\(def.path)") ? pdumpFillState(dt) : nil
        if alive > 0 { updateHistory(dt) }
        if let fillDump { pdumpFillWrite(fillDump) }
        // 0x140236380: children. Their flag byte +0x3f7 is the parent's, with the paused bit forced while the parent is
        // inactive; CP driving (0x14022a580) happens before each child's push and update.
        let childPaused = paused || !active
        for c in staticChildren {
            if c.cpDrivenByParent { driveChildCPs(c) }
            c.top = PMat.mul(top, c.mat) // 0x140229810: worldspace is ignored here
            c.paused = childPaused
            c.update(dt, active: active)
        }
        for k in eventChildren.indices {
            let kind = eventChildren[k].def.kind
            var j = 0
            while j < eventChildren[k].active.count {
                let c = eventChildren[k].active[j]
                if c.cpDrivenByParent { driveChildCPs(c) }
                c.paused = childPaused
                if kind == .eventFollow && c.followIndex >= 0 { placeChild(c, at: c.followIndex) }
                c.updateTop() // 0x140229760
                c.update(dt, active: active)
                // 0x140236512–0x14023658b: right after its update, an event child that is no longer alive (0x14022c310) is
                // moved from the active list to the pool; an eventfollow child still following a particle first drops
                // that particle's follow refcount (+0x438).
                if !c.isAlive {
                    if kind == .eventFollow && c.followIndex >= 0, let r = followRefs[c.followIndex] {
                        if r <= 1 { followRefs[c.followIndex] = nil } else { followRefs[c.followIndex] = r - 1 }
                    }
                    eventChildren[k].pool.append(c)
                    eventChildren[k].active.remove(at: j)
                } else {
                    j += 1
                }
            }
        }
    }

    var childMask: UInt8 { childMaskOverride ?? def.childMask }

    /// `simulate` 0x140236cd0.
    func simulate(_ dt: Float, emit: Bool) {
        let ageDump: [String: Any]? = PDump.want("age\(def.path)")
            ? ["age": PDump.bits(Array(age[0..<min((highWater + 3) & ~3, cap)])), "life": PDump.bits(Array(life[0..<min((highWater + 3) & ~3, cap)])),
               "highwater": highWater, "alive": alive, "order": order, "childmask": Int(childMask), "rope": keepOrder] : nil
        died.removeAll(keepingCapacity: true)
        // 0x140236d11: the death list is kept when the child mask has eventfollow/eventdeath bits or the rope VB exists.
        let wantDeaths = childMask & 0x14 != 0 || keepOrder
        // 0x140236d70: groups of four up to the high-water mark, so the tail lanes of the last group age too.
        for i in 0..<min((highWater + 3) & ~3, cap) {
            age[i] += dt
            if life[i] != 0 && life[i] < age[i] {
                life[i] = 0
                alive -= 1
                if wantDeaths { died.append(i) }
            }
        }
        if flags & ParticleDef.Flags.spriteSheet != 0 && !def.animationRandom {
            let m = def.sequenceMultiplier
            for i in 0..<highWater where life[i] != 0 { phase[i] = (SSEApprox.rcp(life[i]) * age[i]) * m } // rcpps(life)·age·seqmul (0x14023702a)
        }
        if !died.isEmpty {
            if keepOrder {
                let dead = Set(died)
                order.removeAll { dead.contains($0) }
            }
            handleDeaths()
        }
        deaths += died.count
        if let ageDump {
            PDump.write(["kind": "age", "def": def.path, "dt": dt.bitPattern, "before": ageDump, "died": died, "afterAlive": alive,
                         "afterOrder": order, "afterAge": PDump.bits(Array(age[0..<min((highWater + 3) & ~3, cap)])),
                         "afterLife": PDump.bits(Array(life[0..<min((highWater + 3) & ~3, cap)]))])
        }
        resolveControlPoints()
        if emit { emitAndInit(dt, extra: 0) }
        // 0x140237720: k = min(0.025 / C+0x14c (frame time), 1); dt2 = k^0.7 · dt. C+0x148 is the user's fps setting
        // (W+0x18c, 0x1401114e5): 1...20 runs the operators twice with (dt/2, dt2/2), otherwise once.
        let k = min(1, 0.025 / max(frame.frameTime, 1e-6))
        let dt2 = powf(k, 0.7) * dt
        if (1...20).contains(SceneRenderer.fpsSetting) {
            runOperators(dt * 0.5, dt2 * 0.5)
            runOperators(dt * 0.5, dt2 * 0.5)
        } else {
            runOperators(dt, dt2)
        }
        for i in 0..<8 { cps[i].prev = cps[i].world }
    }

    // MARK: - Control points (§6.2)

    func resolveControlPoints() {
        guard PDump.want("cpres\(def.path)") else { return resolveControlPointsBody() }
        func cpd(_ c: [PControlPoint]) -> [[String: Any]] {
            c.map { ["world": PDump.mat($0.world), "prev": PDump.mat($0.prev), "local": PDump.mat($0.local), "flags": $0.flags,
                     "parent": $0.parent] }
        }
        let before: [String: Any] = ["cps": cpd(cps), "ws": worldSpace, "top": PDump.mat(top), "driven": cpDrivenByParent,
                                     "start": cpStart, "parentTop": PDump.mat(parent?.top ?? matrix_identity_float4x4),
                                     "parentCps": parent.map { cpd($0.cps) } ?? [], "parentWs": parent?.worldSpace ?? false,
                                     "mouse": PDump.bits([Float(frame.pointer.x), Float(frame.pointer.y)]),
                                     "proj": PDump.mat(mouseProjection()), "view": PDump.mat(frame.view)]
        resolveControlPointsBody()
        PDump.write(["kind": "cpres", "def": def.path, "before": before, "after": cps.map { PDump.mat($0.world) }])
    }

    /// C+0x38 for the mouse CP. Before the first rendered frame the projection is still unset; build it the same way.
    private func mouseProjection() -> simd_float4x4 {
        let fr = frame
        if fr.proj == matrix_identity_float4x4, let sc = host.scene { return sc.projection(sw: fr.screen.x, sh: fr.screen.y) }
        return fr.proj
    }

    private func resolveControlPointsBody() {
        let ws = worldSpace
        for i in 0..<8 {
            let f = cps[i].flags
            if f & 0x10000 != 0 { continue }
            if f & 1 != 0 {
                cps[i].world = cps[i].local
                let fr = frame
                let proj = mouseProjection()
                // 0x14022e47b–0x14022e669 (session8-leftovers P28): inv = 0x14005f730(0x14005ecb0(proj C+0x38, view C+0x40));
                // x = (mx − 0)·2 − 1, y = ((1 − my) − 0)·2 − 1 with mx/my = C+0x8c/+0x90; NDC z is the constant 0 (its products
                // stay in the sums, so a non-finite column propagates); only x/w and y/w are kept, z is written as 0.
                // A local system then maps (x, y, 0) through inverse(Top) (0x14005f730 of the stack top C+0x30).
                let m = PMat.inverse(PMat.mul(proj, fr.view))
                let z: Float = 0
                let nx = (Float(fr.pointer.x) - z) + (Float(fr.pointer.x) - z) - 1
                let ny = ((1 - Float(fr.pointer.y)) - z) + ((1 - Float(fr.pointer.y)) - z) - 1
                let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
                let w = (c0.w * nx + c1.w * ny) + (c2.w * z + c3.w)
                let px = ((c0.x * nx + c1.x * ny) + (c2.x * z + c3.x)) / w
                let py = ((c0.y * nx + c1.y * ny) + (c2.y * z + c3.y)) / w
                var t = SIMD3<Float>(px, py, 0)
                if !ws {
                    let v = PMat.inverse(top)
                    let a0 = v.columns.0, a1 = v.columns.1, a2 = v.columns.2, a3 = v.columns.3
                    t = SIMD3((a0.x * px + a1.x * py) + (a2.x * z + a3.x),
                              (a0.y * px + a1.y * py) + (a2.y * z + a3.y),
                              (a0.z * px + a1.z * py) + (a2.z * z + a3.z))
                }
                cps[i].world.columns.3.x = t.x
                cps[i].world.columns.3.y = t.y
                cps[i].world.columns.3.z = t.z
            } else if f & 4 != 0, let p = parent, cps[i].parent < 8 {
                // 0x14022e66e: copy when both are worldspace or flags & 8; worldspace child of a local parent:
                // parentTop·pw (the matrix-stack entry under this system's Top); local child: inverse(Top)·pw (worldspace
                // parent) or inverse(Top)·(parentTop·pw), with glm's SSE inverse 0x1402290d0 and 0x14024f0e0 products.
                let pw = p.cps[cps[i].parent].world
                if (ws && p.worldSpace) || f & 8 != 0 {
                    cps[i].world = pw
                } else if ws {
                    cps[i].world = PMat.mul(p.top, pw)
                } else if p.worldSpace {
                    cps[i].world = PMat.mul(PMat.inverseSSE(top), pw)
                } else {
                    cps[i].world = PMat.mul(PMat.inverseSSE(top), PMat.mul(p.top, pw))
                }
            } else if cpDrivenByParent && i >= cpStart {
                continue
            } else if f & 2 != 0 {
                // 0x14022a070 (and the override pass 0x14022c0b6): a worldspace CP (flags & 2) of a local system is
                // inverse(Top)·local, CP 0 included; in a worldspace system CP 0 is Top·local and the others keep local.
                if ws {
                    cps[i].world = i == 0 ? PMat.mul(top, cps[i].local) : cps[i].local
                } else {
                    cps[i].world = PMat.mul(PMat.inverseSSE(top), cps[i].local)
                }
            } else {
                cps[i].world = ws ? PMat.mul(top, cps[i].local) : cps[i].local
            }
        }
    }

    /// `0x14022a580` (ChildDef flags & 1): the alive particles drive the child's CP translations from controlpointstartindex
    /// up. A CP with flags & 0x10005 is not written and does not advance, so it blocks every later CP (the next alive
    /// particle tries the same CP again). Positions go through M = identity for parent and child in the same space,
    /// inverse(parent Top) (0x14005f730) for a worldspace parent and local child, parent Top for the reverse, as
    /// x' = (m00·x + m10·y) + (m20·z + m30) (engine rows).
    func driveChildCPs(_ c: ParticleInstance) {
        guard PDump.want("cpdrive\(def.path)") else { return driveChildCPsBody(c) }
        let n = min(highWater + 4, cap)
        let before: [String: Any] = ["px": PDump.bits((0..<n).map { pos[$0].x }), "py": PDump.bits((0..<n).map { pos[$0].y }),
                                     "pz": PDump.bits((0..<n).map { pos[$0].z }), "life": PDump.bits((0..<n).map { life[$0] }),
                                     "highwater": highWater, "top": PDump.mat(top), "ws": worldSpace, "cws": c.worldSpace,
                                     "start": c.cpStart, "cpflags": c.cps.map { $0.flags }, "cps": c.cps.map { PDump.mat($0.world) }]
        driveChildCPsBody(c)
        PDump.write(["kind": "cpdrive", "def": def.path, "before": before, "after": c.cps.map { PDump.mat($0.world) }])
    }

    private func driveChildCPsBody(_ c: ParticleInstance) {
        var k = c.cpStart
        guard k < 8 else { return }
        let M: simd_float4x4
        switch (worldSpace, c.worldSpace) {
        case (true, false): M = PMat.inverse(top)
        case (false, true): M = top
        default: M = matrix_identity_float4x4
        }
        for i in 0..<highWater {
            guard k < 8 else { break }
            guard life[i] != 0, c.cps[k].flags & 0x10005 == 0 else { continue }
            let p = pos[i]
            let r0 = M.columns.0, r1 = M.columns.1, r2 = M.columns.2, r3 = M.columns.3
            c.cps[k].world.columns.3.x = (r0.x * p.x + r1.x * p.y) + (r2.x * p.z + r3.x)
            c.cps[k].world.columns.3.y = (r0.y * p.x + r1.y * p.y) + (r2.y * p.z + r3.y)
            c.cps[k].world.columns.3.z = (r0.z * p.x + r1.z * p.y) + (r2.z * p.z + r3.z)
            k += 1
        }
    }

    // MARK: - Emission (§3.2)

    /// `0x1402378a0(inst, dt, extraCount)`. Simulate passes 0, script `emitParticles(n)` passes n. While paused
    /// (inst+0x3f7 & 1) only an explicit burst runs. extraCount is assigned before the disabled / paused / delay
    /// checks (0x1402379d6), so every emitter with room spawns at least min(extra, max − alive).
    func emitAndInit(_ dt: Float, extra: Int) {
        guard PDump.want("emitst\(def.path)") else { return emitAndInitBody(dt, extra: extra) }
        func st() -> [[String: Any]] {
            emitters.map { E in ["rate": E.rate.bitPattern, "dur": E.duration.bitPattern, "delay": E.delay.bitPattern,
                                 "acc": E.acc.bitPattern, "timer": E.timer.bitPattern, "pending": E.pending,
                                 "emitted": E.emittedThisPeriod, "flags": Int(E.flags), "mpp": E.maxPerPeriod] }
        }
        let before = st(), a0 = alive, h0 = highWater, ae0 = activeEmitters
        let outer = PRand.tape
        PRand.tape = []
        emitAndInitBody(dt, extra: extra)
        PDump.write(["kind": "emitst", "def": def.path, "dt": dt.bitPattern, "extra": extra, "before": before, "after": st(),
                     "alive0": a0, "hw0": h0, "alive1": alive, "hw1": highWater, "active0": ae0, "active1": activeEmitters,
                     "paused": paused, "tape": PRand.tape ?? []])
        PRand.tape = outer.map { $0 + (PRand.tape ?? []) }
    }

    func emitAndInitBody(_ dt: Float, extra: Int) {
        if paused && extra <= 0 { return }
        born.removeAll(keepingCapacity: true)
        var searchFrom = 0
        for e in emitters.indices {
            var n = 0
            var E = emitters[e]
            if alive < maxCount {
                n = extra
                if !E.disabled && !paused && E.delay <= 0 {
                    var rate = E.rate
                    if E.def.audio.mode != 0 { rate *= E.def.audio.response(host.audioBands) }
                    var phaseStart = false
                    if E.flags & 4 != 0 {
                        if E.timer > 0 {
                            E.timer -= dt
                            if E.timer < 0 { E.timer = -(E.def.minPDelay + PRand.a() * (E.def.maxPDelay - E.def.minPDelay)) }
                        } else {
                            E.timer += dt
                            if E.timer >= 0 {
                                E.timer = E.def.minPDur + PRand.a() * (E.def.maxPDur - E.def.minPDur)
                                E.pending = E.def.instantaneous
                                E.emittedThisPeriod = 0
                                phaseStart = true
                            } else {
                                rate = 0
                            }
                        }
                    }
                    if phaseStart {
                        emitters[e] = E
                        periodicPhaseStart()
                        E = emitters[e]
                    }
                    let burst = E.pending + extra
                    E.pending = 0
                    let acc = E.acc + rate * dt
                    if acc >= 1 && E.duration >= 0 {
                        var k = Int(floorf(acc))
                        E.acc = acc - Float(k + burst)
                        if E.flags & 2 != 0 { k = min(k, 1) }
                        if E.flags & 4 != 0 && E.maxPerPeriod != 0 {
                            k = min(k, max(E.maxPerPeriod - E.emittedThisPeriod, 0))
                            E.emittedThisPeriod += k
                        }
                        n = burst + k
                    } else {
                        // The burst is emitted even when the accumulator is below 1 (rate:0 + instantaneous).
                        E.acc = acc - Float(burst)
                        n = burst
                    }
                }
            }
            if n > 0 {
                n = min(n, maxCount - alive)
                if E.def.kind == .layerImage {
                    spawnLayerImage(&E, n, dt, &searchFrom)
                } else {
                    for _ in 0..<n {
                        var i = searchFrom
                        while i < maxCount && life[i] != 0 { i += 1 }
                        guard i < maxCount else { break }
                        searchFrom = i + 1
                        spawn(i, E)
                    }
                }
            }
            if E.delay > 0 {
                E.delay -= dt
            } else if E.duration > 0 {
                E.duration -= dt
                if E.duration <= 0 { E.duration = -1; disable(&E) }
            } else if E.rate <= 0 && !(E.def.instantaneous != 0 && E.flags & 4 != 0) {
                disable(&E)
            }
            emitters[e] = E
        }
        if !born.isEmpty && childMask & 0x0c != 0 { spawnEventChildrenOnEmit() }
    }

    /// layerimage spawn (op 3, 0x140238c45.., gaps6/particles/layerimage_ref.py): every 1 s with flags & 0x20000 the
    /// capture is redone; until the readback is ready nothing spawns. A point is chosen with Lemire uniform_int on
    /// the context mt19937; pos = (x + ox, −y + oy, oz)·(layerWorld·M), M = inverse(Top) or identity (worldspace);
    /// flags & 0x40000 gives vel = Δpos / frameTime · speed against the previous layer world; flags & 0x10000 tints by
    /// the pixel RGB. Puppet layers: each point follows the bone assigned at capture (0x1401d6d30, see PLayerImage).
    private func spawnLayerImage(_ E: inout PEmitterState, _ count: Int, _ dt: Float, _ searchFrom: inout Int) {
        guard let img = E.image, let layer = img.layer else { return }
        let d = E.def
        if E.flags & 0x20000 != 0 {
            E.captureTimer += dt
            if E.captureTimer > 1 { E.captureTimer = fmodf(E.captureTimer, 1); img.invalidate() }
        }
        let M = worldSpace ? matrix_identity_float4x4 : PMat.inverse(top) // 0x14005f730 (0x140238ccf)
        // 0x1401d3ae0 (state 2) stores the layer's vt+0x80 matrix (image layers: world with the alignment offset,
        // `layerWorld`) in the point set (+0x18); M70 = 0x1401842d0(M, that) = 0x14005ecb0(M, W) (0x140238db5), and the
        // emitter's previous world (payload +0xa8) is replaced by the same matrix (0x14023adef). Mprev = 0x14005ecb0(M, prev)
        // at 0x140238d3a.
        let W = layer.layerWorld
        let M70 = PMat.mul(M, W), Mprev = PMat.mul(M, E.prevLayerWorld)
        // 0x14023add9: the previous layer world is replaced only when the points were ready.
        guard img.getPoints() else { return }
        defer { E.prevLayerWorld = W }
        guard !img.points.isEmpty else { return }
        let pts = img.points
        let M3 = cps[0].world.m3
        let ft = frame.frameTime
        // Puppet layers (0x14023904a–0x1402396cf, 0x140239818..): per bone b, once per frame, pos matrix =
        // invBind[b]·boneWorld[b]·(layerWorld·M) (0x1401d4360, then × M70) and, for flags & 0x40000, prev matrix =
        // invBind[b]·prevLayerSpace[b]·M (0x1401d4400: puppet +0x348, identity on the first frame).
        let pup = layer.puppet
        var skinPos: [Int: simd_float4x4] = [:], skinPrev: [Int: simd_float4x4] = [:]
        func puppetMatrices(_ b: Int) -> (simd_float4x4, simd_float4x4) {
            if let p = skinPos[b], let q = skinPrev[b] { return (p, q) }
            let ib = b < img.invBind.count ? img.invBind[b] : matrix_identity_float4x4
            let cur = pup.map { b < $0.boneWorld.count ? $0.boneWorld[b] : matrix_identity_float4x4 } ?? matrix_identity_float4x4
            let prevLS = img.prevLayerSpaceBones.map { b < $0.count ? $0[b] : matrix_identity_float4x4 } ?? matrix_identity_float4x4
            let p = M70 * (cur * ib), q = M * (prevLS * ib)
            skinPos[b] = p; skinPrev[b] = q
            return (p, q)
        }
        for _ in 0..<count {
            var i = searchFrom
            while i < maxCount && life[i] != 0 { i += 1 }
            guard i < maxCount else { break }
            searchFrom = i + 1
            let pt = pts[PRand.uniformIndex(pts.count)]
            var o = SIMD3<Float>(0, 0, 0)
            if E.flags & 0x80000 != 0 {
                o.x = PRand.a() * d.offsetRange.x + d.offsetMin.x
                o.y = PRand.a() * d.offsetRange.y + d.offsetMin.y
                o.z = PRand.a() * d.offsetRange.z + d.offsetMin.z
            }
            let l = SIMD4<Float>(Float(pt.x) + o.x, Float(-Int32(pt.y)) + o.y, o.z + 0, 1)
            let skinned = pup != nil && pt.bone != 0xff
            let pm = skinned ? puppetMatrices(Int(pt.bone)) : nil
            let p: SIMD4<Float>
            if let pm {
                p = pm.0 * l
            } else {
                // 0x1402396d4: t + ((r0·lx + r1·ly) + r2·lz) with the rows of M70 (simd columns) and t its row 3.
                let r0 = M70.columns.0, r1 = M70.columns.1, r2 = M70.columns.2, t = M70.columns.3
                p = SIMD4(t.x + ((r0.x * l.x + r1.x * l.y) + r2.x * l.z), t.y + ((r0.y * l.x + r1.y * l.y) + r2.y * l.z),
                          t.z + ((r0.z * l.x + r1.z * l.y) + r2.z * l.z), 1)
            }
            pos[i] = SIMD3(p.x, p.y, p.z)
            vel[i] = .zero
            if E.flags & 0x40000 != 0 {
                // 0x14023a7a1 (non-puppet): glm mat4·vec4 (c0·x + c1·y) + (c2·z + c3·1).
                let q: SIMD4<Float> = pm.map { $0.1 * l } ?? {
                    let c0 = Mprev.columns.0, c1 = Mprev.columns.1, c2 = Mprev.columns.2, c3 = Mprev.columns.3
                    let a = c0 * l.x + c1 * l.y, b = c2 * l.z + c3 * l.w
                    return a + b
                }()
                let sp = PRand.a() * (E.speedMax - E.speedMin) + E.speedMin
                vel[i] = (SIMD3(p.x, p.y, p.z) - SIMD3(q.x, q.y, q.z)) / ft * sp
            }
            var c = tint
            if E.flags & 0x10000 != 0 {
                c.x = Float(pt.r) / 255 * tint.x; c.y = Float(pt.g) / 255 * tint.y; c.z = Float(pt.b) / 255 * tint.z
            }
            if PDump.want("li\(def.path)") {
                PDump.write(["kind": "li", "pt": [Int(pt.r), Int(pt.g), Int(pt.b), Int(pt.x), Int(pt.y)], "o": PDump.bits([o.x, o.y, o.z]),
                             "pos": PDump.bits([pos[i].x, pos[i].y, pos[i].z]), "vel": PDump.bits([vel[i].x, vel[i].y, vel[i].z]),
                             "col": PDump.bits([c.x, c.y, c.z, c.w]), "tint": PDump.bits([tint.x, tint.y, tint.z, tint.w]),
                             "W": PDump.mat(W), "prevW": PDump.mat(E.prevLayerWorld), "M": PDump.mat(M),
                             "ft": ft.bitPattern, "flags": Int(E.flags), "offmin": PDump.bits([d.offsetMin.x, d.offsetMin.y, d.offsetMin.z]),
                             "offrange": PDump.bits([d.offsetRange.x, d.offsetRange.y, d.offsetRange.z]),
                             "smin": E.speedMin.bitPattern, "srange": (E.speedMax - E.speedMin).bitPattern])
            }
            initParticle(i, M3: M3, base: c)
            alive += 1
            if i == highWater { highWater += 1 }
            born.append(i)
            if keepOrder { order.append(i) }
        }
    }

    private func disable(_ E: inout PEmitterState) {
        // 0x14023ae5b: `dec byte [inst+0x3f4]` when the emitter was enabled; the byte wraps (0 → 255).
        if !E.disabled { activeEmitters = (activeEmitters - 1) & 0xff; E.flags |= 0x8000_0000 }
    }

    private func spawn(_ i: Int, _ E: PEmitterState) {
        guard PDump.want("spawn\(def.path)") else { return spawnBody(i, E) }
        let outer = PRand.tape
        PRand.tape = []
        let cpm = cps[E.def.cp].world
        spawnBody(i, E)
        PDump.write(["kind": "spawn", "def": def.path, "i": i, "tape": PRand.tape ?? [], "cp": PDump.mat(cpm),
                     "pos": PDump.bits([pos[i].x, pos[i].y, pos[i].z]), "vel": PDump.bits([vel[i].x, vel[i].y, vel[i].z]),
                     "rnd": rnd[i].bitPattern, "smin": E.speedMin.bitPattern, "smax": E.speedMax.bitPattern, "flags": Int(flags),
                     "eflags": Int(E.flags)])
        PRand.tape = outer.map { $0 + (PRand.tape ?? []) }
    }

    private func spawnBody(_ i: Int, _ E: PEmitterState) {
        // Sphere 0x140237d71–0x140238185 and box 0x14023847f–0x140238bda, transliterated (session 7; replayed bit-exact under
        // the emulator; rcpps / rsqrtps through `SSEApprox`, session 8). base = cp translation + origin; the rotation is v·M3 summed
        // (z·r2 + (y·r1 + x·r0)) for the sphere's 4-wide path and ((x·r0 + y·r1) + z·r2) for the box's scalar path.
        let d = E.def
        let cpm = cps[d.cp].world
        let M3 = cpm.m3
        let r0 = M3.columns.0, r1 = M3.columns.1, r2 = M3.columns.2
        let T = cpm.translation
        let base = SIMD3(T.x + d.origin.x, T.y + d.origin.y, T.z + d.origin.z)
        let rotate = worldSpace || d.cp != 0
        @inline(__always) func rot4(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(v.z * r2.x + (v.y * r1.x + v.x * r0.x), v.z * r2.y + (v.y * r1.y + v.x * r0.y), v.z * r2.z + (v.y * r1.z + v.x * r0.z))
        }
        @inline(__always) func len2v(_ v: SIMD3<Float>) -> Float { v.y * v.y + (v.x * v.x + v.z * v.z) } // (y² + w²) + (x² + z²), w = 0
        switch d.kind {
        case .sphere:
            let phi = (PRand.b() * 2) * pPi
            let z = PRand.a() * (1 - d.coneZ) + d.coneZ // distribution A (ctx+0x20, 0x140237dc6); phi, r and speed use B
            let r = cbrtf(PRand.b())
            let s = sqrtf(1 - z * z)
            let rz = r * z, rs = r * s
            let v = SIMD3<Float>(rz * d.directions.x, (sinf(phi) * rs) * d.directions.y, (cosf(phi) * rs) * d.directions.z)
            let len = sqrtf(len2v(v))
            let dist = d.distMax.x - d.distMin.x
            let k = d.distMin.x + dist * len
            let inv = SSEApprox.rcp(len) // rcpps 0x140237ed7
            var dn = SIMD3(inv * v.x, inv * v.y, inv * v.z)
            if d.flags & 1 != 0 {
                for a in 0..<3 where d.sign[a] != 0 && ((d.sign[a] < 0) != (dn[a] < 0)) { dn[a] = dn[a] * -1 }
            }
            var off = SIMD3(k * dn.x, k * dn.y, k * dn.z)
            if rotate { off = rot4(off) }
            pos[i] = off + base
            var dir = off
            if !(Float(bitPattern: 0x38d1_b717) <= len2v(off)) { // 1e-4 > |off|²
                let u1 = PRand.b(), u2 = PRand.b(), u3 = PRand.b()
                dir = SIMD3((u1 * 2 - 1) * d.directions.x, (u2 * 2 - 1) * d.directions.y, (u3 * 2 - 1) * d.directions.z)
                if rotate { dir = rot4(dir) }
            }
            let rq = SSEApprox.rsqrt(len2v(dir)) // rsqrtps 0x140238121
            let sp = PRand.b() * (E.speedMax - E.speedMin) + E.speedMin
            vel[i] = SIMD3(sp * (rq * dir.x), sp * (rq * dir.y), sp * (rq * dir.z))
        case .box:
            let tz = (PRand.b() * 2 - 1) * d.directions.z
            let ty = (PRand.b() * 2 - 1) * d.directions.y
            let tx = (PRand.b() * 2 - 1) * d.directions.x
            let t = SIMD3(tx, ty, tz)
            var off = SIMD3<Float>(0, 0, 0)
            for a in 0..<3 {
                let sg: Float = (t[a] > 0 ? 1 : 0) - (0 > t[a] ? 1 : 0)
                off[a] = sg * ((sg * t[a]) * (d.distMax[a] - d.distMin[a]) + d.distMin[a])
            }
            if rotate { off = rowMul(off, M3) }
            pos[i] = off + base
            var dir = pos[i] - base
            // Quake fast inverse square root (magic 0x5f375a86, one Newton step), L = 1 / y.
            let l2 = (dir.y * dir.y + dir.x * dir.x) + dir.z * dir.z
            let y0 = Float(bitPattern: 0x5f37_5a86 &- (l2.bitPattern >> 1))
            let y1 = (1.5 - ((l2 * 0.5) * y0) * y0) * y0
            if Float(bitPattern: 0x38d1_b717) > 1 / y1 {
                let uz = PRand.b(), uy = PRand.b(), ux = PRand.b()
                dir = SIMD3((ux + ux - 1) * d.directions.x, (uy + uy - 1) * d.directions.y, (uz + uz - 1) * d.directions.z)
                if rotate { dir = rowMul(dir, M3) }
            }
            let inv = 1 / sqrtf((dir.y * dir.y + dir.x * dir.x) + dir.z * dir.z)
            let sp = PRand.b() * (E.speedMax - E.speedMin) + E.speedMin
            vel[i] = SIMD3(sp * (inv * dir.x), sp * (inv * dir.y), sp * (inv * dir.z))
        case .layerImage:
            return // spawnLayerImage
        }
        initParticle(i, M3: M3)
        alive += 1
        if i == highWater { highWater += 1 }
        born.append(i)
        if keepOrder { order.append(i) }
    }

    // MARK: - InitParticle (Part 2 §1, §4)

    func initParticle(_ i: Int, M3: simd_float3x3, base: SIMD4<Float>? = nil) {
        guard PDump.want("initp\(def.path)") else { return initParticleBody(i, M3: M3, base: base) }
        let before = pdumpState(cap)
        let seq = seqState.sorted { $0.key < $1.key }.map { [$0.key, Int($0.value.t.bitPattern), Int($0.value.step.bitPattern)] }
        let outer = PRand.tape, outerCrt = PRand.crtTape
        PRand.tape = []; PRand.crtTape = []
        defer {
            if let o = outer { PRand.tape = o + (PRand.tape ?? []) } else { PRand.tape = nil }
            if let o = outerCrt { PRand.crtTape = o + (PRand.crtTape ?? []) } else { PRand.crtTape = nil }
        }
        initParticleBody(i, M3: M3, base: base)
        PDump.write(["kind": "initp", "def": def.path, "i": i, "before": before, "after": pdumpState(cap),
                     "tape": PRand.tape ?? [], "crt": (PRand.crtTape ?? []).map { Int($0) }, "seq": seq,
                     "M3": PDump.bits([M3.columns.0.x, M3.columns.0.y, M3.columns.0.z, M3.columns.1.x, M3.columns.1.y,
                                       M3.columns.1.z, M3.columns.2.x, M3.columns.2.y, M3.columns.2.z]),
                     "tint": PDump.bits([tint.x, tint.y, tint.z, tint.w]), "base": base.map { PDump.bits([$0.x, $0.y, $0.z, $0.w]) } ?? [],
                     "frametime": frame.frameTime.bitPattern, "prevft": host.prevFrameTime.bitPattern, "scales": PDump.bits([scales.count, scales.speed, scales.lifetime,
                                                                                    scales.size, scales.rate]),
                     "colorActive": scales.colorActive, "ovhsv": PDump.bits([scales.ovHSV.x, scales.ovHSV.y, scales.ovHSV.z]),
                     "flags": Int(flags), "follow": followIndex])
    }

    func initParticleBody(_ i: Int, M3: simd_float3x3, base: SIMD4<Float>? = nil) {
        age[i] = 0
        life[i] = 1
        rnd[i] = PRand.a()
        phase[i] = def.animationRandom ? rnd[i] : 0
        size0[i] = 0.5
        size[i] = 0.5
        // 0x14023b453: rotation is zeroed only when the def has the rotation arrays (mask & 1). Without them the one
        // aliased array keeps whatever the dead slot held (remapvalue / inheritvaluefromevent write it on every slot).
        if def.mask & 1 != 0 { rot[i] = .zero }
        angVel[i] = .zero
        prevPos[i] = pos[i] // spawn position, before the initializers (read only with def mask & 4)
        color0[i] = base ?? tint
        color[i] = color0[i]
        let sc = scales
        for (k, op) in def.initializers.enumerated() {
            switch op {
            case let .lifetime(mn, mx, e):
                let a = mn * sc.lifetime, r = mx * sc.lifetime - a
                life[i] = max(a + r * PRand.exp(e), 0.001)
            case let .size(mn, mx, e):
                let a = mn * sc.size, r = mx * sc.size - a
                size0[i] *= a + r * PRand.exp(e)
            case let .color(mn, mx, e):
                let a = sc.shift(mn), r = sc.shift(mx) - a
                let c = a + r * PRand.exp(e)
                color0[i].x *= c.x; color0[i].y *= c.y; color0[i].z *= c.z
            case let .hsv(hmin, hstep, steps, hrange, smin, srange, vmin, vrange):
                var hueMin = hmin, satMin = smin, satRange = srange, valMin = vmin, valRange = vrange
                if sc.colorActive {
                    // Record type 13 (0x1401d212b): x' = (ov − (0.5·range + min)) + min; s and v clamped to [0, 1] and their
                    // range cut to 1 − min(x', 1) when x' + range > 1; the hue is not clamped.
                    hueMin = (sc.ovHSV.x - (hrange * 0.5 + hmin)) + hmin
                    satMin = sseMin(1, sseMax(0, (sc.ovHSV.y - (srange * 0.5 + smin)) + smin))
                    if satMin + srange > 1 { satRange = 1 - sseMin(satMin, 1) }
                    valMin = sseMin(1, sseMax(0, (sc.ovHSV.z - (vrange * 0.5 + vmin)) + vmin))
                    if valMin + vrange > 1 { valRange = 1 - sseMin(valMin, 1) }
                }
                var kk = min(Int(Float(PRand.crt()) / 32767 * Float(steps + 1)), steps)
                if kk < 0 { kk = 0 }
                let hue = hueMin + Float(kk) * hstep
                let s = satMin + PRand.a() * satRange
                let v = valMin + PRand.a() * valRange
                let c = HSV.toRGB(SIMD3(hue, s, v))
                color0[i].x *= c.x; color0[i].y *= c.y; color0[i].z *= c.z
            case let .colorList(list, noise):
                let C = list[PRand.uniformIndex(list.count)] // 0x14024f410 on [0, n−1]
                var x = SIMD3<Float>(0, 0, 0)
                for ch in 0..<3 {
                    let lo = max(C[ch] - noise[ch], 0), hi = min(C[ch] + noise[ch], 1)
                    x[ch] = lo + (hi - lo) * PRand.a()
                }
                if sc.colorActive { x += sc.hsvShift } // Record type 14 offset.
                x.x -= floorf(x.x)
                x.y = clamp01(x.y); x.z = clamp01(x.z)
                let c = HSV.toRGB(x)
                color0[i].x *= c.x; color0[i].y *= c.y; color0[i].z *= c.z
            case let .alpha(mn, mx, e):
                color0[i].w *= mn + (mx - mn) * PRand.exp(e)
            case let .velocity(mn, mx, e):
                let a = mn * sc.speed, r = mx * sc.speed - a
                var v = SIMD3<Float>(0, 0, 0)
                v.z = a.z + r.z * PRand.exp(e)
                v.y = a.y + r.y * PRand.exp(e)
                v.x = a.x + r.x * PRand.exp(e)
                vel[i] += rowMul(v, M3) // 0x140184440
            case let .inheritCPVelocity(mn, mx, cpi):
                // 0x14023bc32: d = (world.t − prev.t) / C+0x150 (the previous frame's dt); worldspace systems with a CP
                // lacking flag 2 take inverse(Top)·(d, 0) (0x14005f730, 0x14019d470); s = U·(max'−min') + min' (type-6
                // speed record); vel += (s·d)·M3 (0x140184440, the spawn rotation).
                let c = cps[cpi]
                let ft = host.prevFrameTime
                let w = c.world.translation, q = c.prev.translation
                var d = SIMD3((w.x - q.x) / ft, (w.y - q.y) / ft, (w.z - q.z) / ft)
                if worldSpace && c.flags & 2 == 0 {
                    let m = PMat.inverse(top) // 0x14005f730
                    let a = m.columns.0 * d.x + m.columns.1 * d.y, b = m.columns.2 * d.z
                    d = SIMD3(a.x + b.x, a.y + b.y, a.z + b.z)
                }
                let a = mn * sc.speed, r = mx * sc.speed - a
                let sp = PRand.a() * r + a
                vel[i] += rowMul(SIMD3(sp * d.x, sp * d.y, sp * d.z), M3)
            case let .turbulentVelocity(tv):
                // 0x14023bdbc: t = ((U·phaseRange·audio + phasemin) + ctx time) · timescale', timescale' = timescale·rate (type 2
                // record); snoise1 0x14027b090; angle = n·π·scale + offset; dir = glm::rotate(I, angle, right) · forward
                // (0x1401e2500, mat3 row-vector product 0x140184440); speed = U·(max'−min') + min' (type 6, speed override).
                let pr = tv.audio.mode != 0 ? tv.audio.response(host.audioBands) * (tv.phaseMax - tv.phaseMin) : tv.phaseMax - tv.phaseMin
                let ts = tv.timescale * sc.rate
                let t = ((PRand.a() * pr + tv.phaseMin) + frame.time) * ts
                let n = PNoise.snoise1(t)
                let ang = ((n * pPi) * tv.scale) + tv.offset
                let dir = glmRotateApply(angle: ang, axis: tv.right, tv.forward)
                let a = tv.speedMin * sc.speed, r = tv.speedMax * sc.speed - a
                let spd = PRand.a() * r + a
                vel[i] += rowMul(dir * spd, M3)
            case let .rotation(mn, mx, e):
                let r = mx - mn
                var v = rot[i]
                v.x += mn.x + r.x * PRand.exp(e)
                v.y += mn.y + r.y * PRand.exp(e)
                v.z += mn.z + r.z * PRand.exp(e)
                rot[i] = v
            case let .positionOffset(dir, sign, scale, distance, timescale, octaves, useSign):
                let T = timescale * frame.time
                func fbm(_ a: Float, _ b: Float) -> Float {
                    var s: Float = 0, norm: Float = 0, amp: Float = 1, f: Float = 1
                    for _ in 0..<octaves { s += Simplex.noise2(a * f, b * f) * amp; norm += amp; amp *= 0.5; f *= 2 }
                    return s / norm
                }
                let p = pos[i]
                var o = SIMD3<Float>(fbm(p.x * scale, T) * dir.x, fbm(T, p.y * scale) * dir.y, fbm(p.z * scale, -T) * dir.z)
                if useSign { o = simd_abs(o) * sign + o * (1 - simd_abs(sign)) }
                pos[i] += o * distance
            case let .angularVelocity(mn, mx, e):
                let a = mn * sc.speed, r = mx * sc.speed - a
                var v = angVel[i]
                v.x += a.x + r.x * PRand.exp(e)
                v.y += a.y + r.y * PRand.exp(e)
                v.z += a.z + r.z * PRand.exp(e)
                angVel[i] = v
            case let .mapAround(m):
                // 0x14023c4cf–0x14023c9c4 (checked in tools/x64emu.py): the parse-time basis (n, u, w) is rotated by the
                // control point's 3×3; d = p − C splits into `along = d·n'` and a radius |d − n'·along|; at
                // a = (lo + t·range)·2π the particle moves to C + n'·along + (cos a·w' + sin a·u')·radius, and
                // velocity gains s.x·(cos a·u' − sin a·w') + s.y·(cos a·w' + sin a·u') + s.z·n', s = smin + U·range
                // (the uniforms are drawn for z, x, y in that order; speed override type-10 record, 0xd4).
                guard var st = seqState[k] else { break }
                // 0x14023c4cf–0x14023c9c4, transliterated: basis rotated by the CP 3×3 (0x140184440), d = p − C,
                // along = d·n', perp = d − along·n', r = |perp| (0x14019e890), a = (t·range + lo)·2π;
                // pos = dir·r + (along·n' + C) with dir = c·w' + s·u', tangent = (−s)·w' + c·u'; the velocity terms are
                // summed in the engine's order with U1 (z), U2 (x), U3 (y) and the type-10 speed record (min·ov, max·ov − min·ov).
                let cw = cps[m.cp].world
                let C = cw.translation
                let R = cw.m3
                let b = m.basis
                let n = rowMul(b.n, R), u = rowMul(b.u, R), w = rowMul(b.w, R)
                let d = pos[i] - C
                let along = (d.x * n.x + d.y * n.y) + d.z * n.z
                let perp = SIMD3(d.x - along * n.x, d.y - along * n.y, d.z - along * n.z)
                let radial = sqrtf((perp.x * perp.x + perp.y * perp.y) + perp.z * perp.z)
                let ang = (st.t * m.range + m.lo) * pTwoPi
                let sa = sinf(ang), ca = cosf(ang), ns = -sa
                let dir = SIMD3(ca * w.x + sa * u.x, ca * w.y + sa * u.y, ca * w.z + sa * u.z)
                let tg = SIMD3(ns * w.x + ca * u.x, ns * w.y + ca * u.y, ns * w.z + ca * u.z)
                let mn = m.speedMin * sc.speed, rg = m.speedMax * sc.speed - mn
                let u1 = PRand.a(), u2 = PRand.a(), u3 = PRand.a()
                func term(_ dk: Float, _ tk: Float, _ nk: Float) -> Float {
                    (((((dk * mn.y) + u3 * (dk * rg.y)) + mn.x * tk) + u2 * (rg.x * tk)) + mn.z * nk) + u1 * (rg.z * nk)
                }
                pos[i] = SIMD3(dir.x * radial + (along * n.x + C.x), dir.y * radial + (along * n.y + C.y),
                               dir.z * radial + (along * n.z + C.z))
                vel[i] += SIMD3(term(dir.x, tg.x, n.x), term(dir.y, tg.y, n.y), term(dir.z, tg.z, n.z))
                // 0x14023c9c4: t > 1 → mirror: step = −step, t = 1 − (t − 1); repeat: t = fmodf(t, 1); else t < 0 → negate both.
                st.t += st.step
                if st.t > 1 {
                    if m.mirror { st.step = -st.step; st.t = 1 - (st.t - 1) } else { st.t = fmodf(st.t, 1) }
                } else if 0 > st.t { st.t = -st.t; st.step = -st.step }
                seqState[k] = st
            case let .mapBetween(m):
                // 0x14023ca93: worldspace systems first take p − A (0x14019d8f0), local ones project p itself; the along-line
                // point is (u·n)·L + A; w = 1 − powf(|2t − 1|, 2); "repeat" resets t to 0, "mirror" reflects as
                // t = 1 − (t − 1) and skips the t < 0 test.
                guard var st = seqState[k] else { break }
                let A = cps[m.cpStart].world.translation, B = cps[m.cpEnd].world.translation
                let dAB = B - A
                let L = max(sqrtf((dAB.x * dAB.x + dAB.y * dAB.y) + dAB.z * dAB.z), Float.leastNormalMagnitude)
                let n = SIMD3(dAB.x / L, dAB.y / L, dAB.z / L)
                var p = pos[i]
                if worldSpace { p -= A }
                let dp = (p.x * n.x + p.y * n.y) + p.z * n.z
                var perp = SIMD3(p.x - dp * n.x, p.y - dp * n.y, p.z - dp * n.z)
                let u = st.t * m.range + m.lo
                let w = 1 - powf(abs((st.t + st.t) - 1), 2)
                if m.flags & 1 != 0 { perp *= w }
                var np = perp + ((n * u) * L + A)
                if m.flags & 8 != 0 { np += m.arcDirection * ((w * L) * m.arcAmount) }
                pos[i] = np
                if m.flags & 2 != 0 { vel[i] *= w }
                if m.flags & 4 != 0 { size0[i] = ((1 - m.sizeReduction) + m.sizeReduction * w) * size0[i] }
                st.t += st.step
                if st.t > 1 {
                    if m.mirror { st.step = -st.step; st.t = 1 - (st.t - 1) } else { st.t = 0 }
                } else if 0 > st.t { st.t = -st.t; st.step = -st.step }
                seqState[k] = st
            case let .remap(r):
                let dump = PDump.want("init\(def.path)\(k)") ? pdumpState(cap) : nil
                initRemap(r, i)
                if let dump { PDump.write(["kind": "init", "def": def.path, "idx": k, "i": i, "before": dump, "after": pdumpState(cap)]) }
            case let .inheritFromEvent(mode):
                inheritFromParent(mode, i, initial: true)
            }
        }
        size[i] = size0[i]
        color[i] = color0[i]
        if histSegments > 0 {
            for s in 0..<histSegments { hist[i * histSegments + s] = pos[i] }
            histCount[i] = 1
            if !histScroll.isEmpty { histScroll[i] = 0 }
        }
    }

    /// inherit(initial)valuefromevent: the parent particle's current values into this system's slot (op 20 0x140249c30, its
    /// life-blend variant 40 0x14024a355, initializer 16 0x14023f445). The op requires the parent particle to be alive; the
    /// variant blends: set → (P − x)·b + x, multiply → ((P − 1)·b + 1)·x, add → P·b + x. Rotation (10/11) and angular
    /// velocity (12/13) need the arrays in both systems (parent mask & child mask & 1 / & 2), else nothing is written.
    func inheritFromParent(_ mode: Int, _ i: Int, initial: Bool, blend b: Float? = nil) {
        guard followIndex >= 0, let p = parent, followIndex < p.highWater else { return }
        let j = followIndex
        if !initial && !(p.life[j] > 0) { return }
        @inline(__always) func set(_ x: Float, _ P: Float) -> Float { b.map { (P - x) * $0 + x } ?? P }
        @inline(__always) func mul(_ x: Float, _ P: Float) -> Float { b.map { ((P - 1) * $0 + 1) * x } ?? x * P }
        @inline(__always) func add(_ x: Float, _ P: Float) -> Float { b.map { P * $0 + x } ?? x + P }
        let pc = p.color[j]
        var c = initial ? color0[i] : color[i]
        func store() { if initial { color0[i] = c } else { color[i] = c } }
        switch mode {
        case 0: c.x = set(c.x, pc.x); c.y = set(c.y, pc.y); c.z = set(c.z, pc.z); store()
        case 1: c.x = mul(c.x, pc.x); c.y = mul(c.y, pc.y); c.z = mul(c.z, pc.z); store()
        case 2: c.w = set(c.w, pc.w); store()
        case 3: c.w = mul(c.w, pc.w); store()
        case 4: c = SIMD4(set(c.x, pc.x), set(c.y, pc.y), set(c.z, pc.z), set(c.w, pc.w)); store()
        case 5: c = SIMD4(mul(c.x, pc.x), mul(c.y, pc.y), mul(c.z, pc.z), mul(c.w, pc.w)); store()
        case 6: let v = vel[i], pv = p.vel[j]; vel[i] = SIMD3(set(v.x, pv.x), set(v.y, pv.y), set(v.z, pv.z))
        case 7: let v = vel[i], pv = p.vel[j]; vel[i] = SIMD3(add(v.x, pv.x), add(v.y, pv.y), add(v.z, pv.z))
        case 8: if initial { size0[i] = set(size0[i], p.size[j]) } else { size[i] = set(size[i], p.size[j]) }
        case 9: if initial { size0[i] = mul(size0[i], p.size[j]) } else { size[i] = mul(size[i], p.size[j]) }
        case 10, 11:
            // 0x14023f77b / 0x14024a0fb / 0x14024abd8: only when both systems have the rotation arrays (mask & 1).
            guard def.mask & p.def.mask & 1 != 0 else { break }
            let r = rot[i], pr = p.rot[j]
            rot[i] = mode == 10 ? SIMD3(set(r.x, pr.x), set(r.y, pr.y), set(r.z, pr.z))
                                : SIMD3(add(r.x, pr.x), add(r.y, pr.y), add(r.z, pr.z))
        case 12: if def.mask & 2 != 0 && p.def.mask & 2 != 0 {
            let v = angVel[i], pv = p.angVel[j]; angVel[i] = SIMD3(set(v.x, pv.x), set(v.y, pv.y), set(v.z, pv.z)) }
        case 13: if def.mask & 2 != 0 && p.def.mask & 2 != 0 {
            let v = angVel[i], pv = p.angVel[j]; angVel[i] = SIMD3(add(v.x, pv.x), add(v.y, pv.y), add(v.z, pv.z)) }
        default: break
        }
    }

    // MARK: - Children (§7.2)

    /// `0x14022a360`: the child's matrix (+0x3a0) at parent particle `idx`, T = translate(pos[idx]), L = ChildDef transform
    /// (+0x360): same space T·L; worldspace child of a local parent (Top·T)·L; local child of a worldspace parent
    /// (inverse(Top)·T)·L (engine products 0x14005ecb0 / 0x14005f730; Top = the parent's pushed matrix). The caller pushes.
    func placeChild(_ c: ParticleInstance, at idx: Int) {
        guard let cd = c.childDef else { return }
        let T = PMat.translate(pos[idx])
        switch (c.worldSpace, worldSpace) {
        case (true, false): c.mat = PMat.mul(PMat.mul(top, T), cd.transform)
        case (false, true): c.mat = PMat.mul(PMat.mul(PMat.inverse(top), T), cd.transform)
        default: c.mat = PMat.mul(T, cd.transform)
        }
    }

    /// One event child at particle `idx` from slot `k`: the pool's last instance (reset, re-enabled, prewarmed with its own
    /// matrix pushed) or a new one (0x1402293a0, placed, overrides with the parent's flag byte 0x14022f890, then start
    /// 0x14022ebe0, which prewarms). Emission path 0x14023af5b–0x14023b161, death path 0x140237441–0x1402376a7.
    @discardableResult
    private func spawnEventChild(_ k: Int, at idx: Int) -> Bool {
        let cd = eventChildren[k].def
        let c: ParticleInstance
        if let p = eventChildren[k].pool.popLast() {
            c = p
            c.followIndex = idx
            placeChild(c, at: idx)
            c.resetEmitters()
            c.depth = depth + 1
            c.paused = paused
            c.enableEmittersRecursive()
            if c.def.startTime > 0 {
                c.updateTop()
                Self.untaped { c.prewarm() }
            }
        } else {
            guard let d = ParticleDef.load(cd.name, fs: host.resources.fs, ortho: host.ortho) else { return false }
            c = ParticleInstance(def: d, host: host, parent: self, childDef: cd)
            c.followIndex = idx
            c.linkDependencies()
            placeChild(c, at: idx)
            c.depth = depth + 1
            c.paused = paused
            c.updateTop()
            Self.untaped { c.start() }
        }
        eventChildren[k].active.append(c)
        return true
    }

    /// End of emitAndInit (0x14023ae9a–0x14023b28a), when the child mask has eventfollow/eventspawn bits: for each such
    /// slot that is not full, each particle born this call draws u (distribution A) and spawns when u ≤ probability;
    /// eventfollow bumps the particle's follow refcount; the slot stops once it is full.
    func spawnEventChildrenOnEmit() {
        guard PDump.want("kids\(def.path)") else { return spawnEventChildrenOnEmitBody() }
        pdumpKids("emitkids", list: born) { spawnEventChildrenOnEmitBody() }
    }

    /// While a "kids" dump records the parent's draws, a new child's start / prewarm draws are left out (the replay hooks
    /// those calls).
    static var kidsRecording = false
    static func untaped(_ body: () -> Void) {
        guard kidsRecording else { return body() }
        let saved = PRand.tape
        PRand.tape = nil
        body()
        PRand.tape = saved
    }

    /// PHOTON_PDUMP "deathkids" / "emitkids": the event-child state around the death handling / the emission tail, with
    /// the mt19937 draws, for scratchpad r7/particles2/emu/emu_kids.py (which runs those code ranges of the binary).
    private func pdumpKids(_ kind: String, list: [Int], _ body: () -> Void) {
        var ids: [ObjectIdentifier: Int] = [:]
        func id(_ c: ParticleInstance) -> Int {
            if let v = ids[ObjectIdentifier(c)] { return v }
            let v = ids.count; ids[ObjectIdentifier(c)] = v; return v
        }
        func kid(_ c: ParticleInstance) -> [String: Any] {
            ["id": id(c), "follow": c.followIndex, "ws": c.worldSpace, "active": c.activeEmitters, "depth": c.depth,
             "paused": c.paused, "emitters": c.emitters.map { Int($0.flags >> 31) }, "mat": PDump.mat(c.mat),
             "start": c.def.startTime.bitPattern]
        }
        func slots() -> [[String: Any]] {
            eventChildren.map { sl in
                ["kind": sl.def.kind.rawValue, "max": sl.def.maxCount, "prob": sl.def.probability.bitPattern,
                 "local": PDump.mat(sl.def.transform), "active": sl.active.map(kid), "pool": sl.pool.map(kid)]
            }
        }
        let n = min(highWater + 4, cap)
        let before: [String: Any] = ["slots": slots(), "refs": followRefs.map { [$0.key, $0.value] },
                                     "px": PDump.bits((0..<n).map { pos[$0].x }), "py": PDump.bits((0..<n).map { pos[$0].y }),
                                     "pz": PDump.bits((0..<n).map { pos[$0].z }), "top": PDump.mat(top), "ws": worldSpace,
                                     "depth": depth, "paused": paused]
        let outer = PRand.tape, wasRecording = Self.kidsRecording
        PRand.tape = []
        Self.kidsRecording = true
        body()
        Self.kidsRecording = wasRecording
        let tape = PRand.tape ?? []
        PRand.tape = outer.map { $0 + tape }
        PDump.write(["kind": kind, "def": def.path, "list": list, "before": before, "tape": tape,
                     "after": ["slots": slots(), "refs": followRefs.map { [$0.key, $0.value] }]])
    }

    private func spawnEventChildrenOnEmitBody() {
        for k in eventChildren.indices {
            let cd = eventChildren[k].def
            guard cd.kind == .eventFollow || cd.kind == .eventSpawn, eventChildren[k].active.count != cd.maxCount else { continue }
            for idx in born {
                if PRand.a() > cd.probability { continue }
                guard spawnEventChild(k, at: idx) else { return }
                if cd.kind == .eventFollow { followRefs[idx, default: 0] += 1 }
                if eventChildren[k].active.count == cd.maxCount { break }
            }
        }
    }

    /// Death handling in simulate (0x140237129–0x1402376f0), per dead index in death-list order: drop the follow
    /// refcount; stop the eventfollow children following it (followIndex −1, emitters disabled recursively, 0x14022f640);
    /// then, while the eventdeath budget (Σ maxcount − active over the eventdeath slots, taken once before the loop) is
    /// not used up, each eventdeath slot draws u and spawns when u ≤ probability; a slot that becomes full ends this
    /// death's slot loop. The child mask is not consulted here: during prewarm deaths are still recorded when the system
    /// has a rope renderer, and then eventdeath children spawn.
    func handleDeaths() {
        guard PDump.want("kids\(def.path)") else { return handleDeathsBody() }
        pdumpKids("deathkids", list: died) { handleDeathsBody() }
    }

    private func handleDeathsBody() {
        var budget = 0
        for slot in eventChildren where slot.def.kind == .eventDeath { budget += slot.def.maxCount - slot.active.count }
        for idx in died {
            if let r = followRefs[idx] {
                if r <= 1 { followRefs[idx] = nil } else { followRefs[idx] = r - 1 }
            }
            for k in eventChildren.indices where eventChildren[k].def.kind == .eventFollow {
                for c in eventChildren[k].active where c.followIndex == idx {
                    c.followIndex = -1
                    c.disableEmitters()
                }
            }
            guard budget != 0 else { continue }
            for k in eventChildren.indices where eventChildren[k].def.kind == .eventDeath {
                let cd = eventChildren[k].def
                if PRand.a() > cd.probability { continue }
                guard spawnEventChild(k, at: idx) else { return }
                budget -= 1
                if eventChildren[k].active.count == cd.maxCount { break }
            }
        }
    }
}
