import Foundation
import Metal
import PhotonCore
import simd

// Renderers, vertex fill and draw (docs/re/05 Part 4). Like the engine, a system whose base material's program has a
// geometry stage (program flag 1 → def flag 0x800000, `ParticleInstance_UsesGS` 0x140229750) fills point lists, one
// vertex per element, drawn through the program's geometry shader (emulated on Metal, GeometryEmulation). Otherwise
// (PHOTON_NOGS=1) the non-GS quad path: 4 vertices per element, u16-style index list {0,1,2, 0,2,3}.

extension ParticleInstance {
    enum Layouts {
        /// Sprite, thin: pos | u v rot.z size | rot.x rot.y | color (0x34).
        static let spriteThin = VertexLayout(stride: 52, attributes: [
            .init(id: 0, format: .float3, offset: 0), .init(id: 9, format: .float4, offset: 12),
            .init(id: 13, format: .float2, offset: 28), .init(id: 25, format: .float4, offset: 36),
        ])
        /// Sprite, thick: pos | u v rot.z size | vel.xyz phase | rot.x rot.y | color (0x44).
        static let spriteThick = VertexLayout(stride: 68, attributes: [
            .init(id: 0, format: .float3, offset: 0), .init(id: 9, format: .float4, offset: 12),
            .init(id: 12, format: .float4, offset: 28), .init(id: 13, format: .float2, offset: 44),
            .init(id: 25, format: .float4, offset: 52),
        ])
        /// Rope (0x68): {1,9,12,15,18,19,25}.
        static let rope = VertexLayout(stride: 104, attributes: [
            .init(id: 1, format: .float4, offset: 0), .init(id: 9, format: .float4, offset: 16),
            .init(id: 12, format: .float4, offset: 32), .init(id: 15, format: .float4, offset: 48),
            .init(id: 18, format: .float4, offset: 64), .init(id: 19, format: .float2, offset: 80),
            .init(id: 25, format: .float4, offset: 88),
        ])
        /// Ropetrail (0x54): {1,9,12,14,16,25}.
        static let ropeTrail = VertexLayout(stride: 84, attributes: [
            .init(id: 1, format: .float4, offset: 0), .init(id: 9, format: .float4, offset: 16),
            .init(id: 12, format: .float4, offset: 32), .init(id: 14, format: .float3, offset: 48),
            .init(id: 16, format: .float2, offset: 60), .init(id: 25, format: .float4, offset: 68),
        ])

        // GS point lists (`DynamicVertexBuffer_Create` 0x140261250 mode 2, formats from 0x1401d336e–0x1401d3624): one vertex
        // per element, stepped per instance by the emulated geometry stage.
        /// Sprite, thin GS (0x2c): pos | rot.xyz size | color.
        static let spriteThinGS = VertexLayout(stride: 44, attributes: [
            .init(id: 0, format: .float3, offset: 0), .init(id: 9, format: .float4, offset: 12),
            .init(id: 25, format: .float4, offset: 28),
        ], stepPerInstance: true)
        /// Sprite, thick GS (0x3c): pos | rot.xyz size | vel.xyz phase | color.
        static let spriteThickGS = VertexLayout(stride: 60, attributes: [
            .init(id: 0, format: .float3, offset: 0), .init(id: 9, format: .float4, offset: 12),
            .init(id: 12, format: .float4, offset: 28), .init(id: 25, format: .float4, offset: 44),
        ], stepPerInstance: true)
        /// Rope GS (0x60): {1,9,12,15,18,25}.
        static let ropeGS = VertexLayout(stride: 96, attributes: [
            .init(id: 1, format: .float4, offset: 0), .init(id: 9, format: .float4, offset: 16),
            .init(id: 12, format: .float4, offset: 32), .init(id: 15, format: .float4, offset: 48),
            .init(id: 18, format: .float4, offset: 64), .init(id: 25, format: .float4, offset: 80),
        ], stepPerInstance: true)
        /// Ropetrail GS (0x4c): {1,9,12,14,25}.
        static let ropeTrailGS = VertexLayout(stride: 76, attributes: [
            .init(id: 1, format: .float4, offset: 0), .init(id: 9, format: .float4, offset: 16),
            .init(id: 12, format: .float4, offset: 32), .init(id: 14, format: .float3, offset: 48),
            .init(id: 25, format: .float4, offset: 60),
        ], stepPerInstance: true)
    }

    /// Def flag 0x800000 (set after the base material loads, docs/re/05 §5.1): the base program has a geometry stage.
    var usesGS: Bool { baseMaterial?.program?.geometry != nil }

    static var quadIndexCache: [UInt32] = []
    static let quadIndexLock = NSLock()

    static func quadIndices(_ quads: Int) -> [UInt32] {
        quadIndexLock.lock()
        defer { quadIndexLock.unlock() }
        if quadIndexCache.count < quads * 6 {
            var a = [UInt32]()
            a.reserveCapacity(quads * 6)
            for q in 0..<UInt32(max(quads, 1024)) { a += [4 * q, 4 * q + 1, 4 * q + 2, 4 * q, 4 * q + 2, 4 * q + 3] }
            quadIndexCache = a
        }
        return Array(quadIndexCache.prefix(quads * 6))
    }

    static let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)]

    var spriteSheetTexture: GPUTexture? {
        guard let g = baseMaterial?.textures[0]?.gpu, g.tex.flags.contains(.spriteSheet), !g.tex.frames.isEmpty else { return nil }
        return g
    }

    /// `0x1401d2340`: one material per renderer, loaded from the def's material path with renderer combos.
    func setupRenderers() {
        let res = host.resources
        let ropeOverride: [String: Any]? = flags & ParticleDef.Flags.ropeShader != 0 ? ["shader": "genericropeparticle"] : nil
        guard !def.material.isEmpty else { return }
        let base = res.material(def.material, override: ropeOverride)
        baseMaterial = base
        if spriteSheetTexture != nil { flags |= ParticleDef.Flags.spriteSheet }
        let sheet = flags & ParticleDef.Flags.spriteSheet != 0
        var sheetCombos: [String: Any] = [:]
        if sheet, let g = spriteSheetTexture {
            sheetCombos["SPRITESHEET"] = 1
            sheetCombos["SPRITESHEETBLEND"] = (def.flags & ParticleDef.Flags.randomFrame == 0 && !def.animationRandom) ? 1 : 0
            sheetCombos["SPRITESHEETBLENDNPOT"] = g.tex.imageWidth < g.tex.textureWidth ? 1 : 0
        }
        // TEX0FORMAT for RG88 / R8 / RG1616F / R16F textures (ConvertTexture0Format in common_fragment.h).
        var formatCombo: [String: Any] = [:]
        if let t = base.textures[0]?.gpu?.tex, (8...11).contains(t.pixelFormat.rawValue) {
            formatCombo["TEX0FORMAT"] = Int(t.pixelFormat.rawValue)
        }
        renderMaterials = def.renderers.map { r in
            var combos: [String: Any] = formatCombo
            var shader: String? = nil
            switch r.kind {
            case .sprite:
                if !sheet && formatCombo.isEmpty && r.orientation == 0 { return base }
                if sheet { combos["THICKFORMAT"] = 1 }
                combos.merge(sheetCombos) { a, _ in a }
            case .spriteTrail:
                combos.merge(sheetCombos) { a, _ in a }
                combos["THICKFORMAT"] = 1
                combos["TRAILRENDERER"] = 1
            case .rope:
                shader = "genericropeparticle"
                combos["THICKFORMAT"] = 1
                combos["TRAILSUBDIVISION"] = r.subdivision
                combos["ORIENTATION"] = r.orientation
            case .ropeTrail:
                shader = "genericropeparticle"
                combos["TRAILSUBDIVISION"] = r.subdivision
                combos["ORIENTATION"] = r.orientation
                combos["TRAILRENDERER"] = 1
                if flags & ParticleDef.Flags.ropeTrailUVScroll != 0 { combos["TRAILSCROLLALPHA"] = 1 }
                if r.fadeFlags & 1 != 0 { combos["TRAILFADEALPHA"] = 1 }
                if r.fadeFlags & 2 != 0 { combos["TRAILFADESIZE"] = 1 }
            }
            var ov: [String: Any] = ["combos": combos]
            if let s = shader { ov["shader"] = s }
            return res.material(def.material, override: ov)
        }
    }

    /// Ropetrail history (fill `0x140232c9f`): shift every `interval` seconds; the remainder is dropped.
    func updateHistory(_ dt: Float) {
        guard histSegments > 0 else { return }
        histTimer -= dt
        guard histTimer <= 0 else { return }
        histTimer = histInterval
        let S = histSegments
        for i in 0..<highWater where life[i] != 0 {
            let b = i * S
            if S > 1 { for s in stride(from: S - 1, to: 0, by: -1) { hist[b + s] = hist[b + s - 1] } }
            hist[b] = pos[i]
            histCount[i] = UInt16(min(Int(histCount[i]) + 1, S))
            if !histScroll.isEmpty { histScroll[i] = histScroll[i] &+ 1 }
        }
    }

    // MARK: - Draw (`0x1402366f0`)

    func render(_ ctx: RenderContext, _ fr: FrameState, _ scene: SceneRenderer) {
        // 0x1402366fb: without a base material (+0x358) nothing is drawn, children included.
        guard let base = baseMaterial else { return }
        if alive > 0 && !renderMaterials.isEmpty {
            let savedModel = fr.model, savedProj = fr.proj, savedEye = fr.eye, savedView = fr.view
            fr.model = worldSpace ? matrix_identity_float4x4 : top
            // JSON flag 4: the draw (0x1402366f0) pushes view and projection and calls Camera_PushPerspective 0x1401e5b60,
            // shared with `perspective` layers (SceneRenderer.pushPerspective, session 7 loader port).
            if def.flags & ParticleDef.Flags.perspective != 0 { scene.pushPerspective(fr) }
            // 0x1402367dd: a refracting base material copies the frame buffer into _rt_FullFrameBuffer once per object
            // render (obj+0x93d bit 0, cleared by the object's render 0x140236610), before any renderer of this system;
            // the systems after it in the same object (children) reuse that copy.
            if base.readsFrameBuffer && !host.frameBufferCopied {
                host.frameBufferCopied = true
                ctx.copyCurrent(into: scene.fullFrameBuffer.texture)
            }
            var spriteMesh: Mesh?
            let gs = usesGS
            for (k, r) in def.renderers.enumerated() {
                guard let m = renderMaterials[k] else { continue }
                // NaN = component not written: ParticleInstance_Draw 0x1402366f0 writes only some RenderVar0 components per
                // renderer type and the rest keep their last value (StaleBuiltins, Draw.swift; shaders2 session 7).
                var rv0 = SIMD4<Float>(repeating: .nan)
                let mesh: Mesh?
                switch r.kind {
                case .sprite, .spriteTrail:
                    if spriteMesh == nil { spriteMesh = fillSprites(gs: gs) }
                    mesh = spriteMesh
                    if r.kind == .spriteTrail { rv0 = SIMD4(r.length, r.maxLength, r.minLength, .nan) } // xyz, 0x140236a4d
                case .rope:
                    mesh = fillRope(gs: gs)
                    rv0 = SIMD4(.nan, .nan, 0, Float(alive)) // zw, 0x140236a0c
                case .ropeTrail:
                    mesh = fillRopeTrail(r, gs: gs)
                    // 0x14023695b: segments come from the render state (+0x248, the last ropetrail renderer's).
                    rv0.z = 1 - max(histTimer, 0) / histInterval
                    if flags & ParticleDef.Flags.ropeTrailUVScroll != 0 {
                        rv0.w = (Float(histSegments) - 1) * def.uvScaleInv
                        rv0.x = Float(histSegments) - 1
                    } else {
                        rv0.w = Float(histSegments) - 0.5
                    }
                }
                guard let mesh, mesh.vertexCount > 0 else { continue }
                draw(m, mesh, r, rv0, ctx, fr, scene)
            }
            fr.model = savedModel; fr.proj = savedProj; fr.eye = savedEye; fr.view = savedView
        }
        for c in staticChildren { c.render(ctx, fr, scene) }
        for s in eventChildren { for c in s.active { c.render(ctx, fr, scene) } }
    }

    private func viewRows(_ fr: FrameState) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let v = fr.view
        let r0 = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let r1 = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        let r2 = SIMD3(v.columns.0.z, v.columns.1.z, v.columns.2.z)
        return (simd_normalize(r0), simd_normalize(r1), simd_normalize(r2))
    }

    /// `0x1402298b0`: g_OrientationForward (C+0x184), Right (C+0x190), Up (C+0x19c) in particle-local space, transcribed
    /// in the binary's operation order (replayed bit-exact under the emulator, scratchpad r7/particles2/emu/emu_orient.py).
    /// `M` is the model-stack top at draw time (C+0x30); the draw has already replaced it by the base matrix C+0xaf0
    /// (identity) for worldspace systems. Engine rows m_ij = simd column i, component j.
    /// - fixed: F = axis, B = up2, each `(y·m1j + x·m0j) + z·m2j` (v·M) unless renderer flags bit 0.
    /// - upright: B = axis·M (bit 0: (0,1,0)); C = cross(g_ViewForward, B); F = cross(C, B).
    /// - screen: F = −g_ViewForward; B = (0,1,0)·M (bit 0: g_ViewUp); B −= F·dot(F, B).
    /// Then F' = M·F, B' = M·B (`(F.y·m_i1 + F.x·m_i0) + F.z·m_i2`), Right = normalize(cross(B', F')) from the
    /// unnormalised vectors, F and B normalised (1/sqrt, then multiplied).
    private func orientation(_ r: PRendererDef, _ fr: FrameState) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let t = worldSpace ? matrix_identity_float4x4 : top
        let m0 = t.columns.0, m1 = t.columns.1, m2 = t.columns.2 // engine rows 0..2
        let (_, camUp, camBack) = viewRows(fr)
        let vf = fr.viewForward ?? -camBack // g_ViewForward (C+0x160)
        let vu = camUp                       // g_ViewUp (C+0x178)
        let rotate = r.flags & 1 == 0
        @inline(__always) func vM(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((v.y * m1.x + v.x * m0.x) + v.z * m2.x, (v.y * m1.y + v.x * m0.y) + v.z * m2.y,
                  (v.y * m1.z + v.x * m0.z) + v.z * m2.z)
        }
        var F: SIMD3<Float>, B: SIMD3<Float>
        switch r.orientation {
        case 2:
            F = rotate ? vM(r.axis) : r.axis
            B = rotate ? vM(r.up2) : r.up2
        case 1:
            B = rotate ? vM(r.axis) : SIMD3(0, 1, 0)
            let C = SIMD3(vf.y * B.z - vf.z * B.y, vf.z * B.x - B.z * vf.x, B.y * vf.x - vf.y * B.x)
            F = SIMD3(C.y * B.z - C.z * B.y, C.z * B.x - B.z * C.x, B.y * C.x - C.y * B.x)
        default:
            F = SIMD3(-vf.x, -vf.y, -vf.z)
            if rotate {
                let z: Float = 0
                B = SIMD3((m1.x + m0.x * z) + m2.x * z, (m1.y * 1 + m0.y * z) + m2.y * z, (m1.z * 1 + m0.z * z) + m2.z * z)
            } else {
                B = vu
            }
            let d = (F.y * B.y + F.x * B.x) + F.z * B.z
            B = SIMD3(B.x - F.x * d, B.y - F.y * d, B.z - d * F.z)
        }
        let Fp = SIMD3((F.y * m0.y + F.x * m0.x) + F.z * m0.z, (F.y * m1.y + F.x * m1.x) + F.z * m1.z,
                       (F.y * m2.y + F.x * m2.x) + F.z * m2.z)
        let Bp = SIMD3((B.y * m0.y + B.x * m0.x) + B.z * m0.z, (B.y * m1.y + B.x * m1.x) + B.z * m1.z,
                       (B.y * m2.y + B.x * m2.x) + B.z * m2.z)
        let R = SIMD3(Bp.y * Fp.z - Bp.z * Fp.y, Bp.z * Fp.x - Fp.z * Bp.x, Fp.y * Bp.x - Bp.y * Fp.x)
        let iF = 1 / sqrtf((Fp.y * Fp.y + Fp.x * Fp.x) + Fp.z * Fp.z)
        let iR = 1 / sqrtf((R.y * R.y + R.x * R.x) + R.z * R.z)
        let iB = 1 / sqrtf((Bp.y * Bp.y + Bp.x * Bp.x) + Bp.z * Bp.z)
        return (SIMD3(iR * R.x, R.y * iR, R.z * iR), SIMD3(iB * Bp.x, Bp.y * iB, Bp.z * iB), SIMD3(iF * Fp.x, Fp.y * iF, Fp.z * iF))
    }

    private func draw(_ m: Material, _ mesh: Mesh, _ r: PRendererDef, _ rv0: SIMD4<Float>, _ ctx: RenderContext,
                      _ fr: FrameState, _ scene: SceneRenderer) {
        var tex: [Int: BoundTexture] = [:]
        for (slot, name) in m.textureNames where name.hasPrefix("_rt_") {
            if let rt = scene.namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        var u = fr.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current)
        let (right, up, fwd) = orientation(r, fr)
        if PDump.want("orient\(def.path)") {
            let t = worldSpace ? matrix_identity_float4x4 : top
            let (_, camUp, camBack) = viewRows(fr)
            let vf = fr.viewForward ?? -camBack
            PDump.write(["kind": "orient", "def": def.path, "M": PDump.mat(t), "vf": PDump.bits([vf.x, vf.y, vf.z]),
                         "vu": PDump.bits([camUp.x, camUp.y, camUp.z]), "o": r.orientation, "flags": r.flags,
                         "axis": PDump.bits([r.axis.x, r.axis.y, r.axis.z]), "up2": PDump.bits([r.up2.x, r.up2.y, r.up2.z]),
                         "out": PDump.bits([fwd.x, fwd.y, fwd.z, right.x, right.y, right.z, up.x, up.y, up.z])])
        }
        u["g_OrientationRight"] = .floats([right.x, right.y, right.z])
        u["g_OrientationUp"] = .floats([up.x, up.y, up.z])
        u["g_OrientationForward"] = .floats([fwd.x, fwd.y, fwd.z])
        let (vr, vu, _) = viewRows(fr)
        u["g_ViewRight"] = .floats([vr.x, vr.y, vr.z])
        u["g_ViewUp"] = .floats([vu.x, vu.y, vu.z])
        u["g_RenderVar0"] = .floats([rv0.x, rv0.y, rv0.z, rv0.w])
        if flags & ParticleDef.Flags.spriteSheet != 0, let g = spriteSheetTexture, let f0 = g.tex.frames.first {
            let fw = f0.xAxis.x, fh = f0.yAxis.y
            let ratio = (Float(g.tex.textureHeight) / Float(max(g.tex.textureWidth, 1))) * (fw != 0 ? fh / fw : 1)
            u["g_RenderVar1"] = .floats([fw, fh, Float(g.tex.frames.count), ratio])
        } // else RenderVar1 is not written (0x14023682e) and keeps its last value
        if PDump.path != nil && mesh.layout.stepPerInstance { Self.installGSDump(def.path, m) }
        ctx.draw(material: m, mesh: mesh, uniforms: u, textures: tex, blend: BlendState(mode: m.blendMode))
        if PDump.path != nil { RenderContext.geometryDrawObserver = nil }
    }

    /// PHOTON_PDUMP kind `gsin`: the point list, the material's shader and combos, and every uniform the emulated
    /// vertex+geometry function reads, for `photon-tool gs-check` (replays the draw with a capture buffer).
    static func installGSDump(_ defPath: String, _ m: Material) {
        RenderContext.geometryDrawObserver = { program, mesh, all in
            guard PDump.want("gsin" + defPath) else { return }
            var uniforms: [String: Any] = [:]
            for layout in program.vertexBuffers.values {
                for name in layout.members.keys {
                    switch all[name] {
                    case .floats(let f)?: uniforms[name] = ["f": PDump.bits(f)]
                    case .matrix(let x)?: uniforms[name] = ["m": PDump.mat(x)]
                    default: break
                    }
                }
            }
            PDump.write(["kind": "gsin", "def": defPath, "shader": m.shaderName, "combos": program.combos,
                         "stride": mesh.layout.stride, "count": mesh.vertexCount,
                         "attributes": mesh.layout.attributes.map { [$0.id, Int($0.format.rawValue), $0.offset] },
                         "vertices": PDump.bits(mesh.vertices), "uniforms": uniforms])
        }
    }

    // MARK: - Vertex fill (`0x1402308a0`)

    /// Sprite / spritetrail: slot order, unsorted, dead slots skipped. GS (0x14023582a–): one point per particle,
    /// `pos | rot.xyz size [| vel.xyz phase] | color`.
    func fillSprites(gs: Bool = false) -> Mesh {
        let thick = flags & (ParticleDef.Flags.spriteSheet | ParticleDef.Flags.spriteTrail) != 0
        var count = 0
        for i in 0..<highWater where life[i] != 0 { count += 1 }
        // Without def mask & 1 the rotation y/z arrays alias x (0x1401d39da), so the vertex carries the one rotation
        // value in all three slots (a remapvalue → rotation without rotationrandom tumbles the sprite in 3-D).
        let aliasRot = def.mask & 1 == 0
        if gs {
            let per = thick ? 15 : 11
            var v = [Float](repeating: 0, count: count * per)
            v.withUnsafeMutableBufferPointer { b in
                var o = 0
                for i in 0..<highWater where life[i] != 0 {
                    let p = pos[i], c = color[i], w = vel[i]
                    let r = aliasRot ? SIMD3(repeating: rot[i].z) : rot[i]
                    b[o] = p.x; b[o + 1] = p.y; b[o + 2] = p.z; b[o + 3] = r.x; b[o + 4] = r.y; b[o + 5] = r.z; b[o + 6] = size[i]
                    o += 7
                    if thick { b[o] = w.x; b[o + 1] = w.y; b[o + 2] = w.z; b[o + 3] = phase[i]; o += 4 }
                    b[o] = c.x; b[o + 1] = c.y; b[o + 2] = c.z; b[o + 3] = c.w
                    o += 4
                }
            }
            return Mesh(layout: thick ? Layouts.spriteThickGS : Layouts.spriteThinGS, vertices: v, vertexCount: count)
        }
        let per = thick ? 17 : 13
        var v = [Float](repeating: 0, count: count * 4 * per)
        v.withUnsafeMutableBufferPointer { b in
            var o = 0
            for i in 0..<highWater where life[i] != 0 {
                let p = pos[i], c = color[i], s = size[i], w = vel[i], ph = phase[i]
                let r = aliasRot ? SIMD3(repeating: rot[i].z) : rot[i]
                for uv in Self.corners {
                    b[o] = p.x; b[o + 1] = p.y; b[o + 2] = p.z; b[o + 3] = uv.x; b[o + 4] = uv.y; b[o + 5] = r.z; b[o + 6] = s
                    o += 7
                    if thick { b[o] = w.x; b[o + 1] = w.y; b[o + 2] = w.z; b[o + 3] = ph; o += 4 }
                    b[o] = r.x; b[o + 1] = r.y; b[o + 2] = c.x; b[o + 3] = c.y; b[o + 4] = c.z; b[o + 5] = c.w
                    o += 6
                }
            }
        }
        return Mesh(layout: thick ? Layouts.spriteThick : Layouts.spriteThin, vertices: v, indices: Self.quadIndices(count),
                    vertexCount: count * 4)
    }

    /// Rope: consecutive particles in spawn order form segments (Part 4 §5.4). GS (0x60): one point per segment, the
    /// non-GS vertex without its uv.
    func fillRope(gs: Bool = false) -> Mesh? {
        let list = order.filter { life[$0] != 0 }
        guard list.count > 1 else { return nil }
        let ov = host.override
        let rate = def.ropeRate * ov.count, lifeAvg = def.ropeLife * ov.lifetime
        let fpsLimit = Float(SceneRenderer.fpsSetting) // C+0x148 = the fps setting (W+0x18c)
        let nRate = rate * lifeAvg > Float(alive) ? min(fpsLimit, rate) : rate
        let est = nRate * lifeAvg
        var L: Float, P0: Float
        if flags & ParticleDef.Flags.ropeUVScroll != 0 {
            L = est - 1; P0 = Float(deaths)
        } else if est > 0 && Float(alive) >= est - 1 && flags & ParticleDef.Flags.ropeUVSmooth != 0 {
            // 0x140230a52: (life − age[first]) / (1 / n), not · n (the last bit differs).
            P0 = clamp01((lifeAvg - age[list[0]]) / (1 / nRate)) - 1
            L = est - 1
        } else {
            L = Float(alive); P0 = 0
        }
        L *= def.uvScaleInv
        var v = [Float]()
        let segs = list.count - 1
        v.reserveCapacity(segs * 4 * 26)
        for j in 0..<segs {
            let a = list[j], b = list[j + 1]
            let c0 = list[max(j - 1, 0)], c1 = list[min(j + 2, list.count - 1)]
            let pa = pos[a], pb = pos[b], pc0 = pos[c0], pc1 = pos[c1]
            let ca = color[a], cb = color[b]
            if gs {
                v += [pa.x, pa.y, pa.z, size[a], pb.x, pb.y, pb.z, L, pc0.x, pc0.y, pc0.z, Float(j) + P0,
                      pc1.x, pc1.y, pc1.z, size[b], cb.x, cb.y, cb.z, cb.w, ca.x, ca.y, ca.z, ca.w]
                continue
            }
            for uv in Self.corners {
                v += [pa.x, pa.y, pa.z, size[a], pb.x, pb.y, pb.z, L, pc0.x, pc0.y, pc0.z, Float(j) + P0,
                      pc1.x, pc1.y, pc1.z, size[b], cb.x, cb.y, cb.z, cb.w, uv.x, uv.y, ca.x, ca.y, ca.z, ca.w]
            }
        }
        if gs { return Mesh(layout: Layouts.ropeGS, vertices: v, vertexCount: segs) }
        return Mesh(layout: Layouts.rope, vertices: v, indices: Self.quadIndices(segs), vertexCount: segs * 4)
    }

    /// Ropetrail: each live particle emits `segments` elements from its position history. GS (0x4c): one point per
    /// element, the non-GS vertex without its uv.
    func fillRopeTrail(_ r: PRendererDef, gs: Bool = false) -> Mesh? {
        let S = histSegments
        guard S > 0 else { return nil }
        let scroll = flags & ParticleDef.Flags.ropeTrailUVScroll != 0
        var v = [Float]()
        v.reserveCapacity(alive * S * 4 * 21)
        var count = 0
        for i in 0..<highWater where life[i] != 0 {
            let b = i * S
            let c = color[i], s = size[i]
            let W0 = Float(histCount[i]) * def.uvScaleInv
            for k in 0..<max(S, 1) {
                let A = k == 0 ? pos[i] : hist[b + k - 1]
                let B = hist[b + k]
                let CP0 = k <= 1 ? pos[i] : hist[b + k - 2]
                let CP1 = k + 1 < S ? hist[b + k + 1] : B
                var W = W0, T = Float(k)
                if scroll {
                    // 0x140233a6a: the u16 scroll counter is negated (cvtdq2ps of −n); element 0 gets −n, element k ≥ 1
                    // gets (float(k − 1) + (−n)) + 1.
                    let negScroll = Float(-Int32(histScroll.isEmpty ? 0 : histScroll[i]))
                    W = Float(k)
                    T = k == 0 ? negScroll : (Float(k - 1) + negScroll) + 1
                }
                if gs {
                    v += [A.x, A.y, A.z, s, B.x, B.y, B.z, W, CP0.x, CP0.y, CP0.z, T, CP1.x, CP1.y, CP1.z, c.x, c.y, c.z, c.w]
                } else {
                    for uv in Self.corners {
                        v += [A.x, A.y, A.z, s, B.x, B.y, B.z, W, CP0.x, CP0.y, CP0.z, T, CP1.x, CP1.y, CP1.z,
                              uv.x, uv.y, c.x, c.y, c.z, c.w]
                    }
                }
                count += 1
            }
        }
        if gs { return Mesh(layout: Layouts.ropeTrailGS, vertices: v, vertexCount: count) }
        return Mesh(layout: Layouts.ropeTrail, vertices: v, indices: Self.quadIndices(count), vertexCount: count * 4)
    }
}

// MARK: - Fill replay dumps (PHOTON_PDUMP kind "fill")

extension ParticleInstance {
    /// The state `ParticleInstance_FillVertexBuffers` 0x1402308a0 reads after simulate (before the ropetrail history
    /// step): replayed under the emulator by scratchpad `r7/particles2/emu/emu_fill.py`.
    func pdumpFillState(_ dt: Float) -> [String: Any] {
        var d = pdumpState(cap)
        d["kind"] = "fill"; d["def"] = def.path; d["dt"] = dt.bitPattern
        d["flags"] = Int(flags); d["uvscaleinv"] = def.uvScaleInv.bitPattern
        d["ropelife"] = def.ropeLife.bitPattern; d["roperate"] = def.ropeRate.bitPattern
        d["ovcount"] = host.override.count.bitPattern; d["ovlifetime"] = host.override.lifetime.bitPattern
        d["fps"] = SceneRenderer.fpsSetting; d["deaths"] = deaths; d["order"] = order
        d["segments"] = histSegments; d["histtimer"] = histTimer.bitPattern; d["histinterval"] = histInterval.bitPattern
        d["hist"] = PDump.bits(hist.flatMap { [$0.x, $0.y, $0.z] }); d["histcount"] = histCount.map { Int($0) }
        d["histscroll"] = histScroll.map { Int($0) }
        d["renderers"] = def.renderers.map { r in
            ["kind": r.kind.rawValue, "length": r.length.bitPattern, "segments": r.segments, "subdivision": r.subdivision]
        }
        return d
    }

    func pdumpFillWrite(_ before: [String: Any]) {
        var d = before
        if alive > 0 {
            var out: [String: Any] = [:]
            for r in def.renderers {
                switch r.kind {
                case .sprite, .spriteTrail: out["sprite"] = PDump.bits(fillSprites().vertices)
                case .rope: out["rope"] = PDump.bits(fillRope()?.vertices ?? [])
                case .ropeTrail: out["ropetrail"] = PDump.bits(fillRopeTrail(r)?.vertices ?? [])
                }
            }
            d["out"] = out
        }
        d["after"] = ["hist": PDump.bits(hist.flatMap { [$0.x, $0.y, $0.z] }), "histcount": histCount.map { Int($0) },
                      "histscroll": histScroll.map { Int($0) }, "histtimer": histTimer.bitPattern]
        PDump.write(d)
    }
}
