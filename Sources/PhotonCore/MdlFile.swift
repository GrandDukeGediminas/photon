import Foundation
#if canImport(simd)
import simd
#endif

/// `.mdl` puppet/model files (docs/re/06 §1, `Mdl_Load` 0x140261880). Port of docs/re/tools/mdl_parse.py,
/// which parses all 74 corpus files with every section ending on its stored offset.
public struct MdlFile {
    public struct Mesh {
        public let material: String
        /// All `nMatPerMesh` material paths (model objects pick `materials[min(skin, n−1)]`, 0x140224dc4).
        public var materials: [String] = []
        public let flags: UInt32
        public let vertexFlags: UInt32
        public let stride: Int
        public let vertices: Data
        public let indices: [UInt32]
        /// The u32 after `mflags` when `mflags & 2` (mesh +0x1c): `BLENDROWCOUNT` of a texture-channel mesh
        /// (`Image_UpdateMaterialVariants` 0x140209540).
        public var blendRowCount: UInt32 = 0
        /// MDMP0001 morph targets of this mesh (mesh +0x60 scale, +0x64 vertex count, +0x68 0x40-byte records).
        public var morphScale: Float = 1   // mesh ctor 0x1401dd23b: scale 1.0, vertex count 0
        public var morphVertexCount = 0
        public var morphTargets: [MorphTarget] = []
        /// MDLV ≥ 21 16-byte records (mesh +0xa0 count / +0xa8): draw sections `{u32 slot, i32 orderOffset, u32 firstIndex,
        /// u32 indexCount}` (`Puppet_BuildGeometry` 0x14020b3e0–0x14020b446).
        public var sections: [(slot: Int, orderOffset: Int32, first: Int, count: Int)] = []
        /// MDLV ≥ 23 clip groups (mdl +0xb0, 0x50-byte records; `Mdl_Load` 0x140261c0d–0x1402622ce), docs/re/06 §2.1.6.
        public var clipGroups: [ClipGroup] = []
        /// MDLV ≥ 17 `f32 min[3], f32 max[3]` (mesh record +0x20 / +0x2c; `Mdl_Load` 0x1402619a6–0x140261a0f). Zero for
        /// older files: the record ctor 0x1401dd200 clears it.
        public var boundsMin = SIMD3<Float>(repeating: 0)
        public var boundsMax = SIMD3<Float>(repeating: 0)
        public init(material: String, flags: UInt32, vertexFlags: UInt32, stride: Int, vertices: Data, indices: [UInt32]) {
            self.material = material; self.flags = flags; self.vertexFlags = vertexFlags; self.stride = stride
            self.vertices = vertices; self.indices = indices
        }

        /// MDLV ≥ 21 optional float3-per-vertex stream (mesh +0x88), the `a_PositionC1` source of lit puppets.
        public var positionC1: Data?

        /// `MdlMesh_BuildDualVertex` 0x140266fa0: vflags | 0x2000000 (`a_PositionC1`, float3), inserted at its interleave
        /// slot (after `a_Position` and `a_PositionVec4`); each vertex gets `positionC1[i]` or, without the stream, a copy
        /// of its own first 12 bytes (the position). Returns the new vflags, stride and vertex bytes.
        public func dualVertex() -> (vertexFlags: UInt32, stride: Int, vertices: Data) {
            let vf = vertexFlags | 0x2000000
            let newStride = MdlFile.stride(vf)
            let count = stride > 0 ? vertices.count / stride : 0
            var head = 0
            for i in 0..<2 where MdlFile.attributeMasks[i] & vertexFlags != 0 { head += MdlFile.attributeSizes[i] }
            var out = Data(count: newStride * count)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                vertices.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    for v in 0..<count {
                        let so = v * stride, d = v * newStride
                        if head > 0 { dst.baseAddress!.advanced(by: d).copyMemory(from: src.baseAddress!.advanced(by: so), byteCount: head) }
                        if let c1 = positionC1, c1.count >= (v + 1) * 12 {
                            c1.withUnsafeBytes { c in
                                dst.baseAddress!.advanced(by: d + head).copyMemory(from: c.baseAddress!.advanced(by: v * 12), byteCount: 12)
                            }
                        } else {
                            dst.baseAddress!.advanced(by: d + head).copyMemory(from: src.baseAddress!.advanced(by: so), byteCount: 12)
                        }
                        let rest = stride - head
                        if rest > 0 {
                            dst.baseAddress!.advanced(by: d + head + 12).copyMemory(from: src.baseAddress!.advanced(by: so + head), byteCount: rest)
                        }
                    }
                }
            }
            return (vf, newStride, out)
        }
    }

    /// A puppet clip group. File: `u64 id; cstr maskTexture; u32 flags; u32 nA; nA × u32; u32 nB; nB × u32`
    /// (section indices, each checked < section count). `a` (+0x8) holds the clipped sections, `b` (+0x20) the
    /// sections whose `[first, last]` draw-order range forms the mask.
    public struct ClipGroup {
        public let id: UInt64
        /// +0x38, e.g. `masks/clipping_mask_02a9a1b9` (a material-relative texture name).
        public let maskTexture: String
        /// +0x44: 1 = clipped sections blend additive (+0x40 = 2, else 1 translucent), 2 = inverted mask,
        /// 4 = the listed mask sections are not drawn themselves, 8 = clipped sections draw at their own position.
        public let flags: UInt32
        public let a: [Int]
        public let b: [Int]
        /// +0x48: the first other group whose `a` list contains every section of this group's `b` list
        /// (0x14026203c–0x140262200), −1 if none or if the parent chain loops (0x1402622c9).
        public var parent = -1
        public var additive: Bool { flags & 1 != 0 }
        public var inverted: Bool { flags & 2 != 0 }
    }

    /// One MDMP0001 blend shape. Streams are per morph vertex: `positions`/`normals` are int16×3 (snorm, scaled
    /// by the mesh `morphScale` in the shader), `alpha` is u16 (mflags & 0x1000). Record +0x10 positions,
    /// +0x18 normals (mflags & 0x400), +0x20 (mflags & 0x800), +0x28 alpha, +0x30 modifier flags, +0x34 bone,
    /// +0x38/+0x3c modifier range (mflags & 0x2000).
    public struct MorphTarget {
        public let id: UInt64
        public let name: String
        public var positions: [Int16] = []
        public var normals: [Int16] = []
        public var extra: [Int16] = []
        public var alpha: [UInt16] = []
        public var modifierFlags: UInt32 = 0
        public var modifierBone = 0
        public var modifierRange = SIMD2<Float>(-1, 0)   // record ctor 0x140265ba0: +0x38 = −1.0, +0x3c = 0
    }

    public struct Bone {
        public let name: String
        public let parent: Int // -1 = root
        /// Local bind matrix, 16 floats row-major, row-vector convention (translation in 12..14).
        public let localBind: [Float]
        /// MDLS per-bone u32 (bone +0x64) and the physics JSON string parsed by `BonePhysics_Parse` 0x140265c30.
        public var flags: UInt32 = 0
        public var physicsJSON: String = ""
    }

    public struct Animation {
        public enum Mode: String { case loop, mirror, single }
        /// The raw mode string (anim +0x28); `Timeline_Init` 0x1401a8c10 compares it with "mirror" and "single", anything
        /// else (including "") plays as loop.
        public var modeName = "loop"
        public let id: UInt64
        public let name: String
        public let mode: Mode
        public let fps: Float
        public let frames: Int
        /// Per track (bone order): unkeyed flag and (frames+1) samples of pos[3], eulerRad[3], scale[3].
        public let tracks: [(unkeyed: Bool, samples: [Float])]
        /// Raw per-track flags (runtime anim +0x90); `flags & 3 == 1` skips the bone's float tracks.
        public var trackFlags: [UInt32] = []
        /// aver ≥ 3 `u32 n; n × {u32; blob (frames+1)·4}`: blend-map floats (anim +0xd8 → puppet +0x350,
        /// `g_BlendMap`). Inferred mapping, docs/re/06 §3.4.1.
        public var blendTracks: [[Float]] = []
        /// aver ≥ 3 optional per-track floats (anim +0xf0 → puppet +0x268, `g_BonesAlpha`). Empty when absent.
        public var alphaTracks: [[Float]] = []
        /// aver ≥ 4 morph-weight tracks (anim +0x138), one entry per mesh: nil when the mesh's flag bit 0 is clear,
        /// else (morph index, (frames+1) floats) pairs. `Puppet_Update` 0x1401ff0ae / 0x1401ff56e / 0x1401ffa2e.
        public var morphTracks: [[(index: Int, samples: [Float])]?] = []
        /// aver ≥ 6 optional per-track floats (anim +0x108 → puppet +0x280): section draw-order values per slot.
        public var orderTracks: [[Float]] = []
        /// MDLA ≥ 2 handle tracks (anim +0x78/+0x88), one per MDLS handle, same layout as `tracks`: sampled into the
        /// handle pose buffer P+0x248 by the bone kernels (`Puppet_Update` 0x1401fef7b / 0x1401ff3ef / 0x1401ff8e1).
        public var handleTracks: [(unkeyed: Bool, samples: [Float])] = []
        /// MDLA ≥ 2 per-constraint float tracks (anim +0xc0, `{u8 flags; float* samples}`): the constraint weights P+0x250
        /// (overwrite 0x1401fefa0, blend 0x1401ff413, additive 0x1401ff905). Unkeyed (flags & 1) tracks are skipped.
        public var constraintTracks: [(unkeyed: Bool, samples: [Float])] = []
        /// aver ≥ 5 `f32 min[3], f32 max[3]` (anim +0x54 / +0x60, 0x140264d03–0x140264e05): the box the model bounds use
        /// while a layer plays this animation (`Model_UpdateBounds` 0x140226a10). Zero when absent.
        public var boundsMin = SIMD3<Float>(repeating: 0)
        public var boundsMax = SIMD3<Float>(repeating: 0)
        /// `u32 n; n × {f32 time (seconds); cstr json}` at the end of each MDLA record: animation events, pushed by
        /// `Timeline_Advance` into the puppet update's list and sent to SceneScript animationEvent (0x14020021a).
        public var events: [(time: Float, json: String)] = []
        /// MDLA record flags (anim +0x50): bit 0 = a reference block follows (`reference`), 0x400 = the reference block
        /// samples this animation's own data, 0x1f800 = root-motion channels (Model_Update 0x14021cc0c), 0x80000000 = set by
        /// the loader when any bone or handle track is unkeyed (0x140263c9d / 0x140263df0, read by `Puppet_Update`
        /// 0x1401fee46).
        public var flags: UInt32 = 0
        /// The `aflags & 1` block (`Mdl_Load` 0x1402650b0–0x140265348 → 0xc0-byte record at anim +0x150):
        /// `u16 index` (+8, must name an animation loaded earlier, else fast-fail 0x14026519a), `u32 frameA` (+0xc),
        /// `u32 frameB` (+0x10), `u32 rootFrame` (+0x14), `u32 bone` (+0x18). With `flags & 0x401 == 1` the record makes this
        /// animation a clip of animation `index`: the loader skips the SoA conversion of its own tracks (0x140263f92) and
        /// `Model_Update` samples `index`'s data at `frameA` + its own frame indices (0x14021c6b6–0x14021c6e2). With
        /// `flags & 0x1f800` the loader also stores bone `bone`'s model matrices at frameA (+0x1c) and frameB (+0x80) and the
        /// inverse 3×3 of the first (+0x5c, 0x140228b00), sampled by 0x140267580 from `index`'s data (or this animation's
        /// own, frames 0 and `frames`, when `flags & 0x400`): the root-motion data (docs/re/mdl-format.md §5).
        public struct Reference {
            public let index: Int
            public let frameA: Int
            public let frameB: Int
            public let rootFrame: UInt32
            public let bone: Int
            public init(index: Int, frameA: Int, frameB: Int, rootFrame: UInt32, bone: Int) {
                self.index = index; self.frameA = frameA; self.frameB = frameB; self.rootFrame = rootFrame; self.bone = bone
            }
        }
        public var reference: Reference?
        /// True for `flags & 0x401 == 1`: the animation's samples come from `reference.index` offset by `frameA`.
        public var isClip: Bool { flags & 0x401 == 1 && reference != nil }
        /// `Timeline_Init` 0x1401a8c10: frameTime = 1/fps and duration = frames/fps, but with fps ≤ 0 (or a duration ≤ 0)
        /// the init fails with frameTime 1 and no duration (timeline ctor zero), so the layer never advances and samples
        /// frame 0.
        public var frameTime: Float { fps > 0 && Float(frames) / fps > 0 ? 1 / fps : 1 }
        public var duration: Float { fps > 0 ? max(Float(frames) / fps, 0) : 0 }
        /// The loop/mirror/single mode the timeline actually uses: the init sets the mode bits only after a successful
        /// init (0x1401a8c67), so a failed init plays as loop.
        public var timelineMode: Mode { duration > 0 ? mode : .loop }
    }

    public enum Error: Swift.Error { case badMagic, truncated }

    /// `strtol(s, 10)` as used on `magic + 4` and on section tags: leading digits, else 0.
    static func atoi<S: StringProtocol>(_ s: S) -> Int {
        var v = 0, any = false
        for c in s { guard let d = c.wholeNumberValue, c.isASCII else { break }; v = v &* 10 &+ d; any = true }
        return any ? v : 0
    }

    /// MDLE0002 (mdl +0x60): boneCount raw 4×4 matrices; not read by the runtime.
    public var editorPose = Data()

    /// mdl +0x1b8 / +0x1c4: the union of every mesh box (0x1402617c0, FLT_MAX-seeded); when that is not valid
    /// (`max.x > min.x` fails, e.g. pre-v17 files whose boxes are all zero) ±131072 (0xc8000000 / 0x48000000,
    /// 0x140262349–0x140262377).
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for m in meshes { lo = simd_min(lo, m.boundsMin); hi = simd_max(hi, m.boundsMax) }
        if hi.x > lo.x { return (lo, hi) }
        return (SIMD3(repeating: -131072), SIMD3(repeating: 131072))
    }

    public var version = 0
    public var meshes: [Mesh] = []
    public var bones: [Bone] = []
    public var animations: [Animation] = []
    /// MDLS sver ≥ 3 optional `boneCount × i32` (mdl +0x1e8 = puppet +0x1f0): base draw order per slot.
    public var drawOrderBase: [Int32] = []
    /// MDLS cursor hit boxes per bone: half extents and a row-major row-vector matrix in bone space, and the order list.
    public var hitBoxes: [(halfExtents: SIMD3<Float>, matrix: [Float])] = []
    public var hitOrder: [Int] = []
    /// MDLS ≥ 2 IK/constraint data (`Mdl_Load` 0x1402625d0–0x14026341e). Handles: `cstr name; u32 bone; u32 type;
    /// f32[16] matrix` (0x80-byte records at mdl +0x78; type 0 → bone map X+0x48, type 1 → X+0x88).
    public struct Handle {
        public let name: String
        public let bone: Int
        public let type: UInt32
        /// Row-major row-vector matrix in model space (handle +0x20).
        public let matrix: [Float]
        /// Constraints routed to this handle (+0x68).
        public var constraints: [Constraint] = []
    }
    /// 0x14-byte constraint record `{flags, a, b, f0, f1}`: `a` indexes the per-constraint weight track, `b` the target bone.
    public struct Constraint {
        public let flags: UInt32
        public let a: Int
        public let b: Int
        public let f0: Float
        public let f1: Float
    }
    /// 0x28-byte IK link `{bone, flags, maxd, mind, list}` (flags: 1 anchor is a handle, 2 never stretched, 4 rope).
    public struct IKLink {
        public let bone: Int
        public let flags: UInt32
        public let maxd: Float
        public let mind: Float
        public let list: [Int]
    }
    public struct IKEntry {
        public let bone: Int
        public let links: [IKLink]
    }
    /// 0x40-byte chain: trigger bone (+0), entries (+8), handles with constraints (+0x20), flags (+0x38, bit 0 = rope).
    public struct IKChain {
        public let bone: Int
        public let entries: [IKEntry]
        public let handles: [Int]
        public let flags: UInt32
    }
    public var handles: [Handle] = []
    /// Optional MDLS override matrices (mdl +0x48 bones / +0x90 handles, `u8 has` block); empty when absent.
    public var bindOverrideBones: [[Float]] = []
    public var bindOverrideHandles: [[Float]] = []
    /// Constraints owned by bones without flags bit 1 (bone +0xd8), indexed by bone.
    public var boneConstraints: [[Constraint]] = []
    /// Total MDLS constraint count (S+0x28): the number of MDLA per-constraint tracks and of weights.
    public var constraintCount = 0
    /// nD block: per-bone rest segment length (X+0x00, raw u32 bits as float) and rest direction to each child (X+0x18).
    public var segmentLength: [Float] = []
    public var restDirections: [[Int: SIMD3<Float>]] = []
    public var ikChains: [IKChain] = []
    /// bone +0xd4: index of the chain triggered by the bone, −1 for none.
    public var boneChain: [Int] = []

    /// MDAT0001 attachment points: bone index, name and a row-major row-vector matrix in bone space
    /// (puppet +0xb0, 0x68-byte records; read by `Image_GetAttachmentIndex` 0x1401fd510).
    public var attachments: [(bone: Int, name: String, matrix: [Float])] = []

    /// Vertex attribute sizes and flag masks in interleave order (tables at 0x1404849b0 / 0x140484a20).
    public static let attributeSizes = [12, 16, 12, 12, 16, 16, 16, 8, 12, 16, 8, 12, 16, 8, 12, 16, 8, 12, 16, 8, 12, 16, 8, 12, 16, 16]
    public static let attributeMasks: [UInt32] = [0x1, 0x10000, 0x2000000, 0x2, 0x4, 0x800000, 0x1000000, 0x8, 0x10, 0x20, 0x40, 0x80,
                                                  0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000, 0x20000, 0x40000, 0x80000,
                                                  0x100000, 0x200000, 0x400000, 0x8000]

    public static func stride(_ vflags: UInt32) -> Int {
        zip(attributeSizes, attributeMasks).reduce(0) { $0 + ($1.1 & vflags != 0 ? $1.0 : 0) }
    }

    /// Byte offset of each present attribute, keyed by engine attribute id (table index).
    public static func offsets(_ vflags: UInt32) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var off = 0
        for i in 0..<attributeMasks.count where attributeMasks[i] & vflags != 0 {
            out[i] = off
            off += attributeSizes[i]
        }
        return out
    }

    /// An in-memory model (the "MDLVS001" model that `createModelData` registers, exe 0x14018c720).
    public init(meshes: [Mesh], bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil) {
        version = 17
        self.meshes = meshes
        if let b = bounds, !meshes.isEmpty { self.meshes[0].boundsMin = b.min; self.meshes[0].boundsMax = b.max }
    }

    public init(data: Data) throws {
        var r = MdlReader(data)
        let magic = r.cstr()
        // `Mdl_Load` never compares the magic: the version is `strtol(magic + 4)` (0x1402c82c0). photon2 still rejects a
        // file whose first string is not an mdl magic at all, so unrelated data is not parsed as a model.
        guard magic.hasPrefix("MDL") else { throw Error.badMagic }
        version = Self.atoi(magic.dropFirst(4))
        let hflags = r.u32(), nmat = Int(r.u32()), nmesh = Int(r.u32())
        for _ in 0..<nmesh {
            var mats: [String] = []
            for _ in 0..<nmat { mats.append(r.cstr()) }
            let mflags = version >= 4 ? r.u32() : 0
            let rows = mflags & 2 != 0 ? r.u32() : 0
            var vf = hflags
            var bmin = SIMD3<Float>(repeating: 0), bmax = SIMD3<Float>(repeating: 0)
            if version >= 17 {
                bmin = SIMD3(r.f32(), r.f32(), r.f32()); bmax = SIMD3(r.f32(), r.f32(), r.f32())
                vf = r.u32()
            } else if version >= 15 { vf = r.u32() }
            let vb = r.blob(), ib = r.blob()
            var indices: [UInt32] = []
            if mflags & 1 != 0 {
                indices = ib.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            } else {
                indices = ib.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map { UInt32($0) } }
            }
            var sections: [(slot: Int, orderOffset: Int32, first: Int, count: Int)] = []
            var positionC1: Data?
            if version >= 21 {
                // `u8 has; u32 (read and dropped); blob` → mesh +0x80 size / +0x88 data (0x140261b66–0x140261b8f): one float3
                // per vertex, the rest-layout position `MdlMesh_BuildDualVertex` 0x140266fa0 writes as `a_PositionC1`.
                if r.u8() != 0 { _ = r.u32(); positionC1 = r.blob() }
                if r.u8() != 0 {
                    let b = r.blob()
                    b.withUnsafeBytes { raw in
                        for i in 0..<(b.count / 16) {
                            let o = i * 16
                            sections.append((Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)),
                                             raw.loadUnaligned(fromByteOffset: o + 4, as: Int32.self),
                                             Int(raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)),
                                             Int(raw.loadUnaligned(fromByteOffset: o + 12, as: UInt32.self))))
                        }
                    }
                }
            }
            var clips: [ClipGroup] = []
            if version >= 23 {
                let n = Int(r.u32())
                for _ in 0..<n {
                    let id = r.u64(), name = r.cstr(), flags = r.u32()
                    var a: [Int] = [], b: [Int] = []
                    for _ in 0..<Int(r.u32()) { a.append(Int(r.u32())) }
                    for _ in 0..<Int(r.u32()) { b.append(Int(r.u32())) }
                    clips.append(ClipGroup(id: id, maskTexture: name, flags: flags, a: a, b: b))
                }
                if clips.count > 1 {
                    for d in clips.indices where !clips[d].b.isEmpty {
                        guard let p = clips.indices.first(where: { $0 != d && clips[d].b.allSatisfy(clips[$0].a.contains) }) else { continue }
                        clips[d].parent = p
                        var seen: Set<Int> = [], k = p
                        while k != -1 {
                            if !seen.insert(k).inserted { clips[d].parent = -1; break }
                            k = clips[k].parent
                        }
                    }
                }
            }
            var mesh = Mesh(material: mats.first ?? "", flags: mflags, vertexFlags: vf, stride: Self.stride(vf), vertices: vb, indices: indices)
            mesh.blendRowCount = rows
            mesh.boundsMin = bmin
            mesh.positionC1 = positionC1
            mesh.boundsMax = bmax
            mesh.materials = mats
            mesh.sections = sections
            mesh.clipGroups = clips.filter { g in (g.a + g.b).allSatisfy { $0 < sections.count } }
            meshes.append(mesh)
        }
        var handles = 0, constraints = 0
        // `Mdl_Load` 0x140262382: files below MDLV0013 end after the meshes; no section tags are read.
        while version >= 13 && r.remaining > 0 {
            let tag = r.cstr()
            if tag.isEmpty { break }
            let sv = Self.atoi(tag.dropFirst(4))
            let next = Int(r.u32())
            // 0x1402624af / 0x140263970: MDLS and MDLA match on their first 4 characters (any version digits);
            // MDAT0001 / MDMP0001 / MDLE0002 must match all 8 (0x1402655d7, 0x1402656a6, 0x1402658c2). Anything else is
            // skipped through its stored end offset.
            switch tag.prefix(4) == "MDLS" || tag.prefix(4) == "MDLA" ? String(tag.prefix(4)) : tag {
            case "MDLS": (handles, constraints) = parseSkeleton(&r, sv)
            case "MDLA": parseAnimations(&r, sv, handles: handles, constraints: constraints)
            case "MDMP0001": parseMorphs(&r)
            case "MDLE0002":
                // `u32 n` + min(n, 64·boneCount) bytes into mdl +0x60 (boneCount 4×4 matrices). No reader of mdl +0x60 was
                // found in the runtime (pattern search for the 64-byte element count); kept for completeness.
                // Sized copy 0x1400d3ef0: needs 4 + cap bytes left, else the vector is zero-filled and nothing is read.
                let cap = 64 * bones.count
                editorPose = Data(count: cap)
                if r.remaining >= 4 + cap {
                    let n = Int(Int32(bitPattern: r.u32()))
                    let k = max(0, min(n, cap))
                    editorPose.replaceSubrange(0..<k, with: r.bytes(k))
                }
            case "MDAT0001":
                for _ in 0..<Int(r.u16()) {
                    let bone = Int(r.u16()), name = r.cstr()
                    var m = [Float](repeating: 0, count: 16)
                    for i in 0..<16 { m[i] = r.f32() }
                    attachments.append((bone, name, m))
                }
            default: break
            }
            guard next > r.offset || next == r.offset, next <= data.count else { break }
            r.offset = next
        }
    }

    mutating func parseSkeleton(_ r: inout MdlReader, _ sv: Int) -> (Int, Int) {
        let nb = Int(r.u32())
        guard nb <= 128 else { return (0, 0) }
        bones.removeAll()
        handles.removeAll()
        for _ in 0..<nb {
            let name = r.cstr()
            let bflags = r.u32()
            let parent = r.u32()
            // Sized copy 0x1400d3ef0 (cap 64): `u32 n` then min(n, 64) bytes, cursor += min(n, 64); bytes not copied keep the
            // bone ctor's identity (0x14026b892). When fewer than 68 bytes remain, nothing is read and the matrix is zeroed.
            var m: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            if r.remaining >= 68 {
                let n = Int(Int32(bitPattern: r.u32()))
                if n < 0 { m = [Float](repeating: 0, count: 16) }
                let k = max(0, min(n, 64))
                let start = r.offset
                for i in 0..<(k / 4) { m[i] = r.f32() }
                if k % 4 != 0 {
                    // A partial float keeps its low bytes from the file and its high bytes from the identity value.
                    var bits = m[k / 4].bitPattern
                    for b in 0..<(k % 4) { bits = (bits & ~(0xff << (8 * UInt32(b)))) | UInt32(r.data[r.data.startIndex + start + (k / 4) * 4 + b]) << (8 * UInt32(b)) }
                    m[k / 4] = Float(bitPattern: bits)
                }
                r.offset = start + k
            } else {
                m = [Float](repeating: 0, count: 16)
            }
            let phys = r.cstr()
            bones.append(Bone(name: name, parent: parent == 0xFFFF_FFFF ? -1 : Int(parent), localBind: m,
                              flags: bflags, physicsJSON: phys))
        }
        boneConstraints = Array(repeating: [], count: bones.count)
        boneChain = Array(repeating: -1, count: bones.count)
        guard sv >= 2 else { return (0, 0) }
        func mat16() -> [Float] { (0..<16).map { _ in r.f32() } }
        // Handles (0x1402625d0–0x1402626fe).
        let nh = Int(r.u16())
        for _ in 0..<nh {
            let name = r.cstr(), bone = Int(r.u32()), type = r.u32()
            handles.append(Handle(name: name, bone: bone, type: type, matrix: mat16()))
        }
        if r.u8() != 0 {
            bindOverrideBones = (0..<nb).map { _ in mat16() }
            bindOverrideHandles = (0..<nh).map { _ in mat16() }
        }
        // Constraints (0x14026284c–0x1402629fc): `u32 owner; u32 a; u32 b; [sv ≥ 4: u32 flags]; [flags & 2: f32 f0, f1]`,
        // f1 = f1 > FLT_EPSILON ? f1 : FLT_EPSILON. Owner without flags bit 1 → bone +0xd8; else → the first handle of
        // that bone with type 0 (+0x68), dropped when there is none.
        let nc = Int(r.u32())
        constraintCount = nc
        for _ in 0..<nc {
            let owner = Int(r.u32()), a = Int(r.u32()), b = Int(r.u32())
            let fl = sv >= 4 ? r.u32() : 0
            var f0: Float = 0, f1: Float = 0
            if fl & 2 != 0 {
                f0 = r.f32(); f1 = r.f32()
                if !(f1 > 1.1920929e-07) { f1 = 1.1920929e-07 }
            }
            let c = Constraint(flags: fl, a: a, b: b, f0: f0, f1: f1)
            guard owner < bones.count else { continue }
            if bones[owner].flags & 2 == 0 {
                boneConstraints[owner].append(c)
            } else if let h = handles.firstIndex(where: { $0.bone == owner && $0.type == 0 }) {
                handles[h].constraints.append(c)
            }
        }
        // nD block (0x140262a05–0x140262bea): `u16 nD; nD × u32` segment lengths (raw float bits), then per bone
        // `u16 c; c × {u32 child; f32[3] direction}`.
        let nd = Int(r.u16())
        segmentLength = (0..<nd).map { _ in r.f32() }
        restDirections = (0..<nd).map { _ in
            var m: [Int: SIMD3<Float>] = [:]
            for _ in 0..<Int(r.u16()) {
                let child = Int(r.u32())
                m[child] = SIMD3(r.f32(), r.f32(), r.f32())
            }
            return m
        }
        // IK block (0x140262bea–0x14026341e): `u16 nChains`; per chain `u32 bone; u32 nH; nH × u32 handle; u16 nEntries`;
        // per entry `u32 root; u16 nLinks`; per link `u32 bone; u32 flags; f32 maxd; f32 mind; u16 n; n × u32`.
        // Handles without constraints are not kept; a link with flags & 4 sets chain flags bit 0.
        let nChains = Int(r.u16())
        for ci in 0..<nChains {
            let bone = Int(r.u32())
            if bone < boneChain.count { boneChain[bone] = ci }
            var hs: [Int] = []
            for _ in 0..<Int(r.u32()) {
                let h = Int(r.u32())
                if h < handles.count, !handles[h].constraints.isEmpty { hs.append(h) }
            }
            var entries: [IKEntry] = []
            var cflags: UInt32 = 0
            for _ in 0..<Int(r.u16()) {
                let root = Int(r.u32())
                var links: [IKLink] = []
                for _ in 0..<Int(r.u16()) {
                    let lb = Int(r.u32()), lf = r.u32(), maxd = r.f32(), mind = r.f32()
                    let list = (0..<Int(r.u16())).map { _ in Int(r.u32()) }
                    if lf & 4 != 0 { cflags |= 1 }
                    links.append(IKLink(bone: lb, flags: lf, maxd: maxd, mind: mind, list: list))
                }
                entries.append(IKEntry(bone: root, links: links))
            }
            ikChains.append(IKChain(bone: bone, entries: entries, handles: hs, flags: cflags))
        }
        // Cursor hit boxes (`Mdl_Load` 0x14026343e–0x1402635f5 → mdl +0x1a0) and their test order (0x14026361b–0x1402637aa,
        // each clamped to nb − 1 → mdl +0x1d0), read by the image hit test 0x1401fd690.
        if r.u8() != 0 {
            hitBoxes = (0..<nb).map { _ in
                let e = SIMD3<Float>(r.f32(), r.f32(), r.f32())
                return (e, (0..<16).map { _ in r.f32() })
            }
        }
        if r.u8() != 0 { hitOrder = (0..<nb).map { _ in min(Int(r.u32()), max(nb - 1, 0)) } }
        if sv >= 3, r.u8() != 0 { drawOrderBase = (0..<nb).map { _ in Int32(bitPattern: r.u32()) } }
        return (nh, nc)
    }

    /// MDMP0001 (`Mdl_Load` 0x140261880): per mesh `u16 n; if n: f32 scale; u32 nv; n × {u64 id; cstr name;
    /// blob pos (nv·6); [mflags&0x400: blob nv·6]; [&0x800: blob nv·6]; [&0x1000: blob nv·2];
    /// [&0x2000: u32 flags, u32 bone, f32, f32]}` (docs/re/06 §1.6).
    mutating func parseMorphs(_ r: inout MdlReader) {
        for i in meshes.indices {
            let n = Int(r.u16())
            guard n > 0 else { continue }
            meshes[i].morphScale = r.f32()
            var nv = Int(r.u32())
            let fl = meshes[i].flags
            func i16(_ d: Data) -> [Int16] { d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
            for _ in 0..<n {
                let id = r.u64(), name = r.cstr()
                var t = MorphTarget(id: id, name: name)
                let pos = r.blob()
                // 0x14026578f–0x1402657a4: mesh +0x64 = min(nv, size/6) after every target (the size must then be
                // exactly 6·nv, else fast-fail).
                nv = min(nv, pos.count / 6)
                t.positions = i16(pos)
                if fl & 0x400 != 0 { t.normals = i16(r.blob()) }
                if fl & 0x800 != 0 { t.extra = i16(r.blob()) }
                if fl & 0x1000 != 0 { t.alpha = r.blob().withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) } }
                if fl & 0x2000 != 0 {
                    // 0x14026583b–0x14026586d: u32 bone (+0x34, checked < bone count, 0x140265882), u32 flags (+0x30),
                    // f32, f32 (+0x38/+0x3c), in that file order.
                    t.modifierBone = Int(r.u32()); t.modifierFlags = r.u32()
                    t.modifierRange = SIMD2(r.f32(), r.f32())
                }
                meshes[i].morphTargets.append(t)
            }
            meshes[i].morphVertexCount = nv
        }
    }

    mutating func parseAnimations(_ r: inout MdlReader, _ sv: Int, handles: Int, constraints: Int) {
        let na = Int(Int32(bitPattern: r.u32()))
        for _ in 0..<max(na, 0) {
            let id = r.u64(), name = r.cstr(), mode = r.cstr(), fps = r.f32(), frames = Int(r.u32()), flags = r.u32()
            let nt = Int(r.u32())
            let F = frames + 1
            func floats(_ d: Data) -> [Float] {
                d.count == F * 4 ? d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } : []
            }
            var tracks: [(Bool, [Float])] = []
            var trackFlags: [UInt32] = []
            var aflags = flags
            for ti in 0..<nt {
                var fl = r.u32()
                let d = r.blob()
                // 0x140263b1d–0x140263b3f: the track of a bone with flags bit 1 (physics/IK driven) and no IK chain
                // (bone +0xd4 = −1) becomes unkeyed: flags | 1, plus | 2 when it was keyed before.
                if ti < bones.count, bones[ti].flags & 2 != 0, ti < boneChain.count, boneChain[ti] < 0 {
                    fl = (fl & 1 != 0 ? fl : fl | 2) | 1
                }
                if fl & 1 != 0 { aflags |= 0x8000_0000 }
                let samples: [Float] = d.count == F * 36 ? d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } : []
                tracks.append((fl & 1 != 0, samples))
                trackFlags.append(fl)
            }
            var blendTracks: [[Float]] = [], alphaTracks: [[Float]] = []
            var handleTracks: [(unkeyed: Bool, samples: [Float])] = []
            var constraintTracks: [(unkeyed: Bool, samples: [Float])] = []
            if sv >= 2 {
                for _ in 0..<handles {
                    let fl = r.u32(), d = r.blob()
                    if fl & 1 != 0 { aflags |= 0x8000_0000 }   // 0x140263df0
                    handleTracks.append((fl & 1 != 0, d.count == F * 36 ? d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } : []))
                }
                for _ in 0..<constraints { let fl = r.u32(); constraintTracks.append((fl & 1 != 0, floats(r.blob()))) }
            }
            // The u32 before each float-track blob is skipped unread by `Mdl_Load` (0x140264747, 0x140264907; docs/re/06 §7).
            if sv >= 3 {
                for _ in 0..<Int(r.u32()) { _ = r.u32(); blendTracks.append(floats(r.blob())) }
                if r.u8() != 0 { for _ in 0..<nt { _ = r.u32(); alphaTracks.append(floats(r.blob())) } }
            }
            var morphTracks: [[(index: Int, samples: [Float])]?] = []
            if sv >= 4, r.u8() != 0 {
                for _ in meshes {
                    guard r.u32() & 1 != 0 else { morphTracks.append(nil); continue }
                    _ = r.f32()
                    var list: [(index: Int, samples: [Float])] = []
                    for _ in 0..<Int(r.u16()) { let k = Int(r.u16()); list.append((k, floats(r.blob()))) }
                    morphTracks.append(list)
                }
            }
            var abMin = SIMD3<Float>(repeating: 0), abMax = SIMD3<Float>(repeating: 0)
            if sv >= 5 { abMin = SIMD3(r.f32(), r.f32(), r.f32()); abMax = SIMD3(r.f32(), r.f32(), r.f32()) }
            var orderTracks: [[Float]] = []
            if sv >= 6, r.u8() != 0 { for _ in 0..<nt { _ = r.u32(); orderTracks.append(floats(r.blob())) } }
            var reference: Animation.Reference?
            if flags & 1 != 0 {
                let idx = Int(r.u16()), a = Int(r.u32()), b = Int(r.u32()), root = r.u32(), bone = Int(r.u32())
                reference = Animation.Reference(index: idx, frameA: a, frameB: b, rootFrame: root, bone: bone)
            }
            var events: [(time: Float, json: String)] = []
            for _ in 0..<Int(r.u32()) { let t = r.f32(); events.append((t, r.cstr())) }
            var anim = Animation(id: id, name: name, mode: Animation.Mode(rawValue: mode) ?? .loop, fps: fps,
                                 frames: frames, tracks: tracks)
            anim.trackFlags = trackFlags
            anim.handleTracks = handleTracks
            anim.constraintTracks = constraintTracks
            anim.blendTracks = blendTracks
            anim.alphaTracks = alphaTracks
            anim.morphTracks = morphTracks
            anim.orderTracks = orderTracks
            anim.boundsMin = abMin
            anim.boundsMax = abMax
            anim.events = events
            anim.flags = aflags
            anim.modeName = mode
            // The index must name an animation loaded before this one (mdl +0xc0 vector, any MDLA section; fast-fail at
            // 0x14026519a otherwise); 0x1402655a0 resolves it to a pointer after the section.
            if let ref = reference, ref.index < animations.count { anim.reference = ref }
            animations.append(anim)
        }
    }
}

/// Bounds-checked reader: out-of-range reads return 0 (docs/re/06 §1.1).
struct MdlReader {
    let data: Data
    var offset = 0
    init(_ d: Data) { data = d }
    var remaining: Int { data.count - offset }

    mutating func raw<T: FixedWidthInteger>(_: T.Type) -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { offset = data.count; return 0 }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += n
        return T(littleEndian: v)
    }
    mutating func u8() -> UInt8 { raw(UInt8.self) }
    mutating func u16() -> UInt16 { raw(UInt16.self) }
    mutating func u32() -> UInt32 { raw(UInt32.self) }
    mutating func u64() -> UInt64 { raw(UInt64.self) }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func skip(_ n: Int) { offset = min(data.count, offset + max(n, 0)) }
    mutating func bytes(_ n: Int) -> Data {
        let k = max(0, min(n, remaining))
        defer { offset += k }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + k))
    }
    mutating func blob() -> Data {
        let n = Int(u32())
        guard n <= remaining else { offset = data.count; return Data() }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    mutating func cstr() -> String {
        guard let end = data[offset...].firstIndex(of: 0) else { offset = data.count; return "" }
        defer { offset = end + 1 }
        return String(decoding: data[offset..<end], as: UTF8.self)
    }
}
