import Foundation
import Metal
import PhotonCore
import simd

/// A `shape` object (`Scene_CreateObject` 0x1401907ca: 0x460 bytes, vtable 0x140491d10, flags304 |= 0x2000, type id 10).
/// The editor's "light shafts" and similar effect-only layers: there is no image, only effects drawn straight into the
/// scene (docs/re/loader-keys.md §4.5).
///
/// - Load (vt+0x40 0x14025fac0): `size` = (C+0x88, C+0x88), the integer authored projection height in both components,
///   then `Layer_LoadEffects` 0x1401e6f50, which runs the reflected loader first (so an object `size` key overrides it)
///   and loads `effects`. The shape table 0x1404e89e0 registers no keys; lookups fall back to the layer and object tables.
/// - Geometry (vt+0x110 0x140260190): from the first pass material of the **first** effect, the constants `point0`…`point3`
///   (`Shape_GetPoint` 0x14025f8a0, value from the material's constant array). Vertex i = (sx·p.x − sx/2,
///   sy·(1 − p.y) − sy/2, 0) with texcoord p, indices 0,2,1, 0,3,2. Missing constants or no effect: a centred quad of
///   `size` (Mesh_CreateQuad flags 1). The bounding radius +0x450 = the largest vertex |xy| (at least 1).
/// - Draw (vt+0x50 0x14025faf0): visible layer (vt+0x68) with a visible parent chain, sphere-culled; push model/view/proj,
///   model = world · model, the perspective push when `perspective` is set, then **every pass of the last effect** through
///   `RunPass(layer, effect, pass, src = −1, final = true)` 0x1401ebf60 (no composite target), pop. The last normal pass
///   blends additively: RunPass calls vt+0x108, which for shapes (0x140260790) sets the material blending to 2.
final class ShapeObject: SceneObject {
    let resources: SceneResources
    var effects: [Effect] = []
    var size: SIMD2<Float>
    var color = SIMD3<Float>(1, 1, 1)
    var alpha: Float = 1
    var mesh: Mesh?

    init(json: [String: Any], id: Int, resources: SceneResources, projectionHeight: Int, nextEffectID: () -> Int) {
        self.resources = resources
        size = SIMD2(repeating: Float(projectionHeight))
        super.init(json: json, id: id)
        size = EngineValue.vec2(json["size"], default: size)
        color = EngineValue.vec3(json["color"], default: color)
        alpha = EngineValue.float(json["alpha"], default: alpha)
        for (ei, e) in ((json["effects"] as? [[String: Any]]) ?? []).enumerated() {
            guard let file = e["file"] as? String else { continue }
            let eid = (e["id"] as? NSNumber)?.intValue ?? nextEffectID()
            guard let effect = Effect(path: file, instance: e, id: eid, scene: resources) else { continue }
            effect.jsonIndex = ei
            effects.append(effect)
        }
        buildGeometry()
    }

    static let layout = VertexLayout(stride: 20, attributes: [.init(id: 0, format: .float3, offset: 0),
                                                              .init(id: 7, format: .float2, offset: 12)])

    func buildGeometry() {
        let sx = size.x, sy = size.y
        var pts: [SIMD2<Float>] = []
        if let m = effects.first?.passes.first?.material {
            for k in ["point0", "point1", "point2", "point3"] {
                guard let v = m.constants[k] else { break }
                pts.append(EngineValue.vec2(v, default: .zero))
            }
        }
        guard pts.count == 4 else {
            mesh = Quad(size: size, textureSize: SIMD2(1, 1), uvScale: SIMD2(1, 1), flags: .centered).mesh
            return
        }
        var v: [Float] = []
        for p in pts { v += [sx * p.x - sx * 0.5, sy * (1 - p.y) - sy * 0.5, 0, p.x, p.y] }
        mesh = Mesh(layout: Self.layout, vertices: v, indices: [0, 2, 1, 0, 3, 2], vertexCount: 4)
    }

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard effectiveVisible, let mesh, let effect = effects.last else { return }
        let m = frame.model, v = frame.view, p = frame.proj
        let W = world
        frame.model = m * W
        if perspective && scene.isOrtho { scene.pushPerspective(frame) }
        frame.setEffectMatrices(world: W, lmvp: frame.proj * frame.view * W, size: size, final: true)
        for (i, pass) in effect.passes.enumerated() where pass.command == .draw {
            guard let M = pass.material else { continue }
            var tex: [Int: BoundTexture] = [:]
            for (slot, name) in M.textureNames where name.hasPrefix("_rt_") {
                if let rt = scene.namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
            }
            // Last normal pass: RunPass calls L.vt108(M); the shape's 0x140260790 sets M.blending = 2 (additive).
            let blend = BlendState(mode: i == effect.lastNormalPass ? .additive : M.blendMode)
            let u = frame.builtins(color: color, alpha: alpha, target: ctx.current)
            ctx.draw(material: M, mesh: mesh, uniforms: u, textures: tex, blend: blend)
        }
        frame.model = m; frame.view = v; frame.proj = p
    }
}
