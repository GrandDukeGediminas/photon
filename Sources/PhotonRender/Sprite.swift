import Foundation
import Metal
import PhotonCore
import simd

/// A `sprite` object (`Scene_CreateObject` 0x14018ff60 → 0x270 bytes, ctor 0x140256560, vtable 0x140491680, type 3):
/// a camera-facing billboard faded by an occlusion query, e.g. the sun of def:ricepod.
///
/// Ctor: material = the `sprite` path (+0x240, MaterialMgr_Load 0x14014ff70); a 4-vertex mesh (+0x248, renderer vt+0x40):
/// every position is (−1, 0, 1), texcoords (0,0) (1,0) (1,1) (0,1), indices 0,1,2, 0,2,3 (vertex data 0x140492b60…,
/// index words at rsp+0x50); `materials/util/occlusiontest.json` (+0x250); an occlusion query (+0x258, renderer
/// vt+0x80 0x14009ae40 → CreateQuery(D3D11_QUERY_OCCLUSION)). Load is only `Object_LoadParent` (group vt+0x40), and the
/// reflected table is the plain object table, so a sprite has no `visible` key of its own.
///
/// Render (vt+0x50 0x140256780), only in passes with C+0x12eb == 2 (not the shadow caster pass):
/// * n = the query's samples (vt+0x18 0x1400f0090, GetData of the last completed test, 0 before one exists);
///   v = min(((n / 2) / (1 << C+0x1a8)) / (C+0x78)² · 512, 1) — C+0x1a8 the MSAA shift, C+0x78 the target height.
/// * push model, translation row cleared (rotation/scale kept); g_ViewRight (C+0x16c) and g_ViewUp (C+0x178) × 2v,
///   g_Alpha (C+0x120) = v²; draw the sprite material.
/// * once per frame (C+0x144 frame counter vs +0x260): g_ViewRight/Up = original × 0.2, begin query (colour writes off,
///   0x1400f0000), draw occlusiontest, end query.
/// * restore the view vectors, pop model.
/// The billboard comes from the material's vertex shader (`a_Position + (ViewRight·(u−½) + ViewUp·(v−½))·½`).
final class SpriteObject: SceneObject {
    let material: Material
    let occlusionMaterial: Material
    let mesh = Mesh(layout: .quad, vertices: [-1, 0, 1, 0, 0, -1, 0, 1, 1, 0, -1, 0, 1, 1, 1, -1, 0, 1, 0, 1],
                    indices: [0, 1, 2, 0, 2, 3], vertexCount: 4)
    private var query: MTLBuffer?
    private var queried = false
    private var lastQueryFrame = -1
    private var frameCounter = 0

    init(json: [String: Any], id: Int, resources: SceneResources) {
        material = resources.material((json["sprite"] as? String) ?? "")
        occlusionMaterial = resources.material("materials/util/occlusiontest.json")
        query = resources.device.makeBuffer(length: 8, options: .storageModeShared)
        query.map { memset($0.contents(), 0, 8) }
        super.init(json: json, id: id)
    }

    /// GetData: the samples of the last query (the buffer is read on the CPU while this frame records).
    private var samples: UInt64 { queried ? (query?.contents().load(as: UInt64.self) ?? 0) : 0 }

    override func update(_ dt: Float) {
        super.update(dt)
        frameCounter += 1
    }

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        let target = ctx.current
        let shift = target.sampleCount > 1 ? Int(log2(Double(target.sampleCount))) : 0
        let h = Float(target.height)
        let n = Int64(bitPattern: samples)
        var v = min(Float((n / 2) / Int64(1 << shift)) / (h * h) * 512, 1)
        if let d = ProcessInfo.processInfo.environment["PHOTON_SPRITEDEBUG"] {
            NSLog("sprite %d samples %lld v %.3f", id, n, v)
            if let f = Float(d) { v = f }
        }

        let saved = frame.model
        var m = frame.model
        m.columns.3 = SIMD4(0, 0, 0, 1)
        frame.model = m
        defer { frame.model = saved }
        var u = frame.builtins(color: SIMD3(1, 1, 1), alpha: v * v, target: target)
        let right: [Float], up: [Float]
        if case .floats(let r)? = u["g_ViewRight"], case .floats(let w)? = u["g_ViewUp"] { right = r; up = w } else { right = [1, 0, 0]; up = [0, 1, 0] }
        u["g_ViewRight"] = .floats(right.map { $0 * 2 * v })
        u["g_ViewUp"] = .floats(up.map { $0 * 2 * v })
        ctx.draw(material: material, mesh: mesh, uniforms: u, textures: [:], blend: BlendState(mode: material.blendMode))

        // One occlusion test per frame (+0x260 vs C+0x144).
        guard lastQueryFrame != frameCounter, let q = query else { return }
        lastQueryFrame = frameCounter
        u["g_ViewRight"] = .floats(right.map { $0 * 0.2 })
        u["g_ViewUp"] = .floats(up.map { $0 * 0.2 })
        ctx.endEncoder()
        ctx.visibilityBuffer = q
        let e = ctx.renderEncoder()
        e.setVisibilityResultMode(.counting, offset: 0)
        ctx.draw(material: occlusionMaterial, mesh: mesh, uniforms: u, textures: [:],
                 blend: BlendState(mode: occlusionMaterial.blendMode, colorWrite: false))
        e.setVisibilityResultMode(.disabled, offset: 0)
        ctx.endEncoder()
        ctx.visibilityBuffer = nil
        queried = true
    }
}
