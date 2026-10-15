import Foundation
import JavaScriptCore
import simd

/// `imageLayer.transformAttachmentToTexture(layer, attachment)` → Mat3 (0x1401ed0d0, ev_54ea7d4c…): where an attachment
/// of another object lands in this layer's texture space, as a 2D frame (unit x axis, its normal, origin).
extension SceneScriptEngine {
    /// Object vt+0x80: image and text layers include their alignment offset (0x1401fd3f0, 0x140256e10).
    static func vt80(_ o: SceneObject) -> simd_float4x4 {
        if let i = o as? ImageLayer { return i.layerWorld }
        if let t = o as? TextObject { return t.layerWorld }
        return o.world
    }

    /// Per-object parallax offset (+0x178/+0x17c): the shift the parallax draw list applies to the view for the object's
    /// root (SceneGraph_DrawList 0x14018af5d path, `SceneRenderer.drawObjects`); zero without camera parallax.
    private func parallaxOffset(_ o: SceneObject) -> SIMD2<Float> {
        let s = scene
        guard s.cameraParallax && s.userParallax && s.isOrtho else { return .zero }
        let r = o.root
        return SIMD2(s.parallaxAmount * (r.origin.x - s.parallaxP.x) * r.parallaxDepth.x,
                     s.parallaxAmount * (r.origin.y - s.parallaxP.y) * r.parallaxDepth.y)
    }

    /// 0x140184f00: the perspective push (Camera_PushPerspective's matrices) applied to the current view/projection.
    private func pushedPerspective() -> (simd_float4x4, simd_float4x4) {
        let f = scene.frame
        let v = f.view, p = f.proj
        scene.pushPerspective(f)
        let out = (f.view, f.proj)
        f.view = v; f.proj = p
        return out
    }

    /// glm::unProject with viewport (0, 0, 1, 1) (0x14019df90).
    private static func unproject(_ win: SIMD3<Float>, view: simd_float4x4, proj: simd_float4x4) -> SIMD3<Float> {
        let inv = (proj * view).inverse
        let t = SIMD4<Float>(win.x * 2 - 1, win.y * 2 - 1, win.z * 2 - 1, 1)
        let o = inv * t
        return SIMD3(o.x, o.y, o.z) / o.w
    }

    /// 0x1401edb20: the picking ray through window point `ndc` for layer `t`. With `perspective` (+0x120 & 0x80): the
    /// far point (z = 1) of the given view/projection, from the camera position (inverse view, column 3). Otherwise the
    /// mid point (z = 0.5) of the given view with the context projection C+0x11a0, from the eye C+0x68; ortho scenes
    /// cast straight along +z from 2000 below the eye.
    private func pickRay(_ t: SceneObject, _ ndc: SIMD2<Float>, view: simd_float4x4, proj: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>) {
        if t.perspective {
            let p = Self.unproject(SIMD3(ndc.x, ndc.y, 1), view: view, proj: proj)
            let c = view.inverse.columns.3
            let o = SIMD3(c.x, c.y, c.z)
            let d = p - o
            return (o, d / simd_length(d))
        }
        let p = Self.unproject(SIMD3(ndc.x, ndc.y, 0.5), view: view, proj: scene.frame.proj)
        let eye = scene.frame.eye
        if scene.isOrtho { return (SIMD3(p.x, p.y, eye.z - 2000), SIMD3(0, 0, 1)) }
        let d = p - eye
        return (eye, d / simd_length(d))
    }

    /// 0x1401e5dd0: the ray in the layer's local space against the z = 0 plane (Möller–Trumbore with the triangle
    /// (0,0,0), (1,0,0), (0,1,0) at 0x14019d5a0, both sides; |det| ≤ FLT_EPSILON gives (0, 0)), then
    /// uv = flip · ((p − 0.5) · scale + 0.5) with scale = (1/size.x, −1/size.y) and flip = (1, 1).
    private static func layerUV(_ m: simd_float4x4, _ origin: SIMD3<Float>, _ dir: SIMD3<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        let inv = m.inverse
        let o4 = inv * SIMD4(origin, 1), d4 = inv * SIMD4(dir, 0)
        let o = SIMD3(o4.x, o4.y, o4.z), d = SIMD3(d4.x, d4.y, d4.z)
        let det = -d.z
        var p = SIMD2<Float>(0, 0)
        if abs(det) > Float.ulpOfOne {
            let invDet = 1 / det
            p = SIMD2((o.x * -d.z + o.z * d.x) * invDet, (d.y * o.z - d.z * o.y) * invDet)
        }
        return SIMD2((p.x - 0.5) * (1 / size.x) + 0.5, (p.y - 0.5) * (-1 / size.y) + 0.5)
    }

    func transformAttachmentToTexture(_ t: ImageLayer, _ args: [JSValue]) -> JSValue {
        // The engine dereferences the resolved object without a check; photon returns undefined instead.
        guard let s = resolveLayer(args.first) else { return JSValue(undefinedIn: context) }
        var attach = matrix_identity_float4x4
        if args.count > 1 {
            let a = args[1]
            var idx: Int?
            if a.isNumber { idx = Int(a.toInt32()) } else if a.isString { idx = s.attachmentIndex(a.toString() ?? "") }
            if let idx, let m = s.attachmentTransform(idx) { attach = m }
        }
        let A = Self.vt80(s) * attach
        var view = scene.frame.view, proj = scene.frame.proj
        // Ortho scene and a perspective source: the source's perspective push (0x1401ed259–0x1401ed27a).
        let sPushed = scene.isOrtho && s.perspective
        if sPushed { (view, proj) = pushedPerspective() }
        let ps = parallaxOffset(s)
        let PV = proj * view * Mat.translate(SIMD3(ps.x, ps.y, 0))
        func ndc(_ p: SIMD4<Float>) -> SIMD2<Float> {
            let c = PV * A * p
            return SIMD2(c.x / c.w * 0.5 + 0.5, c.y / c.w * 0.5 + 0.5)
        }
        let n0 = ndc(SIMD4(0, 0, 0, 1)), n1 = ndc(SIMD4(100, 0, 0, 1))
        // This layer's view: its own perspective push when it has the bit (and the source did not already push),
        // otherwise the context view C+0x1160; then its parallax offset (0x1401ed5b3–0x1401ed8dc).
        var tView = scene.frame.view, tProj = proj
        if scene.isOrtho && t.perspective {
            if sPushed { tView = view } else { (tView, tProj) = pushedPerspective() }
        }
        let pt = parallaxOffset(t)
        tView = tView * Mat.translate(SIMD3(pt.x, pt.y, 0))
        let r0 = pickRay(t, n0, view: tView, proj: tProj), r1 = pickRay(t, n1, view: tView, proj: tProj)
        let W = Self.vt80(t)
        let uv0 = Self.layerUV(W, r0.0, r0.1, size: t.size), uv1 = Self.layerUV(W, r1.0, r1.1, size: t.size)
        var d = uv1 - uv0
        let len = simd_length(d)
        d = len > Float.ulpOfOne ? d / len : .zero
        return jsMk(10, [d.x, d.y, 0, d.y, -d.x, 0, uv0.x, uv0.y, 1])
    }
}
