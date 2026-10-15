import Foundation
import Metal
import PhotonCore
import simd

/// A 3D model object (`"model": "models/x.mdl"`, vtable 0x140491338), docs/re/06 §6.2 / §6.4.
/// Load 0x14021ad10 → per-mesh materials 0x140224c70; Update vt+0x48 = 0x14021c480; Render vt+0x50 = 0x1402222a0.
/// Skinned models share the puppet animation core: the same skeleton runtime (bind pose, inverse bind world,
/// SoA pose buffers), `animationlayers` (0x1402230c0, same keys as 0x1401fcc20) and the same layer kernels
/// (0x1401f89a0 / 0x1401f9020 / 0x1401f9820). Morph-weight tracks apply to every mesh (skeleton +0x60 records).
/// Frustum culling (session 6): bounds `+0x2f8..+0x30c` from the mdl box at load (0x140224d35), refreshed by
/// `Model_UpdateBounds` 0x140226a10 at the end of every skinned update; `Model_Render` tests their sphere against
/// C+0xec0 (main/reflection draw lists) or each shadow view's planes.
/// The `+0x120 & 0x80` perspective push (0x140222770 → 0x1401e5b60) is in `render`. Root motion (`rootmotion`,
/// 0x14021cbf8 → 0x140225900) is in RootMotion.swift (docs/re/mdl-format.md §6.4). Not implemented: the opaque-only
/// shadow-caster pass (C+0x12eb).
final class ModelObject: SceneObject, RootMotionHost {
    /// `rootmotion` (+0x310 bit 0, bool loader 0x1401e1a90, default off; also a script property).
    lazy var rootMotionEnabled: Bool = EngineValue.bool(json["rootmotion"], default: false)
    /// vt+0x80 of a model: its world matrix.
    var rootMotionWorld: simd_float4x4 { world }
    struct Part {
        let mesh: Mesh
        let material: Material
        /// Skinned mdl mesh index (morph state / morph texture); -1 for bone-less models.
        let mdlMesh: Int
        /// Mesh record +0x10: the per-mesh "morph" texture (`ModelResource_Build` 0x1401d7760).
        let morphTexture: BoundTexture?
    }

    let resources: SceneResources
    var parts: [Part] = []
    /// Animation and skinning (model +0x2d8 skeleton runtime); nil for bone-less models.
    var skeleton: Puppet?
    var mdl: MdlFile?
    /// obj +0x2e0: vertex count of the last mesh that has a morph texture; scales g_MorphOffsets (0x140222e3f).
    var morphStride = 0
    /// obj +0x2f8 / +0x304: local bounds.
    var boundsMin = SIMD3<Float>(repeating: 0)
    var boundsMax = SIMD3<Float>(repeating: 0)
    /// 0x140224cbd / 0x140225241: starts transparent (0x100); any mesh whose material blends normal or
    /// alphatocoverage clears it (and sets 0x400).
    override var isTransparent: Bool {
        !parts.isEmpty && parts.allSatisfy { $0.material.blending != .normal && $0.material.blending != .alphatocoverage }
    }

    /// Model load 0x1402252af: a mesh material with flag 1 (a declared slot named `_rt_Reflection`) sets `+0x120 |= 8`.
    override var needsReflection: Bool { parts.contains { $0.material.samplesReflection } }

    init(json: [String: Any], id: Int, resources: SceneResources) {
        self.resources = resources
        super.init(json: json, id: id)
        // `Model_Load` 0x14021ad10: a string loads a file; a number is a `createModelData` token (0x14021ae58).
        let tokenModel = (json["model"] as? NSNumber).flatMap { resources.modelData[$0.intValue] }
        guard let mdl = tokenModel ?? (json["model"] as? String).flatMap({ resources.fs.read($0) }).flatMap({ try? MdlFile(data: $0) }) else {
            NSLog("photon: model %@ missing or unreadable", "\(json["model"] ?? "")")
            return
        }
        self.mdl = mdl
        (boundsMin, boundsMax) = mdl.bounds   // 0x140224d35–0x140224d71: mdl +0x1b8..+0x1cc
        let skinned = !mdl.bones.isEmpty
        if skinned {
            skeleton = Puppet(mdl: mdl, layersJSON: (json["animationlayers"] as? [[String: Any]]) ?? [], uvScale: SIMD2(1, 1),
                              allMeshMorphs: true)
            skeleton?.rootMotionHost = self
        }
        // `skin` (0x140224cda): material variant index, clamped to the mesh's material count.
        let skin = (unwrapUserValue(json["skin"]) as? NSNumber)?.intValue ?? 0
        // BONECOUNT = min(nextpow2(max(bones, 16)), 128) (0x140224f8b–0x140224fdc).
        var boneCount = 16
        while boneCount < mdl.bones.count { boneCount <<= 1 }
        boneCount = min(boneCount, 128)
        let fmts: [Int: MTLVertexFormat] = [0: .float3, 1: .float4, 2: .float3, 3: .float3, 4: .float4, 5: .uint4, 6: .float4,
                                            7: .float2, 8: .float3, 9: .float4, 25: .float4]
        for (mi, m) in mdl.meshes.enumerated() where !m.indices.isEmpty {
            var attrs: [VertexLayout.Attribute] = []
            for (aid, off) in MdlFile.offsets(m.vertexFlags) {
                if let f = fmts[aid] { attrs.append(.init(id: aid, format: f, offset: off)) }
            }
            let floats: [Float] = m.vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let vertexCount = m.vertices.count / max(m.stride, 1)
            let mesh = Mesh(layout: VertexLayout(stride: m.stride, attributes: attrs), vertices: floats, indices: m.indices,
                            vertexCount: vertexCount)
            let names = m.materials.isEmpty ? [m.material] : m.materials
            var matPath = names[min(max(skin, 0), names.count - 1)]
            if matPath.isEmpty { matPath = "materials/util/error.json" }
            let material: Material
            var morphTex: BoundTexture?
            if !skinned {
                // Bone-less models create the mesh material straight from its path (0x140224e14 → 0x14014ff70).
                material = resources.material(matPath)
            } else {
                // 0x140224ea9–0x14022517b: SKINNING = (vflags & 0x800000) && bones, BONECOUNT, MORPHING when the
                // mesh has morph targets, MORPHING_NORMALS when mflags & 0x400.
                var combos: [String: Any] = ["SKINNING": m.vertexFlags & 0x800000 != 0 ? 1 : 0, "BONECOUNT": boneCount]
                if !m.morphTargets.isEmpty {
                    combos["MORPHING"] = 1
                    if m.flags & 0x400 != 0 { combos["MORPHING_NORMALS"] = 1 }
                    morphTex = MorphGPU.modelTexture(device: resources.device, mesh: m, vertexCount: vertexCount)
                    if morphTex != nil { morphStride = vertexCount } // 0x140225295
                }
                material = resources.material(matPath, override: ["combos": combos])
            }
            parts.append(Part(mesh: mesh, material: material, mdlMesh: skinned ? mi : -1, morphTexture: morphTex))
        }
        // 0x140225387: mesh records are sorted with comparator 0x14021a620 — normal/alphatocoverage materials
        // before blended ones; ties keep their order.
        func opaque(_ p: Part) -> Bool { p.material.blending == .normal || p.material.blending == .alphatocoverage }
        parts = parts.enumerated().sorted { a, b in
            opaque(a.element) != opaque(b.element) ? opaque(a.element) : a.offset < b.offset
        }.map { $0.element }
    }

    override func update(_ dt: Float) {
        super.update(dt)
        skeleton?.update(dt, layerWorld: world)   // Model_Update 0x14021c480 runs the same step inline (0x14021d702)
        // Model_Update returns early without a skeleton, mdl or visibility (0x14021c4b5–0x14021c4f8); otherwise it ends
        // with Model_UpdateBounds (0x140222221).
        if effectiveVisible { updateBounds() }
    }

    /// `Model_UpdateBounds` 0x140226a10: with animation layers, the union of the boxes (anim +0x54 / +0x60) of every
    /// visible layer (layer +0xd0 bit 0), valid when any of them has max.x > min.x; otherwise the mdl box.
    func updateBounds() {
        guard let mdl, let sk = skeleton else { return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var valid = false
        for l in sk.layers where l.visible {
            if l.animation.boundsMax.x > l.animation.boundsMin.x { valid = true }
            lo = simd_min(l.animation.boundsMin, lo)
            hi = simd_max(l.animation.boundsMax, hi)
        }
        if !sk.layers.isEmpty && valid {
            boundsMin = lo; boundsMax = hi
        } else {
            (boundsMin, boundsMax) = mdl.bounds
        }
    }

    /// `Model_Render` bounding sphere in world space.
    var boundingSphere: (SIMD3<Float>, Float) { Frustum.sphere(world: world, min: boundsMin, max: boundsMax) }

    /// `+0x120 & 0xc00 == 0xc00`: models start with 0x800 (`castshadow`, 0x14019018e; the JSON key sets or clears bit 11)
    /// and get 0x400 when a mesh has a normal/alphatocoverage material (0x140224cbd / 0x140225241).
    var castsShadow: Bool { castShadowFlag && parts.contains { opaquePart($0) } }
    /// Bit 11 itself (`castshadow`, script-settable through table 0x1404e8760); bit 10 stays as loaded.
    lazy var castShadowFlag: Bool = jsonBool(json["castshadow"], default: true)
    private func opaquePart(_ p: Part) -> Bool { p.material.blending == .normal || p.material.blending == .alphatocoverage }

    /// Caster pass draw (`SceneGraph_DrawList` mode 2 with `C+0x12eb = 0`: opaque meshes only; `Material_Apply`
    /// 0x140156531 swaps in `materials/util/shadowcaster.json` with the mesh's skinning/morph combos).
    func renderShadowCaster(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer, viewProjections: [Float],
                            viewports: [MTLViewport], material: ([String: Int], String, SceneRenderer) -> Material) {
        // 0x140222540–0x1402226fe: per shadow view v, the bounds sphere against that view's planes (C+0xf20 + 0x60·v,
        // 0x1401849e0 at 0x140196624); a model outside every view is skipped, otherwise the instance count is the number
        // of views it touches and the 3-bit view map (renderer vt+0x98) sends instance k to the k-th of them. Here the
        // visible views' matrices and viewports are passed in that compacted order, which draws the same.
        var viewProjections = viewProjections, viewports = viewports
        if !SceneRenderer.cullingDisabled {
            let (c, r) = boundingSphere
            var keep: [Int] = []
            for v in viewports.indices where viewProjections.count >= (v + 1) * 16 {
                var A = simd_float4x4()
                for row in 0..<4 { for col in 0..<4 { A[col][row] = viewProjections[v * 16 + row * 4 + col] } }
                if Frustum.sphereVisible(Frustum.planes(A), center: c, radius: r) { keep.append(v) }
            }
            if keep.isEmpty { return }
            if keep.count != viewports.count {
                viewProjections = keep.flatMap { v in viewProjections[(v * 16)..<(v * 16 + 16)] }
                viewports = keep.map { viewports[$0] }
            }
        }
        var u = frame.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current)
        u["g_ModelMatrix"] = .matrix(frame.model * world)
        u["g_ViewportViewProjectionMatrices"] = .floats(viewProjections)
        if let sk = skeleton { u["g_Bones"] = .bones(sk.skin) }
        for p in parts where opaquePart(p) {
            // Caster variant (Material_Apply 0x1401561c3–0x140156fbb, built once per pass mode): the program is the mesh
            // shader's `[PASS] shadow` name or `shadowcaster`; its combos are the caster shader's `[COMBO]`s with the mesh
            // program's values (0 when the program has none) plus ALPHATOCOVERAGE for alphatocoverage meshes; textures map
            // caster slot ← the first mesh slot whose sampler `material` annotation is equal (empty matches empty), and
            // annotated constants copy by material key when the kinds match (0x140156ce0–0x140156f54).
            let prog = p.material.program
            let shader = prog?.info.shadowPass.flatMap { $0.isEmpty ? nil : $0 } ?? "shadowcaster"
            let casterInfo = scene.resources.shaders.sources.info(shader: shader)
            var combos: [String: Int] = [:]
            for c in casterInfo.combos { combos[c.name] = prog?.combos[c.name] ?? 0 }
            if p.material.blending == .alphatocoverage { combos["ALPHATOCOVERAGE"] = 1 }
            let m = material(combos, shader, scene)
            var tex: [Int: BoundTexture] = [:]
            if let meshInfo = prog?.info {
                for cs in casterInfo.samplers.values.sorted(by: { $0.slot < $1.slot }) {
                    for ms in meshInfo.samplers.values.sorted(by: { $0.slot < $1.slot }) where (cs.materialKey ?? "") == (ms.materialKey ?? "") {
                        if let t = p.material.textures[ms.slot] { tex[cs.slot] = t }
                        break
                    }
                }
            }
            var pu = u
            if let meshInfo = prog?.info {
                let meshValues = p.material.materialUniforms()
                for cv in casterInfo.values.values {
                    guard let mv = meshInfo.values.values.first(where: { $0.materialKey == cv.materialKey && $0.components == cv.components
                                                                         && $0.isColor == cv.isColor }),
                          let v = meshValues[mv.name] else { continue }
                    pu[cv.name] = v
                }
            }
            if let mt = p.morphTexture, let sk = skeleton, let mdl, p.mdlMesh >= 0, p.mdlMesh < sk.morphs.count {
                // The mesh material's morph slot maps onto the caster sampler annotated "morph" (g_Texture1 in the stock
                // casters); photon2 keeps the morph texture outside the material, so it is placed here.
                tex[casterInfo.samplers.values.first(where: { $0.materialKey == "morph" })?.slot ?? 1] = mt
                for (k, v) in MorphGPU.uniforms(sk.morphs[p.mdlMesh], scale: mdl.meshes[p.mdlMesh].morphScale, stride: morphStride) {
                    pu[k] = v
                }
            }
            // The variant copies the mesh material's blending (0x140156ca7): only normal and alphatocoverage meshes draw here.
            ctx.draw(material: m, mesh: p.mesh, uniforms: pu, textures: tex, blend: BlendState(mode: p.material.blendMode),
                     instances: viewports.count, viewports: viewports, depthBias: true)
        }
    }

    override func attachmentIndex(_ name: String) -> Int { skeleton?.attachmentIndex(name) ?? -1 }
    override func attachmentTransform(_ index: Int) -> simd_float4x4? { skeleton?.attachmentTransform(index) }

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard effectiveVisible, !parts.isEmpty else { return }
        // 0x1402222db: C+0x11c bit 0 → sphere test 0x1401e5a10 against C+0xec0.
        if frame.cullFlags & 1 != 0, let planes = frame.cullPlanes {
            let (c, r) = boundingSphere
            if !Frustum.sphereVisible(planes, center: c, radius: r) { return }
        }
        // 0x140222770: `perspective` (+0x120 bit 7, scripts can set it) pushes view/projection and Camera_PushPerspective
        // 0x1401e5b60 around the draw, like Layer_Render.
        withPerspective(frame, scene) { renderParts(ctx, frame, scene) }
    }

    private func renderParts(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        let saved = frame.model
        frame.model = saved * world // push model; model = world · model (row-vector)
        var u = frame.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current)
        if let sk = skeleton {
            // 0x1402228bb: map g_bufAnimation, copy min(nextpow2(max(n,16)),128) bones (skeleton +0x48, 4×4 →
            // 4×3, renderer vt+0x140); S+0x12e8 = bone count (g_BonesAlpha length).
            u["g_Bones"] = .bones(sk.skin)
            if sk.skinningAlpha { u["g_BonesAlpha"] = .floats(sk.boneAlpha) }
        }
        for p in parts {
            var tex: [Int: BoundTexture] = [:]
            for (slot, name) in p.material.textureNames where name.hasPrefix("_rt_") {
                if let rt = scene.namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
            }
            var pu = u
            // 0x140222a75–0x140222ef8: with a morph texture, tex5 = morph, S+0x1330 = mesh scale (+0x60), then the
            // active targets of this mesh's skeleton +0x60 record → g_MorphOffsets / g_MorphWeights.
            if let mt = p.morphTexture, let sk = skeleton, let mdl, p.mdlMesh >= 0, p.mdlMesh < sk.morphs.count {
                tex[5] = mt
                for (k, v) in MorphGPU.uniforms(sk.morphs[p.mdlMesh], scale: mdl.meshes[p.mdlMesh].morphScale, stride: morphStride) {
                    pu[k] = v
                }
            }
            ctx.draw(material: p.material, mesh: p.mesh, uniforms: pu, textures: tex, blend: BlendState(mode: p.material.blendMode))
        }
        frame.model = saved
    }
}
