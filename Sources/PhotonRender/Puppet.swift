import Foundation
import Metal
import PhotonCore
import simd

/// A puppet-warped image: the `.mdl` mesh replaces the image quad and is skinned on the GPU
/// (docs/re/06 §2–§3).
final class Puppet {
    struct Layer {
        let animation: MdlFile.Animation
        var rate: Float
        var blend: Float
        var visible: Bool
        var additive: Bool
        var blendIn: Bool
        var blendOut: Bool
        var blendTime: Float
        /// Index in the layer's `animationlayers` JSON array; SceneScript play/pause state.
        var jsonIndex = -1
        var paused = false
        // Timeline (0x1401a8c10)
        var time: Float = 0
        var backwards = false
        var finished = false
        /// Timeline flag 0x8000000 (playSingleAnimation): removed after the update in which it ends (0x14020035d).
        var singleShot = false
        /// Layer `name` (+0xd8, reflection table 0x14026c980): the `animationlayers` element's name; SceneScript
        /// getAnimationLayer / destroyAnimationLayer match it. Without one, the animation's name (Inferred).
        var name = ""
        /// `Timeline_Init` 0x1401a8c10 values (fps ≤ 0 or no frames: frameTime 1, duration 0, loop).
        /// Root-motion state (model layers): layer +0xd0 bit 31 (applied on the previous update), +0x148 (timeline time
        /// after that update) and +0x14c (the root bone's model matrix then, row-major row-vector).
        var rootActive = false
        var rootPrevTime: Float = 0
        var rootPrev = [Float](repeating: 0, count: 16)
        var duration: Float { animation.duration }
        var frameTime: Float { animation.frameTime }
        var mode: MdlFile.Animation.Mode { animation.timelineMode }
    }

    struct Pose { var p: SIMD3<Float>; var q: simd_quatf; var s: SIMD3<Float> }

    let mdl: MdlFile
    /// Mesh for the direct path: UVs scaled into the padded texture.
    private(set) var mesh: Mesh
    /// Mesh for the compose step: raw mdl UVs, sampling the image-sized composite.
    private(set) var rawMesh: Mesh
    /// `MdlMesh_BuildDualVertex` 0x140266fa0 result (P+0x400), drawn by the prelit pass.
    let dualMesh: Mesh
    /// Animated section draw order (mesh 0 `mflags & 8`): puppet +0x280 (per-slot values, reset each frame to
    /// float(+0x1f0[i]) at 0x1401fec30), and the section list +0x298 in its current draw order.
    private var orderSlots: [Float] = []
    private var sectionOrder: [Int] = []
    private var sectionKeys: [Int] = []
    var layers: [Layer] = []
    /// Animation-event JSON crossed since the last read (SceneScript animationEvent).
    var firedEvents: [String] = []
    /// `animationlayers` indices of layers that ended since the last read (SceneScript addEndedCallback).
    var endedLayers: [Int] = []
    let bindLocal: [Pose]
    let inverseBindWorld: [simd_float4x4]
    /// Also written by SceneScript setBoneTransform (0x14020f350).
    var skin: [simd_float4x4]
    /// Animated bone world matrices in model space (puppet +0x2c8), for attachments.
    var boneWorld: [simd_float4x4]
    /// P+0x310: local bone matrices of the last pose (written in the puppet update's bone loop, 0x140200b4a / 0x14020087e;
    /// read and written by the script local-bone methods 0x14020f6b0 … 0x140210250).
    var boneLocal: [simd_float4x4] = []
    /// Puppet +0x268, `g_BonesAlpha`: one float per bone when mesh 0 has `mflags & 4` (`SKINNING_ALPHA`), else
    /// empty. Reset to 1.0 every frame before the layers run (0x1401febcd–0x1401fec10).
    private(set) var boneAlpha: [Float]
    /// Puppet +0x350: 16 animated floats copied to `g_BlendMap` for the texture-channel mesh.
    private(set) var blendMap = [Float](repeating: 0, count: 16)
    /// Texture-channel (blend-map) mesh: the first mdl mesh with `mflags & 2` (puppet +0x390 / +0x3f8,
    /// `Image_LoadModel` 0x1401fbf10), drawn raw with its own material (`puppettexturechannels`).
    let channelMesh: Mesh?
    let channelMaterialPath: String?
    let blendRowCount: Int
    var skinningAlpha: Bool { !boneAlpha.isEmpty }
    /// Morph weights per mesh (puppet +0x3a0 / +0x398 for mesh 0; model skeleton +0x60 records, one per mesh).
    /// Settable by SceneScript setBlendShapeWeight (0x1402105c0 writes P+0x3a0 / P+0x398 directly).
    var morphs: [MorphState]
    /// Puppets read only mesh 0's morph tracks (`Puppet_Update` 0x1401ff0d9: record 0); models read every mesh.
    let morphMeshCount: Int
    /// The skeleton of a model object (`Model_Update` 0x14021c480) rather than an image puppet (`Puppet_Update` 0x1401fdf90).
    let isModel: Bool
    /// Root motion (RootMotion.swift): the owning model object, and the reference-record matrices per animation id.
    weak var rootMotionHost: RootMotionHost?
    var rootRefCache: [UInt64: (A: [Float], Ainv: [Float], B: [Float])] = [:]
    /// Bone physics parameters (bone +0x68, nil when the bone has none) and per-bone state (puppet +0x3b8).
    let physics: [BonePhysics?]
    private var physicsState: [BonePhysics.State]
    /// Puppet +0x348: last frame's +0x340 (bone world × layer world), swapped in at 0x1402003f0. nil on the first frame,
    /// which skips the physics step (0x140201387).
    private var previousLayerSpace: [simd_float4x4]?
    /// Puppet +0x340 / +0x348 for other subsystems (particles' layerimage puppet velocity, docs/re/unknowns.md P27):
    /// `boneLayerSpace[i]` = bone world × layer world (vt+0x80) of the last `update`, written per bone after the bone's
    /// constraints and physics and before any IK chain step (0x1402011cb, 0x140202a25), so IK never shows in it;
    /// `boneLayerSpacePrevious` = the same array from the update before (the +0x340/+0x348 swap at 0x1402003f0 runs on
    /// every Puppet_Update call). Both are empty until an update with a layer world ran; an update without one (the
    /// load-time `update(0)`) leaves the pair untouched, and frames on which the layer is not updated leave it stale,
    /// as in the engine.
    var boneLayerSpace: [simd_float4x4] { previousLayerSpaceCurrent }
    var boneLayerSpacePrevious: [simd_float4x4] { previousLayerSpace ?? [] }
    private var previousLayerSpaceCurrent: [simd_float4x4] = []
    static let debugNoPhysics = ProcessInfo.processInfo.environment["PHOTON_NOPHYSICS"] != nil
    /// IK chains, handles and constraints (PuppetIK.swift); nil when the mdl has none.
    let ik: PuppetIK?
    /// Handle bind pose (P+0x240, decomposed handle matrices) and the animated handle pose (P+0x248).
    let handleBind: [Pose]
    private var handlePose: [Pose]
    /// Scene gravity / wind / time for rope chains (C+0x1510); set by the owning layer before `update`.
    var ikEnvironment = PuppetIK.Environment()
    /// True when a chain has a rope link, i.e. the scene callbacks are read.
    var ikUsesScene: Bool { ik?.chains.contains { $0.flags & 1 != 0 } ?? false }

    init?(mdl: MdlFile, layersJSON: [[String: Any]], uvScale: SIMD2<Float>, allMeshMorphs: Bool = false) {
        guard let m = mdl.meshes.first, !mdl.bones.isEmpty else { return nil }
        self.mdl = mdl
        morphMeshCount = allMeshMorphs ? mdl.meshes.count : 1
        isModel = allMeshMorphs
        morphs = mdl.meshes.prefix(morphMeshCount).map { MorphState(count: $0.morphTargets.count) }
        // Vertex layout straight from the file's vflags, attribute ids = engine table indices.
        var attrs: [VertexLayout.Attribute] = []
        let fmts: [Int: MTLVertexFormat] = [0: .float3, 1: .float4, 2: .float3, 3: .float3, 4: .float4, 5: .uint4, 6: .float4,
                                            7: .float2, 8: .float3, 9: .float4, 25: .float4]
        for (id, off) in MdlFile.offsets(m.vertexFlags) {
            if let f = fmts[id] { attrs.append(.init(id: id, format: f, offset: off)) }
        }
        var floats: [Float] = m.vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        rawMesh = Mesh(layout: VertexLayout(stride: m.stride, attributes: attrs), vertices: floats, indices: m.indices,
                       vertexCount: m.vertices.count / max(m.stride, 1))
        // MDL uvs are in image space; padded textures need the image/texture ratio (as the image quad does).
        if let uvOff = MdlFile.offsets(m.vertexFlags)[7], uvScale != SIMD2(1, 1) {
            let strideF = m.stride / 4, o = uvOff / 4
            var i = 0
            while i + o + 1 < floats.count {
                floats[i + o] *= uvScale.x; floats[i + o + 1] *= uvScale.y
                i += strideF
            }
        }
        mesh = Mesh(layout: VertexLayout(stride: m.stride, attributes: attrs), vertices: floats, indices: m.indices,
                    vertexCount: m.vertices.count / max(m.stride, 1))
        // P+0x400 (0x14020a46c): the dual-vertex mesh of lit (prelit) puppets, raw UVs plus `a_PositionC1`.
        let dv = m.dualVertex()
        var dAttrs: [VertexLayout.Attribute] = []
        for (id, off) in MdlFile.offsets(dv.vertexFlags) {
            if let f = fmts[id] { dAttrs.append(.init(id: id, format: f, offset: off)) }
        }
        dualMesh = Mesh(layout: VertexLayout(stride: dv.stride, attributes: dAttrs),
                        vertices: dv.vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, indices: m.indices,
                        vertexCount: dv.vertices.count / max(dv.stride, 1))
        boneAlpha = m.flags & 4 != 0 ? [Float](repeating: 0, count: mdl.bones.count) : []
        if let tc = mdl.meshes.first(where: { $0.flags & 2 != 0 }) {
            var tcAttrs: [VertexLayout.Attribute] = []
            for (id, off) in MdlFile.offsets(tc.vertexFlags) {
                if let f = fmts[id] { tcAttrs.append(.init(id: id, format: f, offset: off)) }
            }
            let v: [Float] = tc.vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            channelMesh = Mesh(layout: VertexLayout(stride: tc.stride, attributes: tcAttrs), vertices: v, indices: tc.indices,
                               vertexCount: tc.vertices.count / max(tc.stride, 1))
            channelMaterialPath = tc.material
            blendRowCount = Int(tc.blendRowCount)
        } else {
            channelMesh = nil
            channelMaterialPath = nil
            blendRowCount = 0
        }

        // Bind pose: world[i] = local[i] × world[parent] (row-vector); here W = Wparent · L.
        var bindWorld: [simd_float4x4] = []
        var locals: [Pose] = []
        for b in mdl.bones {
            let L = Self.matrix(rowMajorRowVector: b.localBind)
            locals.append(Self.decompose(L))
            bindWorld.append(b.parent >= 0 && b.parent < bindWorld.count ? bindWorld[b.parent] * L : L)
        }
        bindLocal = locals
        inverseBindWorld = bindWorld.map { $0.inverse }
        skin = Array(repeating: matrix_identity_float4x4, count: mdl.bones.count)
        // Puppet +0x2c8 starts at the bind world and persists across frames (bones with flags bit 1 keep it).
        boneWorld = bindWorld
        boneLocal = mdl.bones.map { Self.matrix(rowMajorRowVector: $0.localBind) }
        handleBind = mdl.handles.enumerated().map { i, h in
            Self.decompose(Self.matrix(rowMajorRowVector: i < mdl.bindOverrideHandles.count ? mdl.bindOverrideHandles[i] : h.matrix))
        }
        handlePose = handleBind
        if !mdl.ikChains.isEmpty || !mdl.handles.isEmpty || mdl.boneConstraints.contains(where: { !$0.isEmpty }) {
            ik = PuppetIK(mdl: mdl, bindWorld: bindWorld.map(PuppetIK.rows))
        } else {
            ik = nil
        }
        physics = mdl.bones.map { BonePhysics(json: $0.physicsJSON) }
        physicsState = Array(repeating: BonePhysics.State(), count: mdl.bones.count)

        for (li, l) in layersJSON.enumerated() { addLayer(l, jsonIndex: li) }
        // Sections are built when mesh 0 has mflags & 8 or clip groups (`Puppet_BuildGeometry` 0x14020b3e0).
        if (m.flags & 8 != 0 || !m.clipGroups.isEmpty) && !m.sections.isEmpty {
            orderSlots = [Float](repeating: 0, count: mdl.drawOrderBase.count)
            sectionOrder = Array(m.sections.indices)
            sectionKeys = [Int](repeating: 0, count: m.sections.count)
        }
        buildClipCommands()
        update(0)
    }

    /// SceneScript `applyBonePhysicsImpulse(bone, linear, angularDegrees)` 0x140210990: the bone's physics state
    /// (P+0x3b8, 0x50-byte records) gets translation velocity += linear and angular velocity q = q · Euler(angular),
    /// the Euler quaternion built from half angles in radians (w = cx·cy·cz + sx·sy·sz, x = sx·cy·cz − cx·sy·sz,
    /// y = cx·sy·cz + sx·cy·sz, z = cx·cy·sz − sx·sy·cz; product 0x140215380).
    func applyPhysicsImpulse(_ b: Int, linear: SIMD3<Float>, angularDegrees a: SIMD3<Float>) {
        guard b >= 0, b < physicsState.count else { return }
        physicsState[b].w += linear
        let h = a * 0.0174533 * 0.5
        let cz = cosf(h.z), cy = cosf(h.y), cx = cosf(h.x), sz = sinf(h.z), sy = sinf(h.y), sx = sinf(h.x)
        let dq = simd_quatf(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                            iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
        physicsState[b].q = physicsState[b].q * dq
    }

    /// SceneScript `resetBonePhysicsSimulation(bone)` 0x140210e10: the record becomes identity rotation, zeros.
    func resetPhysics(_ b: Int) {
        guard b >= 0, b < physicsState.count else { return }
        physicsState[b] = BonePhysics.State()
    }

    /// `AnimLayer_Create` 0x1401fcc20 for one `animationlayers` element (also SceneScript createAnimationLayer /
    /// playSingleAnimation). Returns false when the animation id is unknown.
    @discardableResult
    func addLayer(_ l: [String: Any], jsonIndex: Int) -> Bool {
        guard let animID = (l["animation"] as? NSNumber)?.uint64Value,
              let anim = mdl.animations.first(where: { $0.id == animID }) else { return false }
        var layer = Layer(animation: anim,
                          rate: jsonFloats(l["rate"]).first ?? 1,
                          blend: jsonFloats(l["blend"]).first ?? 1,
                          visible: jsonBool(l["visible"], default: true),
                          additive: jsonBool(l["additive"], default: false),
                          blendIn: jsonBool(l["blendin"], default: false),
                          // 0x1401fd068: the blend-out flag is cleared unless the animation plays "single".
                          blendOut: jsonBool(l["blendout"], default: false) && anim.timelineMode == .single,
                          blendTime: jsonFloats(l["blendtime"]).first ?? 0.5)
        layer.jsonIndex = jsonIndex
        layer.name = (l["name"] as? String) ?? anim.name
        // `AnimLayer_Create` 0x1401fd078–0x1401fd2e9 (model twin 0x1402230c0): `autosort` (JSON bool true) inserts the
        // layer after the last non-additive layer (before the trailing additive run); else a numeric `index`
        // inserts at min(index, count − 1) (0 when that is 0); else the layer is appended.
        if let a = l["autosort"] as? NSNumber, CFGetTypeID(a) == CFBooleanGetTypeID(), a.boolValue {
            var pos = layers.count
            while pos > 0 && layers[pos - 1].additive { pos -= 1 }
            layers.insert(layer, at: pos)
        } else if let n = l["index"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let last = layers.count - 1
            let i = n.intValue
            let pos = (last < 0 || min(i, last) <= 0) ? 0 : (i > last ? last : i)
            layers.insert(layer, at: min(max(pos, 0), layers.count))
        } else {
            layers.append(layer)
        }
        return true
    }

    /// Section re-sort after the layers (`Puppet_Update` 0x140205507–0x140205668), when any layer wrote +0x280:
    /// order = (int)(float(base[slot] + orderOffset) + +0x280[slot]); if the list is not sorted ascending (0x1401fac30),
    /// stable-sort it and rewrite the mesh's index buffer section by section in the new order (0x1402055d8–0x140205662).
    private func resortSections() {
        guard let m0 = mdl.meshes.first else { return }
        for (i, sec) in m0.sections.enumerated() {
            let base = sec.slot < mdl.drawOrderBase.count ? mdl.drawOrderBase[sec.slot] : 0
            let slotValue = sec.slot < orderSlots.count ? orderSlots[sec.slot] : 0
            sectionKeys[i] = Int(Float(base &+ sec.orderOffset) + slotValue)
        }
        let isSorted = zip(sectionOrder, sectionOrder.dropFirst()).allSatisfy { !(sectionKeys[$1] < sectionKeys[$0]) }
        guard !isSorted else { return }
        sectionOrder = sectionOrder.enumerated().sorted {
            sectionKeys[$0.element] != sectionKeys[$1.element] ? sectionKeys[$0.element] < sectionKeys[$1.element] : $0.offset < $1.offset
        }.map(\.element)
        var idx: [UInt32] = []
        idx.reserveCapacity(m0.indices.count)
        for i in sectionOrder {
            let sec = m0.sections[i]
            guard sec.first >= 0, sec.first + sec.count <= m0.indices.count else { continue }
            idx.append(contentsOf: m0.indices[sec.first..<(sec.first + sec.count)])
        }
        mesh.indices = idx
        rawMesh.indices = idx
        buildClipCommands()
    }

    // MARK: - Clip groups (docs/re/06 §2.1.6)

    /// The clip command list (puppet +0x430) and the runtime draw sections it refers to (mesh vt+0x30/+0x50 index
    /// ranges filled by 0x14020c710). Nil when mesh 0 has no clip groups.
    struct ClipProgram {
        var commands: [Int] = []
        var sections: [[UInt32]] = []
    }
    private(set) var clip: ClipProgram?

    /// `Puppet_BuildClipCommands` 0x14020b720. Positions are indices into the current section order (+0x298); clip
    /// lists hold file section indices (record +0x14).
    private func buildClipCommands() {
        guard let m0 = mdl.meshes.first, !m0.clipGroups.isEmpty, !sectionOrder.isEmpty else { clip = nil; return }
        let groups = m0.clipGroups
        let n = sectionOrder.count
        // Section flags (0x14020b5c0–0x14020b660): 1 = in some group's a list, 8 = in some b list, 4 = in the a list
        // of a group with flags & 8.
        var fileFlags = [UInt32](repeating: 0, count: m0.sections.count)
        for g in groups {
            for x in g.a { fileFlags[x] |= 1 }
            for x in g.b { fileFlags[x] |= 8 }
            if g.flags & 8 != 0 { for x in g.a { fileFlags[x] |= 4 } }
        }
        func flags(_ pos: Int) -> UInt32 { fileFlags[sectionOrder[pos]] }

        // Per-group records (0x40 bytes, defaults 0x140218fd0: minA = INT_MAX, firstB = lastB = −1).
        struct G { var idx: Int; var minA = Int.max; var firstB = -1; var lastB = -1; var mask: [Int] = []; var a: [Int] = [] }
        var recs = groups.indices.map { G(idx: $0) }
        var aGroup: [Int: Int] = [:]          // rbp−0x60: position → group (a lists)
        var hiddenB = Set<Int>()               // rbp+0x50: b positions of groups with flags & 4
        for g in groups.indices {
            for i in 0..<n {
                let file = sectionOrder[i]
                if flags(i) & 1 != 0, groups[g].a.contains(file) {
                    recs[g].a.append(i); recs[g].minA = min(recs[g].minA, i); aGroup[i] = g
                }
                if groups[g].b.contains(file) {
                    if recs[g].firstB < 0 { recs[g].firstB = i }
                    recs[g].lastB = i
                    if groups[g].flags & 4 != 0 { hiddenB.insert(i) }
                }
            }
            // Mask = every position in [firstB, lastB] that is not in the a list (0x14020baa0–0x14020bbe7).
            for i in 0..<n where recs[g].firstB <= i && recs[g].lastB >= i && !recs[g].a.contains(i) { recs[g].mask.append(i) }
        }
        // lastB = max over the parent chain (0x14020bc40–0x14020bca6), then a stable sort by minA (0x1401fac40).
        for g in groups.indices {
            var p = groups[g].parent
            while p != -1 { recs[g].lastB = max(recs[g].lastB, recs[p].lastB); p = groups[p].parent }
        }
        let sorted = recs.enumerated().sorted { $0.element.minA != $1.element.minA ? $0.element.minA < $1.element.minA : $0.offset < $1.offset }.map(\.element)

        var out = ClipProgram()
        var plain: [Int] = []
        var maskSection: [Int: Int] = [:]      // rbp+0xe0
        func emit(_ positions: [Int]) -> Int {   // 0x14020c710
            var idx: [UInt32] = []
            for pos in positions {
                let sec = m0.sections[sectionOrder[pos]]
                guard sec.first >= 0, sec.first + sec.count <= m0.indices.count else { continue }
                idx.append(contentsOf: m0.indices[sec.first..<(sec.first + sec.count)])
            }
            out.sections.append(idx)
            return out.sections.count - 1
        }
        func flush() {                           // 0x14020c850: plain run → op 0
            guard !plain.isEmpty else { return }
            _ = emit(plain); out.commands.append(0); plain.removeAll()
        }
        func emitGroup(_ g: Int, _ rec: G, _ list: [Int]) {   // 0x14020cab0
            var parents: [Int] = []
            var p = groups[g].parent
            while p != -1 { parents.append(p); p = groups[p].parent }
            maskSection[g] = emit(rec.mask)
            _ = emit(list)
            if parents.isEmpty {
                out.commands += [1, g]
            } else {
                out.commands += [2, parents.count]
                for p in parents { out.commands += [p, maskSection[p] ?? 0] }
                out.commands.append(g)
            }
        }
        for i in 0..<n {
            let f = flags(i)
            if f & 1 != 0 {
                if f & 0xc == 0 { continue }
            } else if f & 4 == 0 && !hiddenB.contains(i) {
                plain.append(i)
            }
            if f & 8 != 0 {
                for rec in sorted where groups[rec.idx].flags & 8 == 0 && rec.lastB == i {
                    flush(); emitGroup(rec.idx, rec, rec.a)
                }
            } else if f & 4 != 0, let g = aGroup[i] {
                var run = [i]
                var j = i + 1
                while j < n, aGroup[j] == g { run.append(j); j += 1 }
                if let rec = sorted.first(where: { $0.idx == g }) { flush(); emitGroup(g, rec, run) }
            }
        }
        flush()
        clip = out
        if ProcessInfo.processInfo.environment["PHOTON_CLIPLOG"] != nil { NSLog("photon: clip commands %@ sections %@", out.commands.description, out.sections.map(\.count).description) }
    }

    static func matrix(rowMajorRowVector m: [Float]) -> simd_float4x4 {
        // Row j of the row-vector matrix is column j of the column-vector form.
        simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
    }

    static func decompose(_ M: simd_float4x4) -> Pose {
        let c0 = SIMD3(M.columns.0.x, M.columns.0.y, M.columns.0.z)
        let c1 = SIMD3(M.columns.1.x, M.columns.1.y, M.columns.1.z)
        let c2 = SIMD3(M.columns.2.x, M.columns.2.y, M.columns.2.z)
        let s = SIMD3(simd_length(c0), simd_length(c1), simd_length(c2))
        let r = simd_float3x3(c0 / max(s.x, 1e-8), c1 / max(s.y, 1e-8), c2 / max(s.z, 1e-8))
        return Pose(p: SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z), q: simd_quatf(r), s: s)
    }

    /// Euler → quaternion as at 0x1402641af: q = qZ·qY·qX (X applied first).
    static func quat(_ e: SIMD3<Float>) -> simd_quatf {
        let h = e * 0.5
        let cx = cos(h.x), sx = sin(h.x), cy = cos(h.y), sy = sin(h.y), cz = cos(h.z), sz = sin(h.z)
        return simd_quatf(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
    }

    /// `Timeline_Advance` 0x1401a9f60.
    static func advance(_ l: inout Layer, _ dt: Float) {
        guard !l.finished, l.duration > 0 else { return }
        if l.mode == .single && l.time >= l.duration { return }
        var t = l.time + (l.backwards ? -dt : dt)
        switch l.mode {
        case .single:
            if t >= l.duration { t = l.duration; l.finished = true }
        case .mirror:
            if l.backwards { if t <= 0 { t = -fmodf(t, l.duration); l.backwards = false } }
            else if t >= l.duration { t = l.duration - fmodf(t, l.duration); l.backwards = true }
        case .loop:
            if t < 0 { t = fmodf(t + l.duration, l.duration) }
            if t >= l.duration { t = fmodf(t, l.duration) }
        }
        l.time = t
    }

    /// `AnimLayer_Weight` 0x14026c8b0.
    static func weight(_ l: inout Layer) -> Float {
        var w = l.blend
        let L = min(l.duration * 0.5, l.blendTime)
        if l.blendIn && min(l.duration, l.blendTime) > 1.19e-7 {
            let fin = min(l.time / L, 1); w *= fin
            if l.mode != .single && fin >= 1 { l.blendIn = false }
        }
        if l.blendOut && min(l.duration, l.blendTime) > 1.19e-7 { w *= min((l.duration - l.time) / L, 1) }
        return w
    }

    /// `Timeline_Frames` 0x140170580.
    static func frames(_ a: MdlFile.Animation, time: Float) -> (Int, Int, Float) {
        let ft = a.frameTime
        let i0 = min(max(Int(time / ft), 0), max(a.frames - 1, 0))
        return (i0, min(i0 + 1, a.frames), fmodf(time, ft) / ft)
    }

    func sample(_ a: MdlFile.Animation, bone: Int, time: Float) -> Pose? { sample(a, a.tracks, bone, time: time) }

    func sample(_ a: MdlFile.Animation, _ tracks: [(unkeyed: Bool, samples: [Float])], _ bone: Int, time: Float) -> Pose? {
        let (i0, i1, frac) = Self.frames(a, time: time)
        return sample(tracks, bone, i0, i1, frac)
    }

    func sample(_ tracks: [(unkeyed: Bool, samples: [Float])], _ bone: Int, _ i0: Int, _ i1: Int, _ frac: Float) -> Pose? {
        guard bone < tracks.count, !tracks[bone].unkeyed else { return nil }
        let s = tracks[bone].samples
        guard !s.isEmpty, i0 >= 0, i1 >= 0, (max(i0, i1) + 1) * 9 <= s.count else { return nil }
        func pose(_ f: Int) -> Pose {
            let o = f * 9
            return Pose(p: SIMD3(s[o], s[o + 1], s[o + 2]), q: Self.quat(SIMD3(s[o + 3], s[o + 4], s[o + 5])),
                        s: SIMD3(s[o + 6], s[o + 7], s[o + 8]))
        }
        let A = pose(i0), B = pose(i1)
        var qb = B.q
        if simd_dot(A.q.vector, qb.vector) < 0 { qb = simd_quatf(vector: -qb.vector) }
        return Pose(p: simd_mix(A.p, B.p, SIMD3(repeating: frac)), q: simd_normalize(simd_quatf(vector: simd_mix(A.q.vector, qb.vector, SIMD4(repeating: frac)))),
                    s: simd_mix(A.s, B.s, SIMD3(repeating: frac)))
    }

    /// `Puppet_Update` 0x1401fdf90 → `Anim_SampleBlend`; then skin = inverse(bindWorld) applied to world.
    static let debugNoAnimation = ProcessInfo.processInfo.environment["PHOTON_NOANIM"] != nil

    /// Blend-map (+0xd8 → +0x350) and bone-alpha (+0xf0 → +0x268) float tracks of one layer, per
    /// `Puppet_Update`: overwrite = lerp(a, b, frac) (0x1401ff098 / 0x1401ff25b); blend = lerp(old, s, w)
    /// (0x1401ff537 / 0x1401ff71e); additive: blend map += w·s (0x1401ffa0f), bone alpha =
    /// clamp(old + (s − 1)·w, min(old, s), max(old, s)) (0x1401ffd33–0x1401fff10). Bone-alpha tracks whose
    /// bone track has `flags & 3 == 1` are skipped (0x1401ff1fb).
    func applyFloatTracks(_ a: MdlFile.Animation, _ additive: Bool, _ i0: Int, _ i1: Int, _ frac: Float, weight w: Float, overwrite: Bool) {
        func value(_ t: [Float]) -> Float? {
            guard i0 >= 0, i1 >= 0, i0 < t.count, i1 < t.count else { return nil }
            return t[i0] + (t[i1] - t[i0]) * frac
        }
        for (k, t) in a.blendTracks.enumerated() where k < blendMap.count {
            guard let v = value(t) else { continue }
            if additive { blendMap[k] += v * w } else if overwrite { blendMap[k] = v } else { blendMap[k] += (v - blendMap[k]) * w }
        }
        guard !boneAlpha.isEmpty else { return }
        for (b, t) in a.alphaTracks.enumerated() where b < boneAlpha.count {
            if b < a.trackFlags.count && a.trackFlags[b] & 3 == 1 { continue }
            guard let v = value(t) else { continue }
            let old = boneAlpha[b]
            if additive {
                boneAlpha[b] = min(max(old + (v - 1) * w, min(old, v)), max(old, v))
            } else if overwrite {
                boneAlpha[b] = v
            } else {
                boneAlpha[b] = old + (v - old) * w
            }
        }
    }

    /// One bone (or handle) of the overwrite (0x1401f89a0), blend (0x1401f9020) and additive (0x1401f9820) kernels.
    @inline(__always) static func apply(_ pose: inout Pose, _ s: Pose, ref r: Pose, weight w: Float, additive: Bool, overwrite: Bool) {
        if additive {
            // `Anim_SampleAdditive` 0x1401f9820 (SoA, 4 bones per step), with r = bind local pose:
            //   p' = p + w·(s.p − r.p);  scale' = scale + w·(s.s − r.s)
            //   d = conj(r.q) ⊗ s.q;  e = normalize((1−w)·I ± w·d)  (sign of d.w);  q' = q ⊗ e
            pose.p += (s.p - r.p) * w
            pose.s += (s.s - r.s) * w
            let d = r.q.conjugate * s.q
            let sw = d.real < 0 ? -w : w
            let e = simd_normalize(simd_quatf(vector: SIMD4(0, 0, 0, 1) * (1 - w) + d.vector * sw))
            pose.q = pose.q * e
        } else if overwrite {
            pose = s
        } else {
            var q = s.q
            if simd_dot(pose.q.vector, q.vector) < 0 { q = simd_quatf(vector: -q.vector) }
            pose.q = simd_normalize(simd_quatf(vector: simd_mix(pose.q.vector, q.vector, SIMD4(repeating: w))))
            pose.p = simd_mix(pose.p, s.p, SIMD3(repeating: w))
            pose.s = simd_mix(pose.s, s.s, SIMD3(repeating: w))
        }
    }

    /// `layerWorld`: the image's world matrix (vt+0x80, alignment included), needed by bone physics; nil skips it.
    func update(_ dt: Float, layerWorld: simd_float4x4? = nil) {
        // Puppet +0x230 holds the bind local pose; the first visible layer reads it and writes +0x238, later
        // layers read and write +0x238 (r14 bit 0, 0x1402001c6). Additive layers use +0x230 as their reference.
        var pose = bindLocal
        for b in boneAlpha.indices { boneAlpha[b] = 1 }
        // 0x1401fecba (puppet) / 0x14021c5b0 (model): the morph bitmask and weights are cleared every frame.
        for i in morphs.indices { morphs[i].reset() }
        for i in orderSlots.indices { orderSlots[i] = Float(mdl.drawOrderBase[i]) }
        var orderWritten = false
        handlePose = handleBind
        // r14 bit 0 (0x140200500): a visible layer ran; only then does the IK-aware bone loop 0x1402006c0 run.
        var anyLayer = false
        if Self.debugNoAnimation { layers.removeAll() }
        for i in layers.indices where layers[i].visible {
            if !layers[i].paused {
                // SceneScript animationEvent: events crossed by this step (Timeline_Advance 0x1401a9f60 with the
                // update's event list, 0x1401fed67; dispatched at 0x14020021a).
                let l = layers[i], d = dt * l.rate
                if !l.animation.events.isEmpty, !l.finished, l.duration > 0, !(l.mode == .single && l.time >= l.duration) {
                    firedEvents += ScriptAnimationEvents.crossed(l.animation.events, old: l.time, delta: l.backwards ? -d : d,
                                                                 duration: l.duration,
                                                                 mode: l.mode == .single ? .single : l.mode == .mirror ? .mirror : .loop)
                }
                let wasFinished = l.finished
                Self.advance(&layers[i], d)
                // 0x1401fedb0–0x1401fedfb: a layer "ends" when a single animation finishes, a mirror one turns
                // round, or a loop wraps (new time < old time); its addEndedCallback functions run after the update.
                let n = layers[i]
                let ended = l.mode == .single ? (n.finished && !wasFinished)
                    : l.mode == .mirror ? (n.backwards != l.backwards) : (l.time > n.time)
                if ended && !wasFinished { endedLayers.append(n.jsonIndex) }
            }
            let w = Self.weight(&layers[i])
            let l = layers[i]
            // Model_Update 0x14021c76e: a model layer whose weight is exactly 0 is skipped (kernels, float tracks, root
            // motion); Puppet_Update has no such test and runs the blend kernel with w = 0.
            if isModel && w == 0 { layers[i].rootActive = false; continue }
            // 0x1401fee15: w == 1 && !additive overwrites (0x1401f89a0), else blend (0x1401f9020) or additive (0x1401f9820).
            let overwrite = w == 1 && !l.additive
            // Model_Update 0x14021c6b6–0x14021c6e2: an animation with flags & 0x401 == 1 is a clip of its reference
            // animation: that animation's data is sampled at frameA + the clip's own frame indices. Puppet_Update has no
            // such branch (the clip has no SoA data of its own), so puppets sample the clip's own tracks.
            var (fi0, fi1, ffrac) = Self.frames(l.animation, time: l.time)
            var src = l.animation
            if isModel, let ref = l.animation.reference, l.animation.isClip, ref.index < mdl.animations.count {
                src = mdl.animations[ref.index]; fi0 += ref.frameA; fi1 += ref.frameA
            }
            for b in pose.indices {
                guard let s = sample(src.tracks, b, fi0, fi1, ffrac) else { continue }
                Self.apply(&pose[b], s, ref: bindLocal[b], weight: w, additive: l.additive, overwrite: overwrite)
            }
            // Handle tracks (anim +0x78/+0x88) through the same kernels into P+0x248, reference P+0x240
            // (0x1401fef7b / 0x1401ff3ef / 0x1401ff8e1).
            for h in handlePose.indices {
                guard let s = sample(src.handleTracks, h, fi0, fi1, ffrac) else { continue }
                Self.apply(&handlePose[h], s, ref: handleBind[h], weight: w, additive: l.additive, overwrite: overwrite)
            }
            // Constraint weights P+0x250 (anim +0xc0): the first visible layer clears them (0x1401fee4f) when it overwrites
            // or when its animation has an unkeyed bone/handle track (anim flags bit 31, `cmp [anim+0x50], 0; jge` at
            // 0x1401fee46); overwrite = s, blend = lerp(old, s, w), additive = old + s·w. Unkeyed tracks are skipped.
            if let ik {
                if !anyLayer && (overwrite || l.animation.flags & 0x8000_0000 != 0) { for k in ik.weights.indices { ik.weights[k] = 0 } }
                let (i0, i1, frac) = (fi0, fi1, ffrac)
                for (k, t) in src.constraintTracks.enumerated() where k < ik.weights.count && !t.unkeyed {
                    guard i0 < t.samples.count, i1 < t.samples.count else { continue }
                    let v = t.samples[i0] + (t.samples[i1] - t.samples[i0]) * frac
                    if l.additive { ik.weights[k] = ik.weights[k] + v * w }
                    else if overwrite { ik.weights[k] = v }
                    else { ik.weights[k] = ik.weights[k] + (v - ik.weights[k]) * w }
                }
            }
            anyLayer = true
            applyFloatTracks(src, l.additive, fi0, fi1, ffrac, weight: w, overwrite: overwrite)
            let (i0, i1, frac) = (fi0, fi1, ffrac)
            // Anim +0x108 → puppet +0x280 (0x1401ff280 / 0x1401ff78a / 0x1401fff53): frame a only; tracks whose bone
            // track has `flags & 3 == 1` are skipped. Overwrite: s; blend: lerp(old, s, w); additive:
            // d = (s − base[i])·w, clamp(old + d, min(old, d), max(old, d)).
            if !orderSlots.isEmpty {
                for (b, t) in src.orderTracks.enumerated() where b < orderSlots.count && i0 >= 0 && i0 < t.count {
                    if b < src.trackFlags.count && src.trackFlags[b] & 3 == 1 { continue }
                    let v = t[i0], old = orderSlots[b]
                    if l.additive {
                        let d = (v - Float(mdl.drawOrderBase[b])) * w
                        orderSlots[b] = min(max(old + d, min(old, d)), max(old, d))
                    } else if overwrite {
                        orderSlots[b] = v
                    } else {
                        orderSlots[b] = old + (v - old) * w
                    }
                    orderWritten = true
                }
            }
            for mi in morphs.indices where mi < src.morphTracks.count {
                guard let tracks = src.morphTracks[mi] else { continue }
                morphs[mi].apply(tracks, i0: i0, i1: i1, frac: frac, weight: w,
                                 mode: l.additive ? .additive : overwrite ? .overwrite : .blend)
            }
            if isModel { applyRootMotion(layer: i, src: src, fa: fi0, fb: fi1, frac: ffrac, weight: w, pose: &pose) }
        }
        if orderWritten { resortSections() }
        // Puppet +0x2c8 persists: bones with flags bit 1 and no chain keep last frame's matrix (0x1402006d2–0x1402008cb).
        var world = boneWorld
        // Physics (0x14020136e) runs per bone right after its world matrix, so children follow the moved parent.
        let simulate = layerWorld != nil && !Self.debugNoPhysics && physics.contains { $0?.enabled == true }
        let M = layerWorld ?? matrix_identity_float4x4
        // [rsp+0x64] (0x1402004d2): mean length of the layer matrix's first three rows.
        let avgScale = (simd_length(SIMD3(M.columns.0.x, M.columns.0.y, M.columns.0.z)) +
                        simd_length(SIMD3(M.columns.1.x, M.columns.1.y, M.columns.1.z)) +
                        simd_length(SIMD3(M.columns.2.x, M.columns.2.y, M.columns.2.z))) / 3
        var layerSpace: [simd_float4x4] = []
        // IK state: the flat row-vector BW the IK code works on, kept in sync with `world`.
        let ikActive = anyLayer && ik != nil
        var bw: [Float] = ikActive ? world.flatMap(PuppetIK.rows) : []
        let MR = ikActive ? PuppetIK.rows(M) : []
        if ikActive, let ik {
            // P+0x2e0 from the handle pose, model space, no parent (0x140200520–0x140200654).
            for h in ik.HM.indices where h < handlePose.count {
                ik.HM[h] = PuppetIK.handleMatrix(p: handlePose[h].p, q: handlePose[h].q)
            }
        }
        for (i, b) in mdl.bones.enumerated() {
            let chain = i < mdl.boneChain.count ? mdl.boneChain[i] : -1
            if anyLayer && b.flags & 2 != 0 && chain < 0 {
                if layerWorld != nil { layerSpace.append(M * world[i]) }
                // 0x1402008d0–0x1402008fa: the kept bone's local = inverse(parent world) · world (root: world).
                if i < boneLocal.count { boneLocal[i] = b.parent >= 0 && b.parent < i ? world[b.parent].inverse * world[i] : world[i] }
            } else {
                let P = pose[i]
                let L = Mat.translate(P.p) * simd_float4x4(P.q) * Mat.scale(P.s)
                if i < boneLocal.count { boneLocal[i] = L }
                var W = b.parent >= 0 && b.parent < i ? world[b.parent] * L : L
                // Bone +0xd8 constraints (0x140200df2–0x1402011bf), right after the world matrix.
                if ikActive, let ik, i < mdl.boneConstraints.count, !mdl.boneConstraints[i].isEmpty {
                    let r = PuppetIK.rows(W)
                    for k in 0..<16 { bw[16 * i + k] = r[k] }
                    ik.boneConstraints(&bw, i, mdl.boneConstraints[i])
                    W = PuppetIK.simd(bw, 16 * i)
                }
                // B = last update's +0x340 (swapped into +0x348 at 0x1402003f0); none on the first update (0x140201387).
                if simulate, let ph = physics[i], ph.enabled, i < previousLayerSpaceCurrent.count {
                    W = W * ph.step(&physicsState[i], L: M * W, B: previousLayerSpaceCurrent[i], dt: dt, avgScale: avgScale)
                }
                if layerWorld != nil { layerSpace.append(M * W) }
                world[i] = W
                if ikActive {
                    let r = PuppetIK.rows(W)
                    for k in 0..<16 { bw[16 * i + k] = r[k] }
                }
            }
            // 0x14020365b: ik_prepare, rope (chain flags & 1), solve ×10.
            if ikActive, chain >= 0, let ik {
                ik.step(&bw, chain: chain, layer: MR, dt: dt, env: ikEnvironment)
                for k in world.indices { world[k] = PuppetIK.simd(bw, 16 * k) }
            }
        }
        if ikActive, let ik, PuppetIK.debug { ik.debugFrame += 1 }
        // 0x1402003f0: +0x348 = the old +0x340, +0x340 = this update's snapshot.
        if layerWorld != nil {
            previousLayerSpace = previousLayerSpaceCurrent.isEmpty ? nil : previousLayerSpaceCurrent
            previousLayerSpaceCurrent = layerSpace
        }
        boneWorld = world
        skin = zip(world, inverseBindWorld).map { $0 * $1 }
    }

    /// `0x14020db40`: after a script wrote local matrix `start`, bone `start` and every later bone whose parent was
    /// rebuilt get world = parent world · local (root: local) and skin = world · inverse bind (P+0x2f8); P+0x340
    /// (world × layer world) is formed on demand here. Lasts until the next puppet update rebuilds the pose.
    func rebuildFromLocal(_ start: Int) {
        guard start >= 0, start < mdl.bones.count, boneLocal.count == mdl.bones.count, boneWorld.count == mdl.bones.count else { return }
        var dirty = Set<Int>()
        for i in start..<mdl.bones.count {
            let p = mdl.bones[i].parent
            guard i == start || dirty.contains(p) else { continue }
            dirty.insert(i)
            boneWorld[i] = p < 0 || p >= boneWorld.count ? boneLocal[i] : boneWorld[p] * boneLocal[i]
            if i < skin.count, i < inverseBindWorld.count { skin[i] = boneWorld[i] * inverseBindWorld[i] }
        }
    }

    /// Image vt+0x88 = 0x1401fd690: cursor hit test against the MDLS hit boxes, walking the order list from last to first.
    /// Box b = `{halfExt, m}` in bone space; P+0x340 = bone world × layer world, so (row-vector) the ray goes through
    /// inverse(m · boneWorld · layerWorld) and is slab-tested against [−ext, +ext]. The first hit names the bone, or its
    /// index when the name is empty.
    func hitTest(from a: SIMD3<Float>, to b: SIMD3<Float>, layerWorld: simd_float4x4) -> String? {
        guard !mdl.hitBoxes.isEmpty else { return nil }
        for bone in mdl.hitOrder.reversed() where bone < mdl.hitBoxes.count && bone < boneWorld.count {
            let box = mdl.hitBoxes[bone]
            let inv = (layerWorld * boneWorld[bone] * Self.matrix(rowMajorRowVector: box.matrix)).inverse
            let pa = inv * SIMD4(a, 1), pb = inv * SIMD4(b, 1)
            let o = SIMD3(pa.x, pa.y, pa.z) / (pa.w == 0 ? 1 : pa.w), e = SIMD3(pb.x, pb.y, pb.z) / (pb.w == 0 ? 1 : pb.w)
            let d = e - o
            var t0: Float = 0, t1: Float = 1, hit = true
            for k in 0..<3 {
                let lo = -box.halfExtents[k], hi = box.halfExtents[k]
                if abs(d[k]) < 1e-12 {
                    if o[k] < lo || o[k] > hi { hit = false; break }
                } else {
                    var ta = (lo - o[k]) / d[k], tb = (hi - o[k]) / d[k]
                    if ta > tb { swap(&ta, &tb) }
                    t0 = max(t0, ta); t1 = min(t1, tb)
                    if t0 > t1 { hit = false; break }
                }
            }
            if hit { return mdl.bones[bone].name.isEmpty ? String(bone) : mdl.bones[bone].name }
        }
        return nil
    }

    /// `Image_GetAttachmentIndex` 0x1401fd510: first attachment whose name matches exactly, else -1.
    func attachmentIndex(_ name: String) -> Int { mdl.attachments.firstIndex { $0.name == name } ?? -1 }

    /// `Image_ApplyAttachment` 0x1401fd5c0: row-vector `attach.matrix × boneWorld[attach.bone]`, here in
    /// column-vector form `boneWorld · attach`.
    func attachmentTransform(_ index: Int) -> simd_float4x4? {
        guard index >= 0, index < mdl.attachments.count else { return nil }
        let a = mdl.attachments[index]
        guard a.bone >= 0, a.bone < boneWorld.count else { return nil }
        return boneWorld[a.bone] * Self.matrix(rowMajorRowVector: a.matrix)
    }
}

/// Morph-target weights of one mesh: a 64-bit active mask plus one weight per target (puppet +0x398/+0x3a0).
struct MorphState {
    enum Mode { case overwrite, blend, additive }
    var mask: UInt64 = 0
    var weights: [Float]

    init(count: Int) { weights = [Float](repeating: 0, count: count) }

    mutating func reset() {
        mask = 0
        for i in weights.indices { weights[i] = 0 }
    }

    /// The three kernels of `Puppet_Update` for anim +0x138 (s = lerp(frame a, frame b, frac), eps = 1.19e-7):
    /// overwrite 0x1401ff110: |s| > eps → set bit, weight = s; else clear bit.
    /// blend 0x1401ff5d0: |s| > eps → set bit; weight = lerp(weight, s, w) either way.
    /// additive 0x1401ffa90: |s| > eps → set bit, s' = s·w, weight = clamp(weight + s', min(weight, s'), max(weight, s')).
    mutating func apply(_ tracks: [(index: Int, samples: [Float])], i0: Int, i1: Int, frac: Float, weight w: Float, mode: Mode) {
        for (k, t) in tracks where k < weights.count && k < 64 && i0 < t.count && i1 < t.count {
            let s = t[i0] + (t[i1] - t[i0]) * frac
            let active = abs(s) > 1.1920929e-7
            switch mode {
            case .overwrite:
                if active { mask |= 1 << UInt64(k); weights[k] = s } else { mask &= ~(1 << UInt64(k)) }
            case .blend:
                if active { mask |= 1 << UInt64(k) }
                weights[k] += (s - weights[k]) * w
            case .additive:
                guard active else { continue }
                mask |= 1 << UInt64(k)
                let old = weights[k], a = s * w
                weights[k] = min(max(old + a, min(old, a)), max(old, a))
            }
        }
    }

    /// `Puppet_SetMorphUniforms` 0x14020cff0 / the model render loop 0x140222b20: active targets in index order,
    /// at most 11, stable-sorted by weight descending (comparator 0x140268b60). Returns (target index, weight).
    func activeTargets() -> [(index: Int, weight: Float)] {
        var list: [(index: Int, weight: Float)] = []
        for k in weights.indices where k < 64 && mask & (1 << UInt64(k)) != 0 {
            list.append((k, weights[k]))
            if list.count >= 11 { break }
        }
        // Stable descending sort (std::stable_sort with a.w > b.w).
        return list.enumerated().sorted { $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset }
            .map { $0.element }
    }
}
