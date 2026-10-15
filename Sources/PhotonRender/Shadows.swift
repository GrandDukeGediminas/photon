import Foundation
import Metal
import simd

/// Shadow atlas and caster pass (docs/re/06 §6.5b), as `Lights_Update` 0x140190c80 builds them each frame:
/// shadowed lights get a record (light, tile size 0x14025d3e0, projection +0x338, point flag, feature slot), the records
/// are sorted (0x14019e660, comparator 0x140186c60: key = point·2¹⁵ + tile size, descending), packed into
/// `_rt_shadowAtlas` (0x1401935dc–0x1401939ed), and every record's views are rendered by `Shadow_RenderView` 0x140196530
/// with `materials/util/shadowcaster.json`, instanced once per view into a viewport array.
///
/// Implemented: point lights (one tile, six faces in a 2×3 grid) and spot lights (one tile, one view). Directional
/// cascades are not.
final class ShadowMaps {
    /// `C+0x1ac` (app setting `shadows`).
    let quality: Int
    private(set) var atlas: MTLTexture?
    private var dummyColor: MTLTexture?
    private var sampler: MTLSamplerState?
    /// `C+0x408`: (size, x, y) of each record from the last packing; reused while the sizes match (0x140193615).
    private var cache: [(size: Int, x: Int, y: Int)] = []
    private var materials: [String: Material] = [:]

    struct Record {
        let light: LightObject
        /// Tile size (record +0x48).
        let size: Int
        /// Record +0x54 bit 0: point light (six faces).
        let point: Bool
        /// Light +0x338, column-vector form.
        let projection: simd_float4x4
        /// Index into `g_LFeature_ShadowPointProjectionTransform` (the slot pointer at record +0x58).
        let feature: Int
        var x = 0, y = 0
    }

    init(quality: Int) { self.quality = quality }

    /// `Light_ShadowTileSize` 0x14025d3e0: 0x100 at shadow quality 1–2, 0x200 at 3, 0x400 at 4.
    static func tileSize(_ quality: Int) -> Int { quality >= 4 ? 1024 : quality == 3 ? 512 : 256 }

    /// `Light_BuildShadowProjection` 0x14025d420, point branch (0x14025d9c1): fov 94° at quality 1–2, 92° at 3, 91.2°
    /// otherwise, aspect 1, near = 1 in ortho scenes else max(0.05, lightsourcesize), far = max(radius, near + 0.01),
    /// through renderer vt+0x10 (reverse-Z PerspectiveFovRH).
    static func pointProjection(_ light: LightObject, quality: Int, ortho: Bool) -> simd_float4x4 {
        let fov: Float = (quality == 1 || quality == 2) ? 94 : quality == 3 ? 92 : 91.2
        let zn: Float = ortho ? 1 : max(0.05, light.lightSourceSize)
        let zf = max(light.radius, zn + 0.01)
        return Mat.perspectiveRHReversed(fovY: fov * .pi / 180, aspect: 1, zn: zn, zf: zf)
    }

    /// `Light_BuildShadowProjection` 0x14025d420, spot branch (0x14025d451–0x14025d988): the view is the inverse of the light
    /// world with its axes renormalised (rsqrt + one Newton step), arranged so the camera looks along world row 0 (the spot
    /// direction): view columns = (n2, n1, −n0), translation (−t·n2, −t·n1, t·n0). Projection: fov = 2·outercone°, aspect 1,
    /// near = 1 in ortho scenes else 0.05, far = max(radius, near + 0.01), renderer vt+0x10 (reverse-Z). +0x338 = view × proj.
    static func spotViewProjection(_ light: LightObject, ortho: Bool) -> simd_float4x4 {
        let w = light.world
        let (n0, n1, n2) = renormalisedAxes(w)
        let t = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
        // Column-vector form: rows of the column-vector matrix = columns of the engine's row-vector view.
        let view = simd_float4x4(rows: [SIMD4(n2, -simd_dot(t, n2)), SIMD4(n1, -simd_dot(t, n1)),
                                        SIMD4(-n0, simd_dot(t, n0)), SIMD4(0, 0, 0, 1)])
        let zn: Float = ortho ? 1 : 0.05
        let zf = max(light.radius, zn + 0.01)
        let proj = Mat.perspectiveRHReversed(fovY: 2 * light.outerCone * 0.0174533, aspect: 1, zn: zn, zf: zf)
        return proj * view
    }

    /// The engine's inverse square root: magic 0x5f375a86 and one Newton step `r·(1.5 − 0.5·x·r²)` (max error ≈ 0.17%).
    static func fastRsqrt(_ x: Float) -> Float {
        let r = Float(bitPattern: 0x5f375a86 &- (x.bitPattern >> 1))
        return r * (1.5 - 0.5 * x * r * r)
    }

    /// World rows 0–2 (simd columns), each scaled by `fastRsqrt` of its squared length, as the light view builders do.
    static func renormalisedAxes(_ w: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        func n(_ c: SIMD4<Float>) -> SIMD3<Float> { let v = SIMD3(c.x, c.y, c.z); return v * fastRsqrt(simd_dot(v, v)) }
        return (n(w.columns.0), n(w.columns.1), n(w.columns.2))
    }

    /// Directional cascades (`Lights_Update` 0x14019123d–0x140192a0e; reproduced in an emulator against the binary,
    /// docs/re/06 §6.5e). Per cascade i with extents (w, d) = (cd0, 4·cd1), (cd1, 4·cd1), (cd2, max(1.5·cd2, 4·cd1))
    /// (0x14025d370): the camera forward (C+0x160) loses half of its component along the normalised light row 0; the centre
    /// is eye (C+0x68) + forward'·w/2 (z = 0 in ortho scenes, 0x14017e910); it is snapped by subtracting
    /// row1·fmod(c·row1, w/tile) and row2·fmod(c·row2, w/tile) with the raw world rows (the second fmod uses the
    /// unsnapped centre); the view is the inverse of the renormalised light basis at that centre, columns (n2, n1, −n0);
    /// the projection is OrthoOffCenterLH(±w/2, ±w/2, −d/2, d/2) (renderer vt+0x18). Returns column-vector P·V.
    static func cascadeViewProjections(_ light: LightObject, tile: Int, ortho: Bool, eye: SIMD3<Float>,
                                       viewForward: SIMD3<Float>) -> [simd_float4x4] {
        let w = light.world
        let r0 = SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z)
        let r1 = SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z), r2 = SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z)
        let (n0, n1, n2) = renormalisedAxes(w)
        let cd = light.cascadeDistances
        let extents: [(Float, Float)] = [(cd.x, 4 * cd.y), (cd.y, 4 * cd.y), (cd.z, max(1.5 * cd.z, 4 * cd.y))]
        let dl = simd_length(r0) > 0 ? simd_normalize(r0) : r0
        let fwd = viewForward - dl * (simd_dot(viewForward, dl) * 0.5)
        return extents.map { (ext, depth) in
            let h = ext * 0.5, hd = depth * 0.5
            var c = eye + fwd * h
            if ortho { c.z = 0 }
            let texel = ext / Float(tile)
            let d2 = simd_dot(c, r2)
            c -= r1 * fmodf(simd_dot(c, r1), texel)
            c -= r2 * fmodf(d2, texel)
            let view = simd_float4x4(rows: [SIMD4(n2, -simd_dot(c, n2)), SIMD4(n1, -simd_dot(c, n1)),
                                            SIMD4(-n0, simd_dot(c, n0)), SIMD4(0, 0, 0, 1)])
            let proj = Mat.orthoLH(l: -h, r: h, b: -h, t: h, zn: -hd, zf: hd)
            return proj * view
        }
    }

    /// Light +0x320 = (M22, M32, M23, M33) of the row-vector projection (0x14019337e–0x140193472); M[r][c] is simd P[r][c].
    static func pointProjectionInfo(_ p: simd_float4x4) -> [Float] { [p[2][2], p[3][2], p[2][3], p[3][3]] }

    /// Packs the records and sizes the atlas. Returns false when there is nothing to render (0x1401935f4).
    func pack(_ records: inout [Record], device: MTLDevice) -> Bool {
        guard !records.isEmpty else { return false }
        // std::sort with 0x140186c60; ties keep their order here.
        let order = records.indices.sorted { a, b in
            let ka = (records[a].point ? 1 << 15 : 0) + records[a].size, kb = (records[b].point ? 1 << 15 : 0) + records[b].size
            return ka != kb ? ka > kb : a < b
        }
        records = order.map { records[$0] }
        var maxX = 0, maxY = 0
        if cache.count == records.count && zip(cache, records).allSatisfy({ $0.size == $1.size }) {
            for i in records.indices {
                records[i].x = cache[i].x; records[i].y = cache[i].y
                maxX = max(maxX, records[i].x + records[i].size); maxY = max(maxY, records[i].y + records[i].size)
            }
        } else {
            // Shelf/skyline packer 0x1401936f8–0x1401939ed. Segments are (x0, x1, y, top), starting with
            // (0, 0x2000, 0, 0). For each record (size s), walk the segments in order: top = max(top, y + s); if the
            // segment is at least s wide the tile goes at (x0, y), the segment's x0 advances by s and, when its height
            // (top − y) exceeds s, a segment (x0, x0 + s, y + s, top) is appended; otherwise a new shelf
            // (0, 0x2000, top, top) is appended and the walk continues.
            struct Seg { var x0: Int, x1: Int, y: Int, top: Int }
            var segs = [Seg(x0: 0, x1: 0x2000, y: 0, top: 0)]
            cache = []
            for r in records.indices {
                let s = records[r].size
                var i = 0
                while i < segs.count {
                    segs[i].top = max(segs[i].top, segs[i].y + s)
                    let height = segs[i].top - segs[i].y
                    if segs[i].x1 - segs[i].x0 >= s && height >= s {
                        let x = segs[i].x0, y = segs[i].y
                        records[r].x = x; records[r].y = y
                        cache.append((s, x, y))
                        maxX = max(maxX, x + s); maxY = max(maxY, y + s)
                        segs[i].x0 = x + s
                        if height > s { segs.append(Seg(x0: x, x1: x + s, y: y + s, top: segs[i].top)) }
                        break
                    }
                    segs.append(Seg(x0: 0, x1: 0x2000, y: segs[i].top, top: segs[i].top))
                    i += 1
                }
            }
        }
        // `_rt_shadowAtlas` (0x140193893): at least 2×2; an existing atlas only grows (0x1401939c2–0x1401939d8).
        let w = max(2, maxX), h = max(2, maxY)
        if atlas == nil || atlas!.width < w || atlas!.height < h {
            let nw = max(w, atlas?.width ?? 0), nh = max(h, atlas?.height ?? 0)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: nw, height: nh, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            atlas = device.makeTexture(descriptor: d)
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: nw, height: nh, mipmapped: false)
            c.usage = [.renderTarget]
            c.storageMode = .private
            dummyColor = device.makeTexture(descriptor: c)
        }
        return true
    }

    /// The atlas with its sampler (0x140099980, flags 0x8000008): COMPARISON_MIN_MAG_LINEAR_MIP_POINT, BORDER (0,0,0,0),
    /// ComparisonFunc GREATER.
    func bound(device: MTLDevice) -> BoundTexture? {
        guard let a = atlas else { return nil }
        if sampler == nil {
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .notMipmapped
            s.sAddressMode = .clampToBorderColor; s.tAddressMode = .clampToBorderColor; s.rAddressMode = .clampToBorderColor
            s.borderColor = .transparentBlack
            s.compareFunction = .greater
            sampler = device.makeSamplerState(descriptor: s)
        }
        return BoundTexture(texture: a, sampler: sampler!)
    }

    /// Atlas transform (x/W, y/H, s/W, s/H) with the atlas's current size (0x1401960b1–0x140196114).
    func transform(_ r: Record) -> SIMD4<Float> {
        guard let a = atlas else { return SIMD4(0, 0, 1, 1) }
        let w = Float(a.width), h = Float(a.height), s = Float(r.size)
        return SIMD4(Float(r.x) / w, Float(r.y) / h, s / w, s / h)
    }

    /// Face view matrices of a point light, row-vector rows as `CalculateProjectedCoordsPoint` (engine common_pbr_2.h)
    /// reads them back: +X, −X, +Y, −Y, +Z, −Z, the order of the six viewports at 0x14019611b–0x140196234.
    static func pointFaceViews(_ o: SIMD3<Float>) -> [simd_float4x4] {
        func rows(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ c: SIMD4<Float>, _ d: SIMD4<Float>) -> simd_float4x4 {
            // Column-vector form = transpose of the row-vector matrix: its columns are the row-vector rows.
            simd_float4x4(columns: (a, b, c, d))
        }
        return [
            rows([0, 0, -1, 0], [0, 1, 0, 0], [1, 0, 0, 0], [-o.z, -o.y, o.x, 1]),
            rows([0, 0, 1, 0], [0, 1, 0, 0], [-1, 0, 0, 0], [o.z, -o.y, -o.x, 1]),
            rows([1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0], [-o.x, -o.z, o.y, 1]),
            rows([1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0], [-o.x, o.z, -o.y, 1]),
            rows([-1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1, 0], [o.x, -o.y, o.z, 1]),
            rows([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [-o.x, -o.y, -o.z, 1]),
        ]
    }

    /// Material_Apply 0x14015653e / 0x140156c7e: `materials/util/shadowcaster.json` with the variant's combos and the
    /// program named by the mesh shader's `[PASS] shadow` line (`shadowcaster` without one).
    private func casterMaterial(_ combos: [String: Int], _ shader: String, _ scene: SceneRenderer) -> Material {
        let key = shader + combos.sorted { $0.key < $1.key }.description
        if let m = materials[key] { return m }
        let m = scene.resources.material("materials/util/shadowcaster.json", override: ["combos": combos, "shader": shader])
        materials[key] = m
        return m
    }

    /// Clears the atlas (depth 0 = far, reverse-Z) and renders every record (`Shadow_RenderView` 0x140196530: depth-bias
    /// rasterizer state on via renderer vt+0xa0, `C+0x12eb = 0` so only opaque meshes draw, instance count = view count
    /// via vt+0x150, `SceneGraph_DrawList(mode 2)` = objects with `+0x120 & 0xc00 == 0xc00`).
    func render(_ records: [Record], _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard let atlas, let dummyColor, !records.isEmpty else { return }
        let casters = scene.objects.compactMap { $0 as? ModelObject }.filter { $0.effectiveVisible && $0.castsShadow }
        ctx.attachDepth(atlas, to: dummyColor, clear: true)
        ctx.bind(dummyColor)
        _ = ctx.renderEncoder()   // the clear happens even with no casters
        for r in records where r.point {
            // Light +0x338 copied into the record, M32 −= 0.00333 for the caster pass (0x140193b44–0x140193b64).
            var p = r.projection
            p[3][2] -= 0.00333
            let o = r.light.worldPosition
            let vps = Self.pointFaceViews(o).map { p * $0 }
            // Viewports (0x14019611b–0x140196234): s/2 × ⌊s/3⌋ faces at (x, y), (x + s/2, y), (x, y + t), …
            let hw = r.size / 2, th = r.size / 3
            let vp = (0..<6).map { i in
                MTLViewport(originX: Double(r.x + (i % 2) * hw), originY: Double(r.y + (i / 2) * th),
                            width: Double(hw), height: Double(th), znear: 0, zfar: 1)
            }
            var packed: [Float] = []
            for m in vps { for row in 0..<4 { for col in 0..<4 { packed.append(m[col][row]) } } }
            for c in casters { c.renderShadowCaster(ctx, frame, scene, viewProjections: packed, viewports: vp, material: casterMaterial) }
        }
        // Spot (and directional) records: one view each, the record matrix with M32 −= 0.0005 (0x14019632a) and viewport
        // (x, y, s, s), flushed to Shadow_RenderView in batches of six (0x140196248–0x14019637e).
        let others = records.filter { !$0.point }
        for batch in stride(from: 0, to: others.count, by: 6) {
            var packed: [Float] = []
            var vp: [MTLViewport] = []
            for r in others[batch..<min(batch + 6, others.count)] {
                var p = r.projection
                p[3][2] -= 0.0005
                for row in 0..<4 { for col in 0..<4 { packed.append(p[col][row]) } }
                vp.append(MTLViewport(originX: Double(r.x), originY: Double(r.y), width: Double(r.size), height: Double(r.size), znear: 0, zfar: 1))
            }
            for c in casters { c.renderShadowCaster(ctx, frame, scene, viewProjections: packed, viewports: vp, material: casterMaterial) }
        }
        ctx.unbind()
    }
}

extension LightObject {
    var worldPosition: SIMD3<Float> { let w = world; return SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z) }
}
